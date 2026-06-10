//> using scala 3.3.1
//> using dep org.http4s::http4s-ember-server:0.23.34
//> using dep org.http4s::http4s-dsl:0.23.34
//> using dep org.http4s::http4s-circe:0.23.34
//> using dep io.circe::circe-core:0.14.15

import org.http4s._
import org.http4s.dsl.io._
import org.http4s.implicits._
import org.http4s.circe._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.headers.`WWW-Authenticate`
import org.http4s.Challenge
import io.circe._
import io.circe.syntax._
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import scala.collection.concurrent.TrieMap
import cats.effect._
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

case class UserResponse(id: Int, username: String)
object UserResponse {
  given Encoder[UserResponse] = Encoder.instance { u =>
    Json.obj(
      "id" -> Json.fromInt(u.id),
      "username" -> Json.fromString(u.username)
    )
  }
}

case class TodoResponse(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)
object TodoResponse {
  given Encoder[TodoResponse] = Encoder.instance { t =>
    Json.obj(
      "id" -> Json.fromInt(t.id),
      "title" -> Json.fromString(t.title),
      "description" -> Json.fromString(t.description),
      "completed" -> Json.fromBoolean(t.completed),
      "created_at" -> Json.fromString(t.created_at),
      "updated_at" -> Json.fromString(t.updated_at)
    )
  }
}

case class ErrorResponse(error: String)
object ErrorResponse {
  given Encoder[ErrorResponse] = Encoder.instance { e =>
    Json.obj("error" -> Json.fromString(e.error))
  }
}

case class RegisterRequest(username: Option[String], password: Option[String])
object RegisterRequest {
  given Decoder[RegisterRequest] = Decoder.instance { c =>
    for {
      username <- c.downField("username").as[Option[String]]
      password <- c.downField("password").as[Option[String]]
    } yield RegisterRequest(username, password)
  }
  given EntityDecoder[IO, RegisterRequest] = jsonOf[IO, RegisterRequest]
}

case class LoginRequest(username: Option[String], password: Option[String])
object LoginRequest {
  given Decoder[LoginRequest] = Decoder.instance { c =>
    for {
      username <- c.downField("username").as[Option[String]]
      password <- c.downField("password").as[Option[String]]
    } yield LoginRequest(username, password)
  }
  given EntityDecoder[IO, LoginRequest] = jsonOf[IO, LoginRequest]
}

case class PasswordChangeRequest(oldPassword: Option[String], newPassword: Option[String])
object PasswordChangeRequest {
  given Decoder[PasswordChangeRequest] = Decoder.instance { c =>
    for {
      oldPassword <- c.downField("old_password").as[Option[String]]
      newPassword <- c.downField("new_password").as[Option[String]]
    } yield PasswordChangeRequest(oldPassword, newPassword)
  }
  given EntityDecoder[IO, PasswordChangeRequest] = jsonOf[IO, PasswordChangeRequest]
}

case class CreateTodoRequest(title: Option[String], description: Option[String])
object CreateTodoRequest {
  given Decoder[CreateTodoRequest] = Decoder.instance { c =>
    for {
      title <- c.downField("title").as[Option[String]]
      desc <- c.downField("description").as[Option[String]]
    } yield CreateTodoRequest(title, desc)
  }
  given EntityDecoder[IO, CreateTodoRequest] = jsonOf[IO, CreateTodoRequest]
}

case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])
object UpdateTodoRequest {
  given Decoder[UpdateTodoRequest] = Decoder.instance { c =>
    for {
      title <- c.downField("title").as[Option[String]]
      desc <- c.downField("description").as[Option[String]]
      completed <- c.downField("completed").as[Option[Boolean]]
    } yield UpdateTodoRequest(title, desc, completed)
  }
  given EntityDecoder[IO, UpdateTodoRequest] = jsonOf[IO, UpdateTodoRequest]
}

object State {
  val users = TrieMap[Int, User]()
  val sessions = TrieMap[String, Int]()
  val todos = TrieMap[Int, Todo]()
  
  @volatile var userIdCounter = 0
  @volatile var todoIdCounter = 0
  
  def nextUserId(): Int = {
    userIdCounter += 1
    userIdCounter
  }
  
  def nextTodoId(): Int = {
    todoIdCounter += 1
    todoIdCounter
  }
}

def now(): String = {
  val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
  ZonedDateTime.now(ZoneOffset.UTC).format(formatter)
}

object Main extends IOApp {
  def getSessionId(req: Request[IO]): Option[String] = {
    req.cookies.find(_.name == "session_id").map(_.content)
  }

  def requireAuth(req: Request[IO]): IO[Option[User]] = {
    getSessionId(req) match {
      case Some(token) =>
        IO(State.sessions.get(token).flatMap(userId => State.users.get(userId)))
      case None => IO(None)
    }
  }

  val authChallenge = `WWW-Authenticate`(Challenge("Bearer", "todo-app"))

  def unauthResp: IO[Response[IO]] = Unauthorized(authChallenge, ErrorResponse("Authentication required").asJson)
  def invalidCredsResp: IO[Response[IO]] = Unauthorized(authChallenge, ErrorResponse("Invalid credentials").asJson)

  val httpApp = HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" =>
      for {
        reqBody <- req.as[RegisterRequest]
        resp <- {
          val uName = reqBody.username.getOrElse("")
          val pWord = reqBody.password.getOrElse("")
          if (!uName.matches("^[a-zA-Z0-9_]+$") || uName.length < 3 || uName.length > 50) {
            BadRequest(ErrorResponse("Invalid username").asJson)
          } else if (pWord.length < 8) {
            BadRequest(ErrorResponse("Password too short").asJson)
          } else {
            if (State.users.values.exists(_.username == uName)) {
              Conflict(ErrorResponse("Username already exists").asJson)
            } else {
              val id = State.nextUserId()
              val newUser = User(id, uName, pWord)
              State.users.put(id, newUser)
              Created(UserResponse(id, newUser.username).asJson)
            }
          }
        }
      } yield resp

    case req @ POST -> Root / "login" =>
      for {
        reqBody <- req.as[LoginRequest]
        resp <- {
          val uName = reqBody.username.getOrElse("")
          val pWord = reqBody.password.getOrElse("")
          State.users.values.find(u => u.username == uName && u.password == pWord) match {
            case Some(user) =>
              val token = UUID.randomUUID().toString
              State.sessions.put(token, user.id)
              val cookie = ResponseCookie("session_id", token, httpOnly = true, path = Some("/"))
              Ok(UserResponse(user.id, user.username).asJson).map(_.addCookie(cookie))
            case None =>
              invalidCredsResp
          }
        }
      } yield resp

    case req @ POST -> Root / "logout" =>
      for {
        user <- requireAuth(req)
        resp <- user match {
          case Some(_) =>
            getSessionId(req) match {
              case Some(token) =>
                State.sessions.remove(token)
                val clearCookie = ResponseCookie("session_id", "", maxAge = Some(0L), path = Some("/"))
                Ok(Json.obj()).map(_.addCookie(clearCookie))
              case None =>
                Ok(Json.obj())
            }
          case None =>
            unauthResp
        }
      } yield resp

    case req @ GET -> Root / "me" =>
      for {
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) => Ok(UserResponse(u.id, u.username).asJson)
          case None => unauthResp
        }
      } yield resp

    case req @ PUT -> Root / "password" =>
      for {
        reqBody <- req.as[PasswordChangeRequest]
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            val oldP = reqBody.oldPassword.getOrElse("")
            val newP = reqBody.newPassword.getOrElse("")
            if (u.password != oldP) {
              invalidCredsResp
            } else if (newP.length < 8) {
              BadRequest(ErrorResponse("Password too short").asJson)
            } else {
              val updatedUser = u.copy(password = newP)
              State.users.put(u.id, updatedUser)
              Ok(Json.obj())
            }
          case None =>
            unauthResp
        }
      } yield resp

    case req @ GET -> Root / "todos" =>
      for {
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            val userTodos = State.todos.values
              .filter(_.userId == u.id)
              .toList
              .sortBy(_.id)
              .map(t => TodoResponse(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt))
            Ok(userTodos.asJson)
          case None => unauthResp
        }
      } yield resp

    case req @ POST -> Root / "todos" =>
      for {
        reqBody <- req.as[CreateTodoRequest]
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            val title = reqBody.title.getOrElse("")
            val desc = reqBody.description.getOrElse("")
            if (title.isEmpty) {
              BadRequest(ErrorResponse("Title is required").asJson)
            } else {
              val id = State.nextTodoId()
              val ts = now()
              val newTodo = Todo(
                id = id,
                userId = u.id,
                title = title,
                description = desc,
                completed = false,
                createdAt = ts,
                updatedAt = ts
              )
              State.todos.put(id, newTodo)
              Created(TodoResponse(newTodo.id, newTodo.title, newTodo.description, newTodo.completed, newTodo.createdAt, newTodo.updatedAt).asJson)
            }
          case None => unauthResp
        }
      } yield resp

    case req @ GET -> Root / "todos" / IntVar(todoId) =>
      for {
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            State.todos.get(todoId) match {
              case Some(t) if t.userId == u.id =>
                Ok(TodoResponse(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt).asJson)
              case _ =>
                NotFound(ErrorResponse("Todo not found").asJson)
            }
          case None => unauthResp
        }
      } yield resp

    case req @ PUT -> Root / "todos" / IntVar(todoId) =>
      for {
        reqBody <- req.as[UpdateTodoRequest]
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            State.todos.get(todoId) match {
              case Some(t) if t.userId == u.id =>
                if (reqBody.title.exists(_.isEmpty)) {
                  BadRequest(ErrorResponse("Title is required").asJson)
                } else {
                  val newTitle = reqBody.title.getOrElse(t.title)
                  val newDesc = reqBody.description.getOrElse(t.description)
                  val newCompleted = reqBody.completed.getOrElse(t.completed)
                  val updatedTodo = t.copy(
                    title = newTitle,
                    description = newDesc,
                    completed = newCompleted,
                    updatedAt = now()
                  )
                  State.todos.put(todoId, updatedTodo)
                  Ok(TodoResponse(updatedTodo.id, updatedTodo.title, updatedTodo.description, updatedTodo.completed, updatedTodo.createdAt, updatedTodo.updatedAt).asJson)
                }
              case _ =>
                NotFound(ErrorResponse("Todo not found").asJson)
            }
          case None => unauthResp
        }
      } yield resp

    case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
      for {
        user <- requireAuth(req)
        resp <- user match {
          case Some(u) =>
            State.todos.get(todoId) match {
              case Some(t) if t.userId == u.id =>
                State.todos.remove(todoId)
                NoContent()
              case _ =>
                NotFound(ErrorResponse("Todo not found").asJson)
            }
          case None => unauthResp
        }
      } yield resp
  }.orNotFound

  def run(args: List[String]): IO[ExitCode] = {
    val portInt = args match {
      case "--port" :: p :: _ => p.toInt
      case _ => 8080
    }
    val p = Port.fromInt(portInt).getOrElse(port"8080")
    
    EmberServerBuilder.default[IO]
      .withHost(ipv4"0.0.0.0")
      .withPort(p)
      .withHttpApp(httpApp)
      .build
      .use(_ => IO.never)
      .as(ExitCode.Success)
  }
}