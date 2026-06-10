import akka.actor.ActorSystem
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.server.Route
import akka.stream.ActorMaterializer
import spray.json._
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport._

// JSON serialization support
trait JsonProtocol extends DefaultJsonProtocol {
  implicit val userFormat = jsonFormat3(UserNoPassword)  // Exclude password from response
  implicit val todoFormat = jsonFormat6(Todo)
  implicit val errorFormat = jsonFormat1(ErrorResponse)
  implicit val changePasswordFormat = jsonFormat2(PasswordChangeRequest)
}

// A version of User without the password field for safe output
case class UserNoPassword(id: Int, username: String)
object UserNoPassword {
  def apply(user: User): UserNoPassword = UserNoPassword(user.id, user.username)
}

case class ErrorResponse(error: String)
case class PasswordChangeRequest(old_password: String, new_password: String)

object Main extends App with JsonProtocol {
  implicit val system = ActorSystem("todo-system")
  implicit val materializer = ActorMaterializer()
  implicit val executionContext = system.dispatcher

  // Initialize services
  val userService = new UserService()
  val todoService = new TodoService()
  val sessionManager = new SessionManager()

  // Extract user ID from session cookie
  def extractUserIdFromSession: Directive1[Option[Int]] = {
    optionalCookie("session_id").map { cookieOpt =>
      cookieOpt.map(_.value).flatMap(sessionId => sessionManager.getUserIdForSession(sessionId))
    }
  }

  // Authentication middleware
  def requireAuth: Directive0 = {
    extractUserIdFromSession flatMap {
      case Some(userId) => pass
      case None => complete(StatusCodes.Unauthorized -> ErrorResponse("Authentication required"))
    }
  }

  // Helper to get the authenticated user ID
  def getUserOrRejection: Directive1[Int] = {
    extractUserIdFromSession flatMap {
      case Some(userId) => provide(userId)
      case None => reject // This won't happen since requireAuth filters out unauthenticated requests
    }
  }

  val route: Route = {
    pathPrefix("register") {
      post {
        entity(as[String]) { jsonString =>
          try {
            val json = jsonString.parseJson.asJsObject
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
                } else { // Must be a duplicate
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
        entity(as[String]) { jsonString =>
          try {
            val json = jsonString.parseJson.asJsObject
            val username = json.fields("username").convertTo[String]
            val password = json.fields("password").convertTo[String]

            userService.authenticateUser(username, password) match {
              case Some(user) =>
                val sessionId = sessionManager.createSession(user.id)
                val cookie = HttpCookie("session_id", sessionId, httpOnly = true, path = Some("/"))
                
                respondWithHeader(headers.`Set-Cookie`(cookie)) {
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
        requireAuth {
          extractUserIdFromSession { userIdOpt =>
            userIdOpt.foreach { userId =>
              optionalCookie("session_id") { cookieOpt =>
                cookieOpt.foreach { cookie =>
                  sessionManager.destroySession(cookie.value)
                }
              }
            }
            complete(StatusCodes.OK -> JsObject.empty)
          }
        }
      }
    } ~
    pathPrefix("me") {
      get {
        requireAuth {
          getUserOrRejection { userId =>
            userService.findUser(userId) match {
              case Some(user) =>
                complete(StatusCodes.OK -> UserNoPassword(user))
              case None =>
                complete(StatusCodes.InternalServerError -> ErrorResponse("User not found"))
            }
          }
        }
      }
    } ~
    pathPrefix("password") {
      put {
        requireAuth {
          getUserOrRejection { userId =>
            entity(as[String]) { jsonString =>
              try {
                val json = jsonString.parseJson.asJsObject
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
      }
    } ~
    pathPrefix("todos") {
      get {
        requireAuth {
          getUserOrRejection { userId =>
            val todos = todoService.getTodosByUserId(userId).map(todo => 
              Todo(todo.id, todo.title, todo.description, todo.completed, todo.createdAt, todo.updatedAt, todo.userId))
            complete(StatusCodes.OK -> todos)
          }
        }
      } ~
      post {
        requireAuth {
          getUserOrRejection { userId =>
            entity(as[String]) { jsonString =>
              try {
                val json = jsonString.parseJson.asJsObject
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
        }
      } ~
      path(IntNumber) { todoId =>
        get {
          requireAuth {
            getUserOrRejection { userId =>
              todoService.getTodo(todoId, userId) match {
                case Some(todo) =>
                  complete(StatusCodes.OK -> todo)
                case None =>
                  complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
              }
            }
          }
        } ~
        put {
          requireAuth {
            getUserOrRejection { userId =>
              entity(as[String]) { jsonString =>
                try {
                  val json = jsonString.parseJson.asJsObject
                  
                  // Extract optional fields
                  val titleOpt = json.fields.get("title").map(_.convertTo[String])
                  val descriptionOpt = json.fields.get("description").map(_.convertTo[String])
                  val completedOpt = json.fields.get("completed").map(_.convertTo[Boolean])

                  // Validate title if provided
                  if (titleOpt.exists(_.trim.isEmpty)) {
                    complete(StatusCodes.BadRequest -> ErrorResponse("Title is required"))
                  } else {
                    todoService.updateTodo(todoId, userId, titleOpt, descriptionOpt, completedOpt) match {
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
          }
        } ~
        delete {
          requireAuth {
            getUserOrRejection { userId =>
              val deleted = todoService.deleteTodo(todoId, userId)
              if (deleted) {
                complete(StatusCodes.NoContent)
              } else {
                complete(StatusCodes.NotFound -> ErrorResponse("Todo not found"))
              }
            }
          }
        }
      }
    } ~
    pathEndOrSingleSlash {
      get {
        complete(StatusCodes.OK -> JsObject("message" -> JsString("Welcome to the Todos API")))
      }
    }
  }

  // Handle command line arguments for port
  val port = args.sliding(2, 2).collectFirst { case Array("--port", portStr) => portStr.toInt }.getOrElse(8080)
  
  val bindingFuture = Http().bindAndHandle(route, "0.0.0.0", port)
  
  println(s"Server online at http://0.0.0.0:$port/")

  // For graceful shutdown
  sys.addShutdownHook({
    bindingFuture
      .flatMap(b => b.unbind()) // Trigger unbinding from the port
      .onComplete(_ => system.terminate()) // And shutdown when done
  })
}