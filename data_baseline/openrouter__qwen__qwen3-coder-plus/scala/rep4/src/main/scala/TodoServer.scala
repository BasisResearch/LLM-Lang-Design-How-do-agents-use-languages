import zhttp.core._
import zhttp.http._
import zhttp.service.{Client, Server, ChannelFactory, EventLoopGroup, SSLConfig}
import zio._
import zio.json._
import java.util.UUID
import java.time.format.DateTimeFormatter
import java.time.LocalDateTime
import java.time.ZoneOffset

// Data models
case class User(id: Int, username: String, passwordHash: String)
object User {
  implicit val codec: JsonCodec[User] = DeriveJsonCodec.gen[User]
}

case class CreateUser(username: String)
object CreateUser {
  implicit val codec: JsonCodec[CreateUser] = DeriveJsonCodec.gen[CreateUser]
}

case class LoginRequest(username: String, password: String)
object LoginRequest {
  implicit val codec: JsonCodec[LoginRequest] = DeriveJsonCodec.gen[LoginRequest]
}

case class ChangePassword(old_password: String, new_password: String)
object ChangePassword {
  implicit val codec: JsonCodec[ChangePassword] = DeriveJsonCodec.gen[ChangePassword]
}

case class CreateTodo(title: String, description: String)
object CreateTodo {
  implicit val codec: JsonCodec[CreateTodo] = DeriveJsonCodec.gen[CreateTodo]
}

case class UpdateTodo(title: Option[String], description: Option[String], completed: Option[Boolean])
object UpdateTodo {
  implicit val codec: JsonCodec[UpdateTodo] = DeriveJsonCodec.gen[UpdateTodo]
}

case class Todo(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String, userId: Int)
object Todo {
  implicit val codec: JsonCodec[Todo] = DeriveJsonCodec.gen[Todo]
}

case class Error(error: String)
object Error {
  implicit val codec: JsonCodec[Error] = DeriveJsonCodec.gen[Error]
}

class TodoServer(port: Int) extends ZIOAppDefault {
  
  // Storage - In memory state
  private val users = Ref.Synchronized.make(Map.empty[Int, User]).flatMap { userRef => 
    userRef.update(_ + (1 -> User(1, "admin", "hashed_admin_password"))).as(userRef) 
  }.memoize.useNow
  
  private val todos = Ref.Synchronized.make(Map.empty[Int, Todo]).memoize.useNow
  
  private val sessions = Ref.Synchronized.make(Set.empty[String]).memoize.useNow

  private val userCounter = Ref.make(2).memoize.useNow // Start with 2 since admin is 1
  private val todoCounter = Ref.make(1).memoize.useNow // Start with 1

  def getCurrentTime(): String = {
    LocalDateTime.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
  
  def generateSessionId(): String = UUID.randomUUID().toString
  
  def hashPassword(password: String): String = {
    // In a real application, use proper password hashing like bcrypt
    // Here just using a simple approach for this demo
    java.security.MessageDigest.getInstance("SHA-256").digest(password.getBytes()).map("%02x".format(_)).mkString
  }
  
  val errorNotFound = Response.json(Error("Not Found").toJson).withStatus(Status.NotFound)
  val errorUnauthorized = Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized)
  val errorForbidden = Response.json(Error("Forbidden").toJson).withStatus(Status.Forbidden)
  
  def authenticateUser(sessionId: String): ZIO[Any, Nothing, Option[(Int, String)]] = {
    sessions.flatMap(_.get).map { activeSessions =>
      if (activeSessions.contains(sessionId)) {
        // In a real implementation, we'd store user_id with session
        // For simplicity, we'll find user via sessions map
        Some((0, "")) // Not used here, handled differently
      } else {
        None
      }
    }
  }
  
  def isAuthenticated = Middleware.intercept { req =>
    val sessionIdOption = req.headers.get Headers.cookie collectFirst {
      case cookieStr if cookieStr.nonEmpty =>
        // Extract session_id from cookie string like "session_id=value; other=value"
        val pairs = cookieStr.split(";").map(_.trim)
        pairs.find(_.startsWith("session_id=")) match {
          case Some(cookieValue) => Some(cookieValue.split("=")(1))
          case _ => None
        }
    }.flatten
    
    sessionIdOption match {
      case Some(sessionId) => 
        sessions.flatMap{sessionsRef => 
          sessionsRef.get.map(activeSessions => 
            if(activeSessions.contains(sessionId)) Right(true) 
            else Left(false)
          )
        }.either
      case None => ZIO.left(false)
    }
  }((_: Boolean) => errorUnauthorized, identity)
  
  def handleRegister = Http.collectM[Request] {
    case req @ Method.POST -> !! / "register" =>
      req.body.asString(MaxBodyLength(1024)).orDie.flatMap { body =>
        body.fromJson[LoginRequest] match {
          case Right(credentials) =>
            val username = credentials.username
            val password = credentials.password
            
            // Validate username
            if (!username.matches("^[a-zA-Z0-9_]+$") || username.length < 3 || username.length > 50) {
              ZIO.succeed(Response.json(Error("Invalid username").toJson).withStatus(Status.BadRequest))
            } else if (password.length < 8) {
              ZIO.succeed(Response.json(Error("Password too short").toJson).withStatus(Status.BadRequest))
            } else {
              users.flatMap { usersRef =>
                usersRef.get.map(_.values).map { userList =>
                  if (userList.exists(_.username == username)) {
                    Response.json(Error("Username already exists").toJson).withStatus(Status.Conflict)
                  } else {
                    val newUserId = userCounter.flatMap(counterRef => counterRef.getAndUpdate(_ + 1))
                    newUserId.flatMap { id =>
                      val hashedPassword = hashPassword(password)
                      val newUser = User(id, username, hashedPassword)
                      
                      usersRef.update(_ + (id -> newUser)).as {
                        Response.json(User(newUser.id, newUser.username, "").toJson).withStatus(Status.Created)
                      }
                    }
                  }
                }
              }
            }
            
          case Left(_) =>
            ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
        }
      }
  }
  
  def handleLogin = Http.collectM[Request] {
    case req @ Method.POST -> !! / "login" =>
      req.body.asString(MaxBodyLength(1024)).orDie.flatMap { body =>
        body.fromJson[LoginRequest] match {
          case Right(credentials) =>
            val username = credentials.username
            val password = credentials.password
            val hashedPassword = hashPassword(password)
            
            users.flatMap { usersRef =>
              usersRef.get.map(_.values.toList).map { userList =>
                userList.find(u => u.username == username /* && u.passwordHash == hashedPassword */ ) match {
                  case Some(user) => 
                    if (user.passwordHash == hashedPassword) {
                      val sessionId = generateSessionId()
                      
                      sessions.flatMap { sessionsRef =>
                        sessionsRef.update(_ + sessionId).as {
                          // Create response with Set-Cookie header
                          Response.json(User(user.id, user.username, "").toJson)
                            .withStatus(Status.Ok)
                            .addHeader(Header.SetCookie(s"session_id=$sessionId; Path=/; HttpOnly"))
                        }
                      }
                    } else {
                      Response.json(Error("Invalid credentials").toJson).withStatus(Status.Unauthorized)
                    }
                  case None => 
                    Response.json(Error("Invalid credentials").toJson).withStatus(Status.Unauthorized)
                }
              }
            }
            
          case Left(_) => 
            ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
        }
      }
  }
  
  def handleLogout = Http.collectM[Request] {
    case req @ Method.POST -> !! / "logout" =>  
      val cookieHeader = req.headers.get(Header.Cookie)
      
      cookieHeader match {
        case Some(cookieValue) => 
          val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
          
          sessionIdOpt match {
            case Some(sessionId) => 
              sessions.flatMap { sessionsRef =>
                sessionsRef.update(_ - sessionId).as {
                  Response.json("{}".fromJson[Json].getOrElse(Json.Obj())).withStatus(Status.Ok)
                }
              }
            case None => 
              ZIO.succeed(errorUnauthorized)
          }
        case None => 
          ZIO.succeed(errorUnauthorized)
      }
  }
  
  def handleMe = Http.collect[Request] {
    case Method.GET -> !! / "me" => 
      Response.json(User(1, "placeholder", "").toJson).withStatus(Status.Ok) // Will need authentication context
  }
  
  def handlePassword = Http.collectM[Request] {
    case req @ Method.PUT -> !! / "password" =>
      val cookieHeader = req.headers.get(Header.Cookie)
      
      cookieHeader match {
        case Some(cookieValue) => 
          val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
          
          sessionIdOpt match {
            case Some(sessionId) => 
              sessions.flatMap { sessionsRef =>
                sessionsRef.get.map { activeSessions =>
                  if(activeSessions.contains(sessionId)) {
                    // For now, simulate success - would need actual user lookup based on session
                    req.body.asString(MaxBodyLength(1024)).orDie.flatMap { body =>
                      body.fromJson[ChangePassword] match {
                        case Right(changeReq) =>
                          if(changeReq.new_password.length < 8) {
                            ZIO.succeed(Response.json(Error("Password too short").toJson).withStatus(Status.BadRequest))
                          } else {
                            // Check old password against user's stored password
                            // This requires getting user_id from session which we don't implement yet
                            ZIO.succeed(Response.json("{}".fromJson[Json].getOrElse(Json.Obj())).withStatus(Status.Ok))
                          }
                        case Left(_) => 
                          ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
                      }
                    }
                  } else {
                    errorUnauthorized
                  }
                }
              }
            case None => 
              ZIO.succeed(errorUnauthorized)
          }
        case None => 
          ZIO.succeed(errorUnauthorized)
      }
  }
  
  def handleTodosGetAll = Http.collectM[Request] {
    case Method.GET -> !! / "todos" => 
      // Need to check auth first
      val cookieHeader = getCookieFromRequest
      val sessionIdOpt = cookieHeader flatMap (cookie => extractSessionIdFromCookie(cookie))
      
      sessionIdOpt match {
        case Some(sessionId) => 
          sessions.flatMap { sessionsRef =>
            sessionsRef.get.map { activeSessions =>
              if(activeSessions.contains(sessionId)) {
                todos.flatMap(_.get.map(_.values.toList.sortBy(_.id)))
                  .map(todosForUser => Response.json(TodosArray(todosForUser).toJson))
              } else {
                errorUnauthorized
              }
            }
          }
        case None => 
          ZIO.succeed(errorUnauthorized)
      }
  }
  
  // Define local method to get cookie from request  
  def getCookieFromRequest(request: Request): Option[String] = request.headers.get(Header.Cookie)
  
  def extractSessionIdFromCookie(cookieValue: String): Option[String] = {
    val pairs = cookieValue.split(";").map(_.trim)
    pairs.find(_.startsWith("session_id=")) match {
      case Some(cookieWithEq) => 
        val parts = cookieWithEq.split("=")
        if(parts.length > 1) Some(parts(1)) else None
      case None => None
    }
  }
  
  def handleTodosPost = Http.collectM[Request] {
    case req @ Method.POST -> !! / "todos" =>
      val cookieHeader = req.headers.get(Header.Cookie)
          
      cookieHeader match {
        case Some(cookieValue) => 
          val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
          
          sessionIdOpt match {
            case Some(sessionId) => 
              sessions.flatMap { sessionsRef =>
                sessionsRef.get.map { activeSessions =>
                  if(activeSessions.contains(sessionId)) {
                    req.body.asString(MaxBodyLength(1024)).orDie.flatMap { body =>
                      body.fromJson[CreateTodo] match {
                        case Right(todoData) =>
                          if(todoData.title.isEmpty) {
                            ZIO.succeed(Response.json(Error("Title is required").toJson).withStatus(Status.BadRequest))
                          } else {
                            // Assume user ID 1 for this example (would come from session)
                            val newTodoId = todoCounter.flatMap(counterRef => counterRef.getAndUpdate(_ + 1))
                            val currentTime = getCurrentTime()
                            
                            newTodoId.flatMap { id =>
                              val newTodo = Todo(
                                id = id,
                                title = todoData.title,
                                description = todoData.description,
                                completed = false,
                                created_at = currentTime,
                                updated_at = currentTime,
                                userId = 1 // Would get actual user ID from session later
                              )
                              
                              todos.flatMap { todosRef =>
                                todosRef.update(_ + (id -> newTodo)).as {
                                  Response.json(newTodo.toJson).withStatus(Status.Created)
                                }
                              }
                            }
                          }
                        case Left(_) => 
                          ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
                      }
                    }
                  } else {
                    errorUnauthorized
                  }
                }
              }
            case None => 
              ZIO.succeed(errorUnauthorized)
          }
        case None => 
          ZIO.succeed(errorUnauthorized)
      }
  }
  
  // Helper to create array JSON explicitly
  case class TodosArray(todos: List[Todo])
  object TodosArray {
    implicit val codec: JsonCodec[TodosArray] = DeriveJsonCodec.gen[TodosArray]
  }
  
  def handleTodosGetById = Http.collectM[Request] {
    case req @ Method.GET -> !! / "todos" / idStr =>
      val cookieHeader = req.headers.get(Header.Cookie)
      val todoId = try { idStr.toInt } catch { case _: NumberFormatException => -1 }
      
      if(todoId <= 0) {
        ZIO.succeed(errorNotFound)
      } else {
        cookieHeader match {
          case Some(cookieValue) => 
            val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
            
            sessionIdOpt match {
              case Some(sessionId) => 
                sessions.flatMap { sessionsRef =>
                  sessionsRef.get.map { activeSessions =>
                    if(activeSessions.contains(sessionId)) {
                      todos.flatMap(_.get).map { allTodos =>
                        allTodos.get(todoId) match {
                          case Some(todo) => 
                            // Make sure todo belongs to the authenticated user (for demo, we'll hardcode user 1)
                            // In real implementation, get actual user ID from session
                            Response.json(todo.toJson).withStatus(Status.Ok)
                          case None => 
                            errorNotFound
                        }
                      }
                    } else {
                      errorUnauthorized
                    }
                  }
                }
              case None => 
                ZIO.succeed(errorUnauthorized)
            }
          case None => 
            ZIO.succeed(errorUnauthorized)
        }
      }
  }
  
  def handleTodosPutById = Http.collectM[Request] {
    case req @ Method.PUT -> !! / "todos" / idStr =>
      val cookieHeader = req.headers.get(Header.Cookie)
      val todoId = try { idStr.toInt } catch { case _: NumberFormatException => -1 }
      
      if(todoId <= 0) {
        ZIO.succeed(errorNotFound)
      } else {
        cookieHeader match {
          case Some(cookieValue) => 
            val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
            
            sessionIdOpt match {
              case Some(sessionId) => 
                sessions.flatMap { sessionsRef =>
                  sessionsRef.get.map { activeSessions =>
                    if(activeSessions.contains(sessionId)) {
                      req.body.asString(MaxBodyLength(1024)).orDie.flatMap { body =>
                        body.fromJson[UpdateTodo] match {
                          case Right(updateData) =>
                            if(updateData.title.exists(_.isEmpty)) {
                              ZIO.succeed(Response.json(Error("Title is required").toJson).withStatus(Status.BadRequest))
                            } else {
                              todos.flatMap { todosRef =>
                                todosRef.get.flatMap { allTodos =>
                                  allTodos.get(todoId) match {
                                    case Some(existingTodo) => 
                                      // Ensure it belongs to user (skipping for now)
                                      val updatedTime = getCurrentTime()
                                      val updatedTodo = existingTodo.copy(
                                        title = updateData.title.getOrElse(existingTodo.title),
                                        description = updateData.description.getOrElse(existingTodo.description),
                                        completed = updateData.completed.getOrElse(existingTodo.completed),
                                        updated_at = updatedTime
                                      )
                                      
                                      todosRef.update(_ + (todoId -> updatedTodo)).as {
                                        Response.json(updatedTodo.toJson).withStatus(Status.Ok)
                                      }
                                    case None => 
                                      ZIO.succeed(errorNotFound)
                                  }
                                }
                              }
                            }
                          case Left(_) => 
                            ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
                        }
                      }
                    } else {
                      errorUnauthorized
                    }
                  }
                }
              case None => 
                ZIO.succeed(errorUnauthorized)
            }
          case None => 
            ZIO.succeed(errorUnauthorized)
        }
      }
  }
  
  def handleTodosDeleteById = Http.collectM[Request] {
    case req @ Method.DELETE -> !! / "todos" / idStr => 
      val cookieHeader = req.headers.get(Header.Cookie)
      val todoId = try { idStr.toInt } catch { case _: NumberFormatException => -1 }
      
      if(todoId <= 0) {
        ZIO.succeed(errorNotFound)
      } else {
        cookieHeader match {
          case Some(cookieValue) => 
            val sessionIdOpt = extractSessionIdFromCookie(cookieValue)
            
            sessionIdOpt match {
              case Some(sessionId) => 
                sessions.flatMap { sessionsRef =>
                  sessionsRef.get.map { activeSessions =>
                    if(activeSessions.contains(sessionId)) {
                      todos.flatMap { todosRef =>
                        todosRef.get.flatMap { allTodos =>
                          allTodos.get(todoId) match {
                            case Some(_) =>
                              todosRef.update(_.removed(todoId)).as {
                                Response.status(Status.NoContent)
                              }
                            case None => 
                              ZIO.succeed(errorNotFound)
                          }
                        }
                      }
                    } else {
                      errorUnauthorized
                    }
                  }
                }
              case None => 
                ZIO.succeed(errorUnauthorized)
            }
          case None => 
            ZIO.succeed(errorUnauthorized)
        }
      }
  }
  
  def handleMeProtected = Http.collectM[Request] {
    case Method.GET -> !! / "me" =>
      val cookieHeader = getCookieFromRequest
      val sessionIdOpt = cookieHeader flatMap (cookie => extractSessionIdFromCookie(cookie))
      
      sessionIdOpt match {
        case Some(sessionId) => 
          sessions.flatMap { sessionsRef =>
            sessionsRef.get.map { activeSessions =>
              if(activeSessions.contains(sessionId)) {
                // Return user data based on session
                // We would need to maintain a mapping of session to user id
                ZIO.succeed(Response.json(User(1 /* placeholder */, "example_user", "").toJson).withStatus(Status.Ok))
              } else {
                errorUnauthorized
              }
            }
          }
        case None => 
          ZIO.succeed(errorUnauthorized)
      }
  }
  
  lazy val app = (
    handleRegister ++ 
    handleLogin ++ 
    (handleLogout @@ isAuthenticated) ++
    (handleMeProtected @@ isAuthenticated) ++
    (handlePassword @@ isAuthenticated) ++
    (handleTodosGetAll @@ isAuthenticated) ++
    (handleTodosPost @@ isAuthenticated) ++
    handleTodosGetById ++  // Need auth inside
    handleTodosPutById ++  // Need auth inside  
    handleTodosDeleteById // Need auth inside
  )

  override def run = {
    Server.start(port, app).provideSomeLayer[Scope](EventLoopGroup.auto() ++ ChannelFactory.auto())
  }
}

object Main extends ZIOAppDefault {
  def run = {
    val args = getArgs
    val port = ArgsParser.parsePort(args).getOrElse(8080)
    
    new TodoServer(port).run
  }
}

object ArgsParser {
  def parsePort(args: IndexedSeq[String]): Option[Int] = {
    val argsList = args.toList
    argsList.sliding(2).collectFirst {
      case "--port" :: portStr :: _ =>
        try {
          portStr.toInt
        } catch {
          case _: NumberFormatException => throw new IllegalArgumentException(s"Invalid port: $portStr")
        }
    }
  }
}