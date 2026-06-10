//> using scala "2.13.10"
//> using dep "com.typesafe.akka::akka-http:10.2.9"
//> using dep "com.typesafe.akka::akka-actor:2.6.19"  
//> using dep "com.typesafe.akka::akka-stream:2.6.19"
//> using dep "io.spray::spray-json:1.3.6"
import scala.language.postfixOps // for ~ operator

// Main Akka components
import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directive1
import akka.http.scaladsl.server.Directives._

// JSON libraries
import spray.json._
import spray.json.DefaultJsonProtocol

// Java util imports
import java.time.format.DateTimeFormatter
import java.time.{Instant, ZoneOffset}
import java.util.concurrent.atomic.AtomicInteger
import java.util.UUID
import scala.collection.mutable

// DateTime formatter
object DateTimeHelper {
  private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
  
  def nowAsISO: String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(formatter)
  }
}

// Core entities
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
case class PasswordChangeRequest(old_password: String, new_password: String)
case class ErrorResponse(error: String)

// Define JSON formats by extending both DefaultJsonProtocol and SprayJsonSupport trait
trait TodoJsonProtocol extends DefaultJsonProtocol {
  implicit val userFormat = jsonFormat2(UserNoPassword)
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val passwordFormat = jsonFormat2(PasswordChangeRequest)
}

object TodoJsonProtocol extends TodoJsonProtocol

// Services
class UserService {
  private val users = mutable.HashMap[String, User]()
  private val userCounter = new AtomicInteger(1)

  def register(username: String, password: String): Option[User] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) return None
    if (password.length < 8) return None
    if (users.contains(username)) return None

    val id = userCounter.getAndIncrement()
    val newUser = User(id, username, password)
    users.put(username, newUser)
    Some(newUser)
  }

  def authenticate(username: String, pwd: String): Option[User] = {
    users.get(username).filter(_.passwordHash == pwd)
  }

  def findById(id: Int): Option[User] = {
    users.values.find(_.id == id)
  }

  def updatePassword(userId: Int, oldPw: String, newPw: String): Boolean = synchronized {
    if (newPw.length < 8) return false
    
    users.values.find(_.id == userId) match {
      case Some(user) if user.passwordHash == oldPw =>
        users.update(user.username, user.copy(passwordHash = newPw))
        true
      case _ => false
    }
  }

  def findByUsername(username: String): Option[User] = {
    users.get(username)
  }
}

class TodoService {
  private val todos = mutable.HashMap[Int, Todo]()
  private val todoCounter = new AtomicInteger(1)

  def create(title: String, description: String, userId: Int): Todo = synchronized {
    val id = todoCounter.getAndIncrement()
    val now = DateTimeHelper.nowAsISO
    val newTodo = Todo(id, title, description, false, now, now, userId)
    todos.put(id, newTodo)
    newTodo
  }

  def getByUserId(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getById(todoId: Int, userId: Int): Option[Todo] = {
    todos.get(todoId).filter(_.userId == userId)
  }

  def update(
    id: Int, 
    userId: Int, 
    title: Option[String], 
    description: Option[String], 
    completed: Option[Boolean]
  ): Option[Todo] = synchronized {
    todos.get(id).filter(_.userId == userId) match {
      case Some(existing) =>
        val newTitle = title.getOrElse(existing.title)
        if (newTitle.trim.isEmpty) return None
        
        val newDescription = description.getOrElse(existing.description)
        val newCompleted = completed.getOrElse(existing.completed)

        val updated = existing.copy(
          title = newTitle,
          description = newDescription,
          completed = newCompleted,
          updatedAt = DateTimeHelper.nowAsISO
        )
        todos.update(id, updated) 
        Some(updated)
      case None => None
    }
  }

  def delete(id: Int, userId: Int): Boolean = synchronized {
    todos.get(id) match {
      case Some(todo) if todo.userId == userId =>
        todos.remove(id)
        true
      case _ => false
    }
  }
}

class SessionManager {
  private val sessions = mutable.HashMap[String, Int]() // sessionId -> userId

  def create(userId: Int): String = {
    val sessionId = UUID.randomUUID().toString
    sessions.put(sessionId, userId)
    sessionId
  }

  def getUserId(sessionId: String): Option[Int] = {
    sessions.get(sessionId)
  }

  def destroy(sessionId: String): Unit = {
    sessions.remove(sessionId)
  }
}

object FinalTodoApp extends App with TodoJsonProtocol {
  implicit val system = ActorSystem("todo-app")
  implicit val executionContext = system.dispatcher

  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport._

  // Middleware for authentication
  def requireAuth: Directive1[Int] = optionalCookie("session_id").flatMap {
    case Some(cookie) =>
      sessionManager.getUserId(cookie.value) match {
        case Some(userId) => provide(userId)
        case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
      }
    case None =>
      complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
  }

  // Routes
  val routes = pathPrefix("register") {
    post {
      entity(as[String]) { rawJson =>
        try {
          val json = rawJson.parseJson.asJsObject
          val username = json.fields("username").convertTo[String]
          val password = json.fields("password").convertTo[String]

          userService.register(username, password) match {
            case Some(user) => 
              complete(StatusCodes.Created -> UserNoPassword(user.id, user.username))
            case None =>
              if (userService.findByUsername(username).isDefined) {
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
  pathPrefix("login") {
    post {
      entity(as[String]) { rawJson =>
        try {
          val json = rawJson.parseJson.asJsObject
          val username = json.fields("username").convertTo[String]
          val password = json.fields("password").convertTo[String]

          userService.authenticate(username, password) match {
            case Some(user) =>
              val sessionId = sessionManager.create(user.id)
              val cookie = akka.http.scaladsl.model.headers.`Set-Cookie`(
                akka.http.scaladsl.model.headers.HttpCookie(
                  "session_id", 
                  sessionId,
                  httpOnly = Some(true),
                  path = Some("/")
                )
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
  pathPrefix("logout") {
    post {
      requireAuth { userId =>
        optionalCookie("session_id") { cookieOpt =>
          cookieOpt.foreach(cook => sessionManager.destroy(cook.value))
          complete(StatusCodes.OK -> JsObject.empty)
        }
      }
    }
  } ~
  pathPrefix("me") {
    get {
      requireAuth { userId =>
        userService.findById(userId) match {
          case Some(user) => complete(StatusCodes.OK -> UserNoPassword(user.id, user.username))
          case None => complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
        }
      }
    }
  } ~
  pathPrefix("password") {
    put {
      requireAuth { userId =>
        entity(as[String]) { rawJson =>
          try {
            val json = rawJson.parseJson.asJsObject
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
  pathPrefix("todos") {
    get {
      requireAuth { userId =>
        val todos = todoService.getByUserId(userId)
        complete(StatusCodes.OK -> todos)
      }
    } ~
    post {
      requireAuth { userId =>
        entity(as[String]) { rawJson =>
          try {
            val json = rawJson.parseJson.asJsObject
            val title = json.fields("title").convertTo[String]
            if (title.trim.isEmpty) {
              complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
            } else {
              val desc = json.fields.get("description").map(_.convertTo[String]).getOrElse("")
              val newTodo = todoService.create(title, desc, userId)
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
        requireAuth { userId =>
          todoService.getById(id, userId) match {
            case Some(todo) => complete(StatusCodes.OK -> todo)
            case None => complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
          }
        }
      } ~
      put {
        requireAuth { userId =>
          entity(as[String]) { rawJson =>
            try {
              val json = rawJson.parseJson.asJsObject
              val optTitle = json.fields.get("title").map(_.convertTo[String])
              val optDesc = json.fields.get("description").map(_.convertTo[String])
              val optCompleted = json.fields.get("completed").map(_.convertTo[Boolean])

              todoService.update(id, userId, optTitle, optDesc, optCompleted) match {
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
          if (todoService.delete(id, userId)) {
            complete(StatusCodes.NoContent)
          } else {
            complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
          }
        }
      }
    }
  }

  val port = args.sliding(2, 2).collectFirst { case Array("--port", p) => p.toInt }.getOrElse(8080)
  Http().bindAndHandle(routes, "0.0.0.0", port)
  println(s"Server started on http://0.0.0.0:$port/")

  // Allow stopping with ENTER key
  println("Press Enter to quit...")
  scala.io.StdIn.readLine()

  system.terminate()
}