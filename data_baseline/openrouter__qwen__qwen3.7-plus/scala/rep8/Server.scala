//> using scala "2.13.14"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"

import cats.effect._
import cats.syntax.applicative._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.generic.semiauto._

import java.time.{ZoneOffset, ZonedDateTime}
import java.time.format.DateTimeFormatter
import java.util.UUID

object TodoApp extends IOApp {

  case class User(id: Int, username: String)
  case class Todo(
    id: Int,
    userId: Int,
    title: String,
    description: String,
    completed: Boolean,
    createdAt: String,
    updatedAt: String
  )

  case class RegisterReq(username: String, password: String)
  case class LoginReq(username: String, password: String)
  case class UpdatePasswordReq(old_password: String, new_password: String)
  case class CreateTodoReq(title: Option[String], description: Option[String])
  case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

  case class ErrorResponse(error: String)

  implicit val userEncoder: Encoder[User] = deriveEncoder
  implicit val todoEncoder: Encoder[Todo] = deriveEncoder
  implicit val errorResponseEncoder: Encoder[ErrorResponse] = deriveEncoder

  implicit val registerReqDecoder: Decoder[RegisterReq] = deriveDecoder
  implicit val loginReqDecoder: Decoder[LoginReq] = deriveDecoder
  implicit val updatePasswordReqDecoder: Decoder[UpdatePasswordReq] = deriveDecoder
  implicit val createTodoReqDecoder: Decoder[CreateTodoReq] = deriveDecoder
  implicit val updateTodoReqDecoder: Decoder[UpdateTodoReq] = deriveDecoder

  class InMemStore {
    @volatile private var nextUserId = 1
    @volatile private var nextTodoId = 1

    @volatile private var users = Map.empty[Int, (User, String)]
    @volatile private var sessions = Map.empty[String, Int]
    @volatile private var todos = Map.empty[Int, Todo]

    def getCurrentTime(): String = {
      ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    }

    def register(username: String, password: String): Either[ErrorResponse, User] = synchronized {
      if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
        return Left(ErrorResponse("Invalid username"))
      }
      if (password.length < 8) {
        return Left(ErrorResponse("Password too short"))
      }
      if (users.values.exists(_._1.username == username)) {
        return Left(ErrorResponse("Username already exists"))
      }
      val id = nextUserId
      nextUserId += 1
      val user = User(id, username)
      users = users + (id -> (user, password))
      Right(user)
    }

    def login(username: String, password: String): Either[ErrorResponse, (User, String)] = synchronized {
      val userRecord = users.values.find(_._1.username == username)
      userRecord match {
        case Some((user, pwd)) if pwd == password =>
          val token = UUID.randomUUID().toString
          sessions = sessions + (token -> user.id)
          Right((user, token))
        case _ =>
          Left(ErrorResponse("Invalid credentials"))
      }
    }

    def logout(token: String): Unit = synchronized {
      sessions = sessions - token
    }

    def getUserByToken(token: String): Option[User] = synchronized {
      sessions.get(token).flatMap(users.get).map(_._1)
    }

    def updatePassword(userId: Int, oldPassword: String, newPassword: String): Either[ErrorResponse, Unit] = synchronized {
      users.get(userId) match {
        case Some((user, pwd)) if pwd == oldPassword =>
          if (newPassword.length < 8) {
            return Left(ErrorResponse("Password too short"))
          }
          users = users + (userId -> ((user, newPassword)))
          Right(())
        case _ =>
          Left(ErrorResponse("Invalid credentials"))
      }
    }

    def createTodo(userId: Int, title: String, description: String): Todo = synchronized {
      val id = nextTodoId
      nextTodoId += 1
      val now = getCurrentTime()
      val todo = Todo(id, userId, title, description, false, now, now)
      todos = todos + (id -> todo)
      todo
    }

    def getTodos(userId: Int): List[Todo] = synchronized {
      todos.values.filter(_.userId == userId).toList.sortBy(_.id)
    }

    def getTodo(userId: Int, todoId: Int): Either[ErrorResponse, Todo] = synchronized {
      todos.get(todoId) match {
        case Some(todo) if todo.userId == userId => Right(todo)
        case _ => Left(ErrorResponse("Todo not found"))
      }
    }

    def updateTodo(userId: Int, todoId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Either[ErrorResponse, Todo] = synchronized {
      todos.get(todoId) match {
        case Some(todo) if todo.userId == userId =>
          if (title.exists(_.trim.isEmpty)) {
            return Left(ErrorResponse("Title is required"))
          }
          val now = getCurrentTime()
          val updated = todo.copy(
            title = title.getOrElse(todo.title),
            description = description.getOrElse(todo.description),
            completed = completed.getOrElse(todo.completed),
            updatedAt = now
          )
          todos = todos + (todoId -> updated)
          Right(updated)
        case _ =>
          Left(ErrorResponse("Todo not found"))
      }
    }

    def deleteTodo(userId: Int, todoId: Int): Either[ErrorResponse, Unit] = synchronized {
      todos.get(todoId) match {
        case Some(todo) if todo.userId == userId =>
          todos = todos - todoId
          Right(())
        case _ =>
          Left(ErrorResponse("Todo not found"))
      }
    }
  }

  def err(msg: String): ErrorResponse = ErrorResponse(msg)
  def unauth(msg: String): IO[Response[IO]] = Response[IO](Status.Unauthorized).withEntity(err(msg)).pure[IO]
  def unauthErr(e: ErrorResponse): IO[Response[IO]] = Response[IO](Status.Unauthorized).withEntity(e).pure[IO]

  def routes(store: InMemStore): HttpRoutes[IO] = {
    HttpRoutes.of[IO] {
      case req @ POST -> Root / "register" =>
        req.as[RegisterReq].flatMap { body =>
          store.register(body.username, body.password) match {
            case Right(user) => Created(user)
            case Left(e) => 
              if (e.error == "Username already exists") Conflict(e)
              else BadRequest(e)
          }
        }.handleErrorWith(_ => BadRequest(err("Invalid JSON")))

      case req @ POST -> Root / "login" =>
        req.as[LoginReq].flatMap { body =>
          store.login(body.username, body.password) match {
            case Right((user, token)) =>
              val cookie = ResponseCookie("session_id", token, httpOnly = true, path = Some("/"))
              Ok(user).map(_.addCookie(cookie))
            case Left(e) => unauthErr(e)
          }
        }.handleErrorWith(_ => BadRequest(err("Invalid JSON")))

      case req @ POST -> Root / "logout" =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.logout(cookie.content)
            Ok(Json.obj())
          case None => unauth("Authentication required")
        }

      case req @ GET -> Root / "me" =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) => Ok(user)
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ PUT -> Root / "password" =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                req.as[UpdatePasswordReq].flatMap { body =>
                  store.updatePassword(user.id, body.old_password, body.new_password) match {
                    case Right(_) => Ok(Json.obj())
                    case Left(e) => 
                      if (e.error == "Invalid credentials") unauthErr(e)
                      else BadRequest(e)
                  }
                }.handleErrorWith(_ => BadRequest(err("Invalid JSON")))
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ GET -> Root / "todos" =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                Ok(store.getTodos(user.id))
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ POST -> Root / "todos" =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                req.as[CreateTodoReq].flatMap { body =>
                  body.title match {
                    case None => BadRequest(err("Title is required"))
                    case Some(t) if t.trim.isEmpty => BadRequest(err("Title is required"))
                    case Some(t) =>
                      val desc = body.description.getOrElse("")
                      Created(store.createTodo(user.id, t, desc))
                  }
                }.handleErrorWith(_ => BadRequest(err("Invalid JSON")))
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ GET -> Root / "todos" / id =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                id.toIntOption match {
                  case Some(todoId) =>
                    store.getTodo(user.id, todoId) match {
                      case Right(todo) => Ok(todo)
                      case Left(_) => NotFound(err("Todo not found"))
                    }
                  case None => NotFound(err("Todo not found"))
                }
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ PUT -> Root / "todos" / id =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                id.toIntOption match {
                  case Some(todoId) =>
                    req.as[UpdateTodoReq].flatMap { body =>
                      store.updateTodo(user.id, todoId, body.title, body.description, body.completed) match {
                        case Right(updated) => Ok(updated)
                        case Left(e) =>
                          if (e.error == "Title is required") BadRequest(e)
                          else NotFound(e)
                      }
                    }.handleErrorWith(_ => BadRequest(err("Invalid JSON")))
                  case None => NotFound(err("Todo not found"))
                }
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }

      case req @ DELETE -> Root / "todos" / id =>
        req.cookies.find(_.name == "session_id") match {
          case Some(cookie) =>
            store.getUserByToken(cookie.content) match {
              case Some(user) =>
                id.toIntOption match {
                  case Some(todoId) =>
                    store.deleteTodo(user.id, todoId) match {
                      case Right(_) => NoContent()
                      case Left(_) => NotFound(err("Todo not found"))
                    }
                  case None => NotFound(err("Todo not found"))
                }
              case None => unauth("Authentication required")
            }
          case None => unauth("Authentication required")
        }
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val port = args match {
      case "--port" :: p :: _ => p.toInt
      case _ => 8080
    }

    val store = new InMemStore()
    val httpApp = routes(store).orNotFound

    EmberServerBuilder
      .default[IO]
      .withHost(com.comcast.ip4s.Ipv4Address.fromString("0.0.0.0").get)
      .withPort(com.comcast.ip4s.Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build
      .use { _ =>
        IO.println(s"Server started on port $port") *> IO.never
      }
      .as(ExitCode.Success)
  }
}