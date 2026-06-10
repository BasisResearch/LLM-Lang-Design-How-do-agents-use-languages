//> using scala "2.13"
//> using lib "com.typesafe.akka::akka-http:10.2.10"
//> using lib "com.typesafe.akka::akka-actor-typed:2.6.20"
//> using lib "com.typesafe.akka::akka-stream:2.6.20"
//> using lib "de.heikoseeberger::akka-http-play-json:1.39.2"

import akka.actor.typed.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.server.Route
import akka.http.scaladsl.model.headers.{HttpCookie, `Set-Cookie`}
import akka.util.ByteString
import play.api.libs.json._
import de.heikoseeberger.akkahttpplayjson.PlayJsonSupport

import java.time.Instant  
import java.time.format.DateTimeFormatter
import scala.collection.mutable
import scala.concurrent.{Await, Future}
import scala.concurrent.duration._
import scala.util.{Failure, Success}

// Import PlayJsonSupport
import PlayJsonSupport._

case class User(id: Int, username: String, hashedPassword: String)
case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  userId: Int,
  createdAt: String,
  updatedAt: String
)

case class LoginRequest(username: String, password: String)
case class RegisterRequest(username: String, password: String)
case class PasswordChangeRequest(oldPassword: String, newPassword: String)
case class TodoCreateRequest(title: String, description: String)
case class TodoUpdateRequest(title: Option[String], description: Option[String], completed: Option[Boolean])

object Implicits {
  implicit val loginRequestFormat: OFormat[LoginRequest] = Json.format[LoginRequest]
  implicit val registerRequestFormat: OFormat[RegisterRequest] = Json.format[RegisterRequest]
  implicit val passwordChangeRequestFormat: OFormat[PasswordChangeRequest] = Json.format[PasswordChangeRequest]
  implicit val userFormat: OFormat[User] = Json.format[User]
  implicit val todoCreateRequestFormat: OFormat[TodoCreateRequest] = Json.format[TodoCreateRequest]
  implicit val todoUpdateRequestFormat: OFormat[TodoUpdateRequest] = Json.format[TodoUpdateRequest]
  implicit val todoFormat: OFormat[Todo] = Json.format[Todo]
  implicit val errorFormat: OFormat[Error] = Json.format[Error]

  case class Error(error: String)
}

object TodoApp extends App with PlayJsonSupport {
  import Implicits._

  // Add implicit execution context
  implicit val executionContext = scala.concurrent.ExecutionContext.Implicits.global

  // Session manager
  object SessionManager {
    private val userSessions = mutable.Map[String, Int]() // sessionId -> userId
    
    def createSession(userId: Int): String = {
      val sessionId = java.util.UUID.randomUUID().toString
      userSessions.put(sessionId, userId)
      sessionId
    }
    
    def isValidSession(sessionId: String): Boolean = userSessions.contains(sessionId)
    
    def getUserIdBySession(sessionId: String): Option[Int] = userSessions.get(sessionId)
    
    def removeSession(sessionId: String): Boolean = userSessions.remove(sessionId).isDefined
  }

  // In-memory storage
  private val users = mutable.Map[String, User]() // username -> User  
  private val todos = mutable.Map[Int, Todo]() // id -> Todo
  private var nextUserId = 1
  private var nextTodoId = 1

  def hashPassword(password: String): String = {
    // Simple "hashing" - for production use a proper library like BCrypt
    import java.security.MessageDigest
    val md = MessageDigest.getInstance("SHA-256")
    val hashedBytes = md.digest(password.getBytes("UTF-8"))
    hashedBytes.map("%02x".format(_)).mkString
  }

  def getCurrentISOTime(): String = {
    DateTimeFormatter.ISO_INSTANT.format(Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS))
  }

  def extractSessionId(request: HttpRequest): Option[String] = {
    request.headers.find(_.is("cookie")) match {
      case Some(cookieHeader) =>
        val cookieValue = cookieHeader.value()
        val cookies = cookieValue.split(";").map(_.trim())
        val sessionCookie = cookies.find(_.startsWith("session_id="))
        sessionCookie.map(_.substring(11)) // Remove "session_id=" prefix
      case None => None
    }
  }

  def authenticate: akka.http.scaladsl.server.Directive1[Int] = {
    extractRequest flatMap { request =>
      extractSessionId(request) match {
        case Some(sessionId) if SessionManager.isValidSession(sessionId) =>
          SessionManager.getUserIdBySession(sessionId) match {
            case Some(userId) => provide(userId)
            case None => complete(StatusCodes.Unauthorized -> Error("Authentication required"))
          }
        case _ => complete(StatusCodes.Unauthorized -> Error("Authentication required"))
      }
    }
  }

  def validateUsername(username: String): Option[String] = {
    if (username.length < 3 || username.length > 50) {
      Some("Invalid username")
    } else if (!username.matches("^[a-zA-Z0-9_]+$")) {
      Some("Invalid username")
    } else {
      None
    }
  }

  val route: Route =
    pathPrefix("register") {
      post {
        entity(as[RegisterRequest]) { req =>
          validateUsername(req.username) match {
            case Some(errorMessage) => complete(StatusCodes.BadRequest -> Error(errorMessage))
            case None =>
              if (req.password.length < 8) {
                complete(StatusCodes.BadRequest -> Error("Password too short"))
              } else if (users.contains(req.username)) {
                complete(StatusCodes.Conflict -> Error("Username already exists"))
              } else {
                val newUser = User(nextUserId, req.username, hashPassword(req.password))
                users.put(req.username, newUser)
                nextUserId += 1
                complete(StatusCodes.Created -> newUser)
              }
          }
        }
      }
    } ~
    pathPrefix("login") {
      post {
        entity(as[LoginRequest]) { req =>
          users.get(req.username) match {
            case Some(user) if user.hashedPassword == hashPassword(req.password) =>
              val sessionId = SessionManager.createSession(user.id)
              val response = HttpResponse(
                status = StatusCodes.OK,
                entity = HttpEntity(ContentTypes.`application/json`, Json.toJson(User(user.id, user.username, "")).toString())
              ).withHeaders(`Set-Cookie`(HttpCookie("session_id", sessionId, path = Some("/"), httpOnly = true)))
              complete(response)
            case _ =>
              complete(StatusCodes.Unauthorized -> Error("Invalid credentials"))
          }
        }
      }
    } ~
    pathPrefix("logout") {
      post {
        authenticate { userId =>
          extractRequestContext { ctx =>
            val sessionIdOpt = extractSessionId(ctx.request)
            sessionIdOpt.foreach(SessionManager.removeSession)
            complete(StatusCodes.OK -> Json.obj())
          }
        }
      }
    } ~
    pathPrefix("me") {
      get {
        authenticate { userId =>
          val userOpt = users.values.find(_.id == userId)
          userOpt match {
            case Some(user) =>
              val userDto = User(user.id, user.username, "")
              complete(StatusCodes.OK -> userDto)
            case None => complete(StatusCodes.InternalServerError -> Error("User not found for session"))
          }
        }
      }
    } ~
    pathPrefix("password") {
      put {
        entity(as[PasswordChangeRequest]) { req =>
          authenticate { userId =>
            val userOpt = users.values.find(_.id == userId)
            userOpt match {
              case Some(user) =>
                if (user.hashedPassword != hashPassword(req.oldPassword)) {
                  complete(StatusCodes.Unauthorized -> Error("Invalid credentials"))
                } else if (req.newPassword.length < 8) {
                  complete(StatusCodes.BadRequest -> Error("Password too short"))
                } else {
                  val updatedUser = user.copy(hashedPassword = hashPassword(req.newPassword))
                  users.update(user.username, updatedUser)
                  complete(StatusCodes.OK -> Json.obj())
                }
              case None => complete(StatusCodes.InternalServerError -> Error("User not found for session"))
            }
          }
        }
      }
    } ~
    pathPrefix("todos") {
      get {
        authenticate { userId =>
          val userTodos = todos.values.filter(_.userId == userId).toList.sortBy(_.id)
          complete(userTodos)
        }
      } ~
      post {
        entity(as[TodoCreateRequest]) { req =>
          authenticate { userId =>
            if (req.title.isEmpty) {
              complete(StatusCodes.BadRequest -> Error("Title is required"))
            } else {
              val now = getCurrentISOTime()
              val newTodo = Todo(
                id = nextTodoId,
                title = req.title,
                description = req.description,
                completed = false,
                userId = userId,
                createdAt = now,
                updatedAt = now
              )
              todos.put(nextTodoId, newTodo)
              nextTodoId += 1
              complete(StatusCodes.Created -> newTodo)
            }
          }
        }
      } ~
      path(IntNumber) { todoId =>
        get {
          authenticate { userId =>
            todos.get(todoId) match {
              case Some(todo) if todo.userId == userId => complete(todo)
              case _ => complete(StatusCodes.NotFound -> Error("Todo not found"))
            }
          }
        } ~
        put {
          entity(as[TodoUpdateRequest]) { updateReq =>
            authenticate { userId =>
              todos.get(todoId) match {
                case Some(todo) if todo.userId == userId =>
                  // Validate if title is provided and empty
                  if (updateReq.title.exists(_.isEmpty)) {
                    complete(StatusCodes.BadRequest -> Error("Title is required"))
                  } else {
                    val updatedTitle = updateReq.title.getOrElse(todo.title)
                    val updatedDescription = updateReq.description.getOrElse(todo.description)
                    val updatedCompleted = updateReq.completed.getOrElse(todo.completed)
                    val now = getCurrentISOTime()

                    val updatedTodo = todo.copy(
                      title = updatedTitle,
                      description = updatedDescription,
                      completed = updatedCompleted,
                      updatedAt = now
                    )
                    
                    todos.update(todoId, updatedTodo)
                    complete(updatedTodo)
                  }
                case _ => complete(StatusCodes.NotFound -> Error("Todo not found"))
              }
            }
          }
        } ~
        delete {
          authenticate { userId =>
            todos.get(todoId) match {
              case Some(todo) if todo.userId == userId =>
                todos.remove(todoId)
                complete(StatusCodes.NoContent)
              case _ => complete(StatusCodes.NotFound -> Error("Todo not found"))
            }
          }
        }
      }
    }

    // Parse command line arguments for port
    val portOption = args.sliding(2, 2).collectFirst { case Array("--port", portStr) => portStr.toInt }
    val port = portOption.getOrElse(8080)

    implicit val system: ActorSystem[Nothing] = ActorSystem.wrap(
      akka.actor.ActorSystem("TodoAppSystem")
    )

    try {
      val bindingFuture = Http().newServerAt("0.0.0.0", port).bindFlow(route)
      
      bindingFuture.onComplete {
        case Success(binding) =>
          println(s"Server successfully bound to ${binding.localAddress}")
          println(s"Server online at http://0.0.0.0:$port/")
          
        case Failure(exception) =>
          println(s"Failed to bind to $port: ${exception.getMessage}")
          system.terminate()
          sys.exit(1)
      }
      
      // Keep the application running
      Await.result(Future.never, Duration.Inf)
    } catch {
      case ex: Exception =>
        println(s"Critial error starting server: ${ex.getMessage}")
        ex.printStackTrace()
        sys.exit(1)
    }
}