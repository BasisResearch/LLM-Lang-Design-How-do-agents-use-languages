#!/usr/bin/env -S scala-cli shebang -S 3.3.0 
//> using dep dev.zio::zio:2.1.9
//> using dep dev.zio::zio-http:3.1.0
//> using dep dev.zio::zio-json:0.7.3

import zio._
import zio.http._
import zio.json._
import java.util.UUID
import java.time.format.DateTimeFormatter
import java.time.LocalDateTime
import java.time.ZoneOffset

object SimpleTodoService extends ZIOAppDefault {
  
  // Data models
  case class User(id: Int, username: String, passwordHash: String)
  object User {
    implicit val encoder: JsonEncoder[User] = JsonEncoder.obj(
      ("id", _.id),
      ("username", _.username)
      // Don't include password hash in JSON response
    )
    implicit val decoder: JsonDecoder[User] = JsonDecoder.obj(User.apply)
  }
  
  case class RegisterRequest(username: String, password: String)
  object RegisterRequest {
    implicit val jsonCodec: JsonCodec[RegisterRequest] = DeriveJsonCodec.gen[RegisterRequest]
  }
  
  case class LoginRequest(username: String, password: String)
  object LoginRequest {
    implicit val jsonCodec: JsonCodec[LoginRequest] = DeriveJsonCodec.gen[LoginRequest]
  }
  
  case class ChangePasswordRequest(old_password: String, new_password: String)
  object ChangePasswordRequest {
    implicit val jsonCodec: JsonCodec[ChangePasswordRequest] = DeriveJsonCodec.gen[ChangePasswordRequest]
  }
  
  case class CreateTodoRequest(title: String, description: String = "")
  object CreateTodoRequest {
    implicit val jsonCodec: JsonCodec[CreateTodoRequest] = DeriveJsonCodec.gen[CreateTodoRequest]
  }
  
  case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
  object UpdateTodoRequest {
    implicit val jsonCodec: JsonCodec[UpdateTodoRequest] = DeriveJsonCodec.gen[UpdateTodoRequest]
  }
  
  case class Todo(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String, owner_id: Int)
  object Todo {
    implicit val jsonCodec: JsonCodec[Todo] = DeriveJsonCodec.gen[Todo]
  }

  case class UserData(id: Int, username: String)
  object UserData {
    implicit val jsonCodec: JsonCodec[UserData] = DeriveJsonCodec.gen[UserData]
  }

  case class Error(error: String) 
  object Error {
    implicit val jsonCodec: JsonCodec[Error] = DeriveJsonCodec.gen[Error]
  }
  
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
    req.headers.get("Cookie") match {
      case Some(cookieHeaderValue) =>
        val cookieValue = cookieHeaderValue.toString
        cookieValue.split(";").map(_.trim).find(_.startsWith("session_id=")) match {
          case Some(sessionStr) => Some(sessionStr.substring(11)) // Remove "session_id="
          case None => None
        }
      case None => None
    }
  }

  def validateSessionAndGetUserId(serviceRef: Ref[ServiceState], sessionId: String): ZIO[Any, Nothing, Option[Int]] = {
    serviceRef.get.map(_.sessions.get(sessionId))
  }

  val app = Routes(
    // Register user
    Method.POST / "register" -> handler { (req: Request) =>
      req.body.asString.mapError(new RuntimeException(_)).flatMap { body =>
        body.fromJson[RegisterRequest] match {
          case Right(RegisterRequest(username, password)) =>
            if (username.length < 3 || username.length > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
              ZIO.succeed(Response.text(Error("Invalid username").toJson).withStatus(Status.BAD_REQUEST))
            } else if (password.length < 8) {
              ZIO.succeed(Response.text(Error("Password too short").toJson).withStatus(Status.BAD_REQUEST))
            } else {
              (for {
                stateBefore <- ZIO.service[Ref[ServiceState]]
                state <- stateBefore.get
                _ <- ZIO.when(state.users.values.exists(_.username == username)) {
                  ZIO.succeed(Response.text(Error("Username already exists").toJson).withStatus(Status.CONFLICT))
                }.flatten
                userId = state.userCounter
                newUser = User(userId, username, hashPassword(password))
                _ <- stateBefore.update(s => s.copy(
                  users = s.users + (userId -> newUser),
                  userCounter = s.userCounter + 1
                ))
              } yield Response.text(UserData(newUser.id, newUser.username).toJson).withStatus(Status.CREATED))
              .orElse(Succeed(Response.text(Error("Error processing registration").toJson).withStatus(Status.INTERNAL_SERVER_ERROR)))
            }
          case Left(error) => 
            ZIO.succeed(Response.text(Error(s"Invalid request: $error").toJson).withStatus(Status.BAD_REQUEST))
        }
      }
    },
        
    // Login user  
    Method.POST / "login" -> handler { (req: Request) =>
      req.body.asString.mapError(new RuntimeException(_)).flatMap { body =>
        body.fromJson[LoginRequest] match {
          case Right(LoginRequest(username, password)) =>
            (for {
              serviceRef <- ZIO.service[Ref[ServiceState]]
              state <- serviceRef.get
              userOpt = state.users.values.find(_.username == username)
              user <- ZIO.fromOption(userOpt)
              _ <- ZIO.when(user.passwordHash != hashPassword(password)) {
                ZIO.succeed(Response.text(Error("Invalid credentials").toJson).withStatus(Status.UNAUTHORIZED))
              }.flatten
              sessionId = UUID.randomUUID().toString
              _ <- serviceRef.update(s => s.copy(sessions = s.sessions + (sessionId -> user.id)))
            } yield Response
              .text(UserData(user.id, user.username).toJson)
              .addHeader(Header.SetCookie.Raw("session_id", s"$sessionId; Path=/; HttpOnly")))
            .catchAll { error => 
              error match {
                case response: Response => ZIO.succeed(response)
                case _ => ZIO.succeed(Response.text(Error("Invalid credentials").toJson).withStatus(Status.UNAUTHORIZED))
              }
            }
          case Left(error) =>
            ZIO.succeed(Response.text(Error(s"Invalid request: $error").toJson).withStatus(Status.BAD_REQUEST))
        }
      }
    },
    
    // Logout    
    Method.POST / "logout" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          (for {
            serviceRef <- ZIO.service[Ref[ServiceState]]
            _ <- serviceRef.update(s => s.copy(sessions = s.sessions - sessionId))
          } yield Response.text("{}").withStatus(Status.OK))
        case None =>
          ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
      }
    },
    
    // Get current user
    Method.GET / "me" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          (for {
            serviceRef <- ZIO.service[Ref[ServiceState]]
            state <- serviceRef.get
            userId <- ZIO.fromOption(state.sessions.get(sessionId))
            user <- ZIO.fromOption(state.users.get(userId))
          } yield Response.text(UserData(user.id, user.username).toJson).withStatus(Status.OK))
          .catchAll(_ => ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED)))
          
        case None =>
          ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
      }
    },
    
    // Change password
    Method.PUT / "password" -> handler { (req: Request) =>
      req.body.asString.mapError(new RuntimeException(_)).flatMap { body =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            body.fromJson[ChangePasswordRequest] match {
              case Right(ChangePasswordRequest(oldPassword, newPassword)) =>
                if(newPassword.length < 8) {
                  ZIO.succeed(Response.text(Error("Password too short").toJson).withStatus(Status.BAD_REQUEST))
                } else {
                  (for {
                    serviceRef <- ZIO.service[Ref[ServiceState]]
                    state <- serviceRef.get 
                    userId <- ZIO.fromOption(state.sessions.get(sessionId))
                    user <- ZIO.fromOption(state.users.get(userId))
                    _ <- ZIO.when(user.passwordHash != hashPassword(oldPassword)) {
                      ZIO.succeed(Response.text(Error("Invalid credentials").toJson).withStatus(Status.UNAUTHORIZED))
                    }.flatten
                    _ <- serviceRef.update(s => {
                      s.copy(users = s.users.updated(userId, user.copy(passwordHash = hashPassword(newPassword))))
                    })
                  } yield Response.text("{}").withStatus(Status.OK))
                  .catchAll {
                    case response: Response => ZIO.succeed(response)
                    case _ => ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
                  }
                }
                
              case Left(error) =>
                ZIO.succeed(Response.text(Error(s"Invalid request: $error").toJson).withStatus(Status.BAD_REQUEST))
            }
            
          case None =>
            ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
        }
      }
    },
    
    // Get todos
    Method.GET / "todos" -> handler { (req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          (for {
            serviceRef <- ZIO.service[Ref[ServiceState]]
            state <- serviceRef.get
            userId <- ZIO.fromOption(state.sessions.get(sessionId))
            userTodos = state.todos.values.filter(_.owner_id == userId).toList.sortBy(_.id)
          } yield Response.text(userTodos.toJson).withStatus(Status.OK))
          .catchAll(_ => ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED)))
          
        case None =>
          ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
      }
    },
    
    // Create todo
    Method.POST / "todos" -> handler { (req: Request) =>
      req.body.asString.mapError(new RuntimeException(_)).flatMap { body =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            body.fromJson[CreateTodoRequest] match {
              case Right(CreateTodoRequest(title, description)) =>
                if(title.trim.isEmpty) {
                  ZIO.succeed(Response.text(Error("Title is required").toJson).withStatus(Status.BAD_REQUEST))
                } else {
                  (for {
                    serviceRef <- ZIO.service[Ref[ServiceState]]
                    state <- serviceRef.get
                    userId <- ZIO.fromOption(state.sessions.get(sessionId))
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
                  } yield Response.text(newTodo.toJson).withStatus(Status.CREATED))
                  .catchAll(_ => ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED)))
                }
                
              case Left(error) =>
                ZIO.succeed(Response.text(Error(s"Invalid request: $error").toJson).withStatus(Status.BAD_REQUEST))
            }
            
          case None =>
            ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
        }
      }
    },
    
    // Get specific todo
    Method.GET / "todos" / IntAsSegment() -> handler { (todoId: Int, req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          (for {
            serviceRef <- ZIO.service[Ref[ServiceState]]
            state <- serviceRef.get
            userId <- ZIO.fromOption(state.sessions.get(sessionId))
            todo <- ZIO.fromOption(state.todos.get(todoId))
            _ <- ZIO.when(todo.owner_id != userId) {
              ZIO.fail(new RuntimeException("Not found"))
            }
          } yield Response.text(todo.toJson).withStatus(Status.OK))
          .catchAll(_ => ZIO.succeed(Response.text(Error("Todo not found").toJson).withStatus(Status.NOT_FOUND)))
          
        case None =>
          ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
      }
    },
    
    // Update specific todo
    Method.PUT / "todos" / IntAsSegment() -> handler { (todoId: Int, req: Request) =>
      req.body.asString.mapError(new RuntimeException(_)).flatMap { body =>
        extractSessionId(req) match {
          case Some(sessionId) =>
            body.fromJson[UpdateTodoRequest] match {
              case Right(update) =>
                if(update.title.exists(_.trim.isEmpty)) {
                  ZIO.succeed(Response.text(Error("Title is required").toJson).withStatus(Status.BAD_REQUEST))
                } else {
                  (for {
                    serviceRef <- ZIO.service[Ref[ServiceState]]
                    state <- serviceRef.get
                    userId <- ZIO.fromOption(state.sessions.get(sessionId))
                    originalTodo <- ZIO.fromOption(state.todos.get(todoId))
                    _ <- ZIO.when(originalTodo.owner_id != userId) {
                      ZIO.fail(new RuntimeException("Not found"))
                    }
                    updatedTime = getCurrentTimestamp()
                    updatedTodo = originalTodo.copy(
                      title = update.title.getOrElse(originalTodo.title),
                      description = update.description.getOrElse(originalTodo.description),
                      completed = update.completed.getOrElse(originalTodo.completed),
                      updated_at = updatedTime
                    )
                    _ <- serviceRef.update(s => s.copy(todos = s.todos.updated(todoId, updatedTodo)))
                  } yield Response.text(updatedTodo.toJson).withStatus(Status.OK))
                  .catchAll(_ => ZIO.succeed(Response.text(Error("Todo not found").toJson).withStatus(Status.NOT_FOUND)))
                }
                
              case Left(error) =>
                ZIO.succeed(Response.text(Error(s"Invalid request: $error").toJson).withStatus(Status.BAD_REQUEST))
            }
            
          case None =>
            ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
        }
      }
    },
    
    // Delete specific todo
    Method.DELETE / "todos" / IntAsSegment() -> handler { (todoId: Int, req: Request) =>
      extractSessionId(req) match {
        case Some(sessionId) =>
          (for {
            serviceRef <- ZIO.service[Ref[ServiceState]]
            state <- serviceRef.get
            userId <- ZIO.fromOption(state.sessions.get(sessionId))
            originalTodo <- ZIO.fromOption(state.todos.get(todoId))
            _ <- ZIO.when(originalTodo.owner_id != userId) {
              ZIO.fail(new RuntimeException("Not found"))
            }
            _ <- serviceRef.update(s => s.copy(todos = s.todos - todoId))
          } yield Response.empty.withStatus(Status.NO_CONTENT))
          .catchAll(_ => ZIO.succeed(Response.text(Error("Todo not found").toJson).withStatus(Status.NOT_FOUND)))
          
        case None =>
          ZIO.succeed(Response.text(Error("Authentication required").toJson).withStatus(Status.UNAUTHORIZED))
      }
    }
  ).fold(
    // Handle route not found by returning 404
    error => Routes(RoutePattern.any ~> Handler.ok),
    identity
  )
  
  def intFromPathSegments(req: Request): Option[Int] = {
    req.path.segments.lastOption.flatMap(segment => scala.util.Try(segment.toString.toInt).toOption)
  }.orNull

  override def run = {
    val args = getArgs.map(_.toVector.map(_.toString))
    val portList = args.map(_.sliding(2).collectFirst { case Seq("--port", portStr) => portStr.toInt })
    val port = portList.map(_.getOrElse(8080)).getOrElse(8080)
    
    val serverProgram = for {
      ref <- Ref.make(ServiceState())
      serverApp <- ZIO.environmentWithZIO[Server](_.get.install(app.provideEnvironment(ZEnvironment(ref))))
      _ <- Console.printLine(s"Server starting on port $port at 0.0.0.0...")

      // Start the server
      _ <- serverApp.deploy(port)
    } yield ()

    serverProgram.exitCode
  }
}