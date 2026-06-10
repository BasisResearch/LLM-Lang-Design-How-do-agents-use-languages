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
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport

// JSON protocol
object MyJsonProtocol extends DefaultJsonProtocol with SprayJsonSupport {
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val userFormat = jsonFormat2(UserNoPassword)
}

import MyJsonProtocol._

// Utilities
import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

// Data models
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

// Services implementation
import java.util.concurrent.atomic.AtomicInteger
import scala.collection.mutable
import java.util.UUID

class UserService {
  private val users = mutable.Map[String, User]()
  private val counter = new AtomicInteger(1)

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

  def updateUserPassword(userId: Int, oldPw: String, newPw: String): Boolean = synchronized {
    users.values.find(_.id == userId) match {
      case Some(user) if user.passwordHash == oldPw && newPw.length >= 8 =>
        users.update(user.username, user.copy(passwordHash = newPw))
        true
      case _ => false
    }
  }

  def findUserByUsername(username: String): Option[User] = {
    users.get(username)
  }
}

class TodoService {
  private val allTodos = mutable.Map[Int, Todo]()
  private val counter = new AtomicInteger(1)

  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = counter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(id, title, description, false, now, now, userId)
    allTodos.put(id, todo)
    todo
  }

  def getTodosOfUser(userId: Int): List[Todo] = {
    allTodos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getTodoById(id: Int, userId: Int): Option[Todo] = {
    allTodos.get(id).filter(_.userId == userId)
  }

  def updateTodo(id: Int, userId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    allTodos.get(id).filter(_.userId == userId) match {
      case Some(current) =>
        val newTitle = title match {
          case Some(t) if t.trim.nonEmpty => t
          case Some(_) => return None // Bad title
          case None => current.title
        }
        val newDescription = description.getOrElse(current.description)
        val newCompleted = completed.getOrElse(current.completed)
        val updated = current.copy(
          title = newTitle,
          description = newDescription,
          completed = newCompleted,
          updatedAt = DateTimeHelper.nowAsString()
        )
        allTodos.update(id, updated)
        Some(updated)
      case None => None
    }
  }

  def deleteTodo(id: Int, userId: Int): Boolean = synchronized {
    allTodos.get(id) match {
      case Some(todo) if todo.userId == userId =>
        allTodos.remove(id)
        true
      case _ => false
    }
  }
}

class SessionManager {
  private val sessions = mutable.Map[String, Int]()

  def newSession(userId: Int): String = {
    val sessionId = UUID.randomUUID().toString
    sessions.put(sessionId, userId)
    sessionId
  }

  def lookup(userId: String): Option[Int] = sessions.get(userId)

  def remove(sessionId: String): Unit = sessions.remove(sessionId)
}

// Main application
object MinTodoServer extends App {
  implicit val system = ActorSystem("min-todo-server")
  implicit val ec = system.dispatcher

  val userSvc = new UserService()
  val todoSvc = new TodoService()
  val sessionSvc = new SessionManager()

  // Auth validation directive
  def authenticated: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) =>
      sessionSvc.lookup(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None =>
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  val apiRoute =
    pathPrefix("register") {
      post {
        entity(as[String]) { rawJson =>
          try {
            val json = rawJson.parseJson.asJsObject
            val userName = json.fields("username").convertTo[String]
            val pwd = json.fields("password").convertTo[String]

            userSvc.registerUser(userName, pwd) match {
              case Some(user) =>
                complete(StatusCodes.Created -> UserNoPassword(user.id, user.username))
              case None =>
                if (userSvc.findUserByUsername(userName).isDefined) {
                  complete(StatusCodes.Conflict -> ErrorResponse("Username already exists"))
                } else if (userName.length < 3 || userName.length > 50 || !userName.matches("^[a-zA-Z0-9_]+$")) {
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
    pathPrefix("login") {
      post {
        entity(as[String]) { rawJson =>
          try {
            val json = rawJson.parseJson.asJsObject
            val userName = json.fields("username").convertTo[String]
            val pwd = json.fields("password").convertTo[String]

            userSvc.authenticate(userName, pwd) match {
              case Some(user) =>
                val sid = sessionSvc.newSession(user.id)
                val setCookie = akka.http.scaladsl.model.headers.`Set-Cookie`(
                  akka.http.scaladsl.model.headers.HttpCookie(
                    name = "session_id",
                    value = sid,
                    httpOnly = Some(true),
                    path = Some("/"),
                    secure = None,
                    domain = None,
                    maxAge = None,
                    sameSite = None
                  )
                )
                respondWithHeader(setCookie) {
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
    pathPrefix("logout") {
      post {
        authenticated { _ =>
          optionalCookie("session_id") { cookieOpt =>
            cookieOpt.foreach(c => sessionSvc.remove(c.value))
            complete(StatusCodes.OK -> JsObject.empty)
          }
        }
      }
    } ~
    pathPrefix("me") {
      get {
        authenticated { userId =>
          userSvc.findUser(userId) match {
            case Some(user) => complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
            case None => complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
          }
        }
      }
    } ~
    pathPrefix("password") {
      put {
        authenticated { userId =>
          entity(as[String]) { rawJson =>
            try {
              val json = rawJson.parseJson.asJsObject
              val oldPwd = json.fields("old_password").convertTo[String]
              val newPwd = json.fields("new_password").convertTo[String]

              if (newPwd.length < 8) {
                complete(StatusCodes.BadRequest -> ErrorResponse("Password too short"))
              } else if (userSvc.updateUserPassword(userId, oldPwd, newPwd)) {
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
    pathPrefix("todos") {
      get {
        authenticated { userId =>
          complete(StatusCodes.OK -> todoSvc.getTodosOfUser(userId))
        }
      } ~
      post {
        authenticated { userId =>
          entity(as[String]) { rawJson =>
            try {
              val json = rawJson.parseJson.asJsObject
              val title = json.fields("title").convertTo[String]

              if (title.trim.nonEmpty) {
                val desc = json.fields.get("description").map(_.convertTo[String]).getOrElse("")
                val newTodo = todoSvc.createTodo(title, desc, userId)
                complete(StatusCodes.Created -> newTodo)
              } else {
                complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
              }
            } catch {
              case _: Exception =>
                complete(StatusCodes.BadRequest -> ErrorResponse("Invalid input"))
            }
          }
        }
      } ~
      path(IntNumber) { taskId =>
        get {
          authenticated { userId =>
            todoSvc.getTodoById(taskId, userId) match {
              case Some(todo) => complete(StatusCodes.OK -> todo)
              case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        } ~
        put {
          authenticated { userId =>
            entity(as[String]) { rawJson =>
              try {
                val json = rawJson.parseJson.asJsObject
                val optTitle = json.fields.get("title").map(_.convertTo[String])
                val optDesc = json.fields.get("description").map(_.convertTo[String])
                val optIsDone = json.fields.get("completed").map(_.convertTo[Boolean])

                todoSvc.updateTodo(taskId, userId, optTitle, optDesc, optIsDone) match {
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
          authenticated { userId =>
            if (todoSvc.deleteTodo(taskId, userId)) {
              complete(StatusCodes.NoContent)
            } else {
              complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
            }
          }
        }
      }
    }

  val port = args.sliding(2, 2).collectFirst { case Array("--port", p) => p.toInt }.getOrElse(8080)
  Http().bindAndHandle(apiRoute, "0.0.0.0", port)
  println(s"Server started at http://0.0.0.0:$port/")
  println("Press Enter to quit.")
  scala.io.StdIn.readLine()
  system.terminate()
}