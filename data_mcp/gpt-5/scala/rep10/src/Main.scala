//> using scala "2.13.12"
//> using dep "org.http4s::http4s-ember-server:0.23.26"
//> using dep "org.http4s::http4s-dsl:0.23.26"
//> using dep "org.http4s::http4s-circe:0.23.26"
//> using dep "io.circe::circe-generic:0.14.7"
//> using dep "io.circe::circe-parser:0.14.7"
//> using dep "org.typelevel::cats-effect:3.5.4"

import cats.effect._
import cats.implicits._
import cats.data.Kleisli
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe._
import org.http4s.headers.`Content-Type`
import org.http4s.ember.server.EmberServerBuilder
import com.comcast.ip4s._

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID

object Main extends IOApp {

  case class User(id: Int, username: String)
  case class UserRecord(user: User, password: String)

  case class Todo(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )
  case class TodoRecord(ownerId: Int, todo: Todo)

  case class RegisterRequest(username: String, password: String)
  case class LoginRequest(username: String, password: String)
  case class PasswordChange(old_password: String, new_password: String)
  case class CreateTodoRequest(title: String, description: Option[String])
  case class UpdateTodoRequest(title: Option[String], description: Option[String], completed: Option[Boolean])

  implicit val userEnc: Encoder[User] = deriveEncoder
  implicit val todoEnc: Encoder[Todo] = deriveEncoder

  implicit val regDec: Decoder[RegisterRequest] = deriveDecoder
  implicit val loginDec: Decoder[LoginRequest] = deriveDecoder
  implicit val pwDec: Decoder[PasswordChange] = deriveDecoder
  implicit val createTodoDec: Decoder[CreateTodoRequest] = deriveDecoder
  implicit val updateTodoDec: Decoder[UpdateTodoRequest] = deriveDecoder

  private def nowTrunc(): Instant = Instant.now().truncatedTo(ChronoUnit.SECONDS)
  private def fmt(i: Instant): String = DateTimeFormatter.ISO_INSTANT.format(i)
  private def nowIso(): String = fmt(nowTrunc())
  private def nextIso(prevIso: String): String = {
    val prev = scala.util.Try(Instant.parse(prevIso)).getOrElse(Instant.EPOCH)
    val now = nowTrunc()
    val chosen = if (now.isAfter(prev)) now else prev.plusSeconds(1)
    fmt(chosen)
  }

  case class State(
      nextUserId: Int,
      usersById: Map[Int, UserRecord],
      usersByName: Map[String, Int],
      nextTodoId: Int,
      todos: Map[Int, TodoRecord],
      sessions: Map[String, Int] // token -> userId
  )

  object State {
    val empty: State = State(1, Map.empty, Map.empty, 1, Map.empty, Map.empty)
  }

  class Store(ref: Ref[IO, State]) {

    def createUser(username: String, password: String): IO[Either[String, User]] =
      ref.modify { s =>
        if (s.usersByName.contains(username)) (s, Left("Username already exists"))
        else {
          val u = User(s.nextUserId, username)
          val rec = UserRecord(u, password)
          val s2 = s.copy(
            nextUserId = s.nextUserId + 1,
            usersById = s.usersById + (u.id -> rec),
            usersByName = s.usersByName + (username -> u.id)
          )
          (s2, Right(u))
        }
      }

    def findUserByName(username: String): IO[Option[UserRecord]] =
      ref.get.map { s => s.usersByName.get(username).flatMap(id => s.usersById.get(id)) }

    def getUser(id: Int): IO[Option[UserRecord]] = ref.get.map(_.usersById.get(id))

    def updatePassword(userId: Int, newPassword: String): IO[Unit] =
      ref.update { s =>
        s.usersById.get(userId) match {
          case Some(ur) => s.copy(usersById = s.usersById.updated(userId, ur.copy(password = newPassword)))
          case None     => s // should not happen
        }
      }

    def createSession(userId: Int): IO[String] =
      IO(UUID.randomUUID().toString.replaceAll("-", "")).flatMap { token =>
        ref.update(s => s.copy(sessions = s.sessions + (token -> userId))).as(token)
      }

    def invalidateSession(token: String): IO[Unit] =
      ref.update(s => s.copy(sessions = s.sessions - token))

    def findUserIdBySession(token: String): IO[Option[Int]] =
      ref.get.map(_.sessions.get(token))

    def createTodo(ownerId: Int, title: String, description: String): IO[Todo] =
      ref.modify { s =>
        val id = s.nextTodoId
        val ts = nowIso()
        val todo = Todo(id, title, description, completed = false, created_at = ts, updated_at = ts)
        val s2 = s.copy(
          nextTodoId = id + 1,
          todos = s.todos + (id -> TodoRecord(ownerId, todo))
        )
        (s2, todo)
      }

    def listTodos(ownerId: Int): IO[List[Todo]] =
      ref.get.map { s =>
        s.todos.valuesIterator.collect { case tr if tr.ownerId == ownerId => tr.todo }.toList.sortBy(_.id)
      }

    def getTodo(ownerId: Int, id: Int): IO[Option[Todo]] =
      ref.get.map(_.todos.get(id).filter(_.ownerId == ownerId).map(_.todo))

    def updateTodo(ownerId: Int, id: Int)(f: Todo => Todo): IO[Either[Unit, Todo]] =
      ref.modify { s =>
        s.todos.get(id) match {
          case Some(tr) if tr.ownerId == ownerId =>
            val updated = f(tr.todo)
            val s2 = s.copy(todos = s.todos.updated(id, tr.copy(todo = updated)))
            (s2, Right(updated))
          case Some(_) => (s, Left(())) // belongs to another user
          case None    => (s, Left(()))
        }
      }

    def deleteTodo(ownerId: Int, id: Int): IO[Boolean] =
      ref.modify { s =>
        s.todos.get(id) match {
          case Some(tr) if tr.ownerId == ownerId =>
            (s.copy(todos = s.todos - id), true)
          case _ => (s, false)
        }
      }
  }

  private val usernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private def jsonError(status: Status, msg: String): IO[Response[IO]] =
    Response[IO](status = status).withEntity(Json.obj("error" -> Json.fromString(msg))).pure[IO]

  private def withJson[A](resp: IO[Response[IO]]): IO[Response[IO]] =
    resp.map(_.putHeaders(`Content-Type`(MediaType.application.json)))

  private def authUser(store: Store, req: Request[IO]): IO[Either[Response[IO], (Int, String)]] = {
    val tokenOpt = req.cookies.find(_.name == "session_id").map(_.content)
    tokenOpt match {
      case None => withJson(jsonError(Status.Unauthorized, "Authentication required")).map(Left(_))
      case Some(token) =>
        store.findUserIdBySession(token).flatMap {
          case Some(uid) => IO.pure(Right((uid, token)))
          case None => withJson(jsonError(Status.Unauthorized, "Authentication required")).map(Left(_))
        }
    }
  }

  def routes(store: Store): HttpRoutes[IO] = {

    HttpRoutes.of[IO] {
      // Register
      case req @ POST -> Root / "register" =>
        req.asJsonAttempt.flatMap {
          case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
          case Right(json) =>
            json.as[RegisterRequest] match {
              case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
              case Right(RegisterRequest(username, password)) =>
                if (!usernameRegex.pattern.matcher(username).matches())
                  withJson(jsonError(Status.BadRequest, "Invalid username"))
                else if (password == null || password.length < 8)
                  withJson(jsonError(Status.BadRequest, "Password too short"))
                else {
                  store.createUser(username, password).flatMap {
                    case Left(_) => withJson(jsonError(Status.Conflict, "Username already exists"))
                    case Right(user) =>
                      withJson(Created(user.asJson))
                  }
                }
            }
        }

      // Login
      case req @ POST -> Root / "login" =>
        req.asJsonAttempt.flatMap {
          case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
          case Right(json) =>
            json.as[LoginRequest] match {
              case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
              case Right(LoginRequest(username, password)) =>
                store.findUserByName(username).flatMap {
                  case Some(UserRecord(user, pw)) if pw == password =>
                    for {
                      token <- store.createSession(user.id)
                      cookie = ResponseCookie(name = "session_id", content = token, path = Some("/"), httpOnly = true)
                      res <- Ok(user.asJson)
                    } yield res.putHeaders(`Content-Type`(MediaType.application.json)).addCookie(cookie)
                  case _ => withJson(jsonError(Status.Unauthorized, "Invalid credentials"))
                }
            }
        }

      // Logout
      case req @ POST -> Root / "logout" =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((_, token)) =>
            store.invalidateSession(token) *> withJson(Ok(Json.obj()))
        }

      // Me
      case req @ GET -> Root / "me" =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            store.getUser(uid).flatMap {
              case Some(ur) => withJson(Ok(ur.user.asJson))
              case None => withJson(jsonError(Status.InternalServerError, "User not found"))
            }
        }

      // Change password
      case req @ PUT -> Root / "password" =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            req.asJsonAttempt.flatMap {
              case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
              case Right(json) =>
                json.as[PasswordChange] match {
                  case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
                  case Right(PasswordChange(oldp, newp)) =>
                    store.getUser(uid).flatMap {
                      case Some(ur) if ur.password == oldp =>
                        if (newp == null || newp.length < 8)
                          withJson(jsonError(Status.BadRequest, "Password too short"))
                        else store.updatePassword(uid, newp) *> withJson(Ok(Json.obj()))
                      case _ => withJson(jsonError(Status.Unauthorized, "Invalid credentials"))
                    }
                }
            }
        }

      // List todos
      case req @ GET -> Root / "todos" =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            store.listTodos(uid).flatMap(ts => withJson(Ok(ts.asJson)))
        }

      // Create todo
      case req @ POST -> Root / "todos" =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            req.asJsonAttempt.flatMap {
              case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
              case Right(json) =>
                json.as[CreateTodoRequest] match {
                  case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
                  case Right(CreateTodoRequest(title, descOpt)) =>
                    val titleValid = Option(title).exists(_.trim.nonEmpty)
                    if (!titleValid) withJson(jsonError(Status.BadRequest, "Title is required"))
                    else {
                      val desc = descOpt.getOrElse("")
                      store.createTodo(uid, title.trim, desc).flatMap(t => withJson(Created(t.asJson)))
                    }
                }
            }
        }

      // Get todo by id
      case req @ GET -> Root / "todos" / IntVar(id) =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            store.getTodo(uid, id).flatMap {
              case Some(t) => withJson(Ok(t.asJson))
              case None    => withJson(jsonError(Status.NotFound, "Todo not found"))
            }
        }

      // Update todo
      case req @ PUT -> Root / "todos" / IntVar(id) =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            req.asJsonAttempt.flatMap {
              case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
              case Right(json) =>
                json.as[UpdateTodoRequest] match {
                  case Left(_) => withJson(jsonError(Status.BadRequest, "Invalid JSON"))
                  case Right(UpdateTodoRequest(titleOpt, descOpt, completedOpt)) =>
                    titleOpt match {
                      case Some(t) if t.trim.isEmpty => withJson(jsonError(Status.BadRequest, "Title is required"))
                      case _ =>
                        store.updateTodo(uid, id) { todo =>
                          val nt = titleOpt.map(_.trim).filter(_.nonEmpty).getOrElse(todo.title)
                          val nd = descOpt.getOrElse(todo.description)
                          val nc = completedOpt.getOrElse(todo.completed)
                          todo.copy(title = nt, description = nd, completed = nc, updated_at = nextIso(todo.updated_at))
                        }.flatMap {
                          case Right(updated) => withJson(Ok(updated.asJson))
                          case Left(_)        => withJson(jsonError(Status.NotFound, "Todo not found"))
                        }
                    }
                }
            }
        }

      // Delete todo
      case req @ DELETE -> Root / "todos" / IntVar(id) =>
        authUser(store, req).flatMap {
          case Left(resp) => IO.pure(resp)
          case Right((uid, _)) =>
            store.deleteTodo(uid, id).flatMap {
              case true  => NoContent() // 204, no body
              case false => withJson(jsonError(Status.NotFound, "Todo not found"))
            }
        }
    }
  }

  implicit class RequestOps(val req: Request[IO]) extends AnyVal {
    def asJsonAttempt: IO[Either[Throwable, Json]] = req.as[Json].attempt
  }

  private def withJsonMiddleware(routes: HttpRoutes[IO]): HttpRoutes[IO] = {
    Kleisli { (req: Request[IO]) =>
      routes.run(req).map { resp =>
        if (resp.status.code == 204) resp else resp.putHeaders(`Content-Type`(MediaType.application.json))
      }
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val port = parsePortArg(args).getOrElse(8080)
    for {
      ref <- Ref.of[IO, State](State.empty)
      store = new Store(ref)
      httpApp = withJsonMiddleware(routes(store)).orNotFound
      _ <- EmberServerBuilder.default[IO]
            .withHost(ipv4"0.0.0.0")
            .withPort(Port.fromInt(port).get)
            .withHttpApp(httpApp)
            .build
            .useForever
    } yield ExitCode.Success
  }

  private def parsePortArg(args: List[String]): Option[Int] = {
    args.sliding(2, 1).collectFirst {
      case List("--port", p) => p.toIntOption
    }.flatten
  }
}
