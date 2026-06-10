package todoapp

import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.model.headers._
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.server.Route
import akka.http.scaladsl.unmarshalling.{FromEntityUnmarshaller, Unmarshaller}
import akka.stream.ActorMaterializer
import spray.json._

import java.io.{ByteArrayInputStream, InputStream}
import java.nio.charset.StandardCharsets
import java.util.UUID
import scala.collection.mutable
import scala.concurrent.Future
import scala.io.StdIn
import java.time.Instant
import java.time.format.DateTimeFormatter
import akka.util.ByteString
import akka.http.scaladsl.marshalling.Marshal

// JSON Protocol Definition
object JsonFormats extends DefaultJsonProtocol {
  implicit val userFormat = jsonFormat2(User.apply)
  implicit val todoFormat = jsonFormat6(Todo.apply)
}

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

  def createUser(username: String, hashedPassword: String): User = synchronized {
    val user = User(nextUserId, username)
    users += (nextUserId -> user)
    userCredentials += (username -> hashedPassword)
    nextUserId += 1
    user
  }

  def getUserById(id: Int): Option[User] = synchronized {
    users.get(id)
  }

  def getUserByUsername(username: String): Option[User] = synchronized {
    users.find(_._2.username == username).map(_._2)
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
      description = description,
      completed = false,
      created_at = now,
      updated_at = now
    )
    todos += (nextTodoId -> (userId, todo))
    nextTodoId += 1
    todo
  }

  def getTodosForUser(userId: Int): List[Todo] = synchronized {
    todos.values.filter(_._1 == userId).map(_._2).toList.sortBy(_.id)
  }

  def getTodo(todoId: Int): Option[(Int, Todo)] = synchronized {
    todos.get(todoId)
  }

  def updateTodo(todoId: Int, userId: Int, updates: UpdateTodoData): Option[Todo] = synchronized {
    todos.get(todoId) match {
      case Some((ownerId, existingTodo)) if ownerId == userId =>
        // Apply updates only if they are provided
        val updatedTitle = updates.title.getOrElse(existingTodo.title)
        val updatedDescription = updates.description.getOrElse(existingTodo.description)
        val updatedCompleted = updates.completed.getOrElse(existingTodo.completed)
        
        val now = generateTimestamp()
        val updatedTodo = existingTodo.copy(
          title = updatedTitle,
          description = updatedDescription,
          completed = updatedCompleted,
          updated_at = now
        )
        
        // Validate title if it was included in updates
        if (updates.title.exists(_.isEmpty)) {
          return None
        }
        
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
    // For simplicity, doing basic hash. In production, use bcrypt or similar
    java.security.MessageDigest.getInstance("SHA-256")
      .digest(password.getBytes(StandardCharsets.UTF_8))
      .map("%02x".format(_)).mkString
  }

  private def generateTimestamp(): String = {
    Instant.now().toString.replace("T", "T").dropRight(9) + "Z"
  }
}

object Main {
  def main(args: Array[String]): Unit = {
    // Parse port from arguments
    val portOpt = args.sliding(2, 2).collectFirst { case Array("--port", portStr) => portStr.toInt }
    val port = portOpt.getOrElse(8080)
    
    implicit val system = ActorSystem("todo-app")
    implicit val materializer = ActorMaterializer()
    implicit val executionContext = system.dispatcher
    
    val store = new InMemoryStore()
    
    import JsonFormats._
    
    implicit val registerFormat: RootJsonFormat[RegisterData] = jsonFormat2(RegisterData.apply)
    implicit val loginFormat: RootJsonFormat[LoginData] = jsonFormat2(LoginData.apply)
    implicit val changePasswordFormat: RootJsonFormat[ChangePasswordData] = jsonFormat2(ChangePasswordData.apply)
    implicit val createTodoFormat: RootJsonFormat[CreateTodoData] = jsonFormat2(CreateTodoData.apply)
    
    implicit val updateTodoFormat: RootJsonFormat[UpdateTodoData] = jsonFormat3(UpdateTodoData.apply)
    
    def validateUsername(username: String): Boolean = {
      username.length >= 3 && username.length <= 50 && username.matches("^[a-zA-Z0-9_]+$")
    }
    
    def authenticateUser(): Directive1[Future[Option[Int]]] = {
      optionalHeaderValueByName("Cookie") flatMap { cookieHeader =>
        val sessionIdOpt = cookieHeader.flatMap { cookies =>
          // Cookie header format: session_id=abc123; other_cookie=value
          val cookiePairs = cookies.split(";")
            .map(_.trim)
            .map(cookie => {
              val parts = cookie.split("=", 2)
              if (parts.length > 1) (parts(0).trim, parts(1).trim)
              else (parts(0).trim, "")
            })
            .toMap
          
          cookiePairs.get("session_id")
        }
        
        provide(Future.successful(sessionIdOpt.flatMap(store.getUserIdBySession)))
      }
    }
    
    // Helper endpoint validation
    def validatedAuthEndpoint(innerRoute: Int => Route): Route = {
      authenticateUser() { userIdFuture =>
        onComplete(userIdFuture) {
          case scala.util.Success(Some(userId)) =>
            innerRoute(userId)
          case _ =>
            complete(StatusCodes.Unauthorized, JsObject("error" -> JsString("Authentication required")).compactPrint)
        }
      }
    }
    
    val routes: Route =
      concat(
        // Registration endpoint
        path("register") {
          post {
            entity(as[RegisterData]) { data =>
              if (!validateUsername(data.username)) {
                complete(StatusCodes.BadRequest, JsObject("error" -> JsString("Invalid username")).compactPrint)
              } else if (data.password.length < 8) {
                complete(StatusCodes.BadRequest, JsObject("error" -> JsString("Password too short")).compactPrint)
              } else if (store.getUserByUsername(data.username).isDefined) {
                complete(StatusCodes.Conflict, JsObject("error" -> JsString("Username already exists")).compactPrint)
              } else {
                val user = store.createUser(data.username, data.password)
                complete(StatusCodes.Created, user.toJson.compactPrint)
              }
            }
          }
        },
        
        // Login endpoint
        path("login") {
          post {
            entity(as[LoginData]) { data =>
              val userOpt = store.getUserByUsername(data.username)
              if (userOpt.isDefined && store.checkPassword(data.username, data.password)) {
                val user = userOpt.get
                val sessionId = UUID.randomUUID().toString
                store.storeSession(sessionId, user.id)
                
                val responseHeaders = List(
                  `Set-Cookie`(HttpCookie(
                    name = "session_id",
                    value = sessionId,
                    httpOnly = true,
                    path = Some("/"),
                    secure = false
                  ))
                )
                
                complete(HttpResponse(
                  status = StatusCodes.OK,
                  headers = responseHeaders,
                  entity = HttpEntity(ContentTypes.`application/json`, user.toJson.compactPrint)
                ))
              } else {
                complete(StatusCodes.Unauthorized, JsObject("error" -> JsString("Invalid credentials")).compactPrint)
              }
            }
          }
        },
        
        // Authenticated endpoints
        validatedAuthEndpoint { userId =>
          concat(
            // Get user information
            path("me") {
              get {
                store.getUserById(userId) match {
                  case Some(user) =>
                    complete(StatusCodes.OK, user.toJson.compactPrint)
                  case None =>
                    complete(StatusCodes.InternalServerError, JsObject("error" -> JsString("Unexpected error")).compactPrint)
                }
              }
            },
            
            // Logout endpoint
            path("logout") {
              post {
                optionalHeaderValueByName("Cookie") { cookieHeader =>
                  val sessionIdOpt = cookieHeader.flatMap { cookies =>
                    val cookiePairs = cookies.split(";")
                      .map(_.trim)
                      .map(cookie => {
                        val parts = cookie.split("=", 2)
                        if (parts.length > 1) (parts(0).trim, parts(1).trim)
                        else (parts(0).trim, "")
                      })
                      .toMap
                    
                    cookiePairs.get("session_id")
                  }
                  
                  sessionIdOpt.foreach(store.invalidateSession)
                  complete(StatusCodes.OK, """{}""")
                }
              }
            },
            
            // Password change
            path("password") {
              put {
                entity(as[ChangePasswordData]) { data =>
                  if (data.new_password.length < 8) {
                    complete(StatusCodes.BadRequest, JsObject("error" -> JsString("Password too short")).compactPrint)
                  } else if (store.changePassword(userId, data.old_password, data.new_password)) {
                    complete(StatusCodes.OK, """{}""")
                  } else {
                    complete(StatusCodes.Unauthorized, JsObject("error" -> JsString("Invalid credentials")).compactPrint)
                  }
                }
              }
            },
            
            // Todo endpoints
            pathPrefix("todos") {
              concat(
                // Create new todo
                pathEnd {
                  post {
                    entity(as[CreateTodoData]) { data =>
                      if (data.title.trim.isEmpty || data.title == null) {
                        complete(StatusCodes.BadRequest, JsObject("error" -> JsString("Title is required")).compactPrint)
                      } else {
                        val description = if (data.description != null) data.description else ""
                        val todo = store.createTodo(userId, data.title.trim, description)
                        complete(StatusCodes.Created, todo.toJson.compactPrint)
                      }
                    }
                  }
                },
                
                path(IntNumber) { todoId =>
                  concat(
                    // Get specific todo
                    get {
                      store.getTodo(todoId) match {
                        case Some((ownerId, todo)) if ownerId == userId =>
                          complete(StatusCodes.OK, todo.toJson.compactPrint)
                        case _ =>
                          complete(StatusCodes.NotFound, JsObject("error" -> JsString("Todo not found")).compactPrint)
                      }
                    },
                    
                    // Update todo
                    put {
                      entity(as[UpdateTodoData]) { updates =>
                        if (updates.title.exists(_.isEmpty)) {
                          complete(StatusCodes.BadRequest, JsObject("error" -> JsString("Title is required")).compactPrint)
                        } else {
                          store.updateTodo(todoId, userId, updates) match {
                            case Some(updatedTodo) =>
                              complete(StatusCodes.OK, updatedTodo.toJson.compactPrint)
                            case None =>
                              complete(StatusCodes.NotFound, JsObject("error" -> JsString("Todo not found")).compactPrint)
                          }
                        }
                      }
                    },
                    
                    // Delete todo
                    delete {
                      if (store.deleteTodo(todoId, userId)) {
                        complete(StatusCodes.NoContent, HttpEntity.Empty)
                      } else {
                        complete(StatusCodes.NotFound, JsObject("error" -> JsString("Todo not found")).compactPrint)
                      }
                    }
                  )
                },
                
                // List all todos
                pathEnd {
                  get {
                    val userTodos = store.getTodosForUser(userId)
                    complete(StatusCodes.OK, userTodos.toJson.compactPrint)
                  }
                }
              )
            }
          )
        },
        
        // Handle undefined paths
        complete(StatusCodes.NotFound, JsObject("error" -> JsString("Not Found")).compactPrint)
      )
    
    val bindingFuture = Http().bindAndHandle(routes, "0.0.0.0", port)
    
    println(s"Server online at http://0.0.0.0:$port/")
    println("Press RETURN to stop...")
    StdIn.readLine() // let it run until user presses return
    
    bindingFuture
      .flatMap(_.unbind()) // trigger unbinding from the port
      .onComplete(_ => system.terminate()) // and shutdown when done
  }
}