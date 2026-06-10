//> using scala "2.13"  
//> using dep "org.http4s::http4s-blaze-server:0.23.15"
//> using dep "org.http4s::http4s-dsl:0.23.15"
//> using dep "org.http4s::http4s-circe:0.23.15"
//> using dep "io.circe::circe-generic:0.14.3"
//> using dep "io.circe::circe-parser:0.14.7"

import cats.effect._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.implicits._
import org.http4s.circe._
import io.circe.generic.semiauto._
import io.circe.JsonObject
import io.circe.syntax._
import org.http4s.server.Router
import org.http4s.server.blaze.BlazeServerBuilder
import java.time.format.DateTimeFormatter
import java.time.{ZoneOffset, ZonedDateTime}
import scala.collection.mutable
import java.util.UUID

object Main extends IOApp.Simple {

  // Data Models
  case class ErrorResponse(error: String)
  case class User(id: Int, username: String)  
  case class RegisterLoginRequest(username: String, password: String)
  case class ChangePasswordRequest(oldPassword: String, newPassword: String)  
  case class CreateTodoRequest(title: String, description: String)
  case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
  case class Todo(
    id: Int,
    title: String, 
    description: String,
    completed: Boolean,
    created_at: String,
    updated_at: String
  )

  // Define implicit Circe Encoders/Decoders 
  implicit val errorResponseEncoder = deriveEncoder[ErrorResponse]
  implicit val errorResponseDecoder = deriveDecoder[ErrorResponse] 
  implicit val userEncoder = deriveEncoder[User]
  implicit val userDecoder = deriveDecoder[User]
  implicit val registerLoginRequestEncoder = deriveEncoder[RegisterLoginRequest]
  implicit val registerLoginRequestDecoder = deriveDecoder[RegisterLoginRequest]
  implicit val changePasswordRequestEncoder = deriveEncoder[ChangePasswordRequest]
  implicit val changePasswordRequestDecoder = deriveDecoder[ChangePasswordRequest]
  implicit val createTodoRequestEncoder = deriveEncoder[CreateTodoRequest]
  implicit val createTodoRequestDecoder = deriveDecoder[CreateTodoRequest]
  implicit val updateTodoRequestEncoder = deriveEncoder[UpdateTodoRequest]
  implicit val updateTodoRequestDecoder = deriveDecoder[UpdateTodoRequest]
  implicit val todoEncoder = deriveEncoder[Todo]
  implicit val todoDecoder = deriveDecoder[Todo]
  implicit val todoListEncoder = deriveEncoder[List[Todo]]

  // Storage
  val users = mutable.Map[String, (Int, String)]()
  val userSessions = mutable.Map[String, Int]()
  val userTodos = mutable.Map[Int, mutable.Map[Int, Todo]]()

  // ID Generators
  object GenId {
    private var userCount = 0
    private var todoCount = 0
    
    def nextUser(): Int = synchronized { userCount += 1; userCount }
    def nextTodo(): Int = synchronized { todoCount += 1; todoCount }
  }

  // Utilities
  def checkValidUsername(username: String): Boolean = 
    username.length >= 3 && username.length <= 50 && username.matches("^[a-zA-Z0-9_]+$")

  def getTimestamp: String = 
    ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))

  def createSession: String = UUID.randomUUID().toString

  def identifyUser(request: Request[IO]): Option[Int] = 
    request.cookies.find(_.name == "session_id").map(_.content).flatMap(userSessions.get)

  def mainRoutes: HttpRoutes[IO] = {
    val dsl = Http4sDsl[IO]
    import dsl._
    
    import org.http4s.circe.CirceEntityEncoder._

    HttpRoutes.of[IO] {
      
      // Public Endpoints
      case request @ POST -> Root / "register" =>
        for {
          regPayload <- request.as[RegisterLoginRequest]
          result <- {
            if (!checkValidUsername(regPayload.username)) {
              BadRequest(ErrorResponse("Invalid username"))
            } else if (regPayload.password.length < 8) {
              BadRequest(ErrorResponse("Password too short")) 
            } else if (users.contains(regPayload.username)) {
              Conflict(ErrorResponse("Username already exists"))
            } else {
              val newUserId = GenId.nextUser()
              users.update(regPayload.username, (newUserId, regPayload.password))
              userTodos.update(newUserId, mutable.Map[Int, Todo]())
              Created(User(newUserId, regPayload.username))
            }
          }
        } yield result
      
      case request @ POST -> Root / "login" =>
        for {
          loginPayload <- request.as[RegisterLoginRequest]
          userExists = users.get(loginPayload.username).exists(_._2 == loginPayload.password)
          result <- {
            if (userExists) {
              val userId = users(loginPayload.username)._1
              val sessionId = createSession
              userSessions.update(sessionId, userId)
              
              Ok(User(userId, loginPayload.username)).map(_.addCookie(
                ResponseCookie(
                  name = "session_id",
                  content = sessionId,
                  path = Some("/"),
                  httpOnly = true
                )
              ))
            } else {
              Unauthorized(ErrorResponse("Invalid credentials"))
            }
          }
        } yield result
      
      // Private Endpoints
      case request @ POST -> Root / "logout" =>
        identifyUser(request) match {
          case Some(userId) =>
            userSessions.filterInPlace { case (_, id) => id != userId }
            Ok("")
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))
        }
      
      case request @ GET -> Root / "me" =>  
        identifyUser(request) match {
          case Some(userId) =>
            users.find(_._2._1 == userId) match {
              case Some((username, (id, _))) => Ok(User(id, username))
              case None => Unauthorized(ErrorResponse("Authentication required"))
            }
          case None => 
            Unauthorized(ErrorResponse("Authentication required"))
        }
      
      case request @ PUT -> Root / "password" =>
        identifyUser(request) match {
          case Some(userId) =>
            for {
              pwdPayload <- request.as[ChangePasswordRequest]
              matchingUser = users.find(u => u._2._1 == userId && u._2._2 == pwdPayload.oldPassword)
              result <- { 
                if (matchingUser.isEmpty) {
                  Unauthorized(ErrorResponse("Invalid credentials"))
                } else if (pwdPayload.newPassword.length < 8) {
                  BadRequest(ErrorResponse("Password too short"))
                } else {
                  val userKey = matchingUser.head._1
                  users.update(userKey, (userId, pwdPayload.newPassword))
                  Ok("")
                }
              }
            } yield result
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))
        }
      
      case request @ GET -> Root / "todos" =>
        identifyUser(request) match {
          case Some(userId) =>
            val userTodoList = userTodos.get(userId).map(_.values.toList.sortBy(_.id)).getOrElse(Nil)
            Ok(userTodoList)
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))
        }
      
      case request @ POST -> Root / "todos" =>
        identifyUser(request) match {
          case Some(userId) =>
            for {
              todoPayload <- request.as[CreateTodoRequest]
              result <- {
                if (todoPayload.title.trim.isEmpty) {
                  BadRequest(ErrorResponse("Title is required"))
                } else {
                  val newTodoId = GenId.nextTodo()
                  val now = getTimestamp
                  val newTodo = Todo(
                    id = newTodoId,
                    title = todoPayload.title,
                    description = Option(todoPayload.description).getOrElse(""),  
                    completed = false,
                    created_at = now,
                    updated_at = now
                  )
                  
                  val userTodoMap = userTodos.getOrElseUpdate(userId, mutable.Map[Int, Todo]())
                  userTodoMap.update(newTodoId, newTodo)
                  Created(newTodo)  
                }
              }
            } yield result
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))
        }
      
      case GET -> Root / "todos" / IntVar(todoId) =>
        identifyUser(request) match {
          case Some(userId) =>
            userTodos.get(userId).flatMap(_.get(todoId)) match {
              case Some(todo) => Ok(todo)
              case None => NotFound(ErrorResponse("Todo not found"))
            }
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))  
        }
      
      case request @ PUT -> Root / "todos" / IntVar(todoId) =>
        identifyUser(request) match {
          case Some(userId) =>
            userTodos.get(userId).flatMap(_.get(todoId)) match {
              case Some(existingTodo) =>
                for {
                  updatePayload <- request.as[UpdateTodoRequest]
                  processedResult <- {
                    if (updatePayload.title.exists(_.trim.isEmpty)) {
                      IO.pure(BadRequest(ErrorResponse("Title is required")))
                    } else {
                      val updatedTodo = existingTodo.copy(
                        title = updatePayload.title.getOrElse(existingTodo.title),
                        description = updatePayload.description.getOrElse(existingTodo.description), 
                        completed = updatePayload.completed.getOrElse(existingTodo.completed),
                        updated_at = getTimestamp
                      )
                      
                      userTodos(userId).update(todoId, updatedTodo)
                      IO.pure(Ok(updatedTodo))
                    }
                  }
                } yield processedResult
              case None => 
                IO.pure(NotFound(ErrorResponse("Todo not found")))
            }
          case None =>
            IO.pure(Unauthorized(ErrorResponse("Authentication required")))
        }
      
      case DELETE -> Root / "todos" / IntVar(todoId) =>
        identifyUser(request) match {
          case Some(userId) =>
            userTodos.get(userId) match {
              case Some(todoMap) if todoMap.contains(todoId) =>
                todoMap.remove(todoId)
                NoContent()
              case _ =>
                NotFound(ErrorResponse("Todo not found"))
            }
          case None =>
            Unauthorized(ErrorResponse("Authentication required"))
        }
    }
  }

  def run: IO[Unit] = {
    val portOpt = sys.props.get("HTTP_PORT").flatMap(_.toIntOption).orElse(Some(8080))
    
    BlazeServerBuilder[IO]
      .bindHttp(portOpt.get, "0.0.0.0")
      .withHttpApp(Router("/" -> mainRoutes.orNotFound))
      .serve
      .compile  
      .drain
  }
}