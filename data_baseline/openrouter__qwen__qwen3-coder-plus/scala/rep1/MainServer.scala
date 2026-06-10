//> using scala "2.13.10"
//> using dep com.typesafe.akka::akka-http:10.2.9
//> using dep com.typesafe.akka::akka-actor:2.6.19 
//> using dep com.typesafe.akka::akka-stream:2.6.19
//> using dep io.spray::spray-json:1.3.6

// All code in a single file for clarity

import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.{Directive1, Route}
import akka.http.scaladsl.server.Directives._
import spray.json._
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonMarshaller._
import akka.http.scaladsl.unmarshalling.Unmarshal
import akka.http.scaladsl.model.headers.{Cookie => HttpCookie}
import spray.json.DefaultJsonProtocol._

import java.util.concurrent.atomic.AtomicInteger
import scala.collection.mutable
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.ZoneOffset
import java.util.UUID

// DateTime utilities
object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

// Data models
case class User(
                 id: Int,
                 username: String,
                 passwordHash: String 
               )

case class UserNoPassword(id: Int, username: String)
object UserNoPassword {
  def apply(user: User): UserNoPassword = UserNoPassword(user.id, user.username)
}

case class Todo(
                 id: Int,
                 title: String,
                 description: String = "",
                 completed: Boolean = false,
                 createdAt: String,
                 updatedAt: String,
                 userId: Int
               )

case class ErrorResponse(error: String)
case class PasswordChangeRequest(old_password: String, new_password: String)

// JSON Protocol definitions
trait TodoJsonProtocol extends DefaultJsonProtocol {
  implicit val userNoPasswordFormat = jsonFormat2(UserNoPassword)
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val passwordChangeFormat = jsonFormat2(PasswordChangeRequest)
}

// Services
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
    val maybeUser = users.get(username)
    maybeUser.filter(_.passwordHash == password)
  }

  def findUser(userId: Int): Option[User] = {
    users.values.find(_.id == userId)
  }

  def findUserByUsername(username: String): Option[User] = {
    users.get(username)
  }

  def updatePassword(userId: Int, oldPassword: String, newPassword: String): Boolean = synchronized {
    val existingUser = users.values.find(_.id == userId)
    existingUser match {
      case Some(user) =>
        if (user.passwordHash != oldPassword || newPassword.length < 8) {
          false
        } else {
          users.update(user.username, user.copy(passwordHash = newPassword))
          true
        }
      case None => false
    }
  }
}

class TodoService {
  private val todos = mutable.Map[Int, Todo]()
  private val todoCounter = new AtomicInteger(1)

  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = todoCounter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(
      id = id,
      title = title,
      description = description,
      completed = false,
      createdAt = now,
      updatedAt = now,
      userId = userId
    )
    todos.put(id, todo)
    todo
  }

  def getTodosByUserId(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getTodo(todoId: Int, userId: Int): Option[Todo] = {
    todos.get(todoId).filter(_.userId == userId)
  }

  def updateTodo(todoId: Int, userId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        val newTitle = title.getOrElse(todo.title)
        val newDescription = description.getOrElse(todo.description)
        val newCompleted = completed.getOrElse(todo.completed)
        
        if (newTitle.trim.isEmpty) {
          return None  // Title validation fails
        }
        
        val updatedTodo = todo.copy(
          title = newTitle,
          description = newDescription,
          completed = newCompleted,
          updatedAt = DateTimeHelper.nowAsString()
        )
        todos.update(todoId, updatedTodo)
        Some(updatedTodo)
      case _ => None
    }
  }

  def deleteTodo(todoId: Int, userId: Int): Boolean = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        todos.remove(todoId)
        true
      case _ => false
    }
  }
}

class SessionManager {
  private val activeSessions = mutable.Map[String, Int]()  // sessionId -> userId
  
  def createSession(userId: Int): String = {
    val sessionId = generateSessionId()
    activeSessions.put(sessionId, userId)
    sessionId
  }
  
  def getUserIdForSession(sessionId: String): Option[Int] = {
    activeSessions.get(sessionId)
  }
  
  def destroySession(sessionId: String): Unit = {
    activeSessions.remove(sessionId)
  }
  
  private def generateSessionId(): String = {
    UUID.randomUUID().toString
  }
}

object MainServer extends App with TodoJsonProtocol {
  implicit val system = ActorSystem("todo-api")
  implicit val ec = system.dispatcher

  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  // Add a new import for SprayJsonSupport
  import SprayJsonSupport._

  def authenticate: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) =>
      sessionManager.getUserIdForSession(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None => 
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  val route: Route = {
    pathPrefix("register") {
      post {
        entity(as[String]) { body =>
          try {
            val json = body.parseJson.asJsObject
            val username = json.fields("username").convertTo[String]
            val password = json.fields("password").convertTo[String]

            userService.registerUser(username, password) match {
              case Some(user) =>
                complete(StatusCodes.Created -> UserNoPassword(user))
              case None =>
                if (username.length < 3 || username.length > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Invalid username"))
                } else if (password.length < 8) {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
                } else {
                  complete(StatusCodes.Conflict -> ErrorResponse("Username already exists"))
                }
            }
          } catch {
            case _: Exception =>
              complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
          }
        }
      }
    } ~
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
                  akka.http.scaladsl.model.headers.HttpCookie(
                    name = "session_id",
                    value = sessionId,
                    httpOnly = Some(true),
                    secure = Some(false),
                    maxAge = Some(3600 * 24 * 30), // 30 days
                    path = Some("/")
                  )
                )
                
                respondWithHeader(cookie) {
                  complete(StatusCodes.OK -> UserNoPassword(user))
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
    pathPrefix("logout") {
      post {
        authenticate { userId =>
          optionalCookie("session_id") { cookieOpt =>
            cookieOpt.foreach(cookie => sessionManager.destroySession(cookie.value))
            complete(StatusCodes.OK -> JsObject.empty)
          }
        }
      }
    } ~
    pathPrefix("me") {
      get {
        authenticate { userId =>
          userService.findUser(userId) match {
            case Some(user) =>
              complete(StatusCodes.OK -> UserNoPassword(user))
            case None =>
              complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
          }
        }
      }
    } ~
    pathPrefix("password") {
      put {
        authenticate { userId =>
          entity(as[String]) { body =>
            try {
              val json = body.parseJson.asJsObject
              val oldPassword = json.fields("old_password").convertTo[String]
              val newPassword = json.fields("new_password").convertTo[String]

              if (newPassword.length < 8) {
                complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
              } else {
                if (userService.updatePassword(userId, oldPassword, newPassword)) {
                  complete(StatusCodes.OK -> JsObject.empty)
                } else {
                  complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
                }
              }
            } catch {
              case _: Exception =>
                complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      }
    } ~
    pathPrefix("todos") {
      get {
        authenticate { userId =>
          val todos = todoService.getTodosByUserId(userId)
          complete(StatusCodes.OK -> todos)
        }
      } ~
      post {
        authenticate { userId =>
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
      path(IntNumber) { id =>
        get {
          authenticate { userId =>
            todoService.getTodo(id, userId) match {
              case Some(todo) =>
                complete(StatusCodes.OK -> todo)
              case None =>
                complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        } ~
        put {
          authenticate { userId =>
            entity(as[String]) { body =>
              try {
                val json = body.parseJson.asJsObject
                
                val titleOpt = json.fields.get("title").map(_.convertTo[String])
                val descriptionOpt = json.fields.get("description").map(_.convertTo[String])
                val completedOpt = json.fields.get("completed").map(_.convertTo[Boolean])

                if (titleOpt.exists(_.trim.isEmpty)) {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
                } else {
                  todoService.updateTodo(id, userId, titleOpt, descriptionOpt, completedOpt) match {
                    case Some(updatedTodo) =>
                      complete(StatusCodes.OK -> updatedTodo)
                    case None =>
                      complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
                  }
                }
              } catch {
                case _: Exception =>
                  complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
              }
            }
          }
        } ~
        delete {
          authenticate { userId =>
            if (todoService.deleteTodo(id, userId)) {
              complete(StatusCodes.NoContent)
            } else {
              complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        }
      }
    } ~
    pathEndOrSingleSlash {
      get {
        complete(StatusCodes.OK -> JsObject("message" -> JsString("Todo API")))
      }
    }
  }

  val port = args.sliding(2, 2).collectFirst { case Array("--port", portStr) => portStr.toInt }.getOrElse(8080)
  Http().bindAndHandle(route, "0.0.0.0", port)
  
  println(s"Server started on http://0.0.0.0:$port")
  println("Press Return to stop...")
  scala.io.StdIn.readLine()
  
  system.terminate()
}