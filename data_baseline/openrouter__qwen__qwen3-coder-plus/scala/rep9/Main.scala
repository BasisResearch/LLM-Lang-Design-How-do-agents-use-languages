//> using scala "2.13"
//> using dep "org.http4s::http4s-dsl::0.23.27"
//> using dep "org.http4s::http4s-blaze-server::0.23.17"
//> using dep "org.http4s::http4s-circe::0.23.27"
//> using dep "io.circe::circe-generic::0.14.7"
//> using dep "io.circe::circe-parser::0.14.7"
//> using dep "org.typelevel::cats-effect::3.5.4"

import cats.effect._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.implicits._
import org.http4s.circe.CirceEntityEncoder._
import org.http4s.circe.CirceEntityDecoder._

import io.circe.generic.semiauto._
import io.circe.syntax._
import io.circe.Encoder  
import io.circe.Decoder

import scala.collection.mutable
import java.time.Instant
import java.util.UUID

case class User(id: Int, username: String)
case class Todo(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String)
case class LoginRequest(username: String, password: String)
case class RegisterRequest(username: String, password: String)
case class ChangePasswordRequest(old_password: String, new_password: String)
case class CreateTodoRequest(title: String, description: String)
case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
case class ApiError(error: String)

object Main extends IOApp with Http4sDsl[IO] {
  implicit val userEncoder: Encoder[User] = deriveEncoder[User]
  implicit val userDecoder: Decoder[User] = deriveDecoder[User]
  implicit val todoEncoder: Encoder[Todo] = deriveEncoder[Todo]
  implicit val todoDecoder: Decoder[Todo] = deriveDecoder[Todo]
  implicit val loginRequestDecoder: Decoder[LoginRequest] = deriveDecoder[LoginRequest]
  implicit val registerRequestDecoder: Decoder[RegisterRequest] = deriveDecoder[RegisterRequest]
  implicit val changePasswordRequestDecoder: Decoder[ChangePasswordRequest] = deriveDecoder[ChangePasswordRequest]
  implicit val createTodoRequestDecoder: Decoder[CreateTodoRequest] = deriveDecoder[CreateTodoRequest]
  implicit val updateTodoRequestDecoder: Decoder[UpdateTodoRequest] = deriveDecoder[UpdateTodoRequest]
  implicit val apiErrorEncoder: Encoder[ApiError] = deriveEncoder[ApiError]

  class TodoService {
    private var userIdCounter = 0
    private var todoIdCounter = 0

    private val users = mutable.Map[Int, (User, String)]() // user id -> (user, hashed password)
    private val sessions = mutable.Map[String, Int]() // session id -> user id
    private val userTodos = mutable.Map[Int, List[Int]]() // user id -> list of todo ids
    private val todos = mutable.Map[Int, Todo]() // todo id -> todo

    def register(username: String, password: String): Either[ApiError, User] = synchronized {
      // Validate username: alphanumeric and underscores only, 3 to 50 chars
      if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
        Left(ApiError("Invalid username"))
      } else if (password.length < 8) {
        Left(ApiError("Password too short"))
      } else if (users.exists(_._2._1.username == username)) {
        Left(ApiError("Username already exists"))
      } else {
        userIdCounter += 1
        val user = User(userIdCounter, username)
        users(userIdCounter) = (user, hashPassword(password))
        userTodos(userIdCounter) = List()
        Right(user)
      }
    }

    def login(username: String, password: String): Either[ApiError, (User, String)] = synchronized {
      val maybeUserAndPass = users.values.find(_._1.username == username)

      maybeUserAndPass match {
        case Some((user, hashedPassword)) if verifyPassword(password, hashedPassword) =>
          val sessionId = UUID.randomUUID().toString
          sessions(sessionId) = user.id
          Right((user, sessionId))
        case _ =>
          Left(ApiError("Invalid credentials"))
      }
    }

    def logout(sessionId: String): Unit = synchronized {
      sessions.remove(sessionId)
    }

    def getCurrentUser(sessionId: String): Option[User] = synchronized {
      sessions.get(sessionId).flatMap(users.get).map(_._1)
    }

    def changePassword(userId: Int, oldPassword: String, newPassword: String): Either[ApiError, Unit] = synchronized {
      users.get(userId) match {
        case Some((user, hashedOldPassword)) =>
          if (!verifyPassword(oldPassword, hashedOldPassword)) {
            Left(ApiError("Invalid credentials"))
          } else if (newPassword.length < 8) {
            Left(ApiError("Password too short"))
          } else {
            users(userId) = (user, hashPassword(newPassword))
            Right(())
          }
        case None =>
          Left(ApiError("Invalid credentials")) // User doesn't exist
      }
    }

    def getUserTodos(userId: Int): List[Todo] = synchronized {
      userTodos.get(userId).getOrElse(Nil).flatMap(todos.get).sortBy(_.id)
    }

    def createTodo(userId: Int, title: String, description: String): Todo = synchronized {
      if (title == null || title.trim.isEmpty) throw new IllegalArgumentException("Title cannot be empty")

      todoIdCounter += 1
      val nowStr = formatDate(Instant.now())
      val todo = Todo(
        id = todoIdCounter,
        title = title.trim,
        description = if (description == null) "" else description.trim,
        completed = false,
        created_at = nowStr,
        updated_at = nowStr
      )

      todos(todoIdCounter) = todo
      userTodos(userId) = userTodos(userId) :+ todoIdCounter
      todo
    }

    def getTodo(userId: Int, todoId: Int): Option[Todo] = synchronized {
      val userTodoIds = userTodos.get(userId).getOrElse(Nil)
      if (userTodoIds.contains(todoId)) todos.get(todoId) else None
    }

    def updateTodo(userId: Int, todoId: Int, updates: UpdateTodoRequest): Either[ApiError, Todo] = synchronized {
      val userTodoIds = userTodos.get(userId).getOrElse(Nil)

      if (!userTodoIds.contains(todoId)) {
        Left(ApiError("Todo not found"))
      } else {
        todos.get(todoId) match {
          case Some(existing) =>
            // Validate title if provided and not empty  
            if (updates.title.exists(title => title != null && title.trim.isEmpty)) {
              Left(ApiError("Title is required"))
            } else {
              val newTitle = updates.title match {
                case Some(t) if t != null => t.trim
                case _ => existing.title
              }

              val newDescription = updates.description match {
                case Some(desc) if desc != null => desc.trim
                case _ => existing.description
              }

              val newCompleted = updates.completed.getOrElse(existing.completed)

              val updatedTodo = existing.copy(
                title = newTitle,
                description = newDescription,
                completed = newCompleted,
                updated_at = formatDate(Instant.now())
              )
              todos(todoId) = updatedTodo
              Right(updatedTodo)
            }
          case None => Left(ApiError("Todo not found"))
        }
      }
    }

    def deleteTodo(userId: Int, todoId: Int): Boolean = synchronized {
      val userTodoIds = userTodos.get(userId).getOrElse(Nil)
      if (userTodoIds.contains(todoId)) {
        todos.remove(todoId)
        userTodos(userId) = userTodoIds.filter(_ != todoId)
        true
      } else {
        false
      }
    }

    private def hashPassword(password: String): String = {
      val md = java.security.MessageDigest.getInstance("SHA-256")
      val hashedBytes = md.digest(password.getBytes("UTF-8"))
      hashedBytes.map("%02x".format(_)).mkString
    }

    private def verifyPassword(password: String, hashed: String): Boolean = {
      hashPassword(password) == hashed
    }

    private def formatDate(instant: Instant): String = {
      // Format to YYYY-MM-DDTHH:MM:SSZ
      instant.toString.take(19) + "Z"
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val port = args.sliding(2, 1).collectFirst { case List("--port", portStr) => portStr.toInt }.getOrElse(8080)

    val service = new TodoService()

    val routes = HttpRoutes.of[IO] {
      // POST /register
      case req @ POST -> Root / "register" =>
        for {
          jsonData <- req.as[RegisterRequest]
          result = service.register(jsonData.username, jsonData.password)
          response <- result match {
            case Right(user) => Created(user.asJson)
            case Left(error) =>
              val status = if (error.error == "Username already exists") Status.Conflict else Status.BadRequest
              Response[IO](status).withEntity(error.asJson)
          }
        } yield response

      // POST /login
      case req @ POST -> Root / "login" =>
        for {
          jsonData <- req.as[LoginRequest]
          result = service.login(jsonData.username, jsonData.password)
          response <- result match {
            case Right((user, sessionId)) =>
              val cookie = org.http4s.headers.`Set-Cookie`(
                org.http4s.headers.Cookie.apply("session_id", sessionId).withPath("/").withSecure(false).withHttpOnly(true)
              )
              Ok(user.asJson).map(_.addCookie(cookie))
            case Left(error) =>
              Unauthorized(error.asJson)
          }
        } yield response

      // POST /logout
      case req @ POST -> Root / "logout" =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.logout(sessionId)
            Ok(io.circe.Json.obj())
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // GET /me
      case req @ GET -> Root / "me" =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) => Ok(user.asJson)
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // PUT /password
      case req @ PUT -> Root / "password" =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                for {
                  jsonData <- req.as[ChangePasswordRequest]
                  result = service.changePassword(user.id, jsonData.old_password, jsonData.new_password)
                  response <- result match {
                    case Right(_) => Ok(io.circe.Json.obj())
                    case Left(error) =>
                      val status = if (error.error == "Password too short") Status.BadRequest else Status.Unauthorized
                      Response[IO](status).withEntity(error.asJson)
                  }
                } yield response
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // GET /todos
      case req @ GET -> Root / "todos" =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                val todos = service.getUserTodos(user.id)
                Ok(todos.asJson)
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // POST /todos
      case req @ POST -> Root / "todos" =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                for {
                  jsonData <- req.as[CreateTodoRequest]
                  result <- IO {
                    if (jsonData.title == null || jsonData.title.trim.isEmpty) {
                      Left(ApiError("Title is required"))
                    } else {
                      Right(service.createTodo(user.id, jsonData.title, jsonData.description))
                    }
                  }
                  response <- result match {
                    case Left(error) => BadRequest(error.asJson)
                    case Right(todo) => Created(todo.asJson)
                  }
                } yield response
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // GET /todos/:id
      case req @ GET -> Root / "todos" / IntVar(id) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                service.getTodo(user.id, id) match {
                  case Some(todo) => Ok(todo.asJson)
                  case None => NotFound(ApiError("Todo not found").asJson)
                }
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // PUT /todos/:id
      case req @ PUT -> Root / "todos" / IntVar(id) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                for {
                  updates <- req.as[UpdateTodoRequest]
                  result = service.updateTodo(user.id, id, updates)
                  response <- result match {
                    case Right(updatedTodo) =>
                      Ok(updatedTodo.asJson)
                    case Left(error) =>
                      BadRequest(error.asJson)
                  }
                } yield response
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }

      // DELETE /todos/:id
      case req @ DELETE -> Root / "todos" / IntVar(id) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            service.getCurrentUser(sessionId) match {
              case Some(user) =>
                val deleted = service.deleteTodo(user.id, id)
                if (deleted) {
                  NoContent() // No body for 204
                } else {
                  NotFound(ApiError("Todo not found").asJson)
                }
              case None => Unauthorized(ApiError("Authentication required").asJson)
            }
          case None => Unauthorized(ApiError("Authentication required").asJson)
        }
    }.orNotFound

    import org.http4s.blaze.server.BlazeServerBuilder

    BlazeServerBuilder[IO]
      .bindHttp(port, "0.0.0.0")
      .withHttpApp(routes)
      .serve
      .compile
      .drain
      .as(ExitCode.Success)
  }

  private def extractSessionId(request: Request[IO]): Option[String] = {
    request.cookies.find(_.name == "session_id").map(_.content)
  }
}