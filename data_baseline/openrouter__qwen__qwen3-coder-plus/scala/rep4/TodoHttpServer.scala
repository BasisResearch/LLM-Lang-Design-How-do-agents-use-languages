#!/usr/bin/env -S scala-cli shebang -S 3.3.0
//> using dep dev.zio::zio:2.1.26
//> using dep dev.zio::zio-http:3.11.2
//> using dep dev.zio::zio-json:0.9.2
//> using platform jvm
//> using option -Wunused:imports

import zio._
import zio.http._
import zio.json._
import java.util.UUID
import java.time.format.DateTimeFormatter
import java.time.LocalDateTime
import java.time.ZoneOffset

object TodoHttpServer extends ZIOAppDefault {
  
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
  
  case class TodoServiceState(
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
  
  // Extract session ID from request
  def extractSessionId(req: Request): Option[String] = {
    req.headers.get(Header.Cookie).map { cookieHeader =>
      val cookies = cookieHeader.split(";").map(_.trim)
      cookies.find(_.startsWith("session_id=")).map(_.substring(11)) // Remove "session_id="
    }.flatten
  }
  
  val app: Routes[Any, Response] = Routes(
    // Register
    Method.POST / "register" -> handler { (req: Request) =>
      req.body.asString.orElseFail(new RuntimeException("Request body error")).flatMap { body =>
        body.fromJson[RegisterRequest] match {
          case Right(RegisterRequest(username, password)) =>
            ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
              (for {
                state <- serviceRef.get
                _ <- ZIO.when(username.length < 3 || username.length > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
                  ZIO.fail(Response.json(Error("Invalid username").toJson).withStatus(Status.BadRequest))
                }
                _ <- ZIO.when(password.length < 8) {
                  ZIO.fail(Response.json(Error("Password too short").toJson).withStatus(Status.BadRequest))
                }
                _ <- ZIO.when(state.users.exists(_._2.username == username)) {
                  ZIO.fail(Response.json(Error("Username already exists").toJson).withStatus(Status.Conflict))
                }
                userId = state.userCounter
                newUser = User(userId, username, hashPassword(password))
                _ <- serviceRef.update(s => s.copy(
                  users = s.users + (userId -> newUser),
                  userCounter = s.userCounter + 1
                ))
              } yield Response.json(UserData(newUser.id, newUser.username).toJson).withStatus(Status.Created))
              .catchAll(identity)
            }
          case Left(_) => 
            ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
        }
      }
    },
    
    // Login
    Method.POST / "login" -> handler { (req: Request) =>
      req.body.asString.orElseFail(new RuntimeException("Request body error")).flatMap { body =>
        body.fromJson[LoginRequest] match {
          case Right(LoginRequest(username, password)) =>
            ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
              (for {
                state <- serviceRef.get
                userOpt = state.users.values.find(_.username == username)
                user <- ZIO.fromOption(userOpt)
                _ <- ZIO.unless(user.passwordHash == hashPassword(password)) {
                  ZIO.fail(Response.json(Error("Invalid credentials").toJson).withStatus(Status.Unauthorized))
                }
                sessionId = UUID.randomUUID().toString
                _ <- serviceRef.update(s => s.copy(sessions = s.sessions + (sessionId -> user.id)))
              } yield Response.json(UserData(user.id, user.username).toJson)
                .withHeaders(Headers(Header.SetCookie(s"session_id=$sessionId; Path=/; HttpOnly"))))
              .catchAll(identity)
            }
            
          case Left(_) =>
            ZIO.succeed(Response.json(Error("Invalid request").toJson).withStatus(Status.BadRequest))
        }
      }
    },
    
    // Logout
    Method.POST / "logout" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
            for {
              _ <- serviceRef.update(s => s.copy(sessions = s.sessions - sessionId))
            } yield Response.json("{}".toJson).status(Status.Ok)
          }
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).withStatus(Status.Unauthorized))
      }
    },
    
    // Get user info
    Method.GET / "me" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
            for {
              state <- serviceRef.get
              userIdOpt = state.sessions.get(sessionId)
              userOpt = userIdOpt flatMap (userId => state.users.get(userId))
              response <- userOpt match {
                case Some(user) => 
                  ZIO.succeed(Response.json(UserData(user.id, user.username).toJson).status(Status.Ok))
                case None =>
                  ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
              }
            } yield response
          }
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Change password
    Method.PUT / "password" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
            req.body.asString.orElseFail(new RuntimeException("Request body error")).flatMap { body =>
              body.fromJson[ChangePasswordRequest] match {
                case Right(ChangePasswordRequest(oldPassword, newPassword)) =>
                  (for {
                    state <- serviceRef.get
                    userIdOpt = state.sessions.get(sessionId)
                    userId <- ZIO.fromOption(userIdOpt)
                    userOpt = state.users.get(userId)
                    user <- ZIO.fromOption(userOpt)
                    _ <- ZIO.unless(user.passwordHash == hashPassword(oldPassword)) {
                      ZIO.fail(Response.json(Error("Invalid credentials").toJson).status(Status.Unauthorized))
                    }
                    _ <- ZIO.when(newPassword.length < 8) {
                      ZIO.fail(Response.json(Error("Password too short").toJson).status(Status.BadRequest))
                    }
                    newPasswordHash = hashPassword(newPassword)
                    _ <- serviceRef.update(s => s.copy(users = s.users.updated(userId, user.copy(passwordHash = newPasswordHash))))
                  } yield Response.json("{}".toJson).status(Status.Ok))
                  .catchAll(identity)
                
                case Left(_) =>
                  ZIO.succeed(Response.json(Error("Invalid request").toJson).status(Status.BadRequest))
              }
            }
          }
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Get all todos
    Method.GET / "todos" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
            for {
              state <- serviceRef.get
              userIdOpt = state.sessions.get(sessionId)
              userTodos = userIdOpt match {
                case Some(userId) => 
                  state.todos.values.filter(_.owner_id == userId).toList.sortBy(_.id)
                case None => 
                  List.empty[Todo]
              }
              response <- if (userIdOpt.nonEmpty) {
                ZIO.succeed(Response.json(userTodos.toJson).status(Status.Ok))
              } else {
                ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
              }
            } yield response
          }
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Create todo
    Method.POST / "todos" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
            req.body.asString.orElseFail(new RuntimeException("Request body error")).flatMap { body =>
              body.fromJson[CreateTodoRequest] match {
                case Right(CreateTodoRequest(title, description)) =>
                  if (title.trim.isEmpty) {
                    ZIO.succeed(Response.json(Error("Title is required").toJson).withStatus(Status.BadRequest))
                  } else {
                    (for {
                      state <- serviceRef.get
                      userIdOpt = state.sessions.get(sessionId)
                      userId <- ZIO.fromOption(userIdOpt)
                      todoId = state.todoCounter
                      createdAt = getCurrentTimestamp()
                      newTodo = Todo(
                        id = todoId,
                        title = title.trim,
                        description = description,
                        completed = false,
                        created_at = createdAt,
                        updated_at = createdAt,
                        owner_id = userId
                      )
                      _ <- serviceRef.update(s => s.copy(
                        todos = s.todos + (todoId -> newTodo),
                        todoCounter = s.todoCounter + 1
                      ))
                    } yield Response.json(newTodo.toJson).status(Status.Created))
                    .catchAll(_ => 
                      ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
                    )
                  }
                  
                case Left(_) =>
                  ZIO.succeed(Response.json(Error("Invalid request").toJson).status(Status.BadRequest))
              }
            }
          }
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Get specific todo by ID
    Method.GET / "todos" / "integer" -> handler { (_: String, req: Request) => // Using string path as int handling needs adjustment
      val idStr = req.path.segments.last
      extractSessionId(req) match {
        case Some(sessionId) =>
          idStr.toIntOption match {
            case Some(id) =>
              ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
                for {
                  state <- serviceRef.get
                  userIdOpt = state.sessions.get(sessionId)
                  todoOpt = state.todos.get(id)
                  response <- (userIdOpt, todoOpt) match {
                    case (Some(userId), Some(todo)) if todo.owner_id == userId =>
                      ZIO.succeed(Response.json(todo.toJson).status(Status.Ok))
                    case _ =>
                      ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
                  }
                } yield response
              }
            case None =>
              ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
          }
          
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Update specific todo
    Method.PUT / "todos" / "integer" -> handler { (_: String, req: Request) =>
      val idStr = req.path.segments.last
      extractSessionId(req) match {
        case Some(sessionId) =>
          idStr.toIntOption match {
            case Some(id) =>
              ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
                req.body.asString.orElseFail(new RuntimeException("Request body error")).flatMap { body =>
                  body.fromJson[UpdateTodoRequest] match {
                    case Right(updateData) =>
                      if(updateData.title.exists(_.trim.isEmpty)) {
                        ZIO.succeed(Response.json(Error("Title is required").toJson).status(Status.BadRequest))
                      } else {
                        (for {
                          state <- serviceRef.get
                          userIdOpt = state.sessions.get(sessionId)
                          originalTodoOpt = state.todos.get(id)
                          (Some(userId), Some(originalTodo)) = (userIdOpt, originalTodoOpt) -> "should have user and todo"
                          _ <- ZIO.unless(originalTodo.owner_id == userId) {
                            ZIO.fail(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
                          }
                          updatedTodo = originalTodo.copy(
                            title = updateData.title.getOrElse(originalTodo.title),
                            description = updateData.description.getOrElse(originalTodo.description),
                            completed = updateData.completed.getOrElse(originalTodo.completed),
                            updated_at = getCurrentTimestamp()
                          )
                          _ <- serviceRef.update(s => s.copy(todos = s.todos.updated(id, updatedTodo)))
                        } yield Response.json(updatedTodo.toJson).status(Status.Ok))
                        .catchAll {
                          case response: Response => ZIO.succeed(response)
                          case _ => ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
                        }
                      }
                    
                    case Left(_) =>
                      ZIO.succeed(Response.json(Error("Invalid request").toJson).status(Status.BadRequest))
                  }
                }
              }
              
            case None =>
              ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
          }
          
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    },
    
    // Delete specific todo
    Method.DELETE / "todos" / "integer" -> handler { (_: String, req: Request) =>
      val idStr = req.path.segments.last
      extractSessionId(req) match {
        case Some(sessionId) =>
          idStr.toIntOption match {
            case Some(id) =>
              ZIO.serviceWithZIO[Ref[TodoServiceState]] { serviceRef => 
                (for {
                  state <- serviceRef.get
                  userIdOpt = state.sessions.get(sessionId)
                  userId <- ZIO.fromOption(userIdOpt)
                  originalTodoOpt = state.todos.get(id)
                  originalTodo <- ZIO.fromOption(originalTodoOpt)
                  _ <- ZIO.unless(originalTodo.owner_id == userId) {
                    ZIO.fail(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
                  }
                  _ <- serviceRef.update(s => s.copy(todos = s.todos - id))
                } yield Response.status(Status.NoContent))
                .catchAll {
                  case response: Response => ZIO.succeed(response)
                  case _ => ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
                }
              }
              
            case None =>
              ZIO.succeed(Response.json(Error("Todo not found").toJson).status(Status.NotFound))
          }
          
        case None =>
          ZIO.succeed(Response.json(Error("Authentication required").toJson).status(Status.Unauthorized))
      }
    }
  )
  
  override def run = {
    val args = zio.Runtime.default.unsafeRun(ZIO.serviceWithZIO[cli.Args](_.get).map(_.toVector.map(_.toString)))
    val port = ArgsParser.parsePort(args.zipWithIndex.map { case (arg, i) => if (i > 0) arg else "" }).getOrElse(8080)
    
    val config = Server.Config.default.port(port).binding("0.0.0.0", port)
    
    (for {
      serviceRef <- Ref.make(TodoServiceState())
      _ <- Console.printLine(s"Server starting on port $port...")
      finalApp = app.provideEnvironment(ZEnvironment(serviceRef))
      _ <- Server.install(finalApp ++ Server.requestLogging())
      _ <- ZIO.never
    } yield ())
    .provide(Server.config(config))
    .exitCode
  }
}

object ArgsParser {
  def parsePort(args: Vector[String]): Option[Int] = {
    val argsList = args.toList
    argsList.sliding(2).collectFirst {
      case "--port" :: portStr :: _ =>
        try {
          portStr.toInt
        } catch {
          case _: NumberFormatException => 
            System.err.println(s"Error: Invalid port value: $portStr")
            9999  // Non-standard port to make this obvious there was an issue
        }
    }
  }
}