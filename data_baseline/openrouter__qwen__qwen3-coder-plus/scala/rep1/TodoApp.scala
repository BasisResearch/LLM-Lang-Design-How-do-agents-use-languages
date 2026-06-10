//> using scala "2.13.10"
//> using dep "com.typesafe.akka::akka-http:10.2.9"
//> using dep "com.typesafe.akka::akka-actor:2.6.19" 
//> using dep "com.typesafe.akka::akka-stream:2.6.19"
//> using dep "io.spray::spray-json:1.3.6"

import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directive1
import akka.http.scaladsl.server.Directives._
import spray.json._
import spray.json.DefaultJsonProtocol
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport

import java.util.concurrent.atomic.AtomicInteger
import scala.collection.mutable
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.ZoneOffset
import java.util.UUID

object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

case class User(id: Int, username: String, passwordHash: String)
case class UserNoPassword(id: Int, username: String)
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

trait JsonFormats extends DefaultJsonProtocol with SprayJsonSupport {
  implicit val userNoPasswordFormat = jsonFormat2(UserNoPassword)
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val passwordChangeFormat = jsonFormat2(PasswordChangeRequest)
}
object JsonFormats extends JsonFormats

class UserService {
  private val users = mutable.Map[String, User]()
  private val userCounter = new AtomicInteger(1)
  
  def registerUser(username: String, password: String): Option[User] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]{3,50}$") || password.length < 8 || users.contains(username)) {
      None
    } else {
      val id = userCounter.getAndIncrement()
      val user = User(id, username, password)
      users.put(username, user)
      Some(user)
    }
  }

  def authenticateUser(username: String, password: String): Option[User] = {
    users.get(username).filter(_.passwordHash == password)
  }

  def findUser(userId: Int): Option[User] = {
    users.values.find(_.id == userId)
  }

  def updatePassword(userId: Int, oldPassword: String, newPassword: String): Boolean = synchronized {
    users.values.find(_.id == userId) match {
      case Some(user) if user.passwordHash == oldPassword && newPassword.length >= 8 =>
        users.update(user.username, user.copy(passwordHash = newPassword))
        true
      case _ => false
    }
  }
}

class TodoService {
  private val todos = mutable.Map[Int, Todo]()
  private val todoCounter = new AtomicInteger(1)

  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = todoCounter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(id, title, description, false, now, now, userId)
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
    todos.get(todoId).filter(_.userId == userId) match {
      case Some(todo) =>
        val newTitle = title.getOrElse(todo.title)
        val newDesc = description.getOrElse(todo.description)
        val newCompleted = completed.getOrElse(todo.completed)
        
        if (newTitle.trim.isEmpty) None
        else {
          val updatedTodo = todo.copy(
            title = newTitle,
            description = newDesc,
            completed = newCompleted,
            updatedAt = DateTimeHelper.nowAsString()
          )
          todos.update(todoId, updatedTodo)
          Some(updatedTodo)
        }
      case None => None
    }
  }

  def deleteTodo(todoId: Int, userId: Int): Boolean = synchronized {
    todos.get(todoId).exists(todo => {
      if (todo.userId == userId) {
        todos.remove(todoId)
        true
      } else false
    })
  }
}

class SessionManager {
  private val activeSessions = mutable.Map[String, Int]()
  
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

object TodoApp extends App with JsonFormats {
  implicit val system: ActorSystem = ActorSystem("todo-app")
  implicit val executionContext = system.dispatcher

  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  def requireAuth: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) =>
      sessionManager.getUserIdForSession(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None =>
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  val route = {
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
                val msg = if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) "Invalid username" 
                         else if (password.length < 8) "Password too short" 
                         else "Username already exists"
                complete(StatusCodes.Conflict -> ErrorResponse(msg))
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

            userService.authenticateUser(username, password) match {
              case Some(user) =>
                val sessionId = sessionManager.createSession(user.id)
                val cookie = akka.http.scaladsl.model.headers.`Set-Cookie`(
                  akka.http.scaladsl.model.headers.HttpCookie(
                    "session_id", 
                    sessionId,
                    httpOnly = true,
                    path = Some("/"))
                )
                respondWithHeader(cookie) {
                  complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
                }
              case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Invalid credentials"))
            }
          } catch {
            case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
          }
        }
      }
    } ~
    pathPrefix("logout") {
      post {
        requireAuth { _ =>
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
              case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      }
    } ~
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
              case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      } ~
      path(IntNumber) { id =>
        get {
          requireAuth { userId =>
            todoService.getTodo(id, userId) match {
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
                val title = json.fields.get("title").map(_.convertTo[String])
                val desc = json.fields.get("description").map(_.convertTo[String])
                val completed = json.fields.get("completed").map(_.convertTo[Boolean])
                
                if (title.exists(_.trim.isEmpty)) {
                  complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
                } else {
                  todoService.updateTodo(id, userId, title, desc, completed) match {
                    case Some(todo) => complete(StatusCodes.OK -> todo)
                    case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
                  }
                }
              } catch {
                case _: Exception => complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
              }
            }
          }
        } ~
        delete {
          requireAuth { userId =>
            if (todoService.deleteTodo(id, userId)) complete(StatusCodes.NoContent)
            else complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
          }
        }
      }
    } ~ 
    pathEndOrSingleSlash {
      get {
        complete(StatusCodes.OK -> JsObject("message" -> JsString("Todo API Server")))
      }
    }
  }

  val port = args.sliding(2, 2).collectFirst { case Array("--port", p) => p.toInt }.getOrElse(8080)
  Http().bindAndHandle(route, "0.0.0.0", port)
  println(s"Server online at http://0.0.0.0:$port/")
  scala.io.StdIn.readLine()
  system.terminate()
}