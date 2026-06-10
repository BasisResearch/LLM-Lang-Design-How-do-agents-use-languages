//> using scala 3.3.1
//> using dep org.http4s::http4s-dsl:0.23.27
//> using dep org.http4s::http4s-ember-server:0.23.27
//> using dep org.http4s::http4s-circe:0.23.27
//> using dep io.circe::circe-core:0.14.6
//> using dep io.circe::circe-generic:0.14.6
//> using dep io.circe::circe-parser:0.14.6
//> using dep org.typelevel::cats-effect:3.5.4
//> using dep com.comcast::ip4s-core:3.4.0

import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe.CirceEntityCodec._
import cats.effect._
import cats.effect.unsafe.implicits.global
import cats.implicits._
import cats.data.Kleisli
import io.circe._
import io.circe.generic.auto._
import io.circe.parser._
import io.circe.syntax._

import java.util.UUID
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicInteger

object Config {
  val isoFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
  def now(): String = isoFormatter.format(Instant.now())
}

case class User(id: Int, username: String, password: String)
case class Todo(id: Int, userId: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String)

case class UserRes(id: Int, username: String)
case class TodoRes(id: Int, title: String, description: String, completed: Boolean, created_at: String, updated_at: String)

case class RegisterReq(username: String, password: String)
case class LoginReq(username: String, password: String)
case class PasswordReq(old_password: String, new_password: String)
case class TodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

class Store {
  private val userCounter = new AtomicInteger(1)
  private val todoCounter = new AtomicInteger(1)
  private var users = Map.empty[Int, User]
  private var usernames = Map.empty[String, Int]
  private var sessions = Map.empty[String, Int]
  private var todos = Map.empty[Int, Todo]

  def createUser(username: String, password: String): Either[String, UserRes] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]+$") || username.length < 3 || username.length > 50) {
      Left("Invalid username")
    } else if (password.length < 8) {
      Left("Password too short")
    } else if (usernames.contains(username)) {
      Left("Username already exists")
    } else {
      val id = userCounter.getAndIncrement()
      val user = User(id, username, password)
      users += (id -> user)
      usernames += (username -> id)
      Right(UserRes(id, username))
    }
  }

  def login(username: String, password: String): Either[String, (UserRes, String)] = synchronized {
    usernames.get(username) match {
      case Some(id) =>
        users.get(id) match {
          case Some(u) if u.password == password =>
            val token = UUID.randomUUID().toString
            sessions += (token -> u.id)
            Right((UserRes(u.id, u.username), token))
          case _ => Left("Invalid credentials")
        }
      case None => Left("Invalid credentials")
    }
  }

  def getUser(token: String): Option[User] = synchronized {
    sessions.get(token).flatMap(users.get)
  }

  def logout(token: String): Unit = synchronized {
    sessions -= token
  }

  def changePassword(token: String, oldPass: String, newPass: String): Either[String, Unit] = synchronized {
    sessions.get(token).flatMap(users.get) match {
      case Some(u) if u.password == oldPass =>
        if (newPass.length < 8) Left("Password too short")
        else {
          users += (u.id -> u.copy(password = newPass))
          Right(())
        }
      case Some(_) => Left("Invalid credentials")
      case None => Left("Invalid credentials")
    }
  }

  def createTodo(userId: Int, title: String, description: String): TodoRes = synchronized {
    val id = todoCounter.getAndIncrement()
    val nowStr = Config.now()
    val todo = Todo(id, userId, title, description, false, nowStr, nowStr)
    todos += (id -> todo)
    todoToRes(todo)
  }

  def getTodos(userId: Int): List[TodoRes] = synchronized {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id).map(todoToRes)
  }

  def getTodo(userId: Int, todoId: Int): Option[TodoRes] = synchronized {
    todos.get(todoId).filter(_.userId == userId).map(todoToRes)
  }

  def updateTodo(userId: Int, todoId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Either[String, TodoRes] = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        if (title.exists(_.trim.isEmpty)) Left("Title is required")
        else {
          val updated = todo.copy(
            title = title.getOrElse(todo.title),
            description = description.getOrElse(todo.description),
            completed = completed.getOrElse(todo.completed),
            updated_at = Config.now()
          )
          todos += (todoId -> updated)
          Right(todoToRes(updated))
        }
      case _ => Left("Todo not found")
    }
  }

  def deleteTodo(userId: Int, todoId: Int): Boolean = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        todos -= todoId
        true
      case _ => false
    }
  }

  private def todoToRes(todo: Todo): TodoRes = {
    TodoRes(todo.id, todo.title, todo.description, todo.completed, todo.created_at, todo.updated_at)
  }
}

@main def main(args: String*): Unit = {
  var port = 8080
  var i = 0
  while (i < args.length) {
    if (args(i) == "--port" && i + 1 < args.length) {
      port = args(i + 1).toInt
      i += 2
    } else {
      i += 1
    }
  }

  val store = new Store()

  val authMiddleware: Kleisli[IO, Request[IO], Either[String, User]] = Kleisli { req =>
    req.cookies.find(_.name == "session_id") match {
      case Some(cookie) =>
        store.getUser(cookie.content) match {
          case Some(user) => Right(user).pure[IO]
          case None => Left("Authentication required").pure[IO]
        }
      case None => Left("Authentication required").pure[IO]
    }
  }

  def jsonError(status: Status, msg: String): IO[Response[IO]] = 
    IO.pure(Response[IO](status = status).withEntity(Json.obj("error" -> msg.asJson)))

  def jsonResponse(status: Status, entity: Json): IO[Response[IO]] =
    IO.pure(Response[IO](status = status).withEntity(entity))

  val routes = HttpRoutes.of[IO] {
    case req @ POST -> Root / "register" =>
      req.as[RegisterReq].flatMap { body =>
        store.createUser(body.username, body.password) match {
          case Right(res) => jsonResponse(Status.Created, res.asJson)
          case Left("Invalid username") => jsonError(Status.BadRequest, "Invalid username")
          case Left("Password too short") => jsonError(Status.BadRequest, "Password too short")
          case Left("Username already exists") => jsonError(Status.Conflict, "Username already exists")
          case Left(e) => jsonError(Status.InternalServerError, e)
        }
      }.handleErrorWith(_ => jsonError(Status.BadRequest, "Invalid request"))

    case req @ POST -> Root / "login" =>
      req.as[LoginReq].flatMap { body =>
        store.login(body.username, body.password) match {
          case Right((user, token)) =>
            val cookie = ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)
            val resp = Response[IO](status = Status.Ok).withEntity(user.asJson).addCookie(cookie)
            IO.pure(resp)
          case Left(_) => jsonError(Status.Unauthorized, "Invalid credentials")
        }
      }.handleErrorWith(_ => jsonError(Status.BadRequest, "Invalid request"))

    case req @ POST -> Root / "logout" =>
      authMiddleware(req).flatMap {
        case Right(_) =>
          req.cookies.find(_.name == "session_id").foreach(c => store.logout(c.content))
          jsonResponse(Status.Ok, Json.obj())
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ GET -> Root / "me" =>
      authMiddleware(req).flatMap {
        case Right(user) => jsonResponse(Status.Ok, UserRes(user.id, user.username).asJson)
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ PUT -> Root / "password" =>
      authMiddleware(req).flatMap {
        case Right(_) =>
          req.as[PasswordReq].flatMap { body =>
            store.changePassword(req.cookies.find(_.name == "session_id").get.content, body.old_password, body.new_password) match {
              case Right(_) => jsonResponse(Status.Ok, Json.obj())
              case Left("Invalid credentials") => jsonError(Status.Unauthorized, "Invalid credentials")
              case Left("Password too short") => jsonError(Status.BadRequest, "Password too short")
              case Left(_) => jsonError(Status.InternalServerError, "Internal error")
            }
          }.handleErrorWith(_ => jsonError(Status.BadRequest, "Invalid request"))
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ GET -> Root / "todos" =>
      authMiddleware(req).flatMap {
        case Right(user) => jsonResponse(Status.Ok, store.getTodos(user.id).asJson)
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ POST -> Root / "todos" =>
      authMiddleware(req).flatMap {
        case Right(user) =>
          req.as[TodoReq].flatMap { body =>
            val t = body.title.getOrElse("")
            if (t.trim.isEmpty) {
              jsonError(Status.BadRequest, "Title is required")
            } else {
              jsonResponse(Status.Created, store.createTodo(user.id, t, body.description.getOrElse("")).asJson)
            }
          }.handleErrorWith(_ => jsonError(Status.BadRequest, "Invalid request"))
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ GET -> Root / "todos" / IntVar(id) =>
      authMiddleware(req).flatMap {
        case Right(user) =>
          store.getTodo(user.id, id) match {
            case Some(todo) => jsonResponse(Status.Ok, todo.asJson)
            case None => jsonError(Status.NotFound, "Todo not found")
          }
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ PUT -> Root / "todos" / IntVar(id) =>
      authMiddleware(req).flatMap {
        case Right(user) =>
          req.as[TodoReq].flatMap { body =>
            store.updateTodo(user.id, id, body.title, body.description, body.completed) match {
              case Right(res) => jsonResponse(Status.Ok, res.asJson)
              case Left("Title is required") => jsonError(Status.BadRequest, "Title is required")
              case Left("Todo not found") => jsonError(Status.NotFound, "Todo not found")
              case Left(_) => jsonError(Status.InternalServerError, "Internal error")
            }
          }.handleErrorWith(_ => jsonError(Status.BadRequest, "Invalid request"))
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }

    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      authMiddleware(req).flatMap {
        case Right(user) =>
          if (store.deleteTodo(user.id, id)) {
            IO.pure(Response[IO](status = Status.NoContent))
          } else {
            jsonError(Status.NotFound, "Todo not found")
          }
        case Left(_) => jsonError(Status.Unauthorized, "Authentication required")
      }
  }

  val app = routes.orNotFound

  val server = EmberServerBuilder.default[IO]
    .withHost(com.comcast.ip4s.Host.fromString("0.0.0.0").get)
    .withPort(com.comcast.ip4s.Port.fromInt(port).get)
    .withHttpApp(app)
    .build
    .use { _ =>
      IO.println(s"Server started on http://0.0.0.0:$port") *> IO.never
    }

  server.unsafeRunSync()
}