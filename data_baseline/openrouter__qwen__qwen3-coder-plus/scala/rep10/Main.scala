//> using scala "2.13"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-blaze-server:0.23.17"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"


import cats.effect._
import cats.implicits._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.server.blaze.BlazeServerBuilder
import org.http4s.headers.`Set-Cookie`
import org.http4s.HttpRoutes
import org.http4s.implicits._
import org.http4s.circe._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._

import java.time.Instant
import java.time.format.DateTimeFormatter  
import java.util.UUID
import scala.collection.mutable
import scala.util.matching.Regex

case class User(id: Int, username: String, passwordHash: String)

object User {
  implicit val userEncoder: Encoder[User] = deriveEncoder[User]
  implicit val userDecoder: Decoder[User] = deriveDecoder[User].emap { user =>
    // Don't expose password hash in response  
    Right(user.copy(passwordHash = ""))
  }
}

case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)

object Todo {
  implicit val todoEncoder: Encoder[Todo] = deriveEncoder[Todo]
  implicit val todoDecoder: Decoder[Todo] = deriveDecoder[Todo]
}

object DateTimeUtil {
  def now(): String = Instant.now().toString.replaceAll("\\[.*?\\]", "").take(19) + "Z"
}

class TodoApp extends Http4sDsl[IO] {

  // In-memory storage
  private var userCounter = 0
  private val users = mutable.Map[String, User]() // key: username
  private val sessionToUser = mutable.Map[String, Int]() // key: session_id -> value: user_id
  private var todoCounter = 0
  private val todos = mutable.Map[Int, mutable.Map[Int, Todo]]() // key: user_id -> todo_id -> todo

  // Helper to get next user ID
  private def getNextUserId(): Int = {
    userCounter += 1
    userCounter
  }

  // Helper to get next todo ID
  private def getNextTodoId(): Int = {
    todoCounter += 1
    todoCounter
  }

  // Helper to validate username format
  private val usernamePattern: Regex = "^[a-zA-Z0-9_]+$".r
  private def isValidUsername(username: String): Boolean = {
    username.length >= 3 && 
    username.length <= 50 && 
    usernamePattern.pattern.matcher(username).matches()
  }

  // Helper to validate password (minimum length)
  private def isValidPassword(password: String): Boolean = password.length >= 8

  // Helper to hash password (using simple approach for demo)
  private def hashPassword(password: String): String = password.reverse // In real app, use proper hashing like bcrypt

  // Helper to generate session ID
  private def generateSessionId(): String = UUID.randomUUID().toString.replace("-", "")

  // Authenticate based on session cookie
  private def authenticate(req: Request[IO]): Option[Int] = {
    req.cookies.find(_.name == "session_id") match {
      case Some(cookie) =>
        sessionToUser.get(cookie.content)
      case None => None
    }
  }

  // Middleware to check authentication
  private def withAuth(request: Request[IO])(block: Int => IO[Response[IO]]): IO[Response[IO]] = {
    authenticate(request) match {
      case Some(userId) => block(userId)
      case None => 
        Response[IO](Status.Unauthorized).withEntity(Json.obj("error" := "Authentication required")).pure[IO]
    }
  }

  // JSON decoders and encoders for the routes
  implicit val jsonDecoder: EntityDecoder[IO, Json] = jsonOf[IO, Json]

  // Register endpoint
  val registerRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" =>
      req.attemptAs[Json].value.flatMap {
        case Right(json) =>
          (json.hcursor.downField("username").as[String], json.hcursor.downField("password").as[String]) match {
            case (Right(username), Right(password)) =>
              if (!isValidUsername(username)) {
                BadRequest(Json.obj("error" := "Invalid username"))
              } else if (!isValidPassword(password)) {
                BadRequest(Json.obj("error" := "Password too short"))
              } else if (users.contains(username)) {
                Conflict(Json.obj("error" := "Username already exists"))
              } else {
                val userId = getNextUserId()
                val user = User(userId, username, hashPassword(password))
                users(username) = user
                Created(user.asJson)
              }
            case _ => BadRequest(Json.obj("error" := "Invalid request body"))
          }
        case Left(_) => BadRequest(Json.obj("error" := "Invalid JSON"))
      }
  }

  // Login endpoint
  val loginRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ POST -> Root / "login" =>
      req.attemptAs[Json].value.flatMap {
        case Right(json) =>
          (json.hcursor.downField("username").as[String], json.hcursor.downField("password").as[String]) match {
            case (Right(inputUsername), Right(inputPassword)) =>
              users.get(inputUsername) match {
                case Some(user) if user.passwordHash == hashPassword(inputPassword) =>
                  val sessionId = generateSessionId()
                  sessionToUser(sessionId) = user.id
                  val cookie = ResponseCookie(
                    name = "session_id",
                    content = sessionId,
                    path = Some("/"),
                    httpOnly = true
                  )
                  Ok(user.asJson).map(_.addCookie(cookie))
                case _ => Response[IO](Status.Unauthorized).withEntity(Json.obj("error" := "Invalid credentials")).pure[IO]
              }
            case _ => BadRequest(Json.obj("error" := "Invalid request body"))
          }
        case Left(_) => BadRequest(Json.obj("error" := "Invalid JSON"))
      }
  }

  // Logout endpoint
  val logoutRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ POST -> Root / "logout" =>
      withAuth(req) { userId =>
        req.cookies.find(_.name == "session_id").foreach { cookie =>
          sessionToUser.remove(cookie.content)
        }
        Ok(Json.obj())
      }
  }

  // Get current user endpoint
  val getMeRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ GET -> Root / "me" =>
      withAuth(req) { userId =>
        users.values.find(_.id == userId) match {
          case Some(user) => 
            // Don't include password hash in response
            val responseUser = User(user.id, user.username, "")  
            Ok(responseUser.asJson)
          case None => Response[IO](Status.Unauthorized).withEntity(Json.obj("error" := "Authentication required")).pure[IO]
        }
      }
  }

  // Update password endpoint
  val updatePasswordRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ PUT -> Root / "password" =>
      withAuth(req) { userId =>
        req.attemptAs[Json].value.flatMap {
          case Right(json) =>
            (json.hcursor.downField("old_password").as[String], json.hcursor.downField("new_password").as[String]) match {
              case (Right(oldPassword), Right(newPassword)) =>
                users.values.find(_.id == userId) match {
                  case Some(user) if user.passwordHash == hashPassword(oldPassword) =>
                    if (!isValidPassword(newPassword)) {
                      BadRequest(Json.obj("error" := "Password too short"))
                    } else {
                      val updatedUser = user.copy(passwordHash = hashPassword(newPassword))
                      users(user.username) = updatedUser
                      Ok(Json.obj())
                    }
                  case _ => Response[IO](Status.Unauthorized).withEntity(Json.obj("error" := "Invalid credentials")).pure[IO]
                }
              case _ => BadRequest(Json.obj("error" := "Invalid request body"))  
            }
          case Left(_) => BadRequest(Json.obj("error" := "Invalid JSON"))
        }
      }
  }
  
  // Initialize user's todo map
  private def ensureUserTodosExist(userId: Int): Unit = {
    if (!todos.contains(userId)) {
      todos(userId) = mutable.Map[Int, Todo]()
    }
  }

  // List todos for user
  val getTodosRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ GET -> Root / "todos" =>
      withAuth(req) { userId =>
        ensureUserTodosExist(userId)
        val userTodos = todos(userId).values.toList.sortBy(_.id)
        Ok(userTodos.asJson)
      }
  }

  // Create a new todo
  val createTodoRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ POST -> Root / "todos" =>
      withAuth(req) { userId =>
        req.attemptAs[Json].value.flatMap {
          case Right(json) =>
            val titleOpt = json.hcursor.downField("title").as[String].toOption
            val descOpt = json.hcursor.downField("description").as[String].toOption.orElse(Some(""))
            
            titleOpt match {
              case Some(title) if title.nonEmpty =>
                val timestamp = DateTimeUtil.now()
                val newId = getNextTodoId()
                val todo = Todo(newId, title, descOpt.getOrElse(""), false, timestamp, timestamp)
                
                ensureUserTodosExist(userId)
                todos(userId)(newId) = todo
                Created(todo.asJson)
              case _ => BadRequest(Json.obj("error" := "Title is required"))
            }
          case Left(_) => BadRequest(Json.obj("error" := "Invalid JSON"))
        }
      }
  }

  // Get a specific todo
  val getTodoByIdRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ GET -> Root / "todos" / IntVar(todoId) =>
      withAuth(req) { userId =>
        ensureUserTodosExist(userId)
        todos(userId).get(todoId) match {
          case Some(todo) => Ok(todo.asJson)
          case None => Response[IO](Status.NotFound).withEntity(Json.obj("error" := "Todo not found")).pure[IO]
        }
      }
  }

  // Update a specific todo (partial update)
  val updateTodoRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ PUT -> Root / "todos" / IntVar(todoId) =>
      withAuth(req) { userId =>
        ensureUserTodosExist(userId)
        todos(userId).get(todoId) match {
          case Some(existingTodo) =>
            req.attemptAs[Json].value.flatMap {
              case Right(json) =>
                val updatedTitle = json.hcursor.downField("title").as[String].toOption.getOrElse(existingTodo.title)
                val updatedDesc = json.hcursor.downField("description").as[String].toOption.getOrElse(existingTodo.description)
                val updatedCompleted = json.hcursor.downField("completed").as[Boolean].toOption.getOrElse(existingTodo.completed)
                
                if (updatedTitle.isEmpty) {
                  BadRequest(Json.obj("error" := "Title is required"))
                } else {
                  val timestamp = DateTimeUtil.now()
                  val updatedTodo = existingTodo.copy(
                    title = updatedTitle,
                    description = updatedDesc,
                    completed = updatedCompleted,
                    updated_at = timestamp
                  )
                  
                  todos(userId)(todoId) = updatedTodo
                  Ok(updatedTodo.asJson)
                }
              case Left(_) => BadRequest(Json.obj("error" := "Invalid JSON"))
            }
          case None => Response[IO](Status.NotFound).withEntity(Json.obj("error" := "Todo not found")).pure[IO]
        }
      }
  }

  // Delete a specific todo
  val deleteTodoRoute: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
      withAuth(req) { userId =>
        ensureUserTodosExist(userId)
        if (todos(userId).contains(todoId)) {
          todos(userId).remove(todoId)
          Response[IO](Status.NoContent).pure[IO]
        } else {
          Response[IO](Status.NotFound).withEntity(Json.obj("error" := "Todo not found")).pure[IO]
        }
      }
  }

  val routes: HttpRoutes[IO] = registerRoute <+> 
                              loginRoute <+> 
                              logoutRoute <+> 
                              getMeRoute <+> 
                              updatePasswordRoute <+> 
                              getTodosRoute <+> 
                              createTodoRoute <+> 
                              getTodoByIdRoute <+> 
                              updateTodoRoute <+> 
                              deleteTodoRoute
}

object Main extends IOApp.Simple {
  def run: IO[Unit] = {
    import sys.process._
    
    val args = System.getProperty("scala.cli.args", "").split(" ")
    val portIdx = args.indexOf("--port")
    val port = if (portIdx >= 0) {
      try args(portIdx + 1).toInt catch { case _: Exception => 8080 }
    } else {
      8080
    }
    
    val httpApp = new TodoApp()
    
    BlazeServerBuilder[IO]
      .bindHttp(port, "0.0.0.0") // Bind to all interfaces
      .withHttpApp(httpApp.routes.orNotFound)
      .serve
      .compile
      .drain
  }
}