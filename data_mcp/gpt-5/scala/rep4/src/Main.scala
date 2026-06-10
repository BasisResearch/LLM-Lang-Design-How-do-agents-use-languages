//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-core:0.14.15"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.circe._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.util.UUID
import java.time.Instant
import java.time.temporal.ChronoUnit
import com.comcast.ip4s._

object Main extends IOApp:

  case class User(id: Int, username: String, password: String)
  case class PublicUser(id: Int, username: String)

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
  case class PasswordChangeReq(old_password: String, new_password: String)
  case class CreateTodoReq(title: String, description: Option[String])
  case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

  given Encoder[PublicUser] = deriveEncoder
  given Encoder[Todo] = deriveEncoder
  given Decoder[RegisterReq] = deriveDecoder
  given Decoder[LoginReq] = deriveDecoder
  given Decoder[PasswordChangeReq] = deriveDecoder
  given Decoder[CreateTodoReq] = deriveDecoder
  given Decoder[UpdateTodoReq] = deriveDecoder

  // Ensures JSON content type for circe entities
  given EntityEncoder[IO, Json] = jsonEncoderOf[IO, Json]
  given [A: Encoder]: EntityEncoder[IO, A] = jsonEncoderOf[IO, A]

  given EntityDecoder[IO, Json] = jsonOf[IO, Json]

  case class State(
      nextUserId: Int,
      nextTodoId: Int,
      usersById: Map[Int, User],
      usersByUsername: Map[String, Int],
      sessions: Map[String, Int], // token -> userId
      todos: Map[Int, (Int, Todo)] // todoId -> (ownerId, Todo)
  )

  val initialState = State(1, 1, Map.empty, Map.empty, Map.empty, Map.empty)

  def nowIso(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString

  def publicUser(u: User): PublicUser = PublicUser(u.id, u.username)

  def jsonError(status: Status, msg: String): IO[Response[IO]] =
    val json = Json.obj("error" -> Json.fromString(msg))
    IO.pure(Response[IO](status).withEntity(json))

  def parseJson[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] =
    req.as[Json].attempt.flatMap {
      case Left(_) => jsonError(Status.BadRequest, "Invalid JSON").map(Left(_))
      case Right(j) => j.as[A] match
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON").map(Left(_))
          case Right(v) => IO.pure(Right(v))
    }

  def authUser(req: Request[IO], ref: Ref[IO, State]): IO[Either[Response[IO], (User, String)]] =
    val maybeCookie = req.cookies.find(_.name == "session_id").map(_.content)
    maybeCookie match
      case None => jsonError(Status.Unauthorized, "Authentication required").map(Left(_))
      case Some(token) =>
        ref.get.flatMap { st =>
          st.sessions.get(token) match
            case None => jsonError(Status.Unauthorized, "Authentication required").map(Left(_))
            case Some(uid) =>
              st.usersById.get(uid) match
                case None => jsonError(Status.Unauthorized, "Authentication required").map(Left(_))
                case Some(u) => IO.pure(Right((u, token)))
        }

  def validateUsername(username: String): Boolean =
    val pattern = "^[a-zA-Z0-9_]{3,50}$".r
    pattern.matches(username)

  def routes(ref: Ref[IO, State]): HttpRoutes[IO] =
    HttpRoutes.of[IO] {

      // POST /register
      case req @ POST -> Root / "register" =>
        parseJson[RegisterReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(body) =>
            if (!validateUsername(body.username)) then jsonError(Status.BadRequest, "Invalid username")
            else if (body.password == null || body.password.length < 8) then jsonError(Status.BadRequest, "Password too short")
            else
              ref.modify { st =>
                if (st.usersByUsername.contains(body.username)) then (st, Left(Response[IO](Status.Conflict)))
                else
                  val id = st.nextUserId
                  val user = User(id, body.username, body.password)
                  val st2 = st.copy(
                    nextUserId = id + 1,
                    usersById = st.usersById + (id -> user),
                    usersByUsername = st.usersByUsername + (body.username -> id)
                  )
                  (st2, Right(user))
              }.flatMap {
                case Left(_) => jsonError(Status.Conflict, "Username already exists")
                case Right(user) =>
                  val json = publicUser(user).asJson
                  Created(json)
              }
        }

      // POST /login
      case req @ POST -> Root / "login" =>
        parseJson[LoginReq](req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right(body) =>
            ref.modify { st =>
              st.usersByUsername.get(body.username).flatMap(st.usersById.get) match
                case Some(user) if user.password == body.password =>
                  val token = UUID.randomUUID().toString.replaceAll("-", "")
                  val st2 = st.copy(sessions = st.sessions + (token -> user.id))
                  (st2, Right((user, token)))
                case _ => (st, Left(()))
            }.flatMap {
              case Left(_) => jsonError(Status.Unauthorized, "Invalid credentials")
              case Right((user, token)) =>
                val cookie = ResponseCookie(
                  name = "session_id",
                  content = token,
                  path = Some("/"),
                  httpOnly = true
                )
                Ok(publicUser(user).asJson).map(_.addCookie(cookie))
            }
        }

      // POST /logout
      case req @ POST -> Root / "logout" =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((_, token)) =>
            ref.update(st => st.copy(sessions = st.sessions - token)) *> Ok(Json.obj())
        }

      // GET /me
      case req @ GET -> Root / "me" =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) => Ok(publicUser(user).asJson)
        }

      // PUT /password
      case req @ PUT -> Root / "password" =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            parseJson[PasswordChangeReq](req).flatMap {
              case Left(resp) => IO.pure(resp)
              case Right(body) =>
                if (body.old_password != user.password) then jsonError(Status.Unauthorized, "Invalid credentials")
                else if (body.new_password == null || body.new_password.length < 8) then jsonError(Status.BadRequest, "Password too short")
                else
                  ref.update { st =>
                    val updated = user.copy(password = body.new_password)
                    st.copy(usersById = st.usersById + (user.id -> updated))
                  } *> Ok(Json.obj())
            }
        }

      // GET /todos
      case req @ GET -> Root / "todos" =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            ref.get.flatMap { st =>
              val list = st.todos.values.collect { case (owner, todo) if owner == user.id => todo }.toList.sortBy(_.id)
              Ok(list.asJson)
            }
        }

      // POST /todos
      case req @ POST -> Root / "todos" =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            parseJson[CreateTodoReq](req).flatMap {
              case Left(resp) => IO.pure(resp)
              case Right(body) =>
                val title = Option(body.title).map(_.trim).getOrElse("")
                if (title.isEmpty) then jsonError(Status.BadRequest, "Title is required")
                else
                  val description = body.description.getOrElse("")
                  val created = nowIso()
                  ref.modify { st =>
                    val id = st.nextTodoId
                    val todo = Todo(id, title, description, completed = false, created, created)
                    val st2 = st.copy(
                      nextTodoId = id + 1,
                      todos = st.todos + (id -> (user.id -> todo))
                    )
                    (st2, todo)
                  }.flatMap(todo => Created(todo.asJson))
            }
        }

      // GET /todos/:id
      case req @ GET -> Root / "todos" / IntVar(id) =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            ref.get.flatMap { st =>
              st.todos.get(id) match
                case Some((owner, todo)) if owner == user.id => Ok(todo.asJson)
                case _ => jsonError(Status.NotFound, "Todo not found")
            }
        }

      // PUT /todos/:id
      case req @ PUT -> Root / "todos" / IntVar(id) =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            parseJson[UpdateTodoReq](req).flatMap {
              case Left(resp) => IO.pure(resp)
              case Right(body) =>
                ref.modify { st =>
                  st.todos.get(id) match
                    case Some((owner, todo)) if owner == user.id =>
                      val newTitle = body.title.map(_.trim).getOrElse(todo.title)
                      if (body.title.exists(_.trim.isEmpty)) then (st, Left("Title is required"))
                      else
                        val newDesc = body.description.getOrElse(todo.description)
                        val newComp = body.completed.getOrElse(todo.completed)
                        val updated = todo.copy(title = newTitle, description = newDesc, completed = newComp, updated_at = nowIso())
                        val st2 = st.copy(todos = st.todos + (id -> (owner -> updated)))
                        (st2, Right(updated))
                    case _ => (st, Left("404"))
                }.flatMap {
                  case Left(msg) if msg == "404" => jsonError(Status.NotFound, "Todo not found")
                  case Left(msg) => jsonError(Status.BadRequest, msg)
                  case Right(updated) => Ok(updated.asJson)
                }
            }
        }

      // DELETE /todos/:id
      case req @ DELETE -> Root / "todos" / IntVar(id) =>
        authUser(req, ref).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((user, _)) =>
            ref.modify { st =>
              st.todos.get(id) match
                case Some((owner, _)) if owner == user.id =>
                  val st2 = st.copy(todos = st.todos - id)
                  (st2, Right(()))
                case _ => (st, Left(()))
            }.flatMap {
              case Left(_) => jsonError(Status.NotFound, "Todo not found")
              case Right(_) => NoContent()
            }
        }

      // Fallback 404 as JSON
      case _ => jsonError(Status.NotFound, "Not found")
    }

  def server(portNum: Int): Resource[IO, org.http4s.server.Server] =
    for
      ref <- Resource.eval(Ref.of[IO, State](initialState))
      httpApp = routes(ref).orNotFound
      server <- EmberServerBuilder.default[IO]
        .withHost(ip"0.0.0.0")
        .withPort(Port.fromInt(portNum).get)
        .withHttpApp(httpApp)
        .build
    yield server

  override def run(args: List[String]): IO[ExitCode] =
    val port = args.sliding(2,1).collectFirst { case List("--port", p) => p.toInt }.getOrElse(8080)
    server(port).useForever.as(ExitCode.Success)
