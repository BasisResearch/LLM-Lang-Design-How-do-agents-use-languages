//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-core:0.14.15"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"
//> using dep "org.typelevel::cats-effect:3.5.4"

import cats.effect._
import cats.effect.std.Console
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe._
import io.circe._
import io.circe.syntax._
import io.circe.generic.semiauto._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.server.middleware.Logger
import java.util.UUID
import java.time.Instant
import java.time.temporal.ChronoUnit
import com.comcast.ip4s._

object TodoServer extends IOApp {

  // Data models
  final case class User(id: Int, username: String, password: String)
  final case class PublicUser(id: Int, username: String)

  final case class TodoStored(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  ) {
    def toPublic: TodoPublic = TodoPublic(id, title, description, completed, created_at, updated_at)
  }
  final case class TodoPublic(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )

  final case class RegisterRequest(username: String, password: String)
  object RegisterRequest {
    implicit val decoder: Decoder[RegisterRequest] = deriveDecoder
  }
  final case class LoginRequest(username: String, password: String)
  object LoginRequest { implicit val decoder: Decoder[LoginRequest] = deriveDecoder }

  final case class CreateTodoRequest(title: Option[String], description: Option[String])
  object CreateTodoRequest { implicit val decoder: Decoder[CreateTodoRequest] = deriveDecoder }

  final case class UpdateTodoRequest(
      title: Option[String],
      description: Option[String],
      completed: Option[Boolean]
  )
  object UpdateTodoRequest { implicit val decoder: Decoder[UpdateTodoRequest] = deriveDecoder }

  final case class PasswordChangeRequest(old_password: String, new_password: String)
  object PasswordChangeRequest { implicit val decoder: Decoder[PasswordChangeRequest] = deriveDecoder }

  implicit val publicUserEncoder: Encoder[PublicUser] = deriveEncoder
  implicit val todoPublicEncoder: Encoder[TodoPublic] = deriveEncoder

  // App state
  final case class State(
      users: Map[Int, User],
      usernames: Map[String, Int],
      sessions: Map[String, Int], // token -> userId
      todos: Map[Int, TodoStored],
      nextUserId: Int,
      nextTodoId: Int
  )
  object State { def empty: State = State(Map.empty, Map.empty, Map.empty, Map.empty, 1, 1) }

  // Utilities
  def nowIso: String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString // ISO-8601 with Z

  def jsonError(status: Status, msg: String): IO[Response[IO]] = {
    val body = Json.obj("error" -> Json.fromString(msg))
    Response[IO](status = status).withEntity(body).pure[IO]
  }

  def unauthorizedAuthRequired: IO[Response[IO]] = jsonError(Status.Unauthorized, "Authentication required")

  def parsePort(args: List[String]): Either[String, Int] = {
    args match {
      case "--port" :: p :: _ =>
        Either.catchOnly[NumberFormatException](p.toInt).leftMap(_ => s"Invalid port: $p").flatMap { port =>
          if (port >= 1 && port <= 65535) Right(port)
          else Left(s"Invalid port: $port")
        }
      case _ => Left("Missing --port PORT")
    }
  }

  def routes(stateRef: Ref[IO, State]): HttpRoutes[IO] = {
    given EntityDecoder[IO, RegisterRequest] = jsonOf
    given EntityDecoder[IO, LoginRequest] = jsonOf
    given EntityDecoder[IO, CreateTodoRequest] = jsonOf
    given EntityDecoder[IO, UpdateTodoRequest] = jsonOf
    given EntityDecoder[IO, PasswordChangeRequest] = jsonOf

    def withAuth(req: Request[IO])(f: (User, String) => IO[Response[IO]]): IO[Response[IO]] = {
      val maybeToken = req.cookies.find(_.name == "session_id").map(_.content)
      maybeToken match {
        case None => unauthorizedAuthRequired
        case Some(token) =>
          stateRef.get.flatMap { st =>
            st.sessions.get(token).flatMap(st.users.get) match {
              case Some(user) => f(user, token)
              case None       => unauthorizedAuthRequired
            }
          }
      }
    }

    HttpRoutes.of[IO] {
      // POST /register
      case req @ POST -> Root / "register" =>
        req.attemptAs[RegisterRequest].value.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(body) =>
            val username = body.username
            val password = body.password
            val validUsername = username != null && username.length >= 3 && username.length <= 50 && username.matches("^[a-zA-Z0-9_]+$")
            val validPassword = password != null && password.length >= 8

            if (!validUsername) jsonError(Status.BadRequest, "Invalid username")
            else if (!validPassword) jsonError(Status.BadRequest, "Password too short")
            else {
              stateRef.modify { st =>
                if (st.usernames.contains(username)) (st, Left("Username already exists"))
                else {
                  val id = st.nextUserId
                  val user = User(id, username, password)
                  val newSt = st.copy(
                    users = st.users.updated(id, user),
                    usernames = st.usernames.updated(username, id),
                    nextUserId = id + 1
                  )
                  (newSt, Right(PublicUser(id, username)))
                }
              }.flatMap {
                case Left(_) => jsonError(Status.Conflict, "Username already exists")
                case Right(pub) =>
                  Created(pub.asJson)
              }
            }
        }

      // POST /login
      case req @ POST -> Root / "login" =>
        req.attemptAs[LoginRequest].value.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(body) =>
            stateRef.get.flatMap { st =>
              st.usernames.get(body.username).flatMap(st.users.get) match {
                case Some(user) if user.password == body.password =>
                  val token = UUID.randomUUID().toString
                  stateRef.update(st => st.copy(sessions = st.sessions.updated(token, user.id))) *>
                    Ok(PublicUser(user.id, user.username).asJson)
                      .map(_.addCookie(ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)))
                case _ => jsonError(Status.Unauthorized, "Invalid credentials")
              }
            }
        }

      // POST /logout
      case req @ POST -> Root / "logout" =>
        withAuth(req) { (_, token) =>
          stateRef.update(st => st.copy(sessions = st.sessions - token)) *>
            Ok(Json.obj())
        }

      // GET /me
      case req @ GET -> Root / "me" =>
        withAuth(req) { (user, _) =>
          Ok(PublicUser(user.id, user.username).asJson)
        }

      // PUT /password
      case req @ PUT -> Root / "password" =>
        withAuth(req) { (user, _) =>
          req.attemptAs[PasswordChangeRequest].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(body) =>
              if (body.old_password != user.password) jsonError(Status.Unauthorized, "Invalid credentials")
              else if (body.new_password == null || body.new_password.length < 8) jsonError(Status.BadRequest, "Password too short")
              else {
                stateRef.update { st =>
                  st.copy(users = st.users.updated(user.id, user.copy(password = body.new_password)))
                } *> Ok(Json.obj())
              }
          }
        }

      // GET /todos
      case req @ GET -> Root / "todos" =>
        withAuth(req) { (user, _) =>
          stateRef.get.flatMap { st =>
            val list = st.todos.values.filter(_.userId == user.id).toList.sortBy(_.id).map(_.toPublic)
            Ok(list.asJson)
          }
        }

      // POST /todos
      case req @ POST -> Root / "todos" =>
        withAuth(req) { (user, _) =>
          req.attemptAs[CreateTodoRequest].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(body) =>
              if (body.title.forall(_.trim.isEmpty)) jsonError(Status.BadRequest, "Title is required")
              else {
                val title = body.title.get
                val desc = body.description.getOrElse("")
                val now = nowIso
                stateRef.modify { st =>
                  val id = st.nextTodoId
                  val todo = TodoStored(id, user.id, title, desc, completed = false, created_at = now, updated_at = now)
                  val newSt = st.copy(todos = st.todos.updated(id, todo), nextTodoId = id + 1)
                  (newSt, todo.toPublic)
                }.flatMap { pub =>
                  Created(pub.asJson)
                }
              }
          }
        }

      // GET /todos/:id
      case req @ GET -> Root / "todos" / IntVar(tid) =>
        withAuth(req) { (user, _) =>
          stateRef.get.flatMap { st =>
            st.todos.get(tid) match {
              case Some(todo) if todo.userId == user.id => Ok(todo.toPublic.asJson)
              case _                                    => jsonError(Status.NotFound, "Todo not found")
            }
          }
        }

      // PUT /todos/:id (partial update)
      case req @ PUT -> Root / "todos" / IntVar(tid) =>
        withAuth(req) { (user, _) =>
          req.attemptAs[UpdateTodoRequest].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(body) =>
              body.title match {
                case Some(t) if t.trim.isEmpty => jsonError(Status.BadRequest, "Title is required")
                case _ =>
                  stateRef.modify { st =>
                    st.todos.get(tid) match {
                      case Some(todo) if todo.userId == user.id =>
                        val newTitle = body.title.getOrElse(todo.title)
                        val newDesc = body.description.getOrElse(todo.description)
                        val newCompleted = body.completed.getOrElse(todo.completed)
                        val updated = todo.copy(title = newTitle, description = newDesc, completed = newCompleted, updated_at = nowIso)
                        val newSt = st.copy(todos = st.todos.updated(tid, updated))
                        (newSt, Right(updated.toPublic))
                      case _ => (st, Left(()))
                    }
                  }.flatMap {
                    case Left(_)   => jsonError(Status.NotFound, "Todo not found")
                    case Right(pub) => Ok(pub.asJson)
                  }
              }
          }
        }

      // DELETE /todos/:id
      case req @ DELETE -> Root / "todos" / IntVar(tid) =>
        withAuth(req) { (user, _) =>
          stateRef.modify { st =>
            st.todos.get(tid) match {
              case Some(todo) if todo.userId == user.id =>
                (st.copy(todos = st.todos - tid), Right(()))
              case _ => (st, Left(()))
            }
          }.flatMap {
            case Left(_)  => jsonError(Status.NotFound, "Todo not found")
            case Right(_) => NoContent()
          }
        }
    }
  }

  override def run(args: List[String]): IO[ExitCode] = {
    val portE = parsePort(args)
    val program = for {
      port <- IO.fromEither(portE.leftMap(new RuntimeException(_)))
      ref  <- Ref.of[IO, State](State.empty)
      httpApp = Logger.httpApp(logHeaders = false, logBody = false)(routes(ref).orNotFound)
      _ <- EmberServerBuilder.default[IO]
            .withHost(ipv4"0.0.0.0")
            .withPort(Port.fromInt(port).get)
            .withHttpApp(httpApp)
            .build
            .useForever
    } yield ()

    program.as(ExitCode.Success).handleErrorWith { e =>
      Console[IO].errorln(s"Error: ${e.getMessage}").as(ExitCode.Error)
    }
  }
}
