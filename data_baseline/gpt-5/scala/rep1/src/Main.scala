//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-core:0.14.15"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"

import cats.effect._
import cats.effect.std.UUIDGen
import cats.syntax.all._
import cats.data.Kleisli
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.dsl.Http4sDsl
import org.http4s.circe._
import org.http4s.headers.`Content-Type`
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.security.MessageDigest
import java.time._
import java.time.format.DateTimeFormatter
import com.comcast.ip4s._

object Main extends IOApp {

  // Internal models
  final case class User(id: Int, username: String, passwordHash: String)
  final case class Todo(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: Instant,
      updatedAt: Instant
  )

  // External representations
  final case class UserOut(id: Int, username: String)
  object UserOut {
    def fromUser(u: User): UserOut = UserOut(u.id, u.username)
    implicit val encoder: Encoder[UserOut] = deriveEncoder[UserOut]
  }

  final case class TodoOut(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  object TodoOut {
    def fromTodo(t: Todo): TodoOut = {
      val fmt = DateTimeFormatter.ISO_INSTANT
      TodoOut(
        id = t.id,
        title = t.title,
        description = t.description,
        completed = t.completed,
        created_at = fmt.format(t.createdAt),
        updated_at = fmt.format(t.updatedAt)
      )
    }
    implicit val encoder: Encoder[TodoOut] = deriveEncoder[TodoOut]
  }

  // Requests
  final case class RegisterReq(username: String, password: String)
  object RegisterReq {
    implicit val decoder: Decoder[RegisterReq] = deriveDecoder[RegisterReq]
  }
  final case class LoginReq(username: String, password: String)
  object LoginReq {
    implicit val decoder: Decoder[LoginReq] = deriveDecoder[LoginReq]
  }
  final case class PasswordChangeReq(old_password: String, new_password: String)
  object PasswordChangeReq {
    implicit val decoder: Decoder[PasswordChangeReq] = deriveDecoder[PasswordChangeReq]
  }
  final case class CreateTodoReq(title: String, description: Option[String])
  object CreateTodoReq {
    implicit val decoder: Decoder[CreateTodoReq] = deriveDecoder[CreateTodoReq]
  }
  final case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])
  object UpdateTodoReq {
    implicit val decoder: Decoder[UpdateTodoReq] = deriveDecoder[UpdateTodoReq]
  }

  // App state
  final case class State(
      usersById: Map[Int, User],
      usersByName: Map[String, Int],
      nextUserId: Int,
      sessions: Map[String, Int], // token -> userId
      todosById: Map[Int, Todo],
      nextTodoId: Int
  )
  object State {
    val empty = State(Map.empty, Map.empty, 1, Map.empty, Map.empty, 1)
  }

  private val usernameRe = "^[a-zA-Z0-9_]{3,50}$".r

  private def hashPassword(pw: String): String = {
    val md = MessageDigest.getInstance("SHA-256")
    md.update(pw.getBytes("UTF-8"))
    md.digest().map("%02x".format(_)).mkString
  }

  private def nowInstant: Instant = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)

  private def jsonError(status: Status, msg: String): IO[Response[IO]] = {
    val json = Json.obj("error" -> Json.fromString(msg))
    IO.pure(Response[IO](status).withEntity(json).withContentType(`Content-Type`(MediaType.application.json)))
  }

  private object JsonMiddleware {
    // Ensure all responses except 204 No Content carry application/json content-type
    def apply(routes: HttpRoutes[IO]): HttpRoutes[IO] = Kleisli { (req: Request[IO]) =>
      routes.run(req).map { resp =>
        if (resp.status == Status.NoContent) resp
        else resp.withContentType(`Content-Type`(MediaType.application.json))
      }
    }
  }

  private def service(state: Ref[IO, State]): HttpRoutes[IO] = {
    import org.http4s.circe.CirceEntityCodec._

    def getUserFromSession(req: Request[IO]): IO[Option[User]] = state.get.map { s =>
      val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
      tokenOpt.flatMap(tok => s.sessions.get(tok)).flatMap(uid => s.usersById.get(uid))
    }

    def requireAuth(req: Request[IO])(f: User => IO[Response[IO]]): IO[Response[IO]] =
      getUserFromSession(req).flatMap {
        case Some(u) => f(u)
        case None    => jsonError(Status.Unauthorized, "Authentication required")
      }

    val dsl = new Http4sDsl[IO] {}
    import dsl._

    HttpRoutes.of[IO] {
      // POST /register
      case req @ POST -> Root / "register" =>
        req.attemptAs[RegisterReq].value.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(RegisterReq(username, password)) =>
            // Validate username
            if (!usernameRe.pattern.matcher(username).matches())
              jsonError(Status.BadRequest, "Invalid username")
            else if (password.length < 8)
              jsonError(Status.BadRequest, "Password too short")
            else {
              state.modify { s =>
                if (s.usersByName.contains(username)) (s, Left("exists"))
                else {
                  val id = s.nextUserId
                  val user = User(id, username, hashPassword(password))
                  val s2 = s.copy(
                    usersById = s.usersById + (id -> user),
                    usersByName = s.usersByName + (username -> id),
                    nextUserId = id + 1
                  )
                  (s2, Right(user))
                }
              }.flatMap {
                case Left(_) => jsonError(Status.Conflict, "Username already exists")
                case Right(user) =>
                  val body = UserOut.fromUser(user).asJson
                  Created(body)
              }
            }
        }

      // POST /login
      case req @ POST -> Root / "login" =>
        req.attemptAs[LoginReq].value.flatMap {
          case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
          case Right(LoginReq(username, password)) =>
            state.get.flatMap { s =>
              s.usersByName.get(username).flatMap(s.usersById.get) match {
                case None => jsonError(Status.Unauthorized, "Invalid credentials")
                case Some(user) =>
                  if (user.passwordHash != hashPassword(password))
                    jsonError(Status.Unauthorized, "Invalid credentials")
                  else for {
                    token <- UUIDGen[IO].randomUUID.map(_.toString.replace("-", ""))
                    _ <- state.update(st => st.copy(sessions = st.sessions + (token -> user.id)))
                    resp <- Ok(UserOut.fromUser(user).asJson).map(_.addCookie(ResponseCookie("session_id", token, path = Some("/"), httpOnly = true)))
                  } yield resp
              }
            }
        }

      // POST /logout
      case req @ POST -> Root / "logout" =>
        requireAuth(req) { _ =>
          val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
          tokenOpt match {
            case None => jsonError(Status.Unauthorized, "Authentication required")
            case Some(tok) =>
              state.update(s => s.copy(sessions = s.sessions - tok)) *> Ok(Json.obj())
          }
        }

      // GET /me
      case req @ GET -> Root / "me" =>
        requireAuth(req) { user => Ok(UserOut.fromUser(user).asJson) }

      // PUT /password
      case req @ PUT -> Root / "password" =>
        requireAuth(req) { user =>
          req.attemptAs[PasswordChangeReq].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(PasswordChangeReq(oldp, newp)) =>
              if (user.passwordHash != hashPassword(oldp)) jsonError(Status.Unauthorized, "Invalid credentials")
              else if (newp.length < 8) jsonError(Status.BadRequest, "Password too short")
              else state.modify { s =>
                s.usersById.get(user.id) match {
                  case Some(u) =>
                    val updated = u.copy(passwordHash = hashPassword(newp))
                    val s2 = s.copy(usersById = s.usersById + (u.id -> updated))
                    (s2, ())
                  case None => (s, ())
                }
              } *> Ok(Json.obj())
          }
        }

      // GET /todos
      case req @ GET -> Root / "todos" =>
        requireAuth(req) { user =>
          state.get.flatMap { s =>
            val items = s.todosById.values.filter(_.userId == user.id).toList.sortBy(_.id).map(TodoOut.fromTodo)
            Ok(items.asJson)
          }
        }

      // POST /todos
      case req @ POST -> Root / "todos" =>
        requireAuth(req) { user =>
          req.attemptAs[CreateTodoReq].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(CreateTodoReq(title, descOpt)) =>
              val titleValidated = Option(title).exists(_.nonEmpty)
              if (!titleValidated) jsonError(Status.BadRequest, "Title is required")
              else {
                val now = nowInstant
                state.modify { s =>
                  val id = s.nextTodoId
                  val todo = Todo(
                    id = id,
                    userId = user.id,
                    title = title,
                    description = descOpt.getOrElse(""),
                    completed = false,
                    createdAt = now,
                    updatedAt = now
                  )
                  val s2 = s.copy(todosById = s.todosById + (id -> todo), nextTodoId = id + 1)
                  (s2, todo)
                }.flatMap { todo =>
                  Created(TodoOut.fromTodo(todo).asJson)
                }
              }
          }
        }

      // GET /todos/:id
      case req @ GET -> Root / "todos" / IntVar(id) =>
        requireAuth(req) { user =>
          state.get.flatMap { s =>
            s.todosById.get(id) match {
              case Some(t) if t.userId == user.id => Ok(TodoOut.fromTodo(t).asJson)
              case _ => jsonError(Status.NotFound, "Todo not found")
            }
          }
        }

      // PUT /todos/:id (partial update)
      case req @ PUT -> Root / "todos" / IntVar(id) =>
        requireAuth(req) { user =>
          req.attemptAs[UpdateTodoReq].value.flatMap {
            case Left(_) => jsonError(Status.BadRequest, "Invalid JSON")
            case Right(body) =>
              // Validate title if present
              body.title match {
                case Some(t) if t.isEmpty => jsonError(Status.BadRequest, "Title is required")
                case _ =>
                  val now = nowInstant
                  state.modify { s =>
                    s.todosById.get(id) match {
                      case Some(t) if t.userId == user.id =>
                        val updated = t.copy(
                          title = body.title.getOrElse(t.title),
                          description = body.description.getOrElse(t.description),
                          completed = body.completed.getOrElse(t.completed),
                          updatedAt = now
                        )
                        val s2 = s.copy(todosById = s.todosById + (id -> updated))
                        (s2, Right(updated))
                      case _ => (s, Left(()))
                    }
                  }.flatMap {
                    case Left(_) => jsonError(Status.NotFound, "Todo not found")
                    case Right(todo) => Ok(TodoOut.fromTodo(todo).asJson)
                  }
              }
          }
        }

      // DELETE /todos/:id
      case req @ DELETE -> Root / "todos" / IntVar(id) =>
        requireAuth(req) { user =>
          state.modify { s =>
            s.todosById.get(id) match {
              case Some(t) if t.userId == user.id =>
                val s2 = s.copy(todosById = s.todosById - id)
                (s2, Right(()))
              case _ => (s, Left(()))
            }
          }.flatMap {
            case Left(_) => jsonError(Status.NotFound, "Todo not found")
            case Right(_) => NoContent()
          }
        }
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val defaultPort = 8080
    val port = args.sliding(2, 1).collectFirst {
      case List("--port", p) => p.toInt
    }.getOrElse(defaultPort)

    for {
      ref <- Ref.of[IO, State](State.empty)
      httpApp = JsonMiddleware(service(ref)).orNotFound
      _ <- org.http4s.ember.server.EmberServerBuilder.default[IO]
        .withHost(ipv4"0.0.0.0")
        .withPort(Port.fromInt(port).get)
        .withHttpApp(httpApp)
        .build
        .use(_ => IO.never)
    } yield ExitCode.Success
  }
}
