//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.23"
//> using dep "org.http4s::http4s-dsl:0.23.23"
//> using dep "org.http4s::http4s-circe:0.23.23"
//> using dep "io.circe::circe-generic:0.14.6"
//> using dep "org.slf4j:slf4j-simple:2.0.9"

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.Decoder
import io.circe.Encoder
import java.util.UUID
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import com.comcast.ip4s._

case class User(id: Int, username: String, password: String)
case class Todo(id: Int, userId: Int, title: String, description: String, completed: Boolean, createdAt: String, updatedAt: String)

case class State(
  users: Map[String, User],
  usersById: Map[Int, User],
  nextUserId: Int,
  todos: Map[(Int, Int), Todo],
  nextTodoId: Int,
  sessions: Map[String, Int]
)

object State {
  def initial: State = State(
    users = Map.empty,
    usersById = Map.empty,
    nextUserId = 1,
    todos = Map.empty,
    nextTodoId = 1,
    sessions = Map.empty
  )
}

case class RegisterReq(username: Option[String], password: Option[String])
object RegisterReq {
  implicit val decoder: Decoder[RegisterReq] = Decoder.instance { c =>
    for {
      username <- c.downField("username").as[Option[String]]
      password <- c.downField("password").as[Option[String]]
    } yield RegisterReq(username, password)
  }
}

case class LoginReq(username: Option[String], password: Option[String])
object LoginReq {
  implicit val decoder: Decoder[LoginReq] = Decoder.instance { c =>
    for {
      username <- c.downField("username").as[Option[String]]
      password <- c.downField("password").as[Option[String]]
    } yield LoginReq(username, password)
  }
}

case class PasswordReq(old_password: Option[String], new_password: Option[String])
object PasswordReq {
  implicit val decoder: Decoder[PasswordReq] = Decoder.instance { c =>
    for {
      old_password <- c.downField("old_password").as[Option[String]]
      new_password <- c.downField("new_password").as[Option[String]]
    } yield PasswordReq(old_password, new_password)
  }
}

case class TodoCreateReq(title: Option[String], description: Option[String])
object TodoCreateReq {
  implicit val decoder: Decoder[TodoCreateReq] = Decoder.instance { c =>
    for {
      title <- c.downField("title").as[Option[String]]
      desc <- c.downField("description").as[Option[String]]
    } yield TodoCreateReq(title, desc)
  }
}

case class TodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])
object TodoReq {
  implicit val decoder: Decoder[TodoReq] = Decoder.instance { c =>
    for {
      title <- c.downField("title").as[Option[String]]
      desc <- c.downField("description").as[Option[String]]
      completed <- c.downField("completed").as[Option[Boolean]]
    } yield TodoReq(title, desc, completed)
  }
}

case class ErrorResponse(error: String)
object ErrorResponse {
  implicit val encoder: Encoder[ErrorResponse] = Encoder.forProduct1("error")(_.error)
}

case class UserResp(id: Int, username: String)
object UserResp {
  implicit val encoder: Encoder[UserResp] = Encoder.forProduct2("id", "username")(u => (u.id, u.username))
}

case class TodoResp(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String)
object TodoResp {
  implicit val encoder: Encoder[TodoResp] = Encoder.forProduct6("id", "title", "description", "completed", "created_at", "updated_at")(t =>
    (t.id, t.title, t.description, t.completed, t.created_at, t.updated_at)
  )
}

object Main {
  val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
  def now(): String = formatter.format(Instant.now())

  def decodeJson[A: Decoder](req: Request[IO]): IO[Either[ErrorResponse, A]] = {
    req.as[A].map(Right(_)).handleError(_ => Left(ErrorResponse("Invalid request body")))
  }

  def requireAuth(req: Request[IO], state: Ref[IO, State]): IO[Either[ErrorResponse, Int]] = {
    val sessionIdOpt = req.cookies.find(_.name == "session_id").map(_.content)
    sessionIdOpt match {
      case None => IO.pure(Left(ErrorResponse("Authentication required")))
      case Some(sessionId) =>
        state.get.map { s =>
          s.sessions.get(sessionId) match {
            case Some(userId) => Right(userId)
            case None => Left(ErrorResponse("Authentication required"))
          }
        }
    }
  }

  def handleRegister(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    decodeJson[RegisterReq](req).flatMap {
      case Left(err) => Response(Status.BadRequest).withEntity(err).pure[IO]
      case Right(RegisterReq(usernameOpt, passwordOpt)) =>
        val username = usernameOpt.getOrElse("")
        val password = passwordOpt.getOrElse("")
        state.modify { s =>
          if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            (s, Left(400 -> ErrorResponse("Invalid username")))
          } else if (password.length < 8) {
            (s, Left(400 -> ErrorResponse("Password too short")))
          } else if (s.users.contains(username)) {
            (s, Left(409 -> ErrorResponse("Username already exists")))
          } else {
            val newUser = User(s.nextUserId, username, password)
            val newS = s.copy(
              users = s.users + (username -> newUser),
              usersById = s.usersById + (s.nextUserId -> newUser),
              nextUserId = s.nextUserId + 1
            )
            (newS, Right(newUser))
          }
        }.flatMap {
          case Left((status, err)) => Response(Status.fromInt(status).getOrElse(Status.InternalServerError)).withEntity(err).pure[IO]
          case Right(user) => Response(Status.Created).withEntity(UserResp(user.id, user.username)).pure[IO]
        }
    }
  }

  def handleLogin(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    decodeJson[LoginReq](req).flatMap {
      case Left(err) => Response(Status.BadRequest).withEntity(err).pure[IO]
      case Right(LoginReq(usernameOpt, passwordOpt)) =>
        val username = usernameOpt.getOrElse("")
        val password = passwordOpt.getOrElse("")
        state.get.flatMap { s =>
          s.users.get(username) match {
            case Some(user) if user.password == password =>
              val token = UUID.randomUUID().toString
              state.update(currentS => currentS.copy(sessions = currentS.sessions.updated(token, user.id)))
                .as {
                  val cookie = ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)
                  Response(Status.Ok)
                    .withEntity(UserResp(user.id, user.username))
                    .addCookie(cookie)
                }
            case _ =>
              Response(Status.Unauthorized).withEntity(ErrorResponse("Invalid credentials")).pure[IO]
          }
        }
    }
  }

  def handleLogout(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    requireAuth(req, state).flatMap {
      case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
      case Right(_) =>
        val sessionIdOpt = req.cookies.find(_.name == "session_id").map(_.content)
        sessionIdOpt match {
          case Some(sessionId) =>
            state.update(s => s.copy(sessions = s.sessions - sessionId))
              .as(Response(Status.Ok).withEntity(io.circe.Json.obj()))
          case None =>
            Response(Status.Unauthorized).withEntity(ErrorResponse("Authentication required")).pure[IO]
        }
    }
  }

  def handleMe(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    requireAuth(req, state).flatMap {
      case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
      case Right(userId) =>
        state.get.map { s =>
          s.usersById.get(userId) match {
            case Some(user) => Response(Status.Ok).withEntity(UserResp(user.id, user.username))
            case None => Response(Status.Unauthorized).withEntity(ErrorResponse("Authentication required"))
          }
        }
    }
  }

  def handlePassword(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    decodeJson[PasswordReq](req).flatMap {
      case Left(err) => Response(Status.BadRequest).withEntity(err).pure[IO]
      case Right(PasswordReq(oldPOpt, newPOpt)) =>
        val oldP = oldPOpt.getOrElse("")
        val newP = newPOpt.getOrElse("")
        requireAuth(req, state).flatMap {
          case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
          case Right(userId) =>
            state.modify { s =>
              s.usersById.get(userId) match {
                case Some(user) if user.password == oldP =>
                  if (newP.length < 8) {
                    (s, Left(400 -> ErrorResponse("Password too short")))
                  } else {
                    val newUser = user.copy(password = newP)
                    (s.copy(users = s.users + (user.username -> newUser), usersById = s.usersById + (userId -> newUser)), Right(()))
                  }
                case Some(_) =>
                  (s, Left(401 -> ErrorResponse("Invalid credentials")))
                case None =>
                  (s, Left(401 -> ErrorResponse("Invalid credentials")))
              }
            }.flatMap {
              case Left((status, err)) => Response(Status.fromInt(status).getOrElse(Status.InternalServerError)).withEntity(err).pure[IO]
              case Right(_) => Response(Status.Ok).withEntity(io.circe.Json.obj()).pure[IO]
            }
        }
    }
  }

  def handleGetTodos(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    requireAuth(req, state).flatMap {
      case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
      case Right(userId) =>
        state.get.map { s =>
          val userTodos = s.todos.collect {
            case ((uid, _), todo) if uid == userId => 
              TodoResp(todo.id, todo.title, todo.description, todo.completed, todo.createdAt, todo.updatedAt)
          }.toList.sortBy(_.id)
          Response(Status.Ok).withEntity(userTodos)
        }
    }
  }

  def handleCreateTodo(req: Request[IO], state: Ref[IO, State]): IO[Response[IO]] = {
    decodeJson[TodoCreateReq](req).flatMap {
      case Left(err) => Response(Status.BadRequest).withEntity(err).pure[IO]
      case Right(TodoCreateReq(titleOpt, descOpt)) =>
        requireAuth(req, state).flatMap {
          case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
          case Right(userId) =>
            val title = titleOpt.getOrElse("")
            if (title.trim.isEmpty) {
              Response(Status.BadRequest).withEntity(ErrorResponse("Title is required")).pure[IO]
            } else {
              state.modify { s =>
                val newTodoId = s.nextTodoId
                val nowStr = now()
                val newTodo = Todo(newTodoId, userId, title, descOpt.getOrElse(""), completed = false, nowStr, nowStr)
                val newS = s.copy(
                  todos = s.todos + ((userId, newTodoId) -> newTodo),
                  nextTodoId = newTodoId + 1
                )
                (newS, TodoResp(newTodo.id, newTodo.title, newTodo.description, newTodo.completed, newTodo.createdAt, newTodo.updatedAt))
              }.map { todoResp =>
                Response(Status.Created).withEntity(todoResp)
              }
            }
        }
    }
  }

  def handleGetTodo(req: Request[IO], state: Ref[IO, State], todoId: Int): IO[Response[IO]] = {
    requireAuth(req, state).flatMap {
      case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
      case Right(userId) =>
        state.get.map { s =>
          s.todos.get((userId, todoId)) match {
            case Some(todo) => 
              Response(Status.Ok).withEntity(TodoResp(todo.id, todo.title, todo.description, todo.completed, todo.createdAt, todo.updatedAt))
            case None =>
              Response(Status.NotFound).withEntity(ErrorResponse("Todo not found"))
          }
        }
    }
  }

  def handleUpdateTodo(req: Request[IO], state: Ref[IO, State], todoId: Int): IO[Response[IO]] = {
    decodeJson[TodoReq](req).flatMap {
      case Left(err) => Response(Status.BadRequest).withEntity(err).pure[IO]
      case Right(todoReq) =>
        requireAuth(req, state).flatMap {
          case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
          case Right(userId) =>
            if (todoReq.title.exists(_.trim.isEmpty)) {
              Response(Status.BadRequest).withEntity(ErrorResponse("Title is required")).pure[IO]
            } else {
              state.modify { s =>
                s.todos.get((userId, todoId)) match {
                  case Some(todo) =>
                    val nowStr = now()
                    val updatedTodo = todo.copy(
                      title = todoReq.title.getOrElse(todo.title),
                      description = todoReq.description.getOrElse(todo.description),
                      completed = todoReq.completed.getOrElse(todo.completed),
                      updatedAt = nowStr
                    )
                    val newS = s.copy(todos = s.todos + ((userId, todoId) -> updatedTodo))
                    (newS, Right(TodoResp(updatedTodo.id, updatedTodo.title, updatedTodo.description, updatedTodo.completed, updatedTodo.createdAt, updatedTodo.updatedAt)))
                  case None =>
                    (s, Left(ErrorResponse("Todo not found")))
                }
              }.flatMap {
                case Left(err) => Response(Status.NotFound).withEntity(err).pure[IO]
                case Right(resp) => Response(Status.Ok).withEntity(resp).pure[IO]
              }
            }
        }
    }
  }

  def handleDeleteTodo(req: Request[IO], state: Ref[IO, State], todoId: Int): IO[Response[IO]] = {
    requireAuth(req, state).flatMap {
      case Left(err) => Response(Status.Unauthorized).withEntity(err).pure[IO]
      case Right(userId) =>
        state.modify { s =>
          if (s.todos.contains((userId, todoId))) {
            val newS = s.copy(todos = s.todos - ((userId, todoId)))
            (newS, Right(()))
          } else {
            (s, Left(ErrorResponse("Todo not found")))
          }
        }.flatMap {
          case Left(err) => Response(Status.NotFound).withEntity(err).pure[IO]
          case Right(_) => Response(Status.NoContent).pure[IO]
        }
    }
  }

  def httpApp(state: Ref[IO, State]): HttpApp[IO] = HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" => handleRegister(req, state)
    case req @ POST -> Root / "login" => handleLogin(req, state)
    case req @ POST -> Root / "logout" => handleLogout(req, state)
    case req @ GET -> Root / "me" => handleMe(req, state)
    case req @ PUT -> Root / "password" => handlePassword(req, state)
    case req @ GET -> Root / "todos" => handleGetTodos(req, state)
    case req @ POST -> Root / "todos" => handleCreateTodo(req, state)
    case req @ GET -> Root / "todos" / IntVar(todoId) => handleGetTodo(req, state, todoId)
    case req @ PUT -> Root / "todos" / IntVar(todoId) => handleUpdateTodo(req, state, todoId)
    case req @ DELETE -> Root / "todos" / IntVar(todoId) => handleDeleteTodo(req, state, todoId)
  }.orNotFound

  def main(args: Array[String]): Unit = {
    import cats.effect.unsafe.implicits.global
    
    val port = args.indexOf("--port") match {
      case -1 => 8080
      case i if i + 1 < args.length => args(i + 1).toInt
      case _ => 8080
    }

    val server = for {
      state <- Ref.of[IO, State](State.initial)
      _ <- EmberServerBuilder
        .default[IO]
        .withHost(ip"0.0.0.0")
        .withPort(Port.fromInt(port).get)
        .withHttpApp(httpApp(state))
        .build
        .use { server =>
          IO.println(s"Server started on port $port") *> IO.never
        }
    } yield ()

    server.unsafeRunSync()
  }
}