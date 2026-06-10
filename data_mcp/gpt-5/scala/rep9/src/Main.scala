//> using scala "2.13.12"
//> using dep "org.http4s::http4s-ember-server:0.23.26"
//> using dep "org.http4s::http4s-dsl:0.23.26"
//> using dep "org.http4s::http4s-circe:0.23.26"
//> using dep "io.circe::circe-generic:0.14.7"
//> using dep "io.circe::circe-parser:0.14.7"
//> using dep "com.comcast::ip4s-core:3.5.0"

import cats.effect._
import cats.implicits._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe._
import io.circe._
import io.circe.syntax._
import io.circe.generic.semiauto._
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._
import com.comcast.ip4s._

object Main extends IOApp {

  case class User(id: Int, username: String, password: String)
  case class PublicUser(id: Int, username: String)

  case class Todo(
      id: Int,
      ownerId: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  case class PublicTodo(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )

  implicit val publicUserEncoder: Encoder[PublicUser] = deriveEncoder
  implicit val publicTodoEncoder: Encoder[PublicTodo] = deriveEncoder

  case class RegisterRequest(username: String, password: String)
  case class LoginRequest(username: String, password: String)
  case class PasswordChange(old_password: String, new_password: String)
  case class CreateTodo(title: String, description: Option[String])
  case class UpdateTodo(title: Option[String], description: Option[String], completed: Option[Boolean])

  implicit val registerDecoder: Decoder[RegisterRequest] = deriveDecoder
  implicit val loginDecoder: Decoder[LoginRequest] = deriveDecoder
  implicit val pwdChangeDecoder: Decoder[PasswordChange] = deriveDecoder
  implicit val createTodoDecoder: Decoder[CreateTodo] = deriveDecoder
  implicit val updateTodoDecoder: Decoder[UpdateTodo] = deriveDecoder

  implicit val errorEntityEncoder: EntityEncoder[IO, Json] = jsonEncoderOf[IO, Json]
  implicit val publicUserEntityEncoder: EntityEncoder[IO, PublicUser] = jsonEncoderOf[IO, PublicUser]
  implicit val publicTodoEntityEncoder: EntityEncoder[IO, PublicTodo] = jsonEncoderOf[IO, PublicTodo]
  implicit val publicTodoListEntityEncoder: EntityEncoder[IO, List[PublicTodo]] = jsonEncoderOf[IO, List[PublicTodo]]

  private val UsernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private val users = new ConcurrentHashMap[Int, User]()
  private val usersByName = new ConcurrentHashMap[String, java.lang.Integer]()
  private val sessions = new ConcurrentHashMap[String, Int]() // token -> userId
  private val todos = new ConcurrentHashMap[Int, Todo]()
  private val userIdSeq = new AtomicInteger(0)
  private val todoIdSeq = new AtomicInteger(0)

  private def nowIsoSec(): String = java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString
  private def bumpUpdated(prevIso: String): String = {
    val prev = java.time.Instant.parse(prevIso)
    val now = java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
    if (now.isAfter(prev)) now.toString else prev.plusSeconds(1).toString
  }

  private def toPublic(u: User): PublicUser = PublicUser(u.id, u.username)
  private def toPublic(t: Todo): PublicTodo = PublicTodo(t.id, t.title, t.description, t.completed, t.created_at, t.updated_at)

  private def jsonError(status: Status, msg: String): IO[Response[IO]] = {
    val json = Json.obj("error" -> Json.fromString(msg))
    Response[IO](status = status).withEntity(json).pure[IO]
  }

  private def parseJson[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] = {
    req.as[Json].attempt.flatMap {
      case Left(_) => IO.pure(Left(Response[IO](Status.BadRequest).withEntity(Json.obj("error" -> Json.fromString("Invalid JSON")))))
      case Right(json) =>
        json.as[A] match {
          case Left(_) => IO.pure(Left(Response[IO](Status.BadRequest).withEntity(Json.obj("error" -> Json.fromString("Invalid JSON")))))
          case Right(v) => IO.pure(Right(v))
        }
    }
  }

  private def authed(req: Request[IO]): IO[Either[Response[IO], User]] = IO {
    val maybeToken = req.cookies.find(_.name == "session_id").map(_.content)
    val maybeUser = for {
      token <- maybeToken
      uid <- Option(sessions.get(token))
      user <- Option(users.get(uid))
    } yield user
    maybeUser match {
      case Some(u) => Right(u)
      case None    => Left(Response[IO](Status.Unauthorized).withEntity(Json.obj("error" -> Json.fromString("Authentication required"))))
    }
  }

  private def routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // POST /register
    case req @ POST -> Root / "register" =>
      parseJson[RegisterRequest](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(body) =>
          val username = Option(body.username).getOrElse("")
          val password = Option(body.password).getOrElse("")
          if (UsernameRegex.findFirstIn(username).isEmpty) {
            jsonError(Status.BadRequest, "Invalid username")
          } else if (password.length < 8) {
            jsonError(Status.BadRequest, "Password too short")
          } else if (usersByName.containsKey(username)) {
            jsonError(Status.Conflict, "Username already exists")
          } else {
            val id = userIdSeq.incrementAndGet()
            val user = User(id, username, password)
            users.put(id, user)
            usersByName.put(username, java.lang.Integer.valueOf(id))
            Created(toPublic(user).asJson)
          }
      }

    // POST /login
    case req @ POST -> Root / "login" =>
      parseJson[LoginRequest](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(body) =>
          val maybeUserId = Option(usersByName.get(body.username)).map(_.intValue())
          maybeUserId.flatMap(uid => Option(users.get(uid))) match {
            case Some(user) if user.password == body.password =>
              val token = UUID.randomUUID().toString.replaceAll("-", "")
              sessions.put(token, user.id)
              Ok(toPublic(user).asJson).map(_.addCookie(ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)))
            case _ => jsonError(Status.Unauthorized, "Invalid credentials")
          }
      }

    // POST /logout
    case req @ POST -> Root / "logout" =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(_) =>
          val maybeToken = req.cookies.find(_.name == "session_id").map(_.content)
          maybeToken.foreach(t => sessions.remove(t))
          Ok(Json.obj())
      }

    // GET /me
    case req @ GET -> Root / "me" =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) => Ok(toPublic(u).asJson)
      }

    // PUT /password
    case req @ PUT -> Root / "password" =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          parseJson[PasswordChange](req).flatMap {
            case Left(resp) => IO.pure(resp)
            case Right(body) =>
              if (body.old_password != u.password) {
                jsonError(Status.Unauthorized, "Invalid credentials")
              } else if (body.new_password.length < 8) {
                jsonError(Status.BadRequest, "Password too short")
              } else {
                val updated = u.copy(password = body.new_password)
                users.put(u.id, updated)
                Ok(Json.obj())
              }
          }
      }

    // GET /todos
    case req @ GET -> Root / "todos" =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          val list = todos.values().asScala.toList.filter(_.ownerId == u.id).sortBy(_.id).map(toPublic)
          Ok(list.asJson)
      }

    // POST /todos
    case req @ POST -> Root / "todos" =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          parseJson[CreateTodo](req).flatMap {
            case Left(resp) => IO.pure(resp)
            case Right(body) =>
              val title = Option(body.title).getOrElse("").trim
              if (title.isEmpty) {
                jsonError(Status.BadRequest, "Title is required")
              } else {
                val desc = body.description.getOrElse("")
                val id = todoIdSeq.incrementAndGet()
                val ts = nowIsoSec()
                val todo = Todo(id, u.id, title, desc, completed = false, created_at = ts, updated_at = ts)
                todos.put(id, todo)
                Created(toPublic(todo).asJson)
              }
          }
      }

    // GET /todos/:id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          Option(todos.get(id)) match {
            case Some(t) if t.ownerId == u.id => Ok(toPublic(t).asJson)
            case _ => jsonError(Status.NotFound, "Todo not found")
          }
      }

    // PUT /todos/:id
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          Option(todos.get(id)) match {
            case Some(existing) if existing.ownerId == u.id =>
              parseJson[UpdateTodo](req).flatMap {
                case Left(resp) => IO.pure(resp)
                case Right(body) =>
                  body.title match {
                    case Some(t) if t.trim.isEmpty => jsonError(Status.BadRequest, "Title is required")
                    case _ =>
                      val newTitle = body.title.map(_.trim).getOrElse(existing.title)
                      val newDesc = body.description.getOrElse(existing.description)
                      val newCompleted = body.completed.getOrElse(existing.completed)
                      val newUpdated = bumpUpdated(existing.updated_at)
                      val updated = existing.copy(
                        title = newTitle,
                        description = newDesc,
                        completed = newCompleted,
                        updated_at = newUpdated
                      )
                      todos.put(id, updated)
                      Ok(toPublic(updated).asJson)
                  }
              }
            case _ => jsonError(Status.NotFound, "Todo not found")
          }
      }

    // DELETE /todos/:id
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      authed(req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(u) =>
          Option(todos.get(id)) match {
            case Some(t) if t.ownerId == u.id =>
              todos.remove(id)
              NoContent()
            case _ => jsonError(Status.NotFound, "Todo not found")
          }
      }
  }

  def httpApp: HttpApp[IO] = routes.orNotFound

  override def run(args: List[String]): IO[ExitCode] = {
    val portNum = sys.env.get("PORT").flatMap(s => scala.util.Try(s.toInt).toOption).getOrElse(8080)
    val host = Host.fromString("0.0.0.0").get
    val port = Port.fromInt(portNum).get
    EmberServerBuilder.default[IO]
      .withHost(host)
      .withPort(port)
      .withHttpApp(httpApp)
      .build
      .use(_ => IO.never)
      .as(ExitCode.Success)
  }
}
