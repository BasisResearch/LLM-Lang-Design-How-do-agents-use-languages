//> using scala "3.3.1"
//> using dep "org.http4s::http4s-ember-server:0.23.34"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-core:0.14.15"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"
//> using dep "org.typelevel::cats-effect:3.5.4"

package todoapp

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe._
import io.circe._
import io.circe.syntax._
import io.circe.parser._
import java.time._
import java.time.temporal.ChronoUnit
import org.http4s.ember.server.EmberServerBuilder
import com.comcast.ip4s._

object Server extends IOApp {

  case class User(id: Int, username: String, password: String)

  case class TodoInt(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: Instant,
      updatedAt: Instant
  )

  // Custom Encoder for Todo as per spec (snake_case timestamps)
  given Encoder[TodoInt] = new Encoder[TodoInt] {
    final def apply(t: TodoInt): Json = Json.obj(
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
        Json.fromString(t.createdAt.truncatedTo(ChronoUnit.SECONDS).toString)
      ),
      (
        "updated_at",
        Json.fromString(t.updatedAt.truncatedTo(ChronoUnit.SECONDS).toString)
      )
    )
  }

  // Simple encoder for user response
  case class UserResp(id: Int, username: String)
  given Encoder[UserResp] = Encoder.forProduct2("id", "username")(u => (u.id, u.username))

  // Requests (decoders)
  case class RegisterReq(username: String, password: String)
  given Decoder[RegisterReq] = Decoder.forProduct2("username", "password")(RegisterReq.apply)

  case class LoginReq(username: String, password: String)
  given Decoder[LoginReq] = Decoder.forProduct2("username", "password")(LoginReq.apply)

  case class PasswordChangeReq(old_password: String, new_password: String)
  given Decoder[PasswordChangeReq] = Decoder.forProduct2("old_password", "new_password")(PasswordChangeReq.apply)

  case class CreateTodoReq(title: String, description: Option[String])
  given Decoder[CreateTodoReq] = Decoder.instance { c =>
    for {
      title <- c.downField("title").as[String]
      desc <- c.downField("description").as[Option[String]]
    } yield CreateTodoReq(title, desc)
  }

  case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])
  given Decoder[UpdateTodoReq] = Decoder.instance { c =>
    for {
      t <- c.downField("title").as[Option[String]]
      d <- c.downField("description").as[Option[String]]
      comp <- c.downField("completed").as[Option[Boolean]]
    } yield UpdateTodoReq(t, d, comp)
  }

  // State storage
  case class State(
      users: Ref[IO, Map[Int, User]],
      usersByName: Ref[IO, Map[String, Int]],
      userCounter: Ref[IO, Int],
      todos: Ref[IO, Map[Int, TodoInt]],
      todoCounter: Ref[IO, Int],
      sessions: Ref[IO, Map[String, Int]]
  )

  private val usernameRegex = "^[a-zA-Z0-9_]+$".r

  def now(): Instant = Instant.now().truncatedTo(ChronoUnit.SECONDS)

  def jsonError(msg: String, status: Status): IO[Response[IO]] =
    Response[IO](status).withEntity(Json.obj("error" -> Json.fromString(msg))).pure[IO]

  // Auth helper
  def withAuth(state: State, req: Request[IO])(f: User => IO[Response[IO]]): IO[Response[IO]] = {
    val maybeToken = req.cookies.find(_.name == "session_id").map(_.content)
    maybeToken match {
      case None => jsonError("Authentication required", Status.Unauthorized)
      case Some(token) =>
        state.sessions.get.flatMap { sessMap =>
          sessMap.get(token) match {
            case None => jsonError("Authentication required", Status.Unauthorized)
            case Some(uid) =>
              state.users.get.flatMap { umap =>
                umap.get(uid) match {
                  case None => jsonError("Authentication required", Status.Unauthorized)
                  case Some(user) => f(user)
                }
              }
          }
        }
    }
  }

  def routes(state: State): HttpRoutes[IO] = HttpRoutes.of[IO] { req =>
    req match {
      // POST /register
      case req @ POST -> Root / "register" =>
        req.as[Json].attempt.flatMap {
          case Left(_) => jsonError("Invalid username", Status.BadRequest) // generic on bad/missing
          case Right(json) =>
            val c = json.hcursor
            val usernameOpt = c.downField("username").as[String].toOption
            val passwordOpt = c.downField("password").as[String].toOption

            val validated: Either[(Status, String), (String, String)] = for {
              username <- usernameOpt.toRight((Status.BadRequest, "Invalid username"))
              _ <- Either.cond(username.length >= 3 && username.length <= 50 && usernameRegex.matches(username), (), (Status.BadRequest, "Invalid username"))
              password <- passwordOpt.toRight((Status.BadRequest, "Password too short"))
              _ <- Either.cond(password.length >= 8, (), (Status.BadRequest, "Password too short"))
            } yield (username, password)

            validated match {
              case Left((status, msg)) => jsonError(msg, status)
              case Right((username, password)) =>
                for {
                  exists <- state.usersByName.get.map(_.contains(username))
                  resp <- if (exists) jsonError("Username already exists", Status.Conflict)
                          else for {
                            id <- state.userCounter.modify(n => (n + 1, n + 1))
                            user = User(id, username, password)
                            _ <- state.users.update(_ + (id -> user))
                            _ <- state.usersByName.update(_ + (username -> id))
                            out = UserResp(id, username).asJson
                            r <- Created(out)
                          } yield r
                } yield resp
            }
        }

      // POST /login
      case req @ POST -> Root / "login" =>
        req.as[Json].attempt.flatMap {
          case Left(_) => jsonError("Invalid credentials", Status.Unauthorized)
          case Right(json) =>
            json.as[LoginReq] match {
              case Left(_) => jsonError("Invalid credentials", Status.Unauthorized)
              case Right(LoginReq(username, password)) =>
                for {
                  usersByName <- state.usersByName.get
                  maybeId = usersByName.get(username)
                  resp <- maybeId match {
                    case None => jsonError("Invalid credentials", Status.Unauthorized)
                    case Some(uid) =>
                      state.users.get.map(_.get(uid)).flatMap {
                        case None => jsonError("Invalid credentials", Status.Unauthorized)
                        case Some(user) =>
                          if (user.password != password) jsonError("Invalid credentials", Status.Unauthorized)
                          else {
                            val token = java.util.UUID.randomUUID().toString.replaceAll("-", "")
                            for {
                              _ <- state.sessions.update(_ + (token -> user.id))
                              res <- Ok(UserResp(user.id, user.username).asJson)
                              cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
                              finalRes = res.addCookie(cookie)
                            } yield finalRes
                          }
                      }
                  }
                } yield resp
            }
        }

      // POST /logout
      case req @ POST -> Root / "logout" =>
        withAuth(state, req) { _ =>
          val maybeToken = req.cookies.find(_.name == "session_id").map(_.content)
          maybeToken match {
            case None => jsonError("Authentication required", Status.Unauthorized)
            case Some(token) =>
              for {
                _ <- state.sessions.update(_ - token)
                res <- Ok(Json.obj())
              } yield res
          }
        }

      // GET /me
      case req @ GET -> Root / "me" =>
        withAuth(state, req) { user =>
          Ok(UserResp(user.id, user.username).asJson)
        }

      // PUT /password
      case req @ PUT -> Root / "password" =>
        withAuth(state, req) { user =>
          req.as[Json].attempt.flatMap {
            case Left(_) => jsonError("Invalid credentials", Status.Unauthorized)
            case Right(json) =>
              json.as[PasswordChangeReq] match {
                case Left(_) => jsonError("Invalid credentials", Status.Unauthorized)
                case Right(PasswordChangeReq(oldPwd, newPwd)) =>
                  if (oldPwd != user.password) jsonError("Invalid credentials", Status.Unauthorized)
                  else if (newPwd.length < 8) jsonError("Password too short", Status.BadRequest)
                  else {
                    for {
                      _ <- state.users.update(m => m.updated(user.id, user.copy(password = newPwd)))
                      res <- Ok(Json.obj())
                    } yield res
                  }
              }
          }
        }

      // GET /todos
      case req @ GET -> Root / "todos" =>
        withAuth(state, req) { user =>
          for {
            all <- state.todos.get
            mine = all.values.filter(_.userId == user.id).toList.sortBy(_.id)
            res <- Ok(mine.asJson)
          } yield res
        }

      // POST /todos
      case req @ POST -> Root / "todos" =>
        withAuth(state, req) { user =>
          req.as[Json].attempt.flatMap {
            case Left(_) => jsonError("Title is required", Status.BadRequest)
            case Right(json) =>
              json.as[CreateTodoReq] match {
                case Left(_) => jsonError("Title is required", Status.BadRequest)
                case Right(CreateTodoReq(title, desc)) =>
                  if (title.trim.isEmpty) jsonError("Title is required", Status.BadRequest)
                  else {
                    val nowTs = now()
                    for {
                      id <- state.todoCounter.modify(n => (n + 1, n + 1))
                      todo = TodoInt(id, user.id, title.trim, desc.getOrElse(""), completed = false, createdAt = nowTs, updatedAt = nowTs)
                      _ <- state.todos.update(_ + (id -> todo))
                      res <- Created(todo.asJson)
                    } yield res
                  }
              }
          }
        }

      // GET /todos/:id
      case req @ GET -> Root / "todos" / IntVar(id) =>
        withAuth(state, req) { user =>
          for {
            all <- state.todos.get
            res <- all.get(id) match {
              case Some(t) if t.userId == user.id => Ok(t.asJson)
              case _ => jsonError("Todo not found", Status.NotFound)
            }
          } yield res
        }

      // PUT /todos/:id
      case req @ PUT -> Root / "todos" / IntVar(id) =>
        withAuth(state, req) { user =>
          req.as[Json].attempt.flatMap {
            case Left(_) => jsonError("Todo not found", Status.NotFound)
            case Right(json) =>
              json.as[UpdateTodoReq] match {
                case Left(_) => jsonError("Todo not found", Status.NotFound)
                case Right(UpdateTodoReq(titleOpt, descOpt, compOpt)) =>
                  titleOpt match {
                    case Some(t) if t.trim.isEmpty => jsonError("Title is required", Status.BadRequest)
                    case _ =>
                      for {
                        maybeTodo <- state.todos.get.map(_.get(id))
                        res <- maybeTodo match {
                          case None => jsonError("Todo not found", Status.NotFound)
                          case Some(todo) if todo.userId != user.id => jsonError("Todo not found", Status.NotFound)
                          case Some(todo) =>
                            val updated = todo.copy(
                              title = titleOpt.map(_.trim).getOrElse(todo.title),
                              description = descOpt.getOrElse(todo.description),
                              completed = compOpt.getOrElse(todo.completed),
                              updatedAt = now()
                            )
                            for {
                              _ <- state.todos.update(_ + (id -> updated))
                              r <- Ok(updated.asJson)
                            } yield r
                        }
                      } yield res
                  }
              }
          }
        }

      // DELETE /todos/:id
      case req @ DELETE -> Root / "todos" / IntVar(id) =>
        withAuth(state, req) { user =>
          for {
            maybe <- state.todos.get.map(_.get(id))
            res <- maybe match {
              case Some(t) if t.userId == user.id =>
                state.todos.update(_ - id) *> NoContent()
              case _ => jsonError("Todo not found", Status.NotFound)
            }
          } yield res
        }
    }
  }

  private def httpApp(state: State): HttpApp[IO] = HttpApp[IO] { req =>
    routes(state).run(req).value.flatMap {
      case Some(resp) =>
        // Ensure Content-Type application/json for all responses with an entity except DELETE
        val needsJson = req.method != Method.DELETE
        val resp2 = if (needsJson) resp.putHeaders(headers.`Content-Type`(MediaType.application.json)) else resp
        IO.pure(resp2)
      case None =>
        jsonError("Not found", Status.NotFound)
    }
  }

  override def run(args: List[String]): IO[ExitCode] = {
    for {
      // Initialize in-memory state
      usersRef <- Ref.of[IO, Map[Int, User]](Map.empty)
      usersByNameRef <- Ref.of[IO, Map[String, Int]](Map.empty)
      userCounterRef <- Ref.of[IO, Int](0)
      todosRef <- Ref.of[IO, Map[Int, TodoInt]](Map.empty)
      todoCounterRef <- Ref.of[IO, Int](0)
      sessionsRef <- Ref.of[IO, Map[String, Int]](Map.empty)

      state = State(usersRef, usersByNameRef, userCounterRef, todosRef, todoCounterRef, sessionsRef)

      port = parsePort(args).getOrElse(8080)

      _ <- EmberServerBuilder.default[IO]
        .withHost(ipv4"0.0.0.0")
        .withPort(Port.fromInt(port).get)
        .withHttpApp(httpApp(state))
        .build
        .useForever
    } yield ExitCode.Success
  }

  private def parsePort(args: List[String]): Option[Int] = {
    args.sliding(2).collectFirst {
      case List("--port", p) => p
    }.flatMap(s => scala.util.Try(s.toInt).toOption).filter(p => p > 0 && p < 65536)
  }
}
