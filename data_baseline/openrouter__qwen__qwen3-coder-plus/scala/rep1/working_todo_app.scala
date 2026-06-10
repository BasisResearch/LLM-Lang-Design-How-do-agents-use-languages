//> using scala "2.13.10"
//> using dep "com.typesafe.akka::akka-http:10.2.9"
//> using dep "com.typesafe.akka::akka-actor:2.6.19" 
//> using dep "com.typesafe.akka::akka-stream:2.6.19"
//> using dep "io.spray::spray-json:1.3.6"

// Core imports
import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directive1
import akka.http.scaladsl.server.Directives._
import spray.json._  
import spray.json.DefaultJsonProtocol
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport

// Java utilities
import java.util.concurrent.atomic.AtomicInteger
import java.util.UUID
import scala.collection.mutable
import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
import scala.io.StdIn

// Helper for current datetime
object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

// Models
case class User(id: Int, username: String, passwordHash: String)
case class UserNoPassword(id: Int, username: String)
case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  createdAt: String,
  updatedAt: String,
  userId: Int
)
case class ErrorResponse(error: String)
case class PasswordChangeRequest(old_password: String, new_password: String)

// Define the JSON format
trait JsonProtocols extends DefaultJsonProtocol {
  implicit val userNoPasswordFormat = jsonFormat2(UserNoPassword)
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val passwordChangeFormat = jsonFormat2(PasswordChangeRequest)
  implicit val todoFormat = jsonFormat6(Todo)
}

object JsonProtocols extends JsonProtocols

// Service classes
class UserService {
  private val users = mutable.Map[String, User]()
  private val userCounter = new AtomicInteger(1)

  def registerUser(username: String, password: String): Option[User] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
      return None
    }
    if (password.length < 8) {
      return None
    }
    if (users.contains(username)) {
      return None
    }
    val id = userCounter.getAndIncrement()
    val user = User(id, username, password)
    users.put(username, user)
    Some(user)
  }

  def authenticateUser(username: String, password: String): Option[User] = {
    users.get(username).filter(_.passwordHash == password)
  }

  def findUser(userId: Int): Option[User] = users.values.find(_.id == userId)
  
  def findUserByUsername(username: String): Option[User] = users.get(username)

  def updatePassword(userId: Int, oldPassword: String, newPassword: String): Boolean = synchronized {
    users.values.find(_.id == userId) match {
      case Some(user) if user.passwordHash == oldPassword =>
        if (newPassword.length < 8) false
        else {
          users.update(user.username, user.copy(passwordHash = newPassword))
          true
        }
      case _ => false // No user or password doesn't match
    }
  }
}

class TodoService {
  private val todos = mutable.Map[Int, Todo]()
  private val todoCounter = new AtomicInteger(1)

  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = todoCounter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(id = id, title = title, description = description, completed = false,
      createdAt = now, updatedAt = now, userId = userId)
    todos.put(id, todo)
    todo
  }

  def getTodosByUserId(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getTodo(todoId: Int, userId: Int): Option[Todo] = {
    todos.get(todoId).filter(_.userId == userId)
  }

  def updateTodo(todoId: Int, userId: Int, title: Option[String], 
    description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    todos.get(todoId).filter(_.userId == userId) match {
      case Some(todo) =>
        val newTitle = title.getOrElse(todo.title)
        if (newTitle.trim.isEmpty) return None  // Validation failed
        val newDescription = description.getOrElse(todo.description)
        val newCompleted = completed.getOrElse(todo.completed)
        val updatedTodo = todo.copy(
          title = newTitle,
          description = newDescription,
          completed = newCompleted,
          updatedAt = DateTimeHelper.nowAsString()
        )
        todos.update(todoId, updatedTodo)
        Some(updatedTodo)
      case _ => None // Not found or not owned by user
    }
  }

  def deleteTodo(todoId: Int, userId: Int): Boolean = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        todos.remove(todoId)
        true
      case _ => false // Not found or not owned by user
    }
  }
}

class SessionManager {
  private val activeSessions = mutable.Map[String, Int]() // sessionId -> userId

  def createSession(userId: Int): String = {
    val sessionId = UUID.randomUUID().toString
    activeSessions.put(sessionId, userId)
    sessionId
  }

  def getUserIdForSession(sessionId: String): Option[Int] = {
    activeSessions.get(sessionId)
  }

  def destroySession(sessionId: String): Unit = {
    activeSessions.remove(sessionId)
  }
}

// Main application
object TodoApiApp extends App with JsonProtocols with SprayJsonSupport {
  implicit val system = ActorSystem("todo-api")
  implicit val executionContext = system.dispatcher

  // Initialize services
  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  // Require auth utility
  def requireAuth: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) =>
      sessionManager.getUserIdForSession(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None =>
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  // Main route definition
  val route = {
    // Registration endpoint
    pathPrefix("register") {
      post {
        entity(as[String]) { body =>
          try {
            val json = body.parseJson.asJsObject
            val username = json.fields("username").convertTo[String]
            val password = json.fields("password").convertTo[String]
            
            userService.registerUser(username, password) match {
              case Some(user) => 
                complete(StatusCodes.Created -> UserNoPassword(user.id, user.username))
              case None =>
                if (userService.findUserByUsername(username).isDefined) {
                  complete(StatusCodes.Conflict -> ErrorResponse("Username already exists"))
                } else if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Invalid username"))
                } else {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
                }
            }
          } catch {
            case _: Exception =>
              complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
          }
        }
      }
    } ~
    
    // Login endpoint
    pathPrefix("login") {
      post {
        entity(as[String]) { body =>
          try {
            val json = body.parseJson.asJsObject
            val username = json.fields("username").convertTo[String]
            val password = json.fields("password").convertTo[String]
            
            userService.authenticateUser(username, password) match {
              case Some(user) =>
                val sessionId = sessionManager.createSession(user.id)
                val cookie = akka.http.scaladsl.model.headers.`Set-Cookie`(
                  HttpCookie("session_id", sessionId, httpOnly = Some(true), path = Some("/"))
                )
                respondWithHeader(cookie) {
                  complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
                }
              case None =>
                complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
            }
          } catch {
            case _: Exception =>
              complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
          }
        }
      }
    } ~
    
    // Logout endpoint
    pathPrefix("logout") {
      post {
        requireAuth { userId =>
          optionalCookie("session_id") { cookieOpt =>
            cookieOpt.foreach(cookie => sessionManager.destroySession(cookie.value))
            complete(StatusCodes.OK -> JsObject.empty)
          }
        }
      }
    } ~
    
    // Get current user
    pathPrefix("me") {
      get {
        requireAuth { userId =>
          userService.findUser(userId) match {
            case Some(user) =>
              complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
            case None =>
              complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
          }
        }
      }
    } ~
    
    // Change password
    pathPrefix("password") {
      put {
        requireAuth { userId =>
          entity(as[String]) { body =>
            try {
              val json = body.parseJson.asJsObject
              val oldPassword = json.fields("old_password").convertTo[String]
              val newPassword = json.fields("new_password").convertTo[String]
              
              if (newPassword.length < 8) {
                complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
              } else if (userService.updatePassword(userId, oldPassword, newPassword)) {
                complete(StatusCodes.OK -> JsObject.empty)
              } else {
                complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
              }
            } catch {
              case _: Exception =>
                complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      }
    } ~
    
    // Todo endpoints
    pathPrefix("todos") {
      get {
        requireAuth { userId =>
          val todos = todoService.getTodosByUserId(userId)
          complete(StatusCodes.OK -> todos)
        }
      } ~
      
      post {
        requireAuth { userId =>
          entity(as[String]) { body =>
            try {
              val json = body.parseJson.asJsObject
              val title = json.fields("title").convertTo[String]
              if (title.trim.isEmpty) {
                complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
              } else {
                val description = json.fields.get("description").map(_.convertTo[String]).getOrElse("")
                val newTodo = todoService.createTodo(title, description, userId)
                complete(StatusCodes.Created -> newTodo)
              }
            } catch {
              case _: Exception =>
                complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      } ~
      
      // Individual todo operations
      path(IntNumber) { todoId =>
        get {
          requireAuth { userId =>
            todoService.getTodo(todoId, userId) match {
              case Some(todo) => complete(StatusCodes.OK -> todo)
              case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        } ~
        
        put {
          requireAuth { userId =>
            entity(as[String]) { body =>
              try {
                val json = body.parseJson.asJsObject
                // Extract optional fields
                val title = json.fields.get("title").map(_.convertTo[String])
                val description = json.fields.get("description").map(_.convertTo[String])
                val completed = json.fields.get("completed").map(_.convertTo[Boolean])
                
                todoService.updateTodo(todoId, userId, title, description, completed) match {
                  case Some(todo) => complete(StatusCodes.OK -> todo)
                  case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
                }
              } catch {
                case _: Exception =>
                  complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
              }
            }
          }
        } ~
        
        delete {
          requireAuth { userId =>
            if (todoService.deleteTodo(todoId, userId)) {
              complete(StatusCodes.NoContent)
            } else {
              complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        }
      }
    } ~
    
    // Root path - just for testing
    pathEndOrSingleSlash {
      get {
        complete(StatusCodes.OK -> JsObject("message" -> JsString("Todo API Server Running")))
      }
    }
  }

  // Get port from command line arguments
  val port = args.sliding(2, 2).collectFirst { case Array("--port", portStr) => portStr.toInt }.getOrElse(8080)
  
  // Start server
  val bindingFuture = Http().bindAndHandle(route, "0.0.0.0", port)
  println(s"Server online at http://0.0.0.0:$port/")
  println(s"Press RETURN to stop...")
  
  StdIn.readLine()
  
  // Properly shutdown
  bindingFuture
    .flatMap(_.unbind())
    .onComplete(_ => system.terminate())
}