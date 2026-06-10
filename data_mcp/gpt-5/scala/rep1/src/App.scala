//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"
//> using dep "com.comcast::ip4s-core:3.8.0"

import cats.effect._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import io.circe.parser._
import org.http4s.server.middleware._
import com.comcast.ip4s._

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.UUID
import java.time._
import java.time.format.DateTimeFormatter
import scala.jdk.CollectionConverters._

object App extends IOApp.Simple {

  // Data models
  final case class User(id: Int, username: String, password: String)
  final case class PublicUser(id: Int, username: String)

  final case class Todo(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )

  // Request models
  final case class RegisterReq(username: String, password: String)
  final case class LoginReq(username: String, password: String)
  final case class PasswordChangeReq(old_password: String, new_password: String)
  final case class CreateTodoReq(title: String, description: Option[String])
  final case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

  // Encoders/Decoders
  given Encoder[PublicUser] = deriveEncoder
  given Encoder[Todo] = deriveEncoder
  given Decoder[RegisterReq] = deriveDecoder
  given Decoder[LoginReq] = deriveDecoder
  given Decoder[PasswordChangeReq] = deriveDecoder
  given Decoder[CreateTodoReq] = deriveDecoder
  given Decoder[UpdateTodoReq] = deriveDecoder

  // In-memory stores
  private val usersById = new ConcurrentHashMap[Int, User]()
  private val usersByUsername = new ConcurrentHashMap[String, User]()
  private val sessions = new ConcurrentHashMap[String, Int]() // token -> userId
  private val todos = new ConcurrentHashMap[Int, Todo]()

  private val userIdCounter = new AtomicInteger(0)
  private val todoIdCounter = new AtomicInteger(0)

  private val UsernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private val timeFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
  private def nowTs(): String = timeFormatter.format(Instant.now())

  private def publicUser(u: User): PublicUser = PublicUser(u.id, u.username)

  // Helpers
  private def jsonResponse(status: Status, json: Json): IO[Response[IO]] =
    IO.pure(Response[IO](status).withEntity(json)) // withEntity(Json) sets Content-Type: application/json

  private def ok(json: Json): IO[Response[IO]] = jsonResponse(Status.Ok, json)
  private def created(json: Json): IO[Response[IO]] = jsonResponse(Status.Created, json)
  private def error(status: Status, msg: String): IO[Response[IO]] = jsonResponse(status, Json.obj("error" -> Json.fromString(msg)))

  private def parseJsonBodyAs[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] =
    req.as[String].attempt.flatMap {
      case Left(_) => error(Status.BadRequest, "Invalid JSON").map(Left(_))
      case Right(bodyStr) =>
        parse(bodyStr) match {
          case Left(_) => error(Status.BadRequest, "Invalid JSON").map(Left(_))
          case Right(j) => j.as[A] match {
              case Left(_) => error(Status.BadRequest, "Invalid JSON").map(Left(_))
              case Right(v) => IO.pure(Right(v))
            }
        }
    }

  private def getSessionUser(req: Request[IO]): Option[(String, User)] = {
    val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
    tokenOpt.flatMap { tok =>
      Option(sessions.get(tok)).flatMap(uid => Option(usersById.get(uid)).map(u => (tok, u)))
    }
  }

  private def withAuth(req: Request[IO])(f: (String, User) => IO[Response[IO]]): IO[Response[IO]] = {
    getSessionUser(req) match {
      case Some((tok, user)) => f(tok, user)
      case None => error(Status.Unauthorized, "Authentication required")
    }
  }

  // Routes
  private val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {

    // POST /register
    case req @ POST -> Root / "register" =>
      parseJsonBodyAs[RegisterReq](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(RegisterReq(username, password)) =>
          val validUsername = UsernameRegex.matches(username)
          if (!validUsername) error(Status.BadRequest, "Invalid username")
          else if (password == null || password.length < 8) error(Status.BadRequest, "Password too short")
          else {
            // Uniqueness check with putIfAbsent
            if (usersByUsername.containsKey(username)) error(Status.Conflict, "Username already exists")
            else {
              val id = userIdCounter.incrementAndGet()
              val user = User(id, username, password)
              val prev = usersByUsername.putIfAbsent(username, user)
              if (prev != null) error(Status.Conflict, "Username already exists")
              else {
                usersById.put(id, user)
                created(publicUser(user).asJson)
              }
            }
          }
      }

    // POST /login
    case req @ POST -> Root / "login" =>
      parseJsonBodyAs[LoginReq](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(LoginReq(username, password)) =>
          Option(usersByUsername.get(username)) match {
            case Some(user) if user.password == password =>
              val token = UUID.randomUUID().toString.replaceAll("-", "")
              sessions.put(token, user.id)
              val cookie = ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)
              val resp = Response[IO](Status.Ok).withEntity(publicUser(user).asJson).addCookie(cookie)
              IO.pure(resp)
            case _ => error(Status.Unauthorized, "Invalid credentials")
          }
      }

    // POST /logout
    case req @ POST -> Root / "logout" =>
      withAuth(req) { case (token, _) =>
        sessions.remove(token)
        ok(Json.obj())
      }

    // GET /me
    case req @ GET -> Root / "me" =>
      withAuth(req) { case (_, user) => ok(publicUser(user).asJson) }

    // PUT /password
    case req @ PUT -> Root / "password" =>
      withAuth(req) { case (_, user) =>
        parseJsonBodyAs[PasswordChangeReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(PasswordChangeReq(oldp, newp)) =>
            if (user.password != oldp) error(Status.Unauthorized, "Invalid credentials")
            else if (newp == null || newp.length < 8) error(Status.BadRequest, "Password too short")
            else {
              val updated = user.copy(password = newp)
              usersById.put(user.id, updated)
              usersByUsername.put(user.username, updated)
              ok(Json.obj())
            }
        }
      }

    // GET /todos
    case req @ GET -> Root / "todos" =>
      withAuth(req) { case (_, user) =>
        val list = todos.values().asScala.filter(_.userId == user.id).toList.sortBy(_.id)
        ok(list.asJson)
      }

    // POST /todos
    case req @ POST -> Root / "todos" =>
      withAuth(req) { case (_, user) =>
        parseJsonBodyAs[CreateTodoReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(CreateTodoReq(title, descOpt)) =>
            val titleValid = Option(title).exists(_.trim.nonEmpty)
            if (!titleValid) error(Status.BadRequest, "Title is required")
            else {
              val id = todoIdCounter.incrementAndGet()
              val now = nowTs()
              val todo = Todo(
                id = id,
                userId = user.id,
                title = title.trim,
                description = descOpt.getOrElse("")
                  ,
                completed = false,
                created_at = now,
                updated_at = now
              )
              todos.put(id, todo)
              created(todo.asJson)
            }
        }
      }

    // GET /todos/:id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      withAuth(req) { case (_, user) =>
        Option(todos.get(id)) match {
          case Some(t) if t.userId == user.id => ok(t.asJson)
          case _ => error(Status.NotFound, "Todo not found")
        }
      }

    // PUT /todos/:id (partial update)
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      withAuth(req) { case (_, user) =>
        Option(todos.get(id)) match {
          case None => error(Status.NotFound, "Todo not found")
          case Some(existing) if existing.userId != user.id => error(Status.NotFound, "Todo not found")
          case Some(existing) =>
            parseJsonBodyAs[UpdateTodoReq](req).flatMap {
              case Left(resp) => IO.pure(resp)
              case Right(UpdateTodoReq(titleOpt, descOpt, completedOpt)) =>
                if (titleOpt.exists(_.trim.isEmpty)) error(Status.BadRequest, "Title is required")
                else {
                  val updated = existing.copy(
                    title = titleOpt.map(_.trim).getOrElse(existing.title),
                    description = descOpt.getOrElse(existing.description),
                    completed = completedOpt.getOrElse(existing.completed),
                    updated_at = nowTs()
                  )
                  todos.put(id, updated)
                  ok(updated.asJson)
                }
            }
        }
      }

    // DELETE /todos/:id
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      withAuth(req) { case (_, user) =>
        Option(todos.get(id)) match {
          case Some(t) if t.userId == user.id =>
            todos.remove(id)
            IO.pure(Response[IO](Status.NoContent))
          case _ => error(Status.NotFound, "Todo not found")
        }
      }
  }

  // Main server
  def run: IO[Unit] = {
    val portFromEnv = sys.env.get("PORT").flatMap(s => scala.util.Try(s.toInt).toOption)
    val port = portFromEnv.getOrElse(8080)

    val httpApp: HttpApp[IO] = routes.orNotFound

    EmberServerBuilder.default[IO]
      .withHost(ipv4"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build
      .useForever
  }
}
