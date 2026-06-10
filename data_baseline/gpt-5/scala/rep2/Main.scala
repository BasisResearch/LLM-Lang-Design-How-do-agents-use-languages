//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.26"
//> using dep "org.http4s::http4s-dsl:0.23.26"
//> using dep "org.http4s::http4s-circe:0.23.26"
//> using dep "io.circe::circe-generic:0.14.6"
//> using dep "io.circe::circe-parser:0.14.6"

import cats.effect._
import cats.implicits._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.server.Router
import org.http4s.ember.server._
import org.http4s.circe._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._
import java.time._
import org.http4s.headers.`Content-Type`
import com.comcast.ip4s._

object Main extends IOApp {

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

  // Requests
  case class RegisterReq(username: String, password: String)
  case class LoginReq(username: String, password: String)
  case class PasswordChangeReq(old_password: String, new_password: String)
  case class CreateTodoReq(title: Option[String], description: Option[String])
  case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

  implicit val registerReqDecoder: Decoder[RegisterReq] = deriveDecoder
  implicit val loginReqDecoder: Decoder[LoginReq] = deriveDecoder
  implicit val passwordChangeReqDecoder: Decoder[PasswordChangeReq] = deriveDecoder
  implicit val createTodoReqDecoder: Decoder[CreateTodoReq] = deriveDecoder
  implicit val updateTodoReqDecoder: Decoder[UpdateTodoReq] = deriveDecoder

  // Encoders for responses (intentionally exclude password)
  implicit val userEncoder: Encoder[User] = new Encoder[User] {
    final def apply(u: User): Json = Json.obj(
      ("id", Json.fromInt(u.id)),
      ("username", Json.fromString(u.username))
    )
  }

  implicit val todoEncoder: Encoder[Todo] = new Encoder[Todo] {
    final def apply(t: Todo): Json = Json.obj(
      ("id", Json.fromInt(t.id)),
      ("title", Json.fromString(t.title)),
      ("description", Json.fromString(t.description)),
      ("completed", Json.fromBoolean(t.completed)),
      ("created_at", Json.fromString(t.createdAt)),
      ("updated_at", Json.fromString(t.updatedAt))
    )
  }

  // In-memory stores
  val usersById        = new ConcurrentHashMap[Int, User]()
  // Use boxed Integer in the Java map so we can detect nulls from putIfAbsent
  val userIdByUsername = new ConcurrentHashMap[String, java.lang.Integer]()
  val sessions         = new ConcurrentHashMap[String, Int]() // token -> userId
  val todosById        = new ConcurrentHashMap[Int, Todo]()

  val userIdCounter  = new AtomicInteger(0)
  val todoIdCounter  = new AtomicInteger(0)

  private val registerLock = new AnyRef

  private val usernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private def nowIso(): String = java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString

  private def jsonError(status: Status, message: String): Response[IO] = {
    val body = Json.obj("error" -> Json.fromString(message))
    Response[IO](status)
      .withEntity(body)
      .withHeaders(Headers(`Content-Type`(MediaType.application.json)))
  }

  private def decodeJsonBody[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] = {
    req.attemptAs[Json].value.flatMap {
      case Left(_) => IO.pure(Left(jsonError(Status.BadRequest, "Invalid request")))
      case Right(json) => IO.pure(json.as[A].leftMap(_ => jsonError(Status.BadRequest, "Invalid request")))
    }
  }

  private def notFoundTodo: Response[IO] = jsonError(Status.NotFound, "Todo not found")
  private def authRequired: Response[IO] = jsonError(Status.Unauthorized, "Authentication required")

  // Helper to get cookie by name
  private def getCookie(req: Request[IO], name: String): Option[RequestCookie] = req.cookies.find(_.name == name)

  // Auth extraction returns (user, sessionToken)
  private def withAuth(req: Request[IO])(f: (User, String) => IO[Response[IO]]): IO[Response[IO]] = {
    getCookie(req, "session_id") match {
      case None => IO.pure(authRequired)
      case Some(c) =>
        val token = c.content
        Option(sessions.get(token)) match {
          case None => IO.pure(authRequired)
          case Some(uid) =>
            Option(usersById.get(uid)) match {
              case None => IO.pure(authRequired)
              case Some(user) => f(user, token)
            }
        }
    }
  }

  private def createdResp(json: Json): Response[IO] = Response[IO](Status.Created).withEntity(json).withHeaders(Headers(`Content-Type`(MediaType.application.json)))

  val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // POST /register
    case req @ POST -> Root / "register" =>
      decodeJsonBody[RegisterReq](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(r) =>
          val validUsername = usernameRegex.pattern.matcher(r.username).matches()
          if (!validUsername) IO.pure(jsonError(Status.BadRequest, "Invalid username"))
          else if (Option(r.password).forall(_.length < 8)) IO.pure(jsonError(Status.BadRequest, "Password too short"))
          else {
            // Ensure uniqueness atomically
            val existing = Option(userIdByUsername.get(r.username))
            existing match {
              case Some(_) => IO.pure(jsonError(Status.Conflict, "Username already exists"))
              case None =>
                registerLock.synchronized {
                  // Double-check inside lock
                  if (userIdByUsername.containsKey(r.username)) {
                    jsonError(Status.Conflict, "Username already exists")
                  } else {
                    val id = userIdCounter.incrementAndGet()
                    val user = User(id, r.username, r.password)
                    usersById.put(id, user)
                    userIdByUsername.put(r.username, java.lang.Integer.valueOf(id))
                    createdResp(user.asJson)
                  }
                }.pure[IO]
            }
          }
      }

    // POST /login
    case req @ POST -> Root / "login" =>
      decodeJsonBody[LoginReq](req).flatMap {
        case Left(resp) => IO.pure(resp)
        case Right(lr) =>
          Option(userIdByUsername.get(lr.username)).flatMap(uid => Option(usersById.get(uid.intValue()))) match {
            case Some(user) if user.password == lr.password =>
              val token = UUID.randomUUID().toString.replaceAll("-", "")
              sessions.put(token, user.id)
              val cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
              Ok(user.asJson).map(_.addCookie(cookie)).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
            case _ => IO.pure(jsonError(Status.Unauthorized, "Invalid credentials"))
          }
      }

    // POST /logout
    case req @ POST -> Root / "logout" =>
      withAuth(req) { case (_, token) =>
        sessions.remove(token)
        Ok(Json.obj()).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
      }

    // GET /me
    case req @ GET -> Root / "me" =>
      withAuth(req) { case (user, _) =>
        Ok(user.asJson).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
      }

    // PUT /password
    case req @ PUT -> Root / "password" =>
      withAuth(req) { case (user, _) =>
        decodeJsonBody[PasswordChangeReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(pcr) =>
            if (user.password != pcr.old_password) IO.pure(jsonError(Status.Unauthorized, "Invalid credentials"))
            else if (pcr.new_password.length < 8) IO.pure(jsonError(Status.BadRequest, "Password too short"))
            else {
              val updated = user.copy(password = pcr.new_password)
              usersById.put(user.id, updated)
              Ok(Json.obj()).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
            }
        }
      }

    // GET /todos
    case req @ GET -> Root / "todos" =>
      withAuth(req) { case (user, _) =>
        val list = todosById.values().asScala.filter(_.userId == user.id).toList.sortBy(_.id)
        Ok(list.asJson).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
      }

    // POST /todos
    case req @ POST -> Root / "todos" =>
      withAuth(req) { case (user, _) =>
        decodeJsonBody[CreateTodoReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(tr) =>
            if (!tr.title.exists(_.trim.nonEmpty)) IO.pure(jsonError(Status.BadRequest, "Title is required"))
            else {
              val id = todoIdCounter.incrementAndGet()
              val createdAtStr = nowIso()
              val todo = Todo(
                id = id,
                userId = user.id,
                title = tr.title.get.trim,
                description = tr.description.getOrElse(""),
                completed = false,
                createdAt = createdAtStr,
                updatedAt = createdAtStr
              )
              todosById.put(id, todo)
              IO.pure(createdResp(todo.asJson))
            }
        }
      }

    // GET /todos/:id
    case req @ GET -> Root / "todos" / idStr =>
      withAuth(req) { case (user, _) =>
        scala.util.Try(idStr.toInt).toOption.flatMap(id => Option(todosById.get(id))) match {
          case Some(todo) if todo.userId == user.id => Ok(todo.asJson).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
          case _ => IO.pure(notFoundTodo)
        }
      }

    // PUT /todos/:id
    case req @ PUT -> Root / "todos" / idStr =>
      withAuth(req) { case (user, _) =>
        val maybeId = scala.util.Try(idStr.toInt).toOption
        maybeId match {
          case None => IO.pure(notFoundTodo)
          case Some(id) =>
            Option(todosById.get(id)) match {
              case None => IO.pure(notFoundTodo)
              case Some(existing) if existing.userId != user.id => IO.pure(notFoundTodo)
              case Some(existing) =>
                decodeJsonBody[UpdateTodoReq](req).flatMap {
                  case Left(resp) => IO.pure(resp)
                  case Right(ur) =>
                    ur.title match {
                      case Some(t) if t.trim.isEmpty => IO.pure(jsonError(Status.BadRequest, "Title is required"))
                      case _ =>
                        val updated = existing.copy(
                          title = ur.title.map(_.trim).filter(_.nonEmpty).getOrElse(existing.title),
                          description = ur.description.getOrElse(existing.description),
                          completed = ur.completed.getOrElse(existing.completed),
                          updatedAt = nowIso()
                        )
                        todosById.put(id, updated)
                        Ok(updated.asJson).map(_.putHeaders(`Content-Type`(MediaType.application.json)))
                    }
                }
            }
        }
      }

    // DELETE /todos/:id
    case req @ DELETE -> Root / "todos" / idStr =>
      withAuth(req) { case (user, _) =>
        scala.util.Try(idStr.toInt).toOption match {
          case None => IO.pure(notFoundTodo)
          case Some(id) =>
            Option(todosById.get(id)) match {
              case Some(todo) if todo.userId == user.id =>
                todosById.remove(id)
                // 204 No Content, no Content-Type header
                IO.pure(Response[IO](Status.NoContent))
              case _ => IO.pure(notFoundTodo)
            }
        }
      }
  }

  def runServer(port: Int): IO[Unit] = {
    val httpApp = Router("/" -> routes).orNotFound
    val host = ipv4"0.0.0.0"
    val p = Port.fromInt(port).getOrElse(port"8080")
    EmberServerBuilder.default[IO]
      .withHost(host)
      .withPort(p)
      .withHttpApp(httpApp)
      .build
      .use(_ => IO.never)
  }

  private def parseArgs(args: List[String]): Int = {
    @annotation.tailrec
    def loop(rem: List[String], port: Int): Int = rem match {
      case Nil => port
      case "--port" :: p :: tail =>
        scala.util.Try(p.toInt).toOption match {
          case Some(v) if v > 0 && v < 65536 => loop(tail, v)
          case _ => loop(tail, port)
        }
      case _ :: tail => loop(tail, port)
    }
    loop(args, 8080)
  }

  override def run(args: List[String]): IO[ExitCode] = {
    val fromEnv = sys.env.get("APP_PORT").flatMap(s => scala.util.Try(s.toInt).toOption)
    val fromArgs = Some(parseArgs(args))
    val port = fromEnv.orElse(fromArgs).getOrElse(8080)
    runServer(port).as(ExitCode.Success)
  }
}
