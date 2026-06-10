//> using scala "2.13"
//> using platform "jvm"
//> using dep "org.http4s::http4s-blaze-server::0.23.11"
//> using dep "org.http4s::http4s-circe::0.23.11"
//> using dep "org.http4s::http4s-dsl::0.23.11"
//> using dep "io.circe::circe-generic::0.14.1"

import cats.effect._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.implicits._
import io.circe.generic.auto._
import io.circe.syntax._

import java.time.Instant
import scala.collection.mutable
import scala.util.matching.Regex
import java.util.UUID

case class User(id: Int, username: String)
case class Todo(
  id: Int,
  title: String, 
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)
case class RegisterRequest(username: String, password: String)
case class LoginRequest(username: String, password: String)
case class ChangePasswordRequest(old_password: String, new_password: String)
case class CreateTodoRequest(title: String, description: String)
case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
case class ErrorResponse(error: String)

object TodoApp extends IOApp {

  // In-memory storage  
  val users = mutable.Map.empty[Int, (User, String)] // userId -> (user, hashed_password) 
  val todos = mutable.Map.empty[Int, (Int, Todo)] // todoId -> (userId, todo)
  val sessions = mutable.Map.empty[String, Int] // sessionId -> userId

  // Json encoders and decoders - define once for the whole object
  implicit val CirceEntityDecoder = org.http4s.circe.jsonOf[IO, RegisterRequest]
  implicit val CirceEntityEncoderUser = org.http4s.circe.jsonEncoderOf[IO, User]
  implicit val CirceEntityEncoderTodo = org.http4s.circe.jsonEncoderOf[IO, Todo]
  implicit val CirceEntityEncoderTodoList = org.http4s.circe.jsonEncoderOf[IO, List[Todo]]
  implicit val CirceEntityEncoderError = org.http4s.circe.jsonEncoderOf[IO, ErrorResponse]
  implicit val CirceEntityEncoderEmpty = org.http4s.circe.jsonEncoderOf[IO, Unit]
  
  var nextUserId = 1
  var nextTodoId = 1

  // Validation helpers
  def isValidUsername(username: String): Boolean = {
    val usernameRegex = "^[a-zA-Z0-9_]+$".r
    username.length >= 3 && username.length <= 50 && usernameRegex.matches(username)
  }
  
  def isValidPassword(password: String): Boolean = password.length >= 8
  
  def hashPassword(password: String): String = {
    import java.security.MessageDigest
    val md = MessageDigest.getInstance("SHA-256")
    val hashedBytes = md.digest(password.getBytes("UTF-8"))
    hashedBytes.map("%02x".format(_)).mkString
  }
  
  def getCurrentTimestamp(): String = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString

  def getUserIdFromRequest(request: Request[IO]): Option[Int] = {
    request.cookies.find(_.name == "session_id").map(_.content).flatMap(sessions.get(_))
  }
  
  def requireAuth(request: Request[IO])(f: Int => IO[Response[IO]]): IO[Response[IO]] = {
    val dsl = new Http4sDsl[IO] {}
    import dsl._
    
    getUserIdFromRequest(request) match {
      case Some(userId) => f(userId)
      case None => 
        Response[IO](Status.Unauthorized).withEntity(ErrorResponse("Authentication required")).pure[IO]
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val portOptionIndex = args.indexOf("--port")
    val port = if (portOptionIndex != -1 && portOptionIndex + 1 < args.length) {
      args(portOptionIndex + 1).toInt
    } else {
      8080
    }

    val dsl = new Http4sDsl[IO] {}
    import dsl._
    
    val app = HttpRoutes.of[IO] {
      // REGISTER - No authentication
      case request @ POST -> Root / "register" =>
        implicit val decoder = org.http4s.circe.jsonOf[IO, RegisterRequest]
        request.as[RegisterRequest].flatMap { req =>
          if (!isValidUsername(req.username)) {
            Response[IO](Status.BadRequest).withEntity(ErrorResponse("Invalid username")).pure[IO]
          } else if (!isValidPassword(req.password)) {
            Response[IO](Status.BadRequest).withEntity(ErrorResponse("Password too short")).pure[IO]
          } else if (users.values.exists(_._1.username == req.username)) {
            Response[IO](Status.Conflict).withEntity(ErrorResponse("Username already exists")).pure[IO]
          } else {
            val user = User(nextUserId, req.username)
            val hashedPass = hashPassword(req.password)
            users += (nextUserId -> (user, hashedPass))
            nextUserId += 1
            Response[IO](Status.Created).withEntity(user).pure[IO]
          }
        }
        
      // LOGIN - No authentication  
      case request @ POST -> Root / "login" =>
        implicit val decoder = org.http4s.circe.jsonOf[IO, LoginRequest]
        request.as[LoginRequest].flatMap { req =>
          users.find { case (_, (user, storedPassword)) => 
            user.username == req.username && storedPassword == hashPassword(req.password)
          } match {
            case Some((id, (user, _))) =>
              val sessionId = UUID.randomUUID().toString
              sessions += (sessionId -> id)
              val response = Response[IO](Status.Ok).withEntity(user).pure[IO]
              response.map(_.addCookie(ResponseCookie("session_id", sessionId, path = Some("/"), httpOnly = true)))
            case None =>
              Response[IO](Status.Unauthorized).withEntity(ErrorResponse("Invalid credentials")).pure[IO]
          }
        }
        
      // LOGOUT - Authentication required
      case request @ POST -> Root / "logout" =>
        requireAuth(request) { _ =>
          // Get any session tokens from this request and remove them
          val sessionIds = request.cookies.filter(_.name == "session_id").map(_.content)
          sessionIds.foreach(sid => sessions.remove(sid))
          Response[IO](Status.Ok).withEntity(()).pure[IO]
        }
        
      // ME - Authentication required
      case request @ GET -> Root / "me" =>
        requireAuth(request) { userId =>
          users.get(userId) match {
            case Some((user, _)) => Response[IO](Status.Ok).withEntity(user).pure[IO]
            case None => Response[IO](Status.Unauthorized).withEntity(ErrorResponse("Authentication required")).pure[IO] 
          }
        }
        
      // PASSWORD - Authentication required
      case request @ PUT -> Root / "password" =>
        implicit val decoder = org.http4s.circe.jsonOf[IO, ChangePasswordRequest]
        requireAuth(request) { userId =>
          request.as[ChangePasswordRequest].flatMap { req =>
            if (!isValidPassword(req.new_password)) {
              Response[IO](Status.BadRequest).withEntity(ErrorResponse("Password too short")).pure[IO]
            } else {
              users.get(userId) match {
                case Some((user, currentHashedPassword)) =>
                  if (currentHashedPassword == hashPassword(req.old_password)) {
                    users.update(userId, (user, hashPassword(req.new_password)))
                    Response[IO](Status.Ok).withEntity(()).pure[IO]
                  } else {
                    Response[IO](Status.Unauthorized).withEntity(ErrorResponse("Invalid credentials")).pure[IO]
                  }
                case None => 
                  Response[IO](Status.Unauthorized).withEntity(ErrorResponse("Authentication required")).pure[IO]
              }
            }
          }
        }
        
      // GET TODOS - Authentication required
      case request @ GET -> Root / "todos" =>
        requireAuth(request) { userId =>
          val userTodos = todos.values.filter(_._1 == userId).map(_._2).toList.sortBy(_.id)
          Response[IO](Status.Ok).withEntity(userTodos).pure[IO]
        }
        
      // CREATE TODO - Authentication required  
      case request @ POST -> Root / "todos" =>
        implicit val decoder = org.http4s.circe.jsonOf[IO, CreateTodoRequest]
        requireAuth(request) { userId =>
          request.as[CreateTodoRequest].flatMap { req =>
            if (req.title.trim.isEmpty) {
              Response[IO](Status.BadRequest).withEntity(ErrorResponse("Title is required")).pure[IO]
            } else {
              val now = getCurrentTimestamp()
              val todo = Todo(
                id = nextTodoId, 
                title = req.title, 
                description = req.description, 
                completed = false, 
                created_at = now, 
                updated_at = now
              )
              todos += (nextTodoId -> (userId, todo))
              nextTodoId += 1
              Response[IO](Status.Created).withEntity(todo).pure[IO]
            }
          }
        }
        
      // GET TODO BY ID - Authentication required
      case request @ GET -> Root / "todos" / IntVar(todoId) =>
        requireAuth(request) { userId =>
          todos.get(todoId) match {
            case Some((ownerId, todo)) if ownerId == userId => 
              Response[IO](Status.Ok).withEntity(todo).pure[IO]
            case _ => 
              Response[IO](Status.NotFound).withEntity(ErrorResponse("Todo not found")).pure[IO]
          }
        }
        
      // UPDATE TODO - Authentication required
      case request @ PUT -> Root / "todos" / IntVar(todoId) =>
        implicit val decoder = org.http4s.circe.jsonOf[IO, UpdateTodoRequest]
        requireAuth(request) { userId =>
          request.as[UpdateTodoRequest].flatMap { req =>
            todos.get(todoId) match {
              case Some((ownerId, oldTodo)) if ownerId == userId =>
                if (req.title.exists(_.trim.isEmpty)) {
                  Response[IO](Status.BadRequest).withEntity(ErrorResponse("Title is required")).pure[IO]
                } else {
                  val updatedTodo = Todo(
                    id = oldTodo.id,
                    title = req.title.getOrElse(oldTodo.title),
                    description = req.description.getOrElse(oldTodo.description),
                    completed = req.completed.getOrElse(oldTodo.completed),
                    created_at = oldTodo.created_at,
                    updated_at = getCurrentTimestamp()
                  )
                  todos.update(todoId, (userId, updatedTodo))
                  Response[IO](Status.Ok).withEntity(updatedTodo).pure[IO]
                }
              case _ => 
                Response[IO](Status.NotFound).withEntity(ErrorResponse("Todo not found")).pure[IO]
            }
          }
        }
        
      // DELETE TODO - Authentication required
      case request @ DELETE -> Root / "todos" / IntVar(todoId) =>
        requireAuth(request) { userId =>
          todos.get(todoId) match {
            case Some((ownerId, _)) if ownerId == userId =>
              todos.remove(todoId)
              IO.pure(Response(status = Status.NoContent))
            case _ =>
              Response[IO](Status.NotFound).withEntity(ErrorResponse("Todo not found")).pure[IO]
          }
        }
    }.orNotFound

    org.http4s.blaze.server.BlazeServerBuilder[IO]
      .bindHttp(port, "0.0.0.0")
      .withHttpApp(app)
      .serve
      .compile
      .drain
      .as(ExitCode.Success)
  }
}