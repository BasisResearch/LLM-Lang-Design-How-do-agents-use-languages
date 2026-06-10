//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.24"
//> using dep "org.http4s::http4s-circe:0.23.24"
//> using dep "org.http4s::http4s-dsl:0.23.24"
//> using dep "io.circe::circe-core:0.14.6"
//> using dep "io.circe::circe-generic:0.14.6"
//> using dep "io.circe::circe-parser:0.14.6"

import cats.effect._
import cats.effect.unsafe.implicits.global
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.util.concurrent.atomic.AtomicInteger
import scala.collection.concurrent.TrieMap
import com.comcast.ip4s._

case class User(id: Int, username: String, password: String)
case class Todo(
  id: Int,
  userId: Int,
  title: String,
  description: String,
  completed: Boolean,
  createdAt: String,
  updatedAt: String
)

case class TodoResponse(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)
object TodoResponse {
  given Codec[TodoResponse] = deriveCodec
  def fromTodo(t: Todo): TodoResponse = TodoResponse(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt)
}

case class UserResponse(id: Int, username: String)
object UserResponse {
  given Codec[UserResponse] = deriveCodec
  def fromUser(u: User): UserResponse = UserResponse(u.id, u.username)
}

case class RegisterRequest(username: Option[String], password: Option[String])
object RegisterRequest {
  given Codec[RegisterRequest] = deriveCodec
}

case class LoginRequest(username: Option[String], password: Option[String])
object LoginRequest {
  given Codec[LoginRequest] = deriveCodec
}

case class PasswordRequest(old_password: Option[String], new_password: Option[String])
object PasswordRequest {
  given Codec[PasswordRequest] = deriveCodec
}

case class CreateTodoRequest(title: Option[String], description: Option[String])
object CreateTodoRequest {
  given Codec[CreateTodoRequest] = deriveCodec
}

case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
object UpdateTodoRequest {
  given Codec[UpdateTodoRequest] = deriveCodec
}

object State {
  val users = TrieMap[Int, User]()
  val userIdCounter = AtomicInteger(1)
  val todos = TrieMap[Int, Todo]()
  val todoIdCounter = AtomicInteger(1)
  val sessions = TrieMap[String, Int]()
}

def getCurrentTimestamp(): String = {
  java.time.ZonedDateTime.now(java.time.ZoneOffset.UTC).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
}

def jsonError(msg: String): Json = Json.obj("error" -> Json.fromString(msg))

def unauth(msg: String): IO[Response[IO]] = IO(Response[IO](Status.Unauthorized).withEntity(jsonError(msg)))

def getSessionId(request: Request[IO]): Option[String] = {
  request.cookies.find(_.name == "session_id").map(_.content)
}

def requireAuth(request: Request[IO]): IO[Option[Int]] = {
  val sessionIdOpt = getSessionId(request)
  sessionIdOpt match {
    case Some(token) => IO(State.sessions.get(token))
    case None => IO.pure(None)
  }
}

def authOrFail(request: Request[IO])(f: Int => IO[Response[IO]]): IO[Response[IO]] = {
  requireAuth(request).flatMap {
    case Some(userId) => f(userId)
    case None => unauth("Authentication required")
  }
}

@main def main(args: String*): Unit = {
  val portInt = args.headOption.flatMap(a => scala.util.Try(a.toInt).toOption).getOrElse(8080)
  val port = Port.fromInt(portInt).getOrElse(throw new IllegalArgumentException("Invalid port"))

  val register = HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" =>
      req.as[RegisterRequest].flatMap { body =>
        if (body.username.forall(u => !u.matches("^[a-zA-Z0-9_]{3,50}$"))) {
          BadRequest(jsonError("Invalid username"))
        } else if (body.password.forall(_.length < 8)) {
          BadRequest(jsonError("Password too short"))
        } else {
          val userOpt = State.users.values.find(_.username == body.username.get)
          if (userOpt.isDefined) {
            Conflict(jsonError("Username already exists"))
          } else {
            val newId = State.userIdCounter.getAndIncrement()
            val newUser = User(newId, body.username.get, body.password.get)
            State.users.put(newId, newUser)
            Created(UserResponse.fromUser(newUser).asJson)
          }
        }
      }.handleErrorWith(_ => BadRequest(jsonError("Invalid JSON")))
  }

  val login = HttpRoutes.of[IO] {
    case req @ POST -> Root / "login" =>
      req.as[LoginRequest].flatMap { body =>
        val userOpt = State.users.values.find(u => u.username == body.username.getOrElse("") && u.password == body.password.getOrElse(""))
        userOpt match {
          case Some(user) =>
            val token = java.util.UUID.randomUUID().toString
            State.sessions.put(token, user.id)
            val cookie = ResponseCookie("session_id", token, httpOnly = true, path = Some("/"))
            Ok(UserResponse.fromUser(user).asJson).map(_.addCookie(cookie))
          case None =>
            unauth("Invalid credentials")
        }
      }.handleErrorWith(_ => BadRequest(jsonError("Invalid JSON")))
  }

  val logout = HttpRoutes.of[IO] {
    case req @ POST -> Root / "logout" =>
      authOrFail(req) { userId =>
        val tokenOpt = getSessionId(req)
        tokenOpt.foreach(State.sessions.remove)
        Ok(Json.obj())
      }
  }

  val getMe = HttpRoutes.of[IO] {
    case req @ GET -> Root / "me" =>
      authOrFail(req) { userId =>
        State.users.get(userId) match {
          case Some(user) => Ok(UserResponse.fromUser(user).asJson)
          case None => unauth("Authentication required")
        }
      }
  }

  val updatePassword = HttpRoutes.of[IO] {
    case req @ PUT -> Root / "password" =>
      authOrFail(req) { userId =>
        req.as[PasswordRequest].flatMap { body =>
          State.users.get(userId) match {
            case Some(user) if user.password == body.old_password.getOrElse("") =>
              if (body.new_password.forall(_.length < 8)) {
                BadRequest(jsonError("Password too short"))
              } else {
                State.users.update(userId, user.copy(password = body.new_password.get))
                Ok(Json.obj())
              }
            case _ =>
              unauth("Invalid credentials")
          }
        }.handleErrorWith(_ => BadRequest(jsonError("Invalid JSON")))
      }
  }

  val getTodos = HttpRoutes.of[IO] {
    case req @ GET -> Root / "todos" =>
      authOrFail(req) { userId =>
        val userTodos = State.todos.values.filter(_.userId == userId).toList.sortBy(_.id)
        Ok(userTodos.map(TodoResponse.fromTodo).asJson)
      }
  }

  val createTodo = HttpRoutes.of[IO] {
    case req @ POST -> Root / "todos" =>
      authOrFail(req) { userId =>
        req.as[CreateTodoRequest].flatMap { body =>
          if (body.title.forall(_.trim.isEmpty)) {
            BadRequest(jsonError("Title is required"))
          } else {
            val newId = State.todoIdCounter.getAndIncrement()
            val now = getCurrentTimestamp()
            val newTodo = Todo(
              id = newId,
              userId = userId,
              title = body.title.get,
              description = body.description.getOrElse(""),
              completed = false,
              createdAt = now,
              updatedAt = now
            )
            State.todos.put(newId, newTodo)
            Created(TodoResponse.fromTodo(newTodo).asJson)
          }
        }.handleErrorWith(_ => BadRequest(jsonError("Invalid JSON")))
      }
  }

  val getTodo = HttpRoutes.of[IO] {
    case req @ GET -> Root / "todos" / IntVar(id) =>
      authOrFail(req) { userId =>
        State.todos.get(id) match {
          case Some(todo) if todo.userId == userId =>
            Ok(TodoResponse.fromTodo(todo).asJson)
          case _ =>
            NotFound(jsonError("Todo not found"))
        }
      }
  }

  val updateTodo = HttpRoutes.of[IO] {
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      authOrFail(req) { userId =>
        req.as[UpdateTodoRequest].flatMap { body =>
          State.todos.get(id) match {
            case Some(todo) if todo.userId == userId =>
              if (body.title.exists(_.trim.isEmpty)) {
                BadRequest(jsonError("Title is required"))
              } else {
                val now = getCurrentTimestamp()
                val updatedTodo = todo.copy(
                  title = body.title.getOrElse(todo.title),
                  description = body.description.getOrElse(todo.description),
                  completed = body.completed.getOrElse(todo.completed),
                  updatedAt = now
                )
                State.todos.update(id, updatedTodo)
                Ok(TodoResponse.fromTodo(updatedTodo).asJson)
              }
            case _ =>
              NotFound(jsonError("Todo not found"))
          }
        }.handleErrorWith(_ => BadRequest(jsonError("Invalid JSON")))
      }
  }

  val deleteTodo = HttpRoutes.of[IO] {
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      authOrFail(req) { userId =>
        State.todos.get(id) match {
          case Some(todo) if todo.userId == userId =>
            State.todos.remove(id)
            NoContent()
          case _ =>
            NotFound(jsonError("Todo not found"))
        }
      }
  }

  val routes = register <+> login <+> logout <+> getMe <+> updatePassword <+> getTodos <+> createTodo <+> getTodo <+> updateTodo <+> deleteTodo

  val httpApp = routes.orNotFound

  EmberServerBuilder.default[IO]
    .withHost(host"0.0.0.0")
    .withPort(port)
    .withHttpApp(httpApp)
    .build
    .use(_ => IO.never)
    .unsafeRunSync()
}