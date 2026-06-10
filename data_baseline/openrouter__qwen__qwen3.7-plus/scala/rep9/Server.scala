//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "io.circe::circe-core:0.14.15"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"

import cats.effect._
import cats.effect.std.UUIDGen
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe._
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.syntax._
import java.time.Instant
import java.time.format.DateTimeFormatter
import com.comcast.ip4s._

case class User(id: Int, username: String, password: String)
case class Todo(id: Int, userId: Int, title: String, description: String, completed: Boolean, createdAt: String, updatedAt: String)

case class AppState(
  users: Map[Int, User] = Map.empty,
  usernameToId: Map[String, Int] = Map.empty,
  sessions: Map[String, Int] = Map.empty,
  todos: Map[Int, Todo] = Map.empty,
  nextUserId: Int = 1,
  nextTodoId: Int = 1
)

case class RegisterRequest(username: String, password: String)
case class LoginRequest(username: String, password: String)
case class UserResponse(id: Int, username: String)
case class PasswordChangeRequest(old_password: String, new_password: String)
case class TodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
case class TodoResponse(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String)

given Decoder[RegisterRequest] = Decoder.forProduct2("username", "password")(RegisterRequest.apply)
given Decoder[LoginRequest] = Decoder.forProduct2("username", "password")(LoginRequest.apply)
given Encoder[UserResponse] = Encoder.forProduct2("id", "username")(u => (u.id, u.username))
given Decoder[PasswordChangeRequest] = Decoder.forProduct2("old_password", "new_password")(PasswordChangeRequest.apply)
given Decoder[TodoRequest] = Decoder.forProduct3("title", "description", "completed")(TodoRequest.apply)
given Encoder[TodoResponse] = Encoder.forProduct6("id", "title", "description", "completed", "created_at", "updated_at")(t => (t.id, t.title, t.description, t.completed, t.created_at, t.updated_at))

def nowUtc(): String = {
  val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
  Instant.now().atZone(java.time.ZoneOffset.UTC).format(formatter)
}

val jsonContentType = org.http4s.headers.`Content-Type`(MediaType.application.json)

def jsonResp(status: Status, json: Json): Response[IO] = {
  Response[IO](status).withEntity(json).withHeaders(jsonContentType)
}

def jsonErrorResp(status: Status, msg: String): Response[IO] = {
  jsonResp(status, Json.obj("error" -> Json.fromString(msg)))
}

def checkAuth(req: Request[IO], stateRef: Ref[IO, AppState]): IO[Option[(User, String)]] = {
  stateRef.get.map { state =>
    val sessionId = req.cookies.find(_.name == "session_id").map(_.content)
    for {
      sid <- sessionId
      userId <- state.sessions.get(sid)
      user <- state.users.get(userId)
    } yield (user, sid)
  }
}

def requireAuth(req: Request[IO], stateRef: Ref[IO, AppState])(f: (User, String) => IO[Response[IO]]): IO[Response[IO]] = {
  checkAuth(req, stateRef).flatMap {
    case None => IO.pure(jsonErrorResp(Status.Unauthorized, "Authentication required"))
    case Some((user, sid)) => f(user, sid)
  }
}

object IntVar {
  def unapply(s: String): Option[Int] = scala.util.Try(s.toInt).toOption
}

def routes(stateRef: Ref[IO, AppState]): HttpRoutes[IO] = {
  HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" =>
      req.as[RegisterRequest].flatMap { body =>
        if (body.username == null || !body.username.matches("^[a-zA-Z0-9_]+$") || body.username.length < 3 || body.username.length > 50) {
          IO.pure(jsonErrorResp(Status.BadRequest, "Invalid username"))
        } else if (body.password == null || body.password.length < 8) {
          IO.pure(jsonErrorResp(Status.BadRequest, "Password too short"))
        } else {
          stateRef.modify { state =>
            if (state.usernameToId.contains(body.username)) {
              (state, jsonErrorResp(Status.Conflict, "Username already exists"))
            } else {
              val newUser = User(state.nextUserId, body.username, body.password)
              val newState = state.copy(
                users = state.users + (state.nextUserId -> newUser),
                usernameToId = state.usernameToId + (body.username -> state.nextUserId),
                nextUserId = state.nextUserId + 1
              )
              val resp = jsonResp(Status.Created, UserResponse(newUser.id, newUser.username).asJson)
              (newState, resp)
            }
          }
        }
      }.handleErrorWith(_ => IO.pure(jsonErrorResp(Status.BadRequest, "Invalid request body")))

    case req @ POST -> Root / "login" =>
      req.as[LoginRequest].flatMap { body =>
        stateRef.get.map { state =>
          state.usernameToId.get(body.username).flatMap { userId =>
            state.users.get(userId).filter(_.password == body.password)
          }
        }.flatMap {
          case None => IO.pure(jsonErrorResp(Status.Unauthorized, "Invalid credentials"))
          case Some(user) =>
            UUIDGen.randomString[IO].flatMap { sid =>
              stateRef.update { state =>
                state.copy(sessions = state.sessions + (sid -> user.id))
              }.as {
                val cookie = ResponseCookie("session_id", sid, path = Some("/"), httpOnly = true)
                jsonResp(Status.Ok, UserResponse(user.id, user.username).asJson).addCookie(cookie)
              }
            }
        }
      }.handleErrorWith(_ => IO.pure(jsonErrorResp(Status.BadRequest, "Invalid request body")))

    case req @ POST -> Root / "logout" =>
      requireAuth(req, stateRef) { case (_, sid) =>
        stateRef.update { state =>
          state.copy(sessions = state.sessions - sid)
        }.as(jsonResp(Status.Ok, Json.obj()))
      }

    case req @ GET -> Root / "me" =>
      requireAuth(req, stateRef) { case (user, _) =>
        IO.pure(jsonResp(Status.Ok, UserResponse(user.id, user.username).asJson))
      }

    case req @ PUT -> Root / "password" =>
      requireAuth(req, stateRef) { case (user, _) =>
        req.as[PasswordChangeRequest].flatMap { body =>
          if (body.old_password == null || user.password != body.old_password) {
            IO.pure(jsonErrorResp(Status.Unauthorized, "Invalid credentials"))
          } else if (body.new_password == null || body.new_password.length < 8) {
            IO.pure(jsonErrorResp(Status.BadRequest, "Password too short"))
          } else {
            stateRef.update { state =>
              state.copy(users = state.users + (user.id -> user.copy(password = body.new_password)))
            }.as(jsonResp(Status.Ok, Json.obj()))
          }
        }.handleErrorWith(_ => IO.pure(jsonErrorResp(Status.BadRequest, "Invalid request body")))
      }

    case req @ GET -> Root / "todos" =>
      requireAuth(req, stateRef) { case (user, _) =>
        stateRef.get.map { state =>
          val userTodos = state.todos.values.filter(_.userId == user.id).toList.sortBy(_.id)
          val responses = userTodos.map { t =>
            TodoResponse(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt)
          }
          jsonResp(Status.Ok, responses.asJson)
        }
      }

    case req @ POST -> Root / "todos" =>
      requireAuth(req, stateRef) { case (user, _) =>
        req.as[TodoRequest].flatMap { body =>
          val titleOpt = body.title.flatMap(_.trim match { case "" => None; case s => Some(s) })
          titleOpt match {
            case None =>
              IO.pure(jsonErrorResp(Status.BadRequest, "Title is required"))
            case Some(title) =>
              stateRef.modify { state =>
                val now = nowUtc()
                val newTodo = Todo(
                  id = state.nextTodoId,
                  userId = user.id,
                  title = title,
                  description = body.description.getOrElse(""),
                  completed = body.completed.getOrElse(false),
                  createdAt = now,
                  updatedAt = now
                )
                val newState = state.copy(
                  todos = state.todos + (state.nextTodoId -> newTodo),
                  nextTodoId = state.nextTodoId + 1
                )
                val resp = jsonResp(Status.Created, TodoResponse(newTodo.id, newTodo.title, newTodo.description, newTodo.completed, newTodo.createdAt, newTodo.updatedAt).asJson)
                (newState, resp)
              }
          }
        }.handleErrorWith(_ => IO.pure(jsonErrorResp(Status.BadRequest, "Invalid request body")))
      }

    case req @ GET -> Root / "todos" / IntVar(todoId) =>
      requireAuth(req, stateRef) { case (user, _) =>
        stateRef.get.map { state =>
          state.todos.get(todoId).filter(_.userId == user.id) match {
            case None => jsonErrorResp(Status.NotFound, "Todo not found")
            case Some(t) => jsonResp(Status.Ok, TodoResponse(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt).asJson)
          }
        }
      }

    case req @ PUT -> Root / "todos" / IntVar(todoId) =>
      requireAuth(req, stateRef) { case (user, _) =>
        req.as[TodoRequest].flatMap { body =>
          stateRef.modify { state =>
            state.todos.get(todoId) match {
              case None => (state, jsonErrorResp(Status.NotFound, "Todo not found"))
              case Some(t) if t.userId != user.id => (state, jsonErrorResp(Status.NotFound, "Todo not found"))
              case Some(t) =>
                val newTitle = body.title.getOrElse(t.title)
                if (newTitle == null || newTitle.trim.isEmpty) {
                  (state, jsonErrorResp(Status.BadRequest, "Title is required"))
                } else {
                  val now = nowUtc()
                  val updatedTodo = t.copy(
                    title = newTitle,
                    description = body.description.getOrElse(t.description),
                    completed = body.completed.getOrElse(t.completed),
                    updatedAt = now
                  )
                  val newState = state.copy(todos = state.todos + (todoId -> updatedTodo))
                  val resp = jsonResp(Status.Ok, TodoResponse(updatedTodo.id, updatedTodo.title, updatedTodo.description, updatedTodo.completed, updatedTodo.createdAt, updatedTodo.updatedAt).asJson)
                  (newState, resp)
                }
            }
          }
        }.handleErrorWith(_ => IO.pure(jsonErrorResp(Status.BadRequest, "Invalid request body")))
      }

    case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
      requireAuth(req, stateRef) { case (user, _) =>
        stateRef.modify { state =>
          state.todos.get(todoId) match {
            case None => (state, jsonErrorResp(Status.NotFound, "Todo not found"))
            case Some(t) if t.userId != user.id => (state, jsonErrorResp(Status.NotFound, "Todo not found"))
            case Some(_) =>
              val newState = state.copy(todos = state.todos - todoId)
              (newState, Response[IO](Status.NoContent))
          }
        }
      }
  }
}

@main def run(port: Int): Unit = {
  import cats.effect.unsafe.implicits.global
  
  val program = for {
    stateRef <- Ref[IO].of(AppState())
    httpApp = org.http4s.server.Router("/" -> routes(stateRef)).orNotFound
    _ <- IO.println(s"Server started on port $port")
    _ <- EmberServerBuilder.default[IO]
      .withHost(host"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build
      .use(_ => IO.never)
  } yield ()

  program.unsafeRunSync()
}