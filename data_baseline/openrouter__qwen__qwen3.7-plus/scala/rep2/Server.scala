//> using scala "3.3.3"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"
//> using dep "org.typelevel::log4cats-slf4j:2.8.0"
//> using dep "org.slf4j:slf4j-simple:2.0.18"

import cats.effect._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe.CirceEntityCodec.circeEntityEncoder
import org.http4s.headers.`Content-Type`
import org.http4s.server.Router
import org.typelevel.log4cats.slf4j.Slf4jLogger
import org.typelevel.log4cats.Logger
import io.circe._
import io.circe.generic.auto._
import io.circe.parser._
import java.util.concurrent.atomic.AtomicInteger
import java.time.format.DateTimeFormatter
import java.time.ZoneOffset
import com.comcast.ip4s._

case class User(id: Int, username: String, password: String)
case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)

case class RegisterReq(username: String, password: String)
case class LoginReq(username: String, password: String)
case class PasswordReq(old_password: String, new_password: String)
case class TodoReq(title: Option[String], description: Option[String])
case class TodoUpdateReq(title: Option[String], description: Option[String], completed: Option[Boolean])

case class UserResp(id: Int, username: String)
case class ErrorResponse(error: String)

class State {
  private val users = scala.collection.mutable.Map[Int, User]()
  private val todos = scala.collection.mutable.Map[Int, Todo]()
  private val sessions = scala.collection.mutable.Map[String, Int]()
  private val userTodos = scala.collection.mutable.Map[Int, scala.collection.mutable.Set[Int]]()

  private val nextUserId = new AtomicInteger(1)
  private val nextTodoId = new AtomicInteger(1)

  def createUser(username: String, password: String): Either[String, User] = synchronized {
    if (users.values.exists(_.username == username)) {
      Left("Username already exists")
    } else {
      val id = nextUserId.getAndIncrement()
      val user = User(id, username, password)
      users(id) = user
      userTodos(id) = scala.collection.mutable.Set[Int]()
      Right(user)
    }
  }

  def getUserByUsername(username: String): Option[User] = synchronized {
    users.values.find(_.username == username)
  }

  def getUserById(id: Int): Option[User] = synchronized {
    users.get(id)
  }

  def updatePassword(userId: Int, newPassword: String): Unit = synchronized {
    users.get(userId).foreach { u =>
      users(userId) = u.copy(password = newPassword)
    }
  }

  def createSession(userId: Int): String = synchronized {
    val token = java.util.UUID.randomUUID().toString
    sessions(token) = userId
    token
  }

  def getSession(token: String): Option[Int] = synchronized {
    sessions.get(token)
  }

  def deleteSession(token: String): Unit = synchronized {
    sessions.remove(token)
  }

  def createTodo(userId: Int, title: String, description: String): Todo = synchronized {
    val id = nextTodoId.getAndIncrement()
    val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
    val nowStr = java.time.Instant.now().atZone(ZoneOffset.UTC).format(fmt)
    val todo = Todo(id, title, description, false, nowStr, nowStr)
    todos(id) = todo
    userTodos.getOrElseUpdate(userId, scala.collection.mutable.Set[Int]()) += id
    todo
  }

  def getTodosByUser(userId: Int): List[Todo] = synchronized {
    val ids = userTodos.getOrElse(userId, scala.collection.mutable.Set[Int]())
    ids.toList.sorted.flatMap(todos.get)
  }

  def getTodo(id: Int, userId: Int): Option[Todo] = synchronized {
    todos.get(id).filter(_ => userTodos.getOrElse(userId, scala.collection.mutable.Set[Int]()).contains(id))
  }

  def updateTodo(id: Int, userId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    todos.get(id).filter(_ => userTodos.getOrElse(userId, scala.collection.mutable.Set[Int]()).contains(id)).map { t =>
      val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
      val nowStr = java.time.Instant.now().atZone(ZoneOffset.UTC).format(fmt)
      val updated = t.copy(
        title = title.getOrElse(t.title),
        description = description.getOrElse(t.description),
        completed = completed.getOrElse(t.completed),
        updated_at = nowStr
      )
      todos(id) = updated
      updated
    }
  }

  def deleteTodo(id: Int, userId: Int): Boolean = synchronized {
    val userSet = userTodos.getOrElse(userId, scala.collection.mutable.Set[Int]())
    if (userSet.contains(id)) {
      userSet.remove(id)
      todos.remove(id)
      true
    } else false
  }
}

object Main extends IOApp {
  implicit val logger: Logger[IO] = Slf4jLogger.getLogger[IO]

  val jsonContentType = `Content-Type`(MediaType.application.json)

  def json[A: Encoder](a: A): IO[Response[IO]] = 
    Ok(a).map(_.withContentType(jsonContentType))

  def jsonCreated[A: Encoder](a: A): IO[Response[IO]] = 
    Created(a).map(_.withContentType(jsonContentType))

  def jsonError(status: Status, msg: String): IO[Response[IO]] = 
    IO(Response[IO](status).withEntity(ErrorResponse(msg)).withContentType(jsonContentType))

  def jsonOkEmpty(): IO[Response[IO]] = 
    Ok(Json.obj()).map(_.withContentType(jsonContentType))

  def requireAuth(req: Request[IO], state: State)(f: Int => IO[Response[IO]]): IO[Response[IO]] = {
    val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
    tokenOpt match {
      case Some(token) =>
        state.getSession(token) match {
          case Some(userId) => f(userId)
          case None => jsonError(Status.Unauthorized, "Authentication required")
        }
      case None => jsonError(Status.Unauthorized, "Authentication required")
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val port = args match {
      case "--port" :: p :: _ => p.toInt
      case _ => 8080
    }

    val state = new State()
    val routes = HttpRoutes.of[IO] {
      case req @ POST -> Root / "register" =>
        req.as[String].flatMap { body =>
          decode[RegisterReq](body) match {
            case Left(_) => jsonError(Status.BadRequest, "Invalid username")
            case Right(r) =>
              if (r.username == null || !r.username.matches("^[a-zA-Z0-9_]+$") || r.username.length < 3 || r.username.length > 50) {
                jsonError(Status.BadRequest, "Invalid username")
              } else if (r.password == null || r.password.length < 8) {
                jsonError(Status.BadRequest, "Password too short")
              } else {
                state.createUser(r.username, r.password) match {
                  case Left("Username already exists") => jsonError(Status.Conflict, "Username already exists")
                  case Right(user) => jsonCreated(UserResp(user.id, user.username))
                  case _ => jsonError(Status.BadRequest, "Invalid request")
                }
              }
          }
        }

      case req @ POST -> Root / "login" =>
        req.as[String].flatMap { body =>
          decode[LoginReq](body) match {
            case Left(_) => jsonError(Status.BadRequest, "Invalid request")
            case Right(r) =>
              if (r.username == null || r.password == null) {
                jsonError(Status.Unauthorized, "Invalid credentials")
              } else {
                state.getUserByUsername(r.username) match {
                  case Some(u) if u.password == r.password =>
                    val token = state.createSession(u.id)
                    val resp = json(UserResp(u.id, u.username))
                    resp.map(_.addCookie(ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)))
                  case _ =>
                    jsonError(Status.Unauthorized, "Invalid credentials")
                }
              }
          }
        }

      case req @ POST -> Root / "logout" =>
        requireAuth(req, state) { userId =>
          val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
          tokenOpt.foreach(state.deleteSession)
          jsonOkEmpty()
        }

      case req @ GET -> Root / "me" =>
        requireAuth(req, state) { userId =>
          state.getUserById(userId) match {
            case Some(u) => json(UserResp(u.id, u.username))
            case None => jsonError(Status.Unauthorized, "Authentication required")
          }
        }

      case req @ PUT -> Root / "password" =>
        requireAuth(req, state) { userId =>
          req.as[String].flatMap { body =>
            decode[PasswordReq](body) match {
              case Left(_) => jsonError(Status.BadRequest, "Invalid request")
              case Right(r) =>
                state.getUserById(userId) match {
                  case Some(u) if u.password == r.old_password =>
                    if (r.new_password == null || r.new_password.length < 8) {
                      jsonError(Status.BadRequest, "Password too short")
                    } else {
                      state.updatePassword(userId, r.new_password)
                      jsonOkEmpty()
                    }
                  case _ =>
                    jsonError(Status.Unauthorized, "Invalid credentials")
                }
            }
          }
        }

      case req @ GET -> Root / "todos" =>
        requireAuth(req, state) { userId =>
          val todos = state.getTodosByUser(userId)
          json(todos)
        }

      case req @ POST -> Root / "todos" =>
        requireAuth(req, state) { userId =>
          req.as[String].flatMap { body =>
            decode[TodoReq](body) match {
              case Left(_) => jsonError(Status.BadRequest, "Invalid request")
              case Right(r) =>
                r.title match {
                  case Some(t) if t == null || t.trim.isEmpty => jsonError(Status.BadRequest, "Title is required")
                  case None => jsonError(Status.BadRequest, "Title is required")
                  case Some(t) =>
                    val desc = r.description.getOrElse("")
                    val todo = state.createTodo(userId, t, desc)
                    jsonCreated(todo)
                }
            }
          }
        }

      case req @ GET -> Root / "todos" / id =>
        requireAuth(req, state) { userId =>
          id.toIntOption match {
            case Some(todoId) =>
              state.getTodo(todoId, userId) match {
                case Some(t) => json(t)
                case None => jsonError(Status.NotFound, "Todo not found")
              }
            case None => jsonError(Status.NotFound, "Todo not found")
          }
        }

      case req @ PUT -> Root / "todos" / id =>
        requireAuth(req, state) { userId =>
          id.toIntOption match {
            case Some(todoId) =>
              req.as[String].flatMap { body =>
                decode[TodoUpdateReq](body) match {
                  case Left(_) => jsonError(Status.BadRequest, "Invalid request")
                  case Right(r) =>
                    if (r.title.exists(t => t == null || t.trim.isEmpty)) {
                      jsonError(Status.BadRequest, "Title is required")
                    } else {
                      state.updateTodo(todoId, userId, r.title, r.description, r.completed) match {
                        case Some(t) => json(t)
                        case None => jsonError(Status.NotFound, "Todo not found")
                      }
                    }
                }
              }
            case None => jsonError(Status.NotFound, "Todo not found")
          }
        }

      case req @ DELETE -> Root / "todos" / id =>
        requireAuth(req, state) { userId =>
          id.toIntOption match {
            case Some(todoId) =>
              if (state.deleteTodo(todoId, userId)) {
                IO(Response[IO](status = Status.NoContent))
              } else {
                jsonError(Status.NotFound, "Todo not found")
              }
            case None => jsonError(Status.NotFound, "Todo not found")
          }
        }
    }

    val app = Router("/" -> routes).orNotFound

    EmberServerBuilder.default[IO]
      .withHost(ip"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(app)
      .build
      .use(_ => IO.never)
      .as(ExitCode.Success)
  }
}