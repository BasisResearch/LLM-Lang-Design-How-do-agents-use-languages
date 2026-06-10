//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.implicits._
import org.http4s.circe._
import org.http4s.circe.CirceEntityCodec._
import org.http4s.ember.server._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.time._
import java.time.temporal.ChronoUnit
import scala.jdk.CollectionConverters._
import com.comcast.ip4s._

object Main extends IOApp {

  case class User(id: Int, username: String)
  case class RegisterRequest(username: String, password: String)
  case class LoginRequest(username: String, password: String)
  case class PasswordChangeRequest(old_password: String, new_password: String)
  case class CreateTodoRequest(title: String, description: Option[String])
  case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])

  case class Todo(
      id: Int,
      ownerId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: String,
      updatedAt: String
  )

  implicit val regReqDecoder: Decoder[RegisterRequest] = deriveDecoder
  implicit val loginReqDecoder: Decoder[LoginRequest] = deriveDecoder
  implicit val pwdChangeDecoder: Decoder[PasswordChangeRequest] = deriveDecoder
  implicit val createTodoDecoder: Decoder[CreateTodoRequest] = deriveDecoder
  implicit val updateTodoDecoder: Decoder[UpdateTodoRequest] = deriveDecoder

  implicit val userEncoder: Encoder[User] = deriveEncoder
  implicit val todoEncoder: Encoder[Todo] = new Encoder[Todo]{
    def apply(t: Todo): Json = Json.obj(
      (
        "id",
        Json.fromInt(t.id)
      ),
      (
        "title",
        Json.fromString(t.title)
      ),
      (
        "description",
        Json.fromString(t.description)
      ),
      (
        "completed",
        Json.fromBoolean(t.completed)
      ),
      (
        "created_at",
        Json.fromString(t.createdAt)
      ),
      (
        "updated_at",
        Json.fromString(t.updatedAt)
      )
    )
  }

  // Storage
  private val usersById = new ConcurrentHashMap[Integer, (String /*username*/, String /*password*/)]()
  private val usersByUsername = new ConcurrentHashMap[String, Integer]()
  private val userIdSeq = new AtomicInteger(0)

  private val sessions = new ConcurrentHashMap[String, Integer]() // token -> userId

  private val todosById = new ConcurrentHashMap[Integer, Todo]()
  private val todoIdSeq = new AtomicInteger(0)

  private def nowInstant(): Instant = Instant.now().truncatedTo(ChronoUnit.SECONDS)
  private def nowIso(): String = nowInstant().toString

  private def errorJson(msg: String): Json = Json.obj("error" -> Json.fromString(msg))

  private def jsonResponse(status: Status, json: Json): IO[Response[IO]] =
    Response[IO](status = status)
      .withEntity(json)
      .withContentType(headers.`Content-Type`(MediaType.application.json))
      .pure[IO]

  private object Auth {
    def extractUserId(req: Request[IO]): Option[(Int, String)] = {
      val maybeCookie = req.cookies.find(_.name == "session_id").map(_.content)
      maybeCookie.flatMap { token =>
        Option(sessions.get(token)).map(i => (i.intValue, token))
      }
    }

    def requireAuth(req: Request[IO])(onAuth: (Int, String) => IO[Response[IO]]): IO[Response[IO]] = {
      extractUserId(req) match {
        case Some((uid, token)) => onAuth(uid, token)
        case None => jsonResponse(Status.Unauthorized, errorJson("Authentication required"))
      }
    }
  }

  private def validateUsername(u: String): Boolean = {
    val lenOk = u.length >= 3 && u.length <= 50
    val regexOk = u.matches("^[A-Za-z0-9_]+$")
    lenOk && regexOk
  }

  private def routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // Register
    case req @ POST -> Root / "register" =>
      req.attemptAs[RegisterRequest].value.flatMap {
        case Left(_) => jsonResponse(Status.BadRequest, errorJson("Invalid request"))
        case Right(body) =>
          val username = body.username
          val password = body.password
          if (!validateUsername(username)) {
            jsonResponse(Status.BadRequest, errorJson("Invalid username"))
          } else if (password == null || password.length < 8) {
            jsonResponse(Status.BadRequest, errorJson("Password too short"))
          } else {
            val placeholder = Integer.valueOf(-1)
            val existing = usersByUsername.putIfAbsent(username, placeholder)
            if (existing != null) {
              // username taken
              usersByUsername.replace(username, existing)
              jsonResponse(Status.Conflict, errorJson("Username already exists"))
            } else {
              val id = userIdSeq.incrementAndGet()
              val iid = Integer.valueOf(id)
              usersById.put(iid, (username, password))
              usersByUsername.put(username, iid)
              val user = User(id, username)
              Response[IO](status = Status.Created)
                .withEntity(user)
                .withContentType(headers.`Content-Type`(MediaType.application.json))
                .pure[IO]
            }
          }
      }

    // Login
    case req @ POST -> Root / "login" =>
      req.attemptAs[LoginRequest].value.flatMap {
        case Left(_) => jsonResponse(Status.BadRequest, errorJson("Invalid request"))
        case Right(body) =>
          Option(usersByUsername.get(body.username)) match {
            case None => jsonResponse(Status.Unauthorized, errorJson("Invalid credentials"))
            case Some(iid) =>
              val uid = iid.intValue
              Option(usersById.get(Integer.valueOf(uid))) match {
                case None => jsonResponse(Status.Unauthorized, errorJson("Invalid credentials"))
                case Some(stored) if stored._2 != body.password => jsonResponse(Status.Unauthorized, errorJson("Invalid credentials"))
                case Some(stored) =>
                  val token = java.util.UUID.randomUUID().toString.replaceAll("-", "")
                  sessions.put(token, Integer.valueOf(uid))
                  val user = User(uid, stored._1)
                  val resp = Response[IO](status = Status.Ok)
                    .withEntity(user)
                    .withContentType(headers.`Content-Type`(MediaType.application.json))
                  val cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
                  IO.pure(resp.addCookie(cookie))
              }
          }
      }

    // Logout
    case req @ POST -> Root / "logout" =>
      Auth.requireAuth(req) { case (_, token) =>
        sessions.remove(token)
        Response[IO](status = Status.Ok)
          .withEntity(Json.obj())
          .withContentType(headers.`Content-Type`(MediaType.application.json))
          .pure[IO]
      }

    // Me
    case req @ GET -> Root / "me" =>
      Auth.requireAuth(req) { case (uid, _) =>
        Option(usersById.get(Integer.valueOf(uid))) match {
          case None => jsonResponse(Status.Unauthorized, errorJson("Authentication required"))
          case Some(userRec) =>
            val user = User(uid, userRec._1)
            Response[IO](status = Status.Ok)
              .withEntity(user)
              .withContentType(headers.`Content-Type`(MediaType.application.json))
              .pure[IO]
        }
      }

    // Password change
    case req @ PUT -> Root / "password" =>
      Auth.requireAuth(req) { case (uid, _) =>
        req.attemptAs[PasswordChangeRequest].value.flatMap {
          case Left(_) => jsonResponse(Status.BadRequest, errorJson("Invalid request"))
          case Right(body) =>
            Option(usersById.get(Integer.valueOf(uid))) match {
              case None => jsonResponse(Status.Unauthorized, errorJson("Authentication required"))
              case Some(userRec) if userRec._2 != body.old_password => jsonResponse(Status.Unauthorized, errorJson("Invalid credentials"))
              case Some(userRec) =>
                if (body.new_password == null || body.new_password.length < 8) jsonResponse(Status.BadRequest, errorJson("Password too short"))
                else {
                  usersById.put(Integer.valueOf(uid), (userRec._1, body.new_password))
                  Response[IO](status = Status.Ok)
                    .withEntity(Json.obj())
                    .withContentType(headers.`Content-Type`(MediaType.application.json))
                    .pure[IO]
                }
            }
        }
      }

    // List todos
    case req @ GET -> Root / "todos" =>
      Auth.requireAuth(req) { case (uid, _) =>
        val list = todosById.asScala.values.filter(_.ownerId == uid).toList.sortBy(_.id)
        Response[IO](status = Status.Ok)
          .withEntity(list)
          .withContentType(headers.`Content-Type`(MediaType.application.json))
          .pure[IO]
      }

    // Create todo
    case req @ POST -> Root / "todos" =>
      Auth.requireAuth(req) { case (uid, _) =>
        req.attemptAs[CreateTodoRequest].value.flatMap {
          case Left(_) => jsonResponse(Status.BadRequest, errorJson("Invalid request"))
          case Right(body) =>
            val title = Option(body.title).getOrElse("")
            if (title.trim.isEmpty) jsonResponse(Status.BadRequest, errorJson("Title is required"))
            else {
              val id = todoIdSeq.incrementAndGet()
              val created = nowIso()
              val todo = Todo(
                id = id,
                ownerId = uid,
                title = title,
                description = body.description.getOrElse(""),
                completed = false,
                createdAt = created,
                updatedAt = created
              )
              todosById.put(Integer.valueOf(id), todo)
              Response[IO](status = Status.Created)
                .withEntity(todo)
                .withContentType(headers.`Content-Type`(MediaType.application.json))
                .pure[IO]
            }
        }
      }

    // Get todo by id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) { case (uid, _) =>
        Option(todosById.get(Integer.valueOf(id))) match {
          case None => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(todo) if todo.ownerId != uid => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(todo) =>
            Response[IO](status = Status.Ok)
              .withEntity(todo)
              .withContentType(headers.`Content-Type`(MediaType.application.json))
              .pure[IO]
        }
      }

    // Update todo by id (partial)
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) { case (uid, _) =>
        Option(todosById.get(Integer.valueOf(id))) match {
          case None => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(todo) if todo.ownerId != uid => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(todo) =>
            req.attemptAs[UpdateTodoRequest].value.flatMap {
              case Left(_) => jsonResponse(Status.BadRequest, errorJson("Invalid request"))
              case Right(body) =>
                body.title match {
                  case Some(t) if t.trim.isEmpty => jsonResponse(Status.BadRequest, errorJson("Title is required"))
                  case _ =>
                    val newTitle = body.title.getOrElse(todo.title)
                    val newDesc = body.description.getOrElse(todo.description)
                    val newCompleted = body.completed.getOrElse(todo.completed)
                    val now = nowInstant()
                    val prev = Instant.parse(todo.updatedAt)
                    val chosen = if (now.isAfter(prev)) now else prev.plusSeconds(1)
                    val updated = todo.copy(
                      title = newTitle,
                      description = newDesc,
                      completed = newCompleted,
                      updatedAt = chosen.truncatedTo(ChronoUnit.SECONDS).toString
                    )
                    todosById.put(Integer.valueOf(id), updated)
                    Response[IO](status = Status.Ok)
                      .withEntity(updated)
                      .withContentType(headers.`Content-Type`(MediaType.application.json))
                      .pure[IO]
                }
            }
        }
      }

    // Delete todo by id
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) { case (uid, _) =>
        Option(todosById.get(Integer.valueOf(id))) match {
          case None => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(todo) if todo.ownerId != uid => jsonResponse(Status.NotFound, errorJson("Todo not found"))
          case Some(_) =>
            todosById.remove(Integer.valueOf(id))
            IO.pure(Response[IO](status = Status.NoContent))
        }
      }
  }

  def program(port: Int): IO[Unit] = {
    val httpApp = routes.orNotFound

    val serverResource = EmberServerBuilder.default[IO]
      .withHost(host"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build

    serverResource.use { _ =>
      IO.never
    }
  }

  private def parseArgs(args: List[String]): Int = {
    // default port 8080; look for --port PORT
    def loop(rest: List[String], port: Int): Int = rest match {
      case Nil => port
      case "--port" :: p :: tail => loop(tail, p.toIntOption.getOrElse(port))
      case _ :: tail => loop(tail, port)
    }
    loop(args, 8080)
  }

  override def run(args: List[String]): IO[ExitCode] = {
    val port = parseArgs(args)
    program(port).as(ExitCode.Success)
  }
}
