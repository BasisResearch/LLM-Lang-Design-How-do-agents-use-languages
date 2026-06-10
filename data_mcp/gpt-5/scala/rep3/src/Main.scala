//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.25"
//> using dep "org.http4s::http4s-dsl:0.23.25"
//> using dep "org.http4s::http4s-circe:0.23.25"
//> using dep "io.circe::circe-core:0.14.7"
//> using dep "io.circe::circe-generic:0.14.7"
//> using dep "io.circe::circe-parser:0.14.7"
//> using dep "org.typelevel::cats-effect:3.5.4"

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe._
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.syntax._
import io.circe.generic.semiauto._
import java.util.UUID
import org.typelevel.ci.{CIString, CIStringSyntax}
import com.comcast.ip4s._

object Main extends IOApp {

  case class UserRec(id: Int, username: String, password: String)
  private case class UserPublic(id: Int, username: String)
  private implicit val userPublicEncoder: Encoder[UserPublic] = deriveEncoder

  case class TodoRec(
      id: Int,
      ownerId: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  private case class TodoPublic(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  private implicit val todoPublicEncoder: Encoder[TodoPublic] = deriveEncoder
  private def toPublic(t: TodoRec): TodoPublic =
    TodoPublic(t.id, t.title, t.description, t.completed, t.created_at, t.updated_at)

  private case class RegisterReq(username: String, password: String)
  private implicit val registerReqDecoder: Decoder[RegisterReq] = deriveDecoder
  private case class LoginReq(username: String, password: String)
  private implicit val loginReqDecoder: Decoder[LoginReq] = deriveDecoder
  private case class PasswordReq(old_password: String, new_password: String)
  private implicit val passwordReqDecoder: Decoder[PasswordReq] = deriveDecoder
  private case class CreateTodoReq(title: String, description: Option[String])
  private implicit val createTodoReqDecoder: Decoder[CreateTodoReq] = deriveDecoder
  private case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])
  private implicit val updateTodoReqDecoder: Decoder[UpdateTodoReq] = deriveDecoder

  case class State(
      nextUserId: Int,
      nextTodoId: Int,
      users: Map[Int, UserRec],
      usernameIndex: Map[String, Int],
      sessions: Map[String, Int], // token -> userId
      todos: Map[Int, TodoRec]
  )
  object State {
    def empty: State = State(1, 1, Map.empty, Map.empty, Map.empty, Map.empty)
  }

  private def nowInstant(): java.time.Instant = java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
  private def nowTs(): String = nowInstant().toString
  private def bumpedUpdateTs(prev: String): String = {
    val now = nowInstant()
    val prevI = scala.util.Try(java.time.Instant.parse(prev)).getOrElse(java.time.Instant.EPOCH)
    val chosen = if (now.isAfter(prevI)) now else prevI.plusSeconds(1)
    chosen.toString
  }

  private val JsonCT: Header.Raw = Header.Raw(CIString("Content-Type"), "application/json")

  private def jsonError(msg: String, status: Status): Response[IO] =
    Response[IO](status).withEntity(Json.obj("error" -> Json.fromString(msg))).putHeaders(JsonCT)

  private def jsonOk(entity: Json, status: Status = Status.Ok): Response[IO] =
    Response[IO](status).withEntity(entity).putHeaders(JsonCT)

  private def readJson[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] =
    req.as[Json].attempt.flatMap {
      case Left(_) => IO.pure(Left(jsonError("Invalid JSON", Status.BadRequest)))
      case Right(json) =>
        IO.pure(json.as[A].leftMap(_ => jsonError("Invalid JSON", Status.BadRequest)))
    }

  private def withAuth(state: Ref[IO, State])(req: Request[IO]): IO[Either[Response[IO], (UserRec, String)]] = {
    val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
    tokenOpt match {
      case None => IO.pure(Left(jsonError("Authentication required", Status.Unauthorized)))
      case Some(token) =>
        state.get.map { s =>
          s.sessions.get(token).flatMap(uid => s.users.get(uid)) match {
            case Some(user) => Right((user, token))
            case None => Left(jsonError("Authentication required", Status.Unauthorized))
          }
        }
    }
  }

  private def routes(state: Ref[IO, State]): HttpRoutes[IO] = HttpRoutes.of[IO] {

    // POST /register
    case req @ POST -> Root / "register" =>
      readJson[RegisterReq](req).flatMap {
        case Left(err) => IO.pure(err)
        case Right(body) =>
          val usernameValid = body.username.matches("^[a-zA-Z0-9_]{3,50}$")
          val passwordValid = body.password.length >= 8
          if (!usernameValid) IO.pure(jsonError("Invalid username", Status.BadRequest))
          else if (!passwordValid) IO.pure(jsonError("Password too short", Status.BadRequest))
          else state.modify { s =>
            if (s.usernameIndex.contains(body.username))
              (s, Left(jsonError("Username already exists", Status.Conflict)))
            else {
              val id = s.nextUserId
              val user = UserRec(id, body.username, body.password)
              val s2 = s.copy(
                nextUserId = id + 1,
                users = s.users + (id -> user),
                usernameIndex = s.usernameIndex + (body.username -> id)
              )
              (s2, Right(user))
            }
          }.map {
            case Left(err) => err
            case Right(user) =>
              jsonOk(UserPublic(user.id, user.username).asJson, Status.Created)
          }
      }

    // POST /login
    case req @ POST -> Root / "login" =>
      readJson[LoginReq](req).flatMap {
        case Left(err) => IO.pure(err)
        case Right(body) =>
          state.modify { s =>
            s.usernameIndex.get(body.username).flatMap(s.users.get) match {
              case Some(user) if user.password == body.password =>
                val token = UUID.randomUUID().toString.replaceAll("-", "")
                val s2 = s.copy(sessions = s.sessions + (token -> user.id))
                (s2, Right((user, token)))
              case _ => (s, Left(jsonError("Invalid credentials", Status.Unauthorized)))
            }
          }.map {
            case Left(err) => err
            case Right((user, token)) =>
              val cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
              jsonOk(UserPublic(user.id, user.username).asJson, Status.Ok).addCookie(cookie)
          }
      }

    // POST /logout
    case req @ POST -> Root / "logout" =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((_, token)) =>
          state.update(s => s.copy(sessions = s.sessions - token)) *>
            IO.pure(jsonOk(Json.obj(), Status.Ok))
      }

    // GET /me
    case req @ GET -> Root / "me" =>
      withAuth(state)(req).map {
        case Left(err) => err
        case Right((user, _)) => jsonOk(UserPublic(user.id, user.username).asJson, Status.Ok)
      }

    // PUT /password
    case req @ PUT -> Root / "password" =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          readJson[PasswordReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(body) =>
              if (body.old_password != user.password) IO.pure(jsonError("Invalid credentials", Status.Unauthorized))
              else if (body.new_password.length < 8) IO.pure(jsonError("Password too short", Status.BadRequest))
              else state.update { s =>
                s.copy(users = s.users.updated(user.id, user.copy(password = body.new_password)))
              } *> IO.pure(jsonOk(Json.obj(), Status.Ok))
          }
      }

    // GET /todos
    case req @ GET -> Root / "todos" =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          state.get.map { s =>
            val list = s.todos.values.filter(_.ownerId == user.id).toList.sortBy(_.id).map(toPublic)
            jsonOk(list.asJson, Status.Ok)
          }
      }

    // POST /todos
    case req @ POST -> Root / "todos" =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          readJson[CreateTodoReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(body) =>
              val title = Option(body.title).getOrElse("")
              if (title.trim.isEmpty) IO.pure(jsonError("Title is required", Status.BadRequest))
              else state.modify { s =>
                val id = s.nextTodoId
                val ts = nowTs()
                val todo = TodoRec(id, user.id, title, body.description.getOrElse(""), completed = false, created_at = ts, updated_at = ts)
                val s2 = s.copy(nextTodoId = id + 1, todos = s.todos + (id -> todo))
                (s2, todo)
              }.map { todo => jsonOk(toPublic(todo).asJson, Status.Created) }
          }
      }

    // GET /todos/:id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          state.get.map { s =>
            s.todos.get(id) match {
              case Some(t) if t.ownerId == user.id => jsonOk(toPublic(t).asJson, Status.Ok)
              case _ => jsonError("Todo not found", Status.NotFound)
            }
          }
      }

    // PUT /todos/:id
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          readJson[UpdateTodoReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(body) =>
              state.modify { s =>
                s.todos.get(id) match {
                  case Some(t) if t.ownerId == user.id =>
                    body.title match {
                      case Some(tl) if tl.trim.isEmpty => (s, Left(jsonError("Title is required", Status.BadRequest)))
                      case _ =>
                        val newTitle = body.title.getOrElse(t.title)
                        val newDesc = body.description.getOrElse(t.description)
                        val newComp = body.completed.getOrElse(t.completed)
                        val ts = if (body.title.isDefined || body.description.isDefined || body.completed.isDefined) bumpedUpdateTs(t.updated_at) else t.updated_at
                        val updated = t.copy(title = newTitle, description = newDesc, completed = newComp, updated_at = ts)
                        (s.copy(todos = s.todos.updated(id, updated)), Right(updated))
                    }
                  case _ => (s, Left(jsonError("Todo not found", Status.NotFound)))
                }
              }.map {
                case Left(err) => err
                case Right(todo) => jsonOk(toPublic(todo).asJson, Status.Ok)
              }
          }
      }

    // DELETE /todos/:id
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      withAuth(state)(req).flatMap {
        case Left(err) => IO.pure(err)
        case Right((user, _)) =>
          state.modify { s =>
            s.todos.get(id) match {
              case Some(t) if t.ownerId == user.id =>
                (s.copy(todos = s.todos - id), Right(()))
              case _ => (s, Left(jsonError("Todo not found", Status.NotFound)))
            }
          }.map {
            case Left(err) => err
            case Right(_) => Response[IO](Status.NoContent)
          }
      }
  }

  override def run(args: List[String]): IO[ExitCode] = {
    val defaultPort = 8080
    val portNum = args.sliding(2, 1).collect { case List("--port", p) => p }.toList.headOption.map(_.toInt).getOrElse(defaultPort)
    val ip4sPort = Port.fromInt(portNum).getOrElse(port"8080")

    for {
      ref <- Ref.of[IO, State](State.empty)
      httpApp = routes(ref).orNotFound
      _ <- org.http4s.ember.server.EmberServerBuilder.default[IO]
        .withHost(ipv4"0.0.0.0") // ensure 0.0.0.0 bind
        .withPort(ip4sPort)
        .withHttpApp(httpApp)
        .build
        .use { _ =>
          IO.println(s"Server started at http://0.0.0.0:$portNum") *> IO.never
        }
    } yield ExitCode.Success
  }
}
