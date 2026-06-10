#!/usr/bin/env -S scala-cli shebang -S 3.3.0
//> using dep dev.zio::zio:2.1.26
//> using dep dev.zio::zio-http:3.11.2
//> using dep dev.zio::zio-json:0.9.2

import zio._
import zio.http._
import zio.json._
import java.util.UUID
import java.time.format.DateTimeFormatter
import java.time.LocalDateTime
import java.time.ZoneOffset

object TodoServer extends ZIOAppDefault {
  
  // Data models
  case class User(id: Int, username: String, passwordHash: String) derives JsonCodec

  case class RegisterRequest(username: String, password: String) derives JsonCodec
  
  case class LoginRequest(username: String, password: String) derives JsonCodec
  
  case class ChangePasswordRequest(old_password: String, new_password: String) derives JsonCodec
  
  case class CreateTodoRequest(title: String, description: String) derives JsonCodec
  
  case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean]) derives JsonCodec
  
  case class Todo(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String, owner_id: Int) derives JsonCodec

  case class UserData(id: Int, username: String) derives JsonCodec

  case class Error(error: String) derives JsonCodec
  
  case class ServiceState(
    users: Map[Int, User] = Map.empty,
    userCounter: Int = 1,
    todos: Map[Int, Todo] = Map.empty,
    todoCounter: Int = 1,
    sessions: Map[String, Int] = Map.empty // session_id -> user_id
  )
  
  def getCurrentTimestamp(): String = {
    LocalDateTime.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
  
  def hashPassword(password: String): String = {
    import java.security.MessageDigest
    val digest = MessageDigest.getInstance("SHA-256").digest(password.getBytes)
    digest.map("%02x".format(_)).mkString
  }
  
  def extractSessionId(req: Request): Option[String] = {
    // Access cookie directly from headers
    req.headers.get(Header.Cookie).map { cookiesStr => 
      cookiesStr.split(";").find(_.trim.startsWith("session_id=")).map(_.split("=")(1)).getOrElse(null)
    }.getOrElse(null) match {
      case s: String => Some(s)
      case _ => None
    }
  }

  def createApp(serviceRef: Ref[ServiceState]): Routes[Any, Response] = {
    Routes(
      // Register user
      Method.POST / "register" -> handler { (req: Request) =>
        req.body.asString.orElseFail(new RuntimeException("Could not read body")).flatMap { body =>
          body.fromJson[RegisterRequest] match {
            case Right(RegisterRequest(username, password)) =>
              if (username.length < 3 || username.length > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
                ZIO.succeed(Response.json(Error("Invalid username").toJson).withStatus(Status.BadRequest))
              } else if (password.length < 8) {
                ZIO.succeed(Response.json(Error("Password too short").toJson).withStatus(Status.BadRequest))
              } else {
                serviceRef.modifyZIO { state =>
                  if (state.users.exists(_._2.username == username)) {
                    ZIO.succeed((Response.json(Error("Username already exists").toJson).withStatus(Status.Conflict), state))
                  } else {
                    val userId = state.userCounter
                    val newUser = User(userId, username, hashPassword(password))
                    val newState = state.copy(
                      users = state.users + (userId -> newUser),
                      userCounter = state.userCounter + 1
                    )
                    ZIO.succeed((Response.json(UserData(newUser.id, newUser.username).toJson).withStatus(Status.Created), newState))
                  }
                }
              }
            case Left(error) => 
              ZIO.succeed(Response.json(Error(s"Invalid request: $error").toJson).withStatus(Status.BadRequest))
          }
        }
      },
      
      // Login user  
      Method.POST / "login" -> handler { (req: Request) =>
        req.body.asString.orElseFail(new RuntimeException("Could not read body")).flatMap { body =>
          body.fromJson[LoginRequest] match {
            case Right(LoginRequest(username, password)) =>
              serviceRef.get.flatMap { state =>
                state.users.values.find(_.username == username) match {
                  case Some(user) if user.passwordHash == hashPassword(password) =>
                    val sessionId = UUID.randomUUID().toString
                    val response = Response.json(UserData(user.id, user.username).toJson)
                      .withHeaders(Headers(Header.SetCookie(s"session_id=$sessionId; Path=/; HttpOnly")))
                    serviceRef.update(_.copy(sessions = _.sessions + (sessionId -> user.id))).as(response)
                  case _ =>
                    ZIO.succeed(Response.json(Error("Invalid credentials").toJson).withStatus(Status.Unauthorized))
                }
              }
            case Left(error) =>
              ZIO.succeed(Response.json(Error(s"Invalid request: $error").toJson).withStatus(Status.BadRequest))
          }
        }
      },
      
      // Logout user
      Method.POST / "logout" -> handler { (req: Request) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            serviceRef.update(s => s.copy(sessions = s.sessions - sessionId)).as {
              Response.json("{}".toJson).withStatus(Status.Ok)
            }
          case None =>
            ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
        }
      },
          
      // Get current user info
      Method.GET / "me" -> handler { (req: Request) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            serviceRef.get.flatMap { state =>
              state.sessions.get(sessionId) match {
                case Some(userId) =>
                  state.users.get(userId) match {
                    case Some(user) =>
                      ZIO.succeed(Response.json(UserData(user.id, user.username).toJson).withStatus(Status.Ok))
                    case None =>
                      ZIO.succeed(Response.json(Error("User not found").toJson).withStatus(Status.Unauthorized))
                  }
                case None =>
                  ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
              }
            }
          case None =>
            ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
        }
      },
          
      // Change password
      Method.PUT / "password" -> handler { (req: Request) =>
        req.body.asString.orElseFail(new RuntimeException("Could not read body")).flatMap { body =>
          extractSessionId(req) match {
            case Some(sessionId) =>
              body.fromJson[ChangePasswordRequest] match {
                case Right(ChangePasswordRequest(old_password, new_password)) =>
                  if (new_password.length < 8) {
                    ZIO.succeed(Response.json(Error("Password too short").toJson).withStatus(Status.BadRequest))
                  } else {
                    serviceRef.modifyZIO { state =>
                      state.sessions.get(sessionId) match {
                        case Some(userId) =>
                          state.users.get(userId) match {
                            case Some(user) if user.passwordHash == hashPassword(old_password) =>
                              val updatedUser = user.copy(passwordHash = hashPassword(new_password))
                              val updatedState = state.copy(users = state.users.updated(userId, updatedUser))
                              ZIO.succeed((Response.json("{}".toJson).withStatus(Status.Ok), updatedState))
                            case Some(_) =>
                              ZIO.succeed((Response.json(Error("Invalid credentials").toJson).withStatus(Status.Unauthorized), state))
                            case None =>
                              ZIO.succeed((Response.json(Error("User not found").toJson).withStatus(Status.Unauthorized), state))
                          }
                        case None =>
                          ZIO.succeed((Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized), state))
                      }
                    }
                  }
                case Left(error) =>
                  ZIO.succeed(Response.json(Error(s"Invalid request: $error").toJson).withStatus(Status.BadRequest))
              }
            case None =>
              ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
          }
        }
      },
          
      // Get todos for current user
      Method.GET / "todos" -> handler { (req: Request) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            serviceRef.get.flatMap { state =>
              state.sessions.get(sessionId) match {
                case Some(userId) =>
                  val userTodos = state.todos.values.filter(_.owner_id == userId).toList.sortBy(_.id)
                  ZIO.succeed(Response.json(userTodos.toJson).withStatus(Status.Ok))
                case None =>
                  ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
              }
            }
          case None =>
            ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
          }
      },
      
      // Create new todo
      Method.POST / "todos" -> handler { (req: Request) =>
        req.body.asString.orElseFail(new RuntimeException("Could not read body")).flatMap { body =>
          extractSessionId(req) match {
            case Some(sessionId) =>
              body.fromJson[CreateTodoRequest] match {
                case Right(CreateTodoRequest(title, description)) =>
                  if (title.trim.isEmpty) {
                    ZIO.succeed(Response.json(Error("Title is required").toJson).withStatus(Status.BadRequest))
                  } else {
                    serviceRef.modifyZIO { state =>
                      state.sessions.get(sessionId) match {
                        case Some(userId) =>
                          val todoId = state.todoCounter
                          val createdAt = getCurrentTimestamp()
                          val newTodo = Todo(
                            id = todoId,
                            title = title.trim,
                            description = description,
                            completed = false,
                            created_at = createdAt,
                            updated_at = createdAt,
                            owner_id = userId
                          )
                          val newState = state.copy(
                            todos = state.todos + (todoId -> newTodo),
                            todoCounter = state.todoCounter + 1
                          )
                          ZIO.succeed((Response.json(newTodo.toJson).withStatus(Status.Created), newState))
                        case None =>
                          ZIO.succeed((Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized), state))
                      }
                    }
                  }
                case Left(error) =>
                  ZIO.succeed(Response.json(Error(s"Invalid request: $error").toJson).withStatus(Status.BadRequest))
              }
            case None =>
              ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
          }
        }
      },
      
      // Get todo by ID
      Method.GET / "todos" / RouteCodec.int -> handler { (todoId: Int, req: Request) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            serviceRef.get.flatMap { state =>
              state.sessions.get(sessionId) match {
                case Some(userId) =>
                  state.todos.get(todoId) match {
                    case Some(todo) if todo.owner_id == userId =>
                      ZIO.succeed(Response.json(todo.toJson).withStatus(Status.Ok))
                    case _ =>
                      ZIO.succeed(Response.json(Error("Todo not found").toJson).withStatus(Status.NotFound))
                  }
                case None =>
                  ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
              }
            }
          case None =>
            ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
        }
      },
      
      // Update todo
      Method.PUT / "todos" / RouteCodec.int -> handler { (todoId: Int, req: Request) =>
        req.body.asString.orElseFail(new RuntimeException("Could not read body")).flatMap { body =>
          body.fromJson[UpdateTodoRequest] match {
            case Right(updateData) =>
              if(updateData.title.exists(_.trim.isEmpty)) {
                ZIO.succeed(Response.json(Error("Title is required").toJson).withStatus(Status.BadRequest))
              } else {
                extractSessionId(req) match {
                  case Some(sessionId) =>
                    serviceRef.modifyZIO { state =>
                      state.sessions.get(sessionId) match {
                        case Some(userId) =>
                          state.todos.get(todoId) match {
                            case Some(todo) if todo.owner_id == userId =>
                              val updatedTime = getCurrentTimestamp()
                              val updatedTodo = todo.copy(
                                title = updateData.title.getOrElse(todo.title),
                                description = updateData.description.getOrElse(todo.description),
                                completed = updateData.completed.getOrElse(todo.completed),
                                updated_at = updatedTime
                              )
                              val newState = state.copy(todos = state.todos.updated(todoId, updatedTodo))
                              ZIO.succeed((Response.json(updatedTodo.toJson).withStatus(Status.Ok), newState))
                            case _ =>
                              ZIO.succeed((Response.json(Error("Todo not found").toJson).withStatus(Status.NotFound), state))
                          }
                        case None =>
                          ZIO.succeed((Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized), state))
                      }
                    }
                  case None =>
                    ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
                }
              }
            case Left(error) =>
              ZIO.succeed(Response.json(Error(s"Invalid request: $error").toJson).withStatus(Status.BadRequest))
          }
        }
      },
      
      // Delete todo
      Method.DELETE / "todos" / RouteCodec.int -> handler { (todoId: Int, req: Request) =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            serviceRef.modifyZIO { state =>
              state.sessions.get(sessionId) match {
                case Some(userId) =>
                  state.todos.get(todoId) match {
                    case Some(todo) if todo.owner_id == userId =>
                      val newState = state.copy(todos = state.todos - todoId)
                      ZIO.succeed((Response.status(Status.NoContent), newState))
                    case _ =>
                      ZIO.succeed((Response.json(Error("Todo not found").toJson).withStatus(Status.NotFound), state))
                  }
                case None =>
                  ZIO.succeed((Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized), state))
              }
            }
          case None =>
            ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
        }
      }
    )
  }

  override def run = {
    val args = Runtime.default.unsafeRun(getArgs.map(_.map(_.toString).toVector))
    val optionPort = args.sliding(2).collectFirst { case "--port" :: port :: _ => port }
    val port = optionPort.map(_.toInt).getOrElse(8080)
    
    val program = for {
      ref <- Ref.make(ServiceState())
      app = createApp(ref)
      server <- Server.app(app)
      _ <- Console.printLine(s"Server starting on port $port at 0.0.0.0...")
      serverStart <- Server.install(server ++ Server.requestLogging()).race(ZIO.never)
    } yield serverStart
      
    program.exitCode
  }
}