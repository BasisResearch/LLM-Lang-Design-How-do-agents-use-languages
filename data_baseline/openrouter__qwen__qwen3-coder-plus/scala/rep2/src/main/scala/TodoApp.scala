package todoapp

import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.model.headers.{HttpCookie, `Set-Cookie`}
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.server.Route
import akka.http.scaladsl.unmarshalling.FromEntityUnmarshaller
import akka.stream.ActorMaterializer
import akka.util.ByteString
import spray.json._

import java.security.MessageDigest
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import scala.collection.mutable
import scala.concurrent.ExecutionContextExecutor
import scala.io.StdIn
import java.time.Instant
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport._

// JSON Protocol Definition
trait JsonProtocol extends DefaultJsonProtocol {
  implicit val userFormat: RootJsonFormat[User] = jsonFormat2(User)
  implicit val todoFormat: RootJsonFormat[Todo] = jsonFormat6(Todo)
}

object Formats extends JsonProtocol

case class User(id: Int, username: String)
case class Todo(
    id: Int,
    title: String,
    description: String,
    completed: Boolean,
    created_at: String,
    updated_at: String
)
case class RegisterData(username: String, password: String)
case class LoginData(username: String, password: String)
case class ChangePasswordData(old_password: String, new_password: String)
case class CreateTodoData(title: String, description: String)
case class UpdateTodoData(title: Option[String], description: Option[String], completed: Option[Boolean])

// Storage
class InMemoryStore {
  private var users = mutable.Map.empty[Int, User]
  private var userCredentials = mutable.Map.empty[String, String] // username -> password hash
  private var todos = mutable.Map.empty[Int, (Int, Todo)] // todoId -> (userId, todo)
  private var sessions = mutable.Map.empty[String, Int] // sessionId -> userId
  private var nextUserId = 1
  private var nextTodoId = 1

  def createUser(username: String, password: String): User = synchronized {
    val user = User(nextUserId, username)
    users += (nextUserId -> user)
    userCredentials += (username -> hashPassword(password))
    nextUserId += 1
    user
  }

  def getUserById(id: Int): Option[User] = synchronized {
    users.get(id)
  }

  def getUserByUsername(username: String): Option[User] = synchronized {
    users.values.find(_.username == username)
  }

  def checkPassword(username: String, password: String): Boolean = synchronized {
    userCredentials.get(username) match {
      case Some(hashedPassword) => hashedPassword == hashPassword(password)
      case None => false
    }
  }

  def changePassword(userId: Int, oldPassword: String, newPassword: String): Boolean = synchronized {
    val usernameOpt = users.get(userId).map(_.username)
    usernameOpt match {
      case Some(username) =>
        if (checkPassword(username, oldPassword)) {
          userCredentials.update(username, hashPassword(newPassword))
          true
        } else {
          false
        }
      case None => false
    }
  }

  def storeSession(sessionId: String, userId: Int): Unit = synchronized {
    sessions += (sessionId -> userId)
  }

  def getUserIdBySession(sessionId: String): Option[Int] = synchronized {
    sessions.get(sessionId)
  }

  def invalidateSession(sessionId: String): Unit = synchronized {
    sessions -= sessionId
  }

  def createTodo(userId: Int, title: String, description: String): Todo = synchronized {
    val now = generateTimestamp()
    val todo = Todo(
      id = nextTodoId,
      title = title,
      description = if (description == null) "" else description,
      completed = false,
      created_at = now,
      updated_at = now
    )
    todos += (nextTodoId -> (userId, todo))
    nextTodoId += 1
    todo
  }

  def getTodosForUser(userId: Int): List[Todo] = synchronized {
    todos.filter(_._2._1 == userId).values.map(_._2).toList.sortBy(_.id)
  }

  def getTodo(todoId: Int): Option[(Int, Todo)] = synchronized {
    todos.get(todoId)
  }

  def updateTodo(todoId: Int, userId: Int, updates: UpdateTodoData): Option[Todo] = synchronized {
    todos.get(todoId) match {
      case Some((ownerId, existingTodo)) if ownerId == userId =>
        val updatedTitle = updates.title.getOrElse(existingTodo.title)
        val updatedDescription = updates.description.getOrElse(existingTodo.description)
        val updatedCompleted = updates.completed.getOrElse(existingTodo.completed)
        
        if (updates.title.exists(_.isEmpty)) {
          return None
        }
        
        val now = generateTimestamp()
        val updatedTodo = existingTodo.copy(
          title = updatedTitle,
          description = updatedDescription,
          completed = updatedCompleted,
          updated_at = now
        )
        
        todos += (todoId -> (userId, updatedTodo))
        Some(updatedTodo)
      case _ => None
    }
  }

  def deleteTodo(todoId: Int, userId: Int): Boolean = synchronized {
    todos.get(todoId) match {
      case Some((ownerId, _)) if ownerId == userId =>
        todos -= todoId
        true
      case _ => false
    }
  }

  private def hashPassword(password: String): String = {
    MessageDigest.getInstance("SHA-256")
      .digest(password.getBytes("UTF-8"))
      .map("%02x".format(_)).mkString
  }

  private def generateTimestamp(): String = {
    Instant.now().atOffset(ZoneOffset.UTC)
      .format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

object TodoApp extends App with JsonProtocol {
  // Parse port from arguments
  val portOpt = args.sliding(2, 2).collectFirst { case Array("--port", portArg) => portArg.toInt }
  val port = portOpt.getOrElse(8080)

  implicit val system: ActorSystem = ActorSystem("todo-system")
  implicit val materializer: ActorMaterializer = ActorMaterializer()
  implicit val executionContext: ExecutionContextExecutor = system.dispatcher

  val store = new InMemoryStore()

  def validateUsername(username: String): Boolean = {
    username.nonEmpty && username.length >= 3 && username.length <= 50 && username.matches("^[a-zA-Z0-9_]+$")
  }

  def getSessionId(requestCtx: HttpRequest): Option[String] = {
    requestCtx.headers.find(_.name.toLowerCase == "cookie").map(_.value).flatMap { cookieHeader =>
      val cookies = cookieHeader.split(";\\s*").map(_.split("=")).collect {
        case Array(key, value) => key -> value
      }.toMap
      cookies.get("session_id")
    }
  }

  val route: Route =
    path("register") {
      post {
        entity(as[RegisterData]) { regData =>
          if (!validateUsername(regData.username)) {
            complete(StatusCodes.BadRequest -> JsObject("error" -> JsString("Invalid username")))
          } else if (regData.password.length < 8) {
            complete(StatusCodes.BadRequest -> JsObject("error" -> JsString("Password too short")))
          } else if (store.getUserByUsername(regData.username).isDefined) {
            complete(StatusCodes.Conflict -> JsObject("error" -> JsString("Username already exists")))
          } else {
            val user = store.createUser(regData.username, regData.password)
            complete(StatusCodes.Created -> user)
          }
        }
      }
    } ~
    path("login") {
      post {
        entity(as[LoginData]) { loginData =>
          if (!store.checkPassword(loginData.username, loginData.password)) {
            complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Invalid credentials")))
          } else {
            val user = store.getUserByUsername(loginData.username)
            user match {
              case Some(u) =>
                val sessionId = UUID.randomUUID().toString
                store.storeSession(sessionId, u.id)
                
                val responseHeaders = List(
                  `Set-Cookie`(HttpCookie(
                    name = "session_id",
                    value = sessionId,
                    httpOnly = true,
                    path = Some("/")
                  ))
                )
                
                complete(HttpResponse(
                  status = StatusCodes.OK,
                  headers = responseHeaders,
                  entity = HttpEntity(ContentTypes.`application/json`, u.toJson.compactPrint)
                ))
              case None =>
                complete(StatusCodes.InternalServerError -> JsObject("error" -> JsString("Unexpected error")))
            }
          }
        }
      }
    } ~
    path("logout") {
      post {
        optionalCookie("session_id") { sessionCookieOpt =>
          sessionCookieOpt match {
            case Some(sessionCookie) =>
              store.invalidateSession(sessionCookie.value)
              complete(StatusCodes.OK -> JsObject())
            case None =>
              complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Authentication required")))
          }
        } ~
        headerValueByName("Cookie") { cookieHeader =>
          val sessionIdOpt = cookieHeader.split(";").map(_.split("=")).find(_(0).trim == "session_id").map(_(1).trim)
          sessionIdOpt match {
            case Some(sessionId) =>
              if (store.getUserIdBySession(sessionId).isDefined) {
                store.invalidateSession(sessionId)
                complete(StatusCodes.OK -> JsObject())
              } else {
                complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Authentication required")))
              }
            case None =>
              complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Authentication required")))
          }
        }
      }
    } ~
    path("me") {
      get {
        authenticateSession { userId =>
          store.getUserById(userId) match {
            case Some(user) => complete(StatusCodes.OK -> user)
            case None => complete(StatusCodes.InternalServerError -> JsObject("error" -> JsString("Unexpected error")))
          }
        }
      }
    } ~
    path("password") {
      put {
        authenticateSession { userId =>
          entity(as[ChangePasswordData]) { pwdData =>
            if (pwdData.new_password.length < 8) {
              complete(StatusCodes.BadRequest -> JsObject("error" -> JsString("Password too short")))
            } else if (!store.changePassword(userId, pwdData.old_password, pwdData.new_password)) {
              complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Invalid credentials")))
            } else {
              complete(StatusCodes.OK -> JsObject())
            }
          }
        }
      }
    } ~
    pathPrefix("todos") {
      authenticateSession { userId =>
        pathEndOrSingleSlash {
          get {
            val userTodos = store.getTodosForUser(userId)
            complete(StatusCodes.OK -> userTodos)
          } ~
          post {
            entity(as[CreateTodoData]) { createData =>
              if (createData.title == null || createData.title.trim.isEmpty) {
                complete(StatusCodes.BadRequest -> JsObject("error" -> JsString("Title is required")))
              } else {
                val description = if (createData.description == null) "" else createData.description
                val todo = store.createTodo(userId, createData.title.trim, description)
                complete(StatusCodes.Created -> todo)
              }
            }
          }
        } ~
        path(IntNumber) { todoId =>
          get {
            store.getTodo(todoId) match {
              case Some((ownerId, todo)) if ownerId == userId =>
                complete(StatusCodes.OK -> todo)
              case _ =>
                complete(StatusCodes.NotFound -> JsObject("error" -> JsString("Todo not found")))
            }
          } ~
          put {
            entity(as[UpdateTodoData]) { updates =>
              val updatedTodoOpt = store.updateTodo(todoId, userId, updates)
              
              if (updates.title.exists(_.isEmpty)) {
                complete(StatusCodes.BadRequest -> JsObject("error" -> JsString("Title is required")))
              } else {
                updatedTodoOpt match {
                  case Some(updatedTodo) => complete(StatusCodes.OK -> updatedTodo)
                  case None => complete(StatusCodes.NotFound -> JsObject("error" -> JsString("Todo not found")))
                }
              }
            }
          } ~
          delete {
            if (store.deleteTodo(todoId, userId)) {
              complete(StatusCodes.NoContent -> HttpEntity.Empty)  
            } else {
              complete(StatusCodes.NotFound -> JsObject("error" -> JsString("Todo not found")))
            }
          }
        }
      }
    } ~
    path(Remaining) { _ =>
      complete(StatusCodes.NotFound -> JsObject("error" -> JsString("Not Found")))
    }

  def authenticateSession(innerRoute: Int => Route): Route = {
    optionalCookie("session_id") { sessionCookieOpt =>
      val userIdOpt = sessionCookieOpt.flatMap(cookie => store.getUserIdBySession(cookie.value))
      userIdOpt match {
        case Some(userId) => innerRoute(userId)
        case None => complete(StatusCodes.Unauthorized -> JsObject("error" -> JsString("Authentication required")))
      }
    }
  }

  Http().bindAndHandle(route, "0.0.0.0", port)

  println(s"Server online at http://0.0.0.0:$port/")
  println("Press RETURN to stop the server...")
  StdIn.readLine()
  
  system.terminate()
}