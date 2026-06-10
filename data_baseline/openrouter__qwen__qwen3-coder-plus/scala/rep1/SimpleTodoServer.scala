//> using scala "2.13.10"
//> using dep "com.typesafe.akka::akka-http:10.2.9"
//> using dep "com.typesafe.akka::akka-actor:2.6.19"
//> using dep "com.typesafe.akka::akka-stream:2.6.19"
//> using dep "io.spray::spray-json:1.3.6"
import scala.language.postfixOps
import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directive1
import akka.http.scaladsl.server.Directives._
import spray.json._
import spray.json.DefaultJsonProtocol

// Basic models
case class User(id: Int, username: String, passwordHash: String)
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
case class UserNoPassword(id: Int, username: String)

// Date/time helper
import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

// Define formats separately from trait
object FormatObjects extends DefaultJsonProtocol {
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val userNoPasswordFormat = jsonFormat2(UserNoPassword)
}

import FormatObjects._

// Simple services with mutable collections
import java.util.concurrent.atomic.AtomicInteger
import scala.collection.mutable
import java.util.UUID

class UserService {
  private val users = mutable.Map[String, User]()
  private val counter = new AtomicInteger(1)

  def registerUser(username: String, password: String): Option[User] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]{3,50}$") || password.length < 8 || users.contains(username)) {
      return None
    }
    val id = counter.getAndIncrement()
    val user = User(id, username, password)
    users.put(username, user)
    Some(user)
  }

  def authenticate(username: String, password: String): Option[User] = {
    users.get(username).filter(_.passwordHash == password)
  }

  def findUser(userId: Int): Option[User] = {
    users.values.find(_.id == userId)
  }

  def updatePassword(userId: Int, oldPw: String, newPw: String): Boolean = synchronized {
    users.values.find(_.id == userId) match {
      case Some(u) if u.passwordHash == oldPw && newPw.length >= 8 =>
        users.update(u.username, u.copy(passwordHash = newPw))
        true
      case _ => false
    }
  }
}

class TodoService {
  private val todos = mutable.Map[Int, Todo]()
  private val counter = new AtomicInteger(1)

  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = counter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(id, title, description, false, now, now, userId) 
    todos.put(id, todo)
    todo
  }

  def getTodosByUser(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getTodoById(id: Int, userId: Int): Option[Todo] = {
    todos.get(id).filter(_.userId == userId)
  }

  def updateTodo(id: Int, userId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    todos.get(id).filter(_.userId == userId) match {
      case Some(todo) =>
        val newTitle = title match {
          case Some(t) if t.trim.nonEmpty => t
          case Some(_) => return None // Validation error
          case None => todo.title
        }
        val newDesc = description.getOrElse(todo.description) 
        val newComplete = completed.getOrElse(todo.completed)
        val updated = todo.copy(
          title = newTitle,
          description = newDesc,
          completed = newComplete,
          updatedAt = DateTimeHelper.nowAsString()
        )
        todos.update(id, updated)
        Some(updated)
      case None => None
    }
  }

  def deleteTodo(id: Int, userId: Int): Boolean = synchronized {
    todos.get(id) match {
      case Some(todo) if todo.userId == userId => 
        todos.remove(id)
        true
      case _ => false
    }
  }
}

class SessionManager {
  private val sessions = mutable.Map[String, Int]()

  def createSession(userId: Int): String = {
    val sessionId = UUID.randomUUID().toString
    sessions.put(sessionId, userId)
    sessionId
  }

  def getUserId(sessionId: String): Option[Int] = sessions.get(sessionId)
  
  def destroySession(sessionId: String): Unit = sessions.remove(sessionId)
}

// Main app
object SimpleTodoServer extends App {
  implicit val system = ActorSystem("todo-server")
  implicit val ec = system.dispatcher

  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  def requireAuth: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) => 
      sessionManager.getUserId(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None => 
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  val route = 
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
                val msg = if (userService.findUserByUsername(username).isDefined) "Username already exists"
                         else if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) "Invalid username"
                         else "Password too short"
                complete(StatusCodes.BadRequest -> ErrorResponse(msg))
            }
          } catch {
            case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
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
            
            userService.authenticate(username, password) match {
              case Some(user) =>
                val sessionId = sessionManager.createSession(user.id)
                val cookie = akka.http.scaladsl.model.headers.`Set-Cookie`(
                  akka.http.scaladsl.model.headers.HttpCookie("session_id", sessionId, httpOnly = true, path = Some("/"))
                )
                respondWithHeader(cookie) {
                  complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
                }
              case None =>
                complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
            }
          } catch {
            case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
          }
        }
      }
    } ~
    pathPrefix("logout") {
      post {
        requireAuth { userId =>
          optionalCookie("session_id") { cookieOpt =>
            cookieOpt.foreach(c => sessionManager.destroySession(c.value))
            complete(StatusCodes.OK -> JsObject.empty)
          }
        }
      }
    } ~
    pathPrefix("me") {
      get {
        requireAuth { userId =>
          userService.findUser(userId) match {
            case Some(user) => complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
            case None => complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
          }
        }
      }
    } ~
    pathPrefix("password") {
      put {
        requireAuth { userId =>
          entity(as[String]) { body =>
            try {
              val json = body.parseJson.asJsObject
              val oldPw = json.fields("old_password").convertTo[String]
              val newPw = json.fields("new_password").convertTo[String]
              
              if (newPw.length < 8) {
                complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
              } else if (userService.updatePassword(userId, oldPw, newPw)) {
                complete(StatusCodes.OK -> JsObject.empty)
              } else {
                complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
              }
            } catch {
              case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      }
    } ~
    pathPrefix("todos") {
      get {
        requireAuth { userId =>
          complete(StatusCodes.OK -> todoService.getTodosByUser(userId))
        }
      } ~
      post {
        requireAuth { userId =>
          entity(as[String]) { body =>
            try {
              val json = body.parseJson.asJsObject
              val title = json.fields("title").convertTo[String]
              
              if (title.trim.nonEmpty) {
                val desc = json.fields.getOrElse("description", JsString("")).convertTo[String]
                val todo = todoService.createTodo(title, desc, userId)
                complete(StatusCodes.Created -> todo)
              } else {
                complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
              }
            } catch {
              case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      } ~
      path(IntNumber) { id =>
        get {
          requireAuth { userId =>
            todoService.getTodoById(id, userId) match {
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
                val optTitle = json.fields.get("title").map(_.convertTo[String])
                val optDesc = json.fields.get("description").map(_.convertTo[String])
                val optCompleted = json.fields.get("completed").map(_.convertTo[Boolean])
                
                todoService.updateTodo(id, userId, optTitle, optDesc, optCompleted) match {
                  case Some(todo) => complete(StatusCodes.OK -> todo)
                  case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
                }
              } catch {
                case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
              }
            }
          }
        } ~
        delete {
          requireAuth { userId =>
            if (todoService.deleteTodo(id, userId)) {
              complete(StatusCodes.NoContent)
            } else {
              complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        }
      }
    }

  val port = args.sliding(2, 2).collectFirst { case Array("--port", p) => p.toInt }.getOrElse(8080)
  Http().bindAndHandle(route, "0.0.0.0", port)
  println(s"Server online at http://0.0.0.0:$port/")
  println("Press Enter to quit...")
  scala.io.StdIn.readLine()
  system.terminate()
}

// Add extension method for finding user by username in UserService
implicit class UserServiceExtensions(val service: UserService) extends AnyVal {
  def findUserByUsername(username: String): Option[User] = {
    service.users.get(username) 
  }
}