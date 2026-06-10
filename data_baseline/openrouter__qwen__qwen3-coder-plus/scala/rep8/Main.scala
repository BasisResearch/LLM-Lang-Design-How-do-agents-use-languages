//> using scala "2.13"
//> using dep "org.http4s::http4s-blaze-server:0.21.33"
//> using dep "org.http4s::http4s-circe:0.21.33"
//> using dep "org.http4s::http4s-dsl:0.21.33"
//> using dep "org.typelevel::cats-core:2.7.0"
//> using dep "org.typelevel::cats-effect:2.5.4"
//> using dep "io.circe::circe-generic:0.14.1"

import cats.effect._
import io.circe.generic.semiauto.{deriveDecoder, deriveEncoder}
import io.circe.{Decoder, Encoder}
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.headers.`Set-Cookie`
import org.http4s.implicits._
import org.http4s.server.Router
import org.http4s.server.blaze.BlazeServerBuilder
import org.http4s.circe.CirceEntityCodec._
import io.circe.syntax._
import io.circe.Json

import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.time.{Instant, ZoneOffset}
import java.util.UUID
import scala.collection.mutable


case class User(id: Int, username: String)
case class FullUser(id: Int, username: String, passwordHash: String)
case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)
case class LoginRequest(username: String, password: String)
case class RegisterRequest(username: String, password: String)
case class NewTodoRequest(title: String, description: String = "")
case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
case class ChangePasswordRequest(old_password: String, new_password: String)


object Main extends IOApp {

  implicit val userDecoder: Decoder[User] = deriveDecoder[User]
  implicit val userEncoder: Encoder.AsObject[User] = deriveEncoder[User]
  implicit val fullUserDecoder: Decoder[FullUser] = deriveDecoder[FullUser]
  implicit val fullUserEncoder: Encoder.AsObject[FullUser] = deriveEncoder[FullUser]
  implicit val todoDecoder: Decoder[Todo] = deriveDecoder[Todo]
  implicit val todoEncoder: Encoder.AsObject[Todo] = deriveEncoder[Todo]
  implicit val loginRequestDecoder: Decoder[LoginRequest] = deriveDecoder[LoginRequest]
  implicit val registerRequestDecoder: Decoder[RegisterRequest] = deriveDecoder[RegisterRequest]
  implicit val newTodoRequestDecoder: Decoder[NewTodoRequest] = deriveDecoder[NewTodoRequest]
  implicit val updateTodoRequestDecoder: Decoder[UpdateTodoRequest] = deriveDecoder[UpdateTodoRequest]
  implicit val changePasswordRequestDecoder: Decoder[ChangePasswordRequest] = deriveDecoder[ChangePasswordRequest]

  def run(args: List[String]): IO[ExitCode] = {
    val portOption = args.sliding(2, 2).collectFirst { case Seq("--port", p) => p }
    val port = portOption.map(_.toInt).getOrElse(8080)
    
    val serverResource = BlazeServerBuilder[IO]
      .bindHttp(port, "0.0.0.0")
      .withHttpApp(createApp())
      .resource

    serverResource.use(_ => IO.never).as(ExitCode.Success)
  }
  
  def createApp(): HttpApp[IO] = {
    implicit val dsl: Http4sDsl[IO] = Http4sDsl[IO]
    import dsl._

    // In-memory storage
    val usersByUsername = mutable.Map.empty[String, FullUser]
    val todosById = mutable.Map.empty[Int, Todo]
    val userTodos = mutable.Map.empty[Int, Set[Int]] 
    val validSessions = mutable.Map.empty[String, Int] 
    
    var nextUserId = 1
    var nextTodoId = 1

    def getCurrentTime(): String = {
      Instant.now.truncatedTo(ChronoUnit.SECONDS).atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    }
    
    def generateSessionId(): String = UUID.randomUUID().toString
    
    def validateUsername(username: String): Boolean = {
      username.length >= 3 && 
      username.length <= 50 && 
      username.matches("^[a-zA-Z0-9_]+$")
    }
    
    def hashPassword(password: String): String = {
      import java.security.MessageDigest
      val md = MessageDigest.getInstance("SHA-256")
      val hashedBytes = md.digest(password.getBytes("UTF-8"))
      hashedBytes.map("%02x".format(_)).mkString
    }

    def authenticateRequest(req: Request[IO]): Option[FullUser] = {
      val sessionIdOpt = req.cookies.find(_.name == "session_id").map(_.content)
      sessionIdOpt.flatMap { sessionId =>
        validSessions.get(sessionId).flatMap { userId =>
          usersByUsername.values.find(_.id == userId)
        }
      }
    }

    val publicRoutes: HttpRoutes[IO] = HttpRoutes.of[IO] {
      case req @ POST -> Root / "register" =>
        req.as[RegisterRequest].flatMap { registerReq =>
          val username = registerReq.username
          val password = registerReq.password
          
          if (!validateUsername(username)) {
            BadRequest(Json.obj("error" -> Json.fromString("Invalid username")).spaces2)
          } else if (password.length < 8) {
            BadRequest(Json.obj("error" -> Json.fromString("Password too short")).spaces2)
          } else if (usersByUsername.contains(username)) {
            Conflict(Json.obj("error" -> Json.fromString("Username already exists")).spaces2)
          } else {
            val userId = nextUserId
            val hashedPassword = hashPassword(password)
            val newUser = FullUser(userId, username, hashedPassword)
            usersByUsername.put(username, newUser)
            
            nextUserId += 1
            
            Created(Json.obj("id" -> Json.fromInt(newUser.id), 
                            "username" -> Json.fromString(newUser.username)).spaces2)
          }
        }
      
      case req @ POST -> Root / "login" =>
        req.as[LoginRequest].flatMap { loginReq =>
          val username = loginReq.username
          val password = loginReq.password
          val hashedPassword = hashPassword(password)
          
          usersByUsername.get(username) match {
            case Some(user) if user.passwordHash == hashedPassword =>
              val sessionId = generateSessionId()
              validSessions.put(sessionId, user.id)
              
              val response = Ok(Json.obj("id" -> Json.fromInt(user.id), 
                                        "username" -> Json.fromString(user.username)).spaces2)
              response.map(_.putHeaders(
                `Set-Cookie`(org.http4s.headers.Cookie("session_id", sessionId, 
                  path = Some("/"))
              )))
            case _ =>
              Unauthorized(Json.obj("error" -> Json.fromString("Invalid credentials")).spaces2)
          }
        }
    }
    
    val protectedRoutes: HttpRoutes[IO] = HttpRoutes.of[IO] {
      case req @ GET -> Root / "me" =>
        authenticateRequest(req) match {
          case Some(user) => 
            Ok(Json.obj("id" -> Json.fromInt(user.id), 
                        "username" -> Json.fromString(user.username)).spaces2)
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ POST -> Root / "logout" =>
        authenticateRequest(req) match {
          case Some(_) => 
            val sessionIdOpt = req.cookies.find(_.name == "session_id").map(_.content)
            sessionIdOpt.foreach(validSessions.remove)
            Ok("{}")
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ PUT -> Root / "password" =>
        authenticateRequest(req) match {
          case Some(user) => 
            req.as[ChangePasswordRequest].flatMap { changeReq =>
              val oldPassword = changeReq.old_password
              val newPassword = changeReq.new_password
              
              if (hashPassword(oldPassword) != user.passwordHash) {
                Unauthorized(Json.obj("error" -> Json.fromString("Invalid credentials")).spaces2)
              } else if (newPassword.length < 8) {
                BadRequest(Json.obj("error" -> Json.fromString("Password too short")).spaces2)
              } else {
                val updatedUser = user.copy(passwordHash = hashPassword(newPassword))
                usersByUsername.update(user.username, updatedUser)
                Ok("{}")
              }
            }
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ GET -> Root / "todos" =>
        authenticateRequest(req) match {
          case Some(user) =>
            val userTodosList = userTodos.getOrElse(user.id, Set.empty).toList
              .map(todosById)
              .sortBy(_.id)
            val jsonTodos = userTodosList.map(_.asJson).asJson
            Ok(jsonTodos.spaces2)
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ POST -> Root / "todos" =>
        authenticateRequest(req) match {
          case Some(user) => 
            req.as[NewTodoRequest].flatMap { newTodoReq =>
              if (newTodoReq.title.trim.isEmpty) {
                BadRequest(Json.obj("error" -> Json.fromString("Title is required")).spaces2)
              } else {
                val todoId = nextTodoId
                val now = getCurrentTime()
                val newTodo = Todo(
                  id = todoId,
                  title = newTodoReq.title,
                  description = newTodoReq.description,
                  completed = false,
                  created_at = now,
                  updated_at = now
                )
                
                todosById.put(todoId, newTodo)
                val currentUserTodos = userTodos.getOrElse(user.id, Set.empty) + todoId
                userTodos.update(user.id, currentUserTodos)
                
                nextTodoId += 1
                
                Created(newTodo.asJson.spaces2)
              }
            }
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ GET -> Root / "todos" / IntVar(todoId) =>
        authenticateRequest(req) match {
          case Some(user) =>
            val userTodosSet = userTodos.getOrElse(user.id, Set.empty)
            if (userTodosSet.contains(todoId)) {
              todosById.get(todoId) match {
                case Some(todo) => Ok(todo.asJson.spaces2)
                case None => NotFound(Json.obj("error" -> Json.fromString("Todo not found")).spaces2)
              }
            } else {
              NotFound(Json.obj("error" -> Json.fromString("Todo not found")).spaces2)
            }
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ PUT -> Root / "todos" / IntVar(todoId) =>
        authenticateRequest(req) match {
          case Some(currentUser) =>
            val userTodosSet = userTodos.getOrElse(currentUser.id, Set.empty)
            if (userTodosSet.contains(todoId)) {
              req.as[UpdateTodoRequest].flatMap { updateReq =>
                todosById.get(todoId) match {
                  case Some(existingTodo) =>
                    val newTitle = updateReq.title.map { t => 
                      if (t.trim.isEmpty) {
                        return BadRequest(Json.obj("error" -> Json.fromString("Title is required")).spaces2).pure[IO]
                      } else t
                    }.getOrElse(existingTodo.title)
                    
                    val newDescription = updateReq.description.getOrElse(existingTodo.description)
                    val newCompleted = updateReq.completed.getOrElse(existingTodo.completed)
                    val updatedAt = getCurrentTime()
                    
                    val updatedTodo = existingTodo.copy(
                      title = newTitle,
                      description = newDescription,
                      completed = newCompleted,
                      updated_at = updatedAt
                    )
                    
                    todosById.update(todoId, updatedTodo)
                    Ok(updatedTodo.asJson.spaces2)
                  case None => 
                    NotFound(Json.obj("error" -> Json.fromString("Todo not found")).spaces2)
                }
              }
            } else {
              NotFound(Json.obj("error" -> Json.fromString("Todo not found")).spaces2)
            }
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
      
      case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
        authenticateRequest(req) match {
          case Some(currentUser) =>
            val userTodosSet = userTodos.getOrElse(currentUser.id, Set.empty)
            if (userTodosSet.contains(todoId)) {
              todosById.remove(todoId)
              userTodos.update(currentUser.id, userTodosSet - todoId)
              NoContent()
            } else {
              NotFound(Json.obj("error" -> Json.fromString("Todo not found")).spaces2)
            }
          case None => 
            Unauthorized(Json.obj("error" -> Json.fromString("Authentication required")).spaces2)
        }
    }
    
    Router("/" -> HttpRoutes.of[IO] { 
      case r if r.pathInfo.toString.startsWith("/register") || r.pathInfo.toString.startsWith("/login") =>
        publicRoutes.orNotFound(r)  
      case r => // All other paths need auth
        protectedRoutes.orNotFound(r)
    }).orNotFound
  }
}