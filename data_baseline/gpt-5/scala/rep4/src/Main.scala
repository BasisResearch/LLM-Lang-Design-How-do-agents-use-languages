//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.26"
//> using dep "org.http4s::http4s-dsl:0.23.26"
//> using dep "org.http4s::http4s-circe:0.23.26"
//> using dep "io.circe::circe-generic:0.14.6"
//> using dep "io.circe::circe-parser:0.14.6"

import cats.effect._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe._
import io.circe._
import io.circe.syntax._
import io.circe.generic.semiauto._
import org.http4s.ember.server._
import com.comcast.ip4s._

import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.time.Instant
import java.time.temporal.ChronoUnit
import scala.collection.concurrent.TrieMap

object Main extends IOApp {

  case class User(id: Int, username: String)
  case class UserRecord(id: Int, username: String, var password: String)

  case class Todo(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  case class TodoRecord(ownerId: Int, todo: Todo)

  // Requests
  case class RegisterRequest(username: String, password: String)
  case class LoginRequest(username: String, password: String)
  case class PasswordChange(old_password: String, new_password: String)
  case class CreateTodo(title: String, description: Option[String])
  case class UpdateTodo(title: Option[String], description: Option[String], completed: Option[Boolean])

  implicit val userEncoder: Encoder[User] = deriveEncoder
  implicit val todoEncoder: Encoder[Todo] = deriveEncoder
  implicit val regDecoder: Decoder[RegisterRequest] = deriveDecoder
  implicit val loginDecoder: Decoder[LoginRequest] = deriveDecoder
  implicit val pwDecoder: Decoder[PasswordChange] = deriveDecoder
  implicit val createTodoDecoder: Decoder[CreateTodo] = deriveDecoder
  implicit val updateTodoDecoder: Decoder[UpdateTodo] = deriveDecoder

  implicit val userEntityEncoder: EntityEncoder[IO, Json] = jsonEncoderOf[IO, Json]
  implicit def entityDecoderJson[A: Decoder]: EntityDecoder[IO, A] = jsonOf[IO, A]

  // In-memory stores
  private val usersByUsername = TrieMap.empty[String, UserRecord]
  private val usersById = TrieMap.empty[Int, UserRecord]
  private val sessions = TrieMap.empty[String, Int] // token -> userId
  private val todos = TrieMap.empty[Int, TodoRecord] // id -> (ownerId, todo)

  private val userIdCounter = new AtomicInteger(0)
  private val todoIdCounter = new AtomicInteger(0)

  private def nowIso(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString

  private val usernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private def invalidUsername(u: String): Boolean = usernameRegex.findFirstIn(u).isEmpty

  private def jsonError(status: Status, msg: String): IO[Response[IO]] = {
    val json = Json.obj("error" -> Json.fromString(msg))
    IO.pure(Response[IO](status).withEntity(json).putHeaders(headers.`Content-Type`(MediaType.application.json)))
  }

  private def jsonOk(status: Status, json: Json, cookies: List[ResponseCookie] = Nil): IO[Response[IO]] = {
    val base = Response[IO](status).withEntity(json).putHeaders(headers.`Content-Type`(MediaType.application.json))
    IO.pure(cookies.foldLeft(base)((resp, c) => resp.addCookie(c)))
  }

  private def getSessionToken(req: Request[IO]): Option[String] = req.cookies.find(_.name == "session_id").map(_.content)

  private def withAuth(req: Request[IO])(f: (UserRecord, String) => IO[Response[IO]]): IO[Response[IO]] = {
    getSessionToken(req) match {
      case None => jsonError(Status.Unauthorized, "Authentication required")
      case Some(token) =>
        sessions.get(token) match {
          case None => jsonError(Status.Unauthorized, "Authentication required")
          case Some(userId) =>
            usersById.get(userId) match {
              case None => jsonError(Status.Unauthorized, "Authentication required")
              case Some(user) => f(user, token)
            }
        }
    }
  }

  private def userView(u: UserRecord): User = User(u.id, u.username)

  private object IntVar { def unapply(str: String): Option[Int] = str.toIntOption }

  val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // Register
    case req @ POST -> Root / "register" =>
      req.as[RegisterRequest].attempt.flatMap {
        case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
        case Right(body) =>
          val username = body.username
          val password = body.password
          if (username == null || invalidUsername(username)) jsonError(Status.BadRequest, "Invalid username")
          else if (password == null || password.length < 8) jsonError(Status.BadRequest, "Password too short")
          else {
            // ensure uniqueness
            val created: Option[UserRecord] = synchronized {
              if (usersByUsername.contains(username)) None
              else {
                val id = userIdCounter.incrementAndGet()
                val rec = UserRecord(id, username, password)
                usersByUsername.put(username, rec)
                usersById.put(id, rec)
                Some(rec)
              }
            }
            created match {
              case None => jsonError(Status.Conflict, "Username already exists")
              case Some(rec) => jsonOk(Status.Created, userView(rec).asJson)
            }
          }
      }

    // Login
    case req @ POST -> Root / "login" =>
      req.as[LoginRequest].attempt.flatMap {
        case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
        case Right(body) =>
          usersByUsername.get(body.username) match {
            case Some(rec) if rec.password == body.password =>
              val token = UUID.randomUUID().toString.replaceAll("-", "")
              sessions.put(token, rec.id)
              val cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
              jsonOk(Status.Ok, userView(rec).asJson, cookies = List(cookie))
            case _ => jsonError(Status.Unauthorized, "Invalid credentials")
          }
      }

    // Logout
    case req @ POST -> Root / "logout" =>
      withAuth(req) { (_, token) =>
        sessions.remove(token)
        jsonOk(Status.Ok, Json.obj())
      }

    // Me
    case req @ GET -> Root / "me" =>
      withAuth(req) { (user, _) => jsonOk(Status.Ok, userView(user).asJson) }

    // Change password
    case req @ PUT -> Root / "password" =>
      withAuth(req) { (user, _) =>
        req.as[PasswordChange].attempt.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(body) =>
            if (user.password != body.old_password) jsonError(Status.Unauthorized, "Invalid credentials")
            else if (body.new_password == null || body.new_password.length < 8) jsonError(Status.BadRequest, "Password too short")
            else {
              user.password = body.new_password
              jsonOk(Status.Ok, Json.obj())
            }
        }
      }

    // List todos
    case req @ GET -> Root / "todos" =>
      withAuth(req) { (user, _) =>
        val items = todos.values.collect { case TodoRecord(ownerId, t) if ownerId == user.id => t }.toSeq.sortBy(_.id)
        jsonOk(Status.Ok, items.asJson)
      }

    // Create todo
    case req @ POST -> Root / "todos" =>
      withAuth(req) { (user, _) =>
        req.as[CreateTodo].attempt.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(body) =>
            val title = Option(body.title).getOrElse("")
            if (title.trim.isEmpty) jsonError(Status.BadRequest, "Title is required")
            else {
              val desc = body.description.getOrElse("")
              val id = todoIdCounter.incrementAndGet()
              val now = nowIso()
              val todo = Todo(id, title, desc, completed = false, created_at = now, updated_at = now)
              todos.put(id, TodoRecord(user.id, todo))
              jsonOk(Status.Created, todo.asJson)
            }
        }
      }

    // Get todo by id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      withAuth(req) { (user, _) =>
        todos.get(id) match {
          case Some(TodoRecord(ownerId, t)) if ownerId == user.id => jsonOk(Status.Ok, t.asJson)
          case _ => jsonError(Status.NotFound, "Todo not found")
        }
      }

    // Update todo partial
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      withAuth(req) { (user, _) =>
        todos.get(id) match {
          case Some(TodoRecord(ownerId, t)) if ownerId == user.id =>
            req.as[UpdateTodo].attempt.flatMap {
              case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
              case Right(body) =>
                body.title match {
                  case Some(v) if v.trim.isEmpty => jsonError(Status.BadRequest, "Title is required")
                  case _ =>
                    val newTitle = body.title.getOrElse(t.title)
                    val newDesc = body.description.getOrElse(t.description)
                    val newComp = body.completed.getOrElse(t.completed)
                    val updated = t.copy(title = newTitle, description = newDesc, completed = newComp, updated_at = nowIso())
                    todos.update(id, TodoRecord(ownerId, updated))
                    jsonOk(Status.Ok, updated.asJson)
                }
            }
          case _ => jsonError(Status.NotFound, "Todo not found")
        }
      }

    // Delete todo
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      withAuth(req) { (user, _) =>
        todos.get(id) match {
          case Some(TodoRecord(ownerId, _)) if ownerId == user.id =>
            todos.remove(id)
            IO.pure(Response[IO](Status.NoContent))
          case _ => jsonError(Status.NotFound, "Todo not found")
        }
      }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val port = parsePort(args).getOrElse(8080)
    val httpApp = routes.orNotFound

    EmberServerBuilder.default[IO]
      .withHost(host"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build
      .use(_ => IO.never)
      .as(ExitCode.Success)
  }

  private def parsePort(args: List[String]): Option[Int] = {
    def parseRec(lst: List[String]): Option[Int] = lst match {
      case Nil => None
      case ("-p" | "--port") :: v :: tail => v.toIntOption.orElse(parseRec(tail))
      case _ :: tail => parseRec(tail)
    }
    parseRec(args)
  }
}
