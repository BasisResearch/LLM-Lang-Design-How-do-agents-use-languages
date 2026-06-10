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
import org.http4s.dsl.Http4sDsl
import org.http4s.ember.server._
import org.http4s.implicits._
import org.http4s.circe._
import org.http4s.circe.CirceEntityDecoder._
import org.http4s.circe.CirceEntityEncoder._
import io.circe._
import io.circe.syntax._
import io.circe.generic.semiauto._
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._
import java.time.Instant
import java.time.temporal.ChronoUnit
import com.comcast.ip4s._

object Main extends IOApp {

  final case class User(id: Int, username: String, password: String)
  object User {
    implicit val userEncoder: Encoder[User] = new Encoder[User] {
      def apply(u: User): Json = Json.obj(
        "id" -> Json.fromInt(u.id),
        "username" -> Json.fromString(u.username)
      )
    }
  }

  final case class Todo(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String,
      ownerId: Int
  )
  object Todo {
    implicit val todoEncoder: Encoder[Todo] = new Encoder[Todo] {
      def apply(t: Todo): Json = Json.obj(
        "id" -> Json.fromInt(t.id),
        "title" -> Json.fromString(t.title),
        "description" -> Json.fromString(t.description),
        "completed" -> Json.fromBoolean(t.completed),
        "created_at" -> Json.fromString(t.created_at),
        "updated_at" -> Json.fromString(t.updated_at)
      )
    }
  }

  // Request DTOs
  final case class RegisterReq(username: String, password: String)
  object RegisterReq { implicit val dec: Decoder[RegisterReq] = deriveDecoder }

  final case class LoginReq(username: String, password: String)
  object LoginReq { implicit val dec: Decoder[LoginReq] = deriveDecoder }

  final case class PasswordChangeReq(old_password: String, new_password: String)
  object PasswordChangeReq { implicit val dec: Decoder[PasswordChangeReq] = deriveDecoder }

  final case class CreateTodoReq(title: String, description: Option[String])
  object CreateTodoReq { implicit val dec: Decoder[CreateTodoReq] = deriveDecoder }

  final case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])
  object UpdateTodoReq { implicit val dec: Decoder[UpdateTodoReq] = deriveDecoder }

  // In-memory stores
  private val userIdGen = new AtomicInteger(0)
  private val todoIdGen = new AtomicInteger(0)
  private val usersById = new ConcurrentHashMap[Int, User]()
  private val usersByUsername = new ConcurrentHashMap[String, User]()
  private val sessions = new ConcurrentHashMap[String, Int]() // token -> userId
  private val todosById = new ConcurrentHashMap[Int, Todo]()
  private val usersLock = new Object()

  private val cookieName = "session_id"

  private def nowTs(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString

  private def jsonError(status: Status, msg: String): IO[Response[IO]] = {
    val body = Json.obj("error" -> Json.fromString(msg))
    IO.pure(Response[IO](status).withEntity(body))
  }

  private def readJson[A: Decoder](req: Request[IO]): IO[Either[Response[IO], A]] =
    req.attemptAs[Json].value.flatMap {
      case Left(_) => jsonError(Status.BadRequest, "Invalid request").map(Left(_))
      case Right(json) =>
        json.as[A] match {
          case Left(_)  => jsonError(Status.BadRequest, "Invalid request").map(Left(_))
          case Right(a) => IO.pure(Right(a))
        }
    }

  private def withAuth(req: Request[IO])(f: User => IO[Response[IO]]): IO[Response[IO]] = {
    val maybeToken = req.cookies.find(_.name == cookieName).map(_.content)
    maybeToken match {
      case None => jsonError(Status.Unauthorized, "Authentication required")
      case Some(token) =>
        val uid = sessions.get(token)
        if (uid == 0 && !sessions.containsKey(token)) then
          jsonError(Status.Unauthorized, "Authentication required")
        else {
          val user = usersById.get(uid)
          if (user == null) jsonError(Status.Unauthorized, "Authentication required")
          else f(user)
        }
    }
  }

  private def register(username: String, password: String): Either[Response[IO], User] = {
    val validUser = username.matches("^[a-zA-Z0-9_]{3,50}$")
    if (!validUser) return Left(Response[IO](Status.BadRequest).withEntity(Json.obj("error" -> Json.fromString("Invalid username"))))
    if (password.length < 8) return Left(Response[IO](Status.BadRequest).withEntity(Json.obj("error" -> Json.fromString("Password too short"))))

    usersLock.synchronized {
      if (usersByUsername.containsKey(username))
        Left(Response[IO](Status.Conflict).withEntity(Json.obj("error" -> Json.fromString("Username already exists"))))
      else {
        val id = userIdGen.incrementAndGet()
        val user = User(id, username, password)
        usersById.put(id, user)
        usersByUsername.put(username, user)
        Right(user)
      }
    }
  }

  private def createSession(userId: Int): String = {
    val token = UUID.randomUUID().toString.replaceAll("-", "")
    sessions.put(token, userId)
    token
  }

  private def invalidateSession(token: String): Unit = {
    sessions.remove(token)
  }

  private def parseTodoId(s: String): Option[Int] =
    try Some(s.toInt) catch { case _: NumberFormatException => None }

  private def routes: HttpRoutes[IO] = {
    val dsl = new Http4sDsl[IO] {}
    import dsl._

    HttpRoutes.of[IO] {
      // Register
      case req @ POST -> Root / "register" =>
        readJson[RegisterReq](req).flatMap {
          case Left(err) => IO.pure(err)
          case Right(RegisterReq(username, password)) =>
            register(username, password) match {
              case Left(resp) => IO.pure(resp)
              case Right(user) => Created(user.asJson)
            }
        }

      // Login
      case req @ POST -> Root / "login" =>
        readJson[LoginReq](req).flatMap {
          case Left(err) => IO.pure(err)
          case Right(LoginReq(username, password)) =>
            val user = usersByUsername.get(username)
            if (user == null || user.password != password)
              jsonError(Status.Unauthorized, "Invalid credentials")
            else {
              val token = createSession(user.id)
              val cookie = ResponseCookie(name = cookieName, content = token, path = Some("/"), httpOnly = true)
              Ok(user.asJson).map(_.addCookie(cookie))
            }
        }

      // Logout
      case req @ POST -> Root / "logout" =>
        withAuth(req) { _ =>
          req.cookies.find(_.name == cookieName).map(_.content) match {
            case Some(token) =>
              IO(invalidateSession(token)) *> Ok(Json.obj())
            case None => jsonError(Status.Unauthorized, "Authentication required")
          }
        }

      // Me
      case req @ GET -> Root / "me" =>
        withAuth(req) { user => Ok(user.asJson) }

      // Change password
      case req @ PUT -> Root / "password" =>
        withAuth(req) { user =>
          readJson[PasswordChangeReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(PasswordChangeReq(oldp, newp)) =>
              if (oldp != user.password) jsonError(Status.Unauthorized, "Invalid credentials")
              else if (newp.length < 8) jsonError(Status.BadRequest, "Password too short")
              else IO {
                val updated = user.copy(password = newp)
                usersLock.synchronized {
                  usersById.put(user.id, updated)
                  usersByUsername.put(user.username, updated)
                }
              } *> Ok(Json.obj())
          }
        }

      // List todos
      case req @ GET -> Root / "todos" =>
        withAuth(req) { user =>
          val todos = todosById.values().asScala.toVector.filter(_.ownerId == user.id).sortBy(_.id)
          Ok(Json.arr(todos.map(_.asJson): _*))
        }

      // Create todo
      case req @ POST -> Root / "todos" =>
        withAuth(req) { user =>
          readJson[CreateTodoReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(CreateTodoReq(title, description)) =>
              val t = title.trim
              if (t.isEmpty) jsonError(Status.BadRequest, "Title is required")
              else IO {
                val id = todoIdGen.incrementAndGet()
                val now = nowTs()
                val todo = Todo(id, t, description.getOrElse(""), completed = false, created_at = now, updated_at = now, ownerId = user.id)
                todosById.put(id, todo)
                todo
              }.flatMap(todo => Created(todo.asJson))
          }
        }

      // Get todo by id
      case req @ GET -> Root / "todos" / idStr =>
        withAuth(req) { user =>
          parseTodoId(idStr) match {
            case None => jsonError(Status.NotFound, "Todo not found")
            case Some(id) =>
              val todo = todosById.get(id)
              if (todo == null || todo.ownerId != user.id) jsonError(Status.NotFound, "Todo not found")
              else Ok(todo.asJson)
          }
        }

      // Update todo (partial)
      case req @ PUT -> Root / "todos" / idStr =>
        withAuth(req) { user =>
          parseTodoId(idStr) match {
            case None => jsonError(Status.NotFound, "Todo not found")
            case Some(id) =>
              readJson[UpdateTodoReq](req).flatMap {
                case Left(err) => IO.pure(err)
                case Right(UpdateTodoReq(titleOpt, descOpt, compOpt)) =>
                  val existing = todosById.get(id)
                  if (existing == null || existing.ownerId != user.id) jsonError(Status.NotFound, "Todo not found")
                  else {
                    titleOpt match {
                      case Some(t) if t.trim.isEmpty => jsonError(Status.BadRequest, "Title is required")
                      case _ => IO {
                        val newTitle = titleOpt.map(_.trim).filter(_.nonEmpty).getOrElse(existing.title)
                        val newDesc = descOpt.getOrElse(existing.description)
                        val newComp = compOpt.getOrElse(existing.completed)
                        val updated = existing.copy(title = newTitle, description = newDesc, completed = newComp, updated_at = nowTs())
                        todosById.put(id, updated)
                        updated
                      }.flatMap(t => Ok(t.asJson))
                    }
                  }
              }
          }
        }

      // Delete todo
      case req @ DELETE -> Root / "todos" / idStr =>
        withAuth(req) { user =>
          parseTodoId(idStr) match {
            case None => jsonError(Status.NotFound, "Todo not found")
            case Some(id) =>
              val todo = todosById.get(id)
              if (todo == null || todo.ownerId != user.id) jsonError(Status.NotFound, "Todo not found")
              else IO {
                todosById.remove(id)
              } *> NoContent()
          }
        }
    }
  }

  def run(args: List[String]): IO[ExitCode] = {
    val (port, _) = parseArgs(args)

    val httpApp = routes.orNotFound

    EmberServerBuilder.default[IO]
      .withHost(ipv4"0.0.0.0")
      .withPort(Port.fromInt(port).get)
      .withHttpApp(httpApp)
      .build
      .useForever
      .as(ExitCode.Success)
  }

  private def parseArgs(args: List[String]): (Int, List[String]) = {
    def loop(xs: List[String], port: Int, rest: List[String]): (Int, List[String]) = xs match {
      case "--port" :: p :: tail => loop(tail, p.toIntOption.getOrElse(port), rest)
      case arg :: tail            => loop(tail, port, rest :+ arg)
      case Nil                    => (if (port == 0) 8080 else port, rest)
    }
    loop(args, 0, Nil)
  }
}
