//> using scala "3.4.2"
//> using dep "com.softwaremill.sttp.tapir::tapir-http4s-server:1.10.7"
//> using dep "org.http4s::http4s-ember-server:0.23.26"
//> using dep "org.http4s::http4s-circe:0.23.26"
//> using dep "io.circe::circe-generic:0.14.7"
//> using dep "io.circe::circe-parser:0.14.7"
//> using dep "ch.qos.logback:logback-classic:1.5.6"

import cats.effect._
import cats.syntax.all._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.implicits._
import org.http4s.circe._
import io.circe._
import io.circe.generic.semiauto._
import io.circe.syntax._
import java.time._
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import scala.jdk.CollectionConverters._
import com.comcast.ip4s._

object Main extends IOApp.Simple:

  case class User(id: Int, username: String)
  case class UserWithPassword(user: User, password: String)

  case class Todo(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )

  given Encoder[User] = deriveEncoder
  given Decoder[User] = deriveDecoder

  given Encoder[Todo] = deriveEncoder
  given Decoder[Todo] = deriveDecoder

  case class RegisterReq(username: String, password: String)
  case class LoginReq(username: String, password: String)
  case class ChangePasswordReq(old_password: String, new_password: String)
  case class CreateTodoReq(title: String, description: Option[String])
  case class UpdateTodoReq(title: Option[String], description: Option[String], completed: Option[Boolean])

  given Decoder[RegisterReq] = deriveDecoder
  given Decoder[LoginReq] = deriveDecoder
  given Decoder[ChangePasswordReq] = deriveDecoder
  given Decoder[CreateTodoReq] = deriveDecoder
  given Decoder[UpdateTodoReq] = deriveDecoder

  private val contentJson: Header.Raw = Header.Raw(ci"Content-Type", "application/json")

  def jsonResponse(status: Status, json: Json): Response[IO] =
    Response[IO](status).withHeaders(Headers(contentJson)).withEntity(json.noSpaces)

  def jsonError(status: Status, message: String): Response[IO] =
    jsonResponse(status, Json.obj("error" -> Json.fromString(message)))

  object State:
    private val usersById = new ConcurrentHashMap[Int, UserWithPassword]()
    private val usersByName = new ConcurrentHashMap[String, Int]()
    private val sessions = new ConcurrentHashMap[String, Int]() // token -> userId
    private val todosById = new ConcurrentHashMap[Int, Todo]()
    private var userSeq: Int = 0
    private var todoSeq: Int = 0

    private val usernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

    private def nextUserId(): Int = synchronized { userSeq += 1; userSeq }
    private def nextTodoId(): Int = synchronized { todoSeq += 1; todoSeq }

    def register(username: String, password: String): Either[Response[IO], User] =
      if username == null || password == null then Left(jsonError(Status.BadRequest, "Invalid request"))
      else if !usernameRegex.pattern.matcher(username).matches() then Left(jsonError(Status.BadRequest, "Invalid username"))
      else if password.length < 8 then Left(jsonError(Status.BadRequest, "Password too short"))
      else synchronized {
        if usersByName.containsKey(username) then Left(jsonError(Status.Conflict, "Username already exists"))
        else
          val id = nextUserId()
          val user = User(id, username)
          usersById.put(id, UserWithPassword(user, password))
          usersByName.put(username, id)
          Right(user)
      }

    def login(username: String, password: String): Either[Response[IO], (User, String)] =
      val uid = Option(usersByName.get(username)).getOrElse(-1)
      val maybe = Option(usersById.get(uid))
      maybe match
        case Some(uwp) if uwp.password == password =>
          val token = UUID.randomUUID().toString.replaceAll("-", "")
          sessions.put(token, uwp.user.id)
          Right((uwp.user, token))
        case _ => Left(jsonError(Status.Unauthorized, "Invalid credentials"))

    def userBySession(token: String): Option[User] =
      Option(sessions.get(token)).flatMap(id => Option(usersById.get(id)).map(_.user))

    def invalidateSession(token: String): Unit = sessions.remove(token)

    def changePassword(userId: Int, oldPassword: String, newPassword: String): Either[Response[IO], Unit] =
      val maybe = Option(usersById.get(userId))
      maybe match
        case Some(uwp) if uwp.password == oldPassword =>
          if newPassword.length < 8 then Left(jsonError(Status.BadRequest, "Password too short"))
          else
            usersById.put(userId, uwp.copy(password = newPassword))
            Right(())
        case _ => Left(jsonError(Status.Unauthorized, "Invalid credentials"))

    private def nowIso(): String =
      java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString

    def listTodos(userId: Int): List[Todo] =
      todosById.values().asScala.toList.filter(_.userId == userId).sortBy(_.id)

    def createTodo(userId: Int, title: String, description: Option[String]): Either[Response[IO], Todo] =
      if title == null || title.trim.isEmpty then Left(jsonError(Status.BadRequest, "Title is required"))
      else synchronized {
        val id = nextTodoId()
        val ts = nowIso()
        val todo = Todo(id, userId, title, description.getOrElse(""), false, ts, ts)
        todosById.put(id, todo)
        Right(todo)
      }

    def getTodo(userId: Int, id: Int): Either[Response[IO], Todo] =
      Option(todosById.get(id)) match
        case Some(t) if t.userId == userId => Right(t)
        case _ => Left(jsonError(Status.NotFound, "Todo not found"))

    def updateTodo(userId: Int, id: Int, patch: UpdateTodoReq): Either[Response[IO], Todo] =
      Option(todosById.get(id)) match
        case Some(t) if t.userId == userId =>
          patch.title match
            case Some(v) if v.trim.isEmpty => Left(jsonError(Status.BadRequest, "Title is required"))
            case _ =>
              val newTitle = patch.title.getOrElse(t.title)
              val newDesc = patch.description.getOrElse(t.description)
              val newCompleted = patch.completed.getOrElse(t.completed)
              val updated = t.copy(title = newTitle, description = newDesc, completed = newCompleted, updated_at = nowIso())
              todosById.put(id, updated)
              Right(updated)
        case _ => Left(jsonError(Status.NotFound, "Todo not found"))

    def deleteTodo(userId: Int, id: Int): Either[Response[IO], Unit] =
      Option(todosById.get(id)) match
        case Some(t) if t.userId == userId =>
          todosById.remove(id)
          Right(())
        case _ => Left(jsonError(Status.NotFound, "Todo not found"))

  end State

  object Auth:
    private val CookieName = "session_id"

    def extractSession(req: Request[IO]): Option[String] =
      req.cookies.find(_.name == CookieName).map(_.content)

    def requireAuth(req: Request[IO]): Either[Response[IO], User] =
      extractSession(req) match
        case Some(token) => State.userBySession(token).toRight(jsonError(Status.Unauthorized, "Authentication required"))
        case None        => Left(jsonError(Status.Unauthorized, "Authentication required"))

    def setCookie(token: String): Header.Raw =
      Header.Raw(ci"Set-Cookie", s"$CookieName=$token; Path=/; HttpOnly")

    def invalidate(req: Request[IO]): Unit =
      extractSession(req).foreach(State.invalidateSession)

  end Auth

  given EntityDecoder[IO, Json] = jsonOf[IO, Json]

  private def parseJsonBody[T: Decoder](req: Request[IO]): IO[Either[Response[IO], T]] =
    req.attemptAs[Json].value.map {
      case Left(_) => Left(jsonError(Status.BadRequest, "Invalid JSON"))
      case Right(json) =>
        json.as[T] match
          case Left(_) => Left(jsonError(Status.BadRequest, "Invalid request"))
          case Right(value) => Right(value)
    }

  private def userJson(u: User): Json = Json.obj("id" -> Json.fromInt(u.id), "username" -> Json.fromString(u.username))

  val routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    // POST /register
    case req @ POST -> Root / "register" =>
      parseJsonBody[RegisterReq](req).flatMap {
        case Left(err) => IO.pure(err)
        case Right(RegisterReq(username, password)) =>
          State.register(username, password) match
            case Left(err) => IO.pure(err)
            case Right(user) => IO.pure(jsonResponse(Status.Created, userJson(user)))
      }

    // POST /login
    case req @ POST -> Root / "login" =>
      parseJsonBody[LoginReq](req).flatMap {
        case Left(err) => IO.pure(err)
        case Right(LoginReq(username, password)) =>
          State.login(username, password) match
            case Left(err) => IO.pure(err)
            case Right((user, token)) =>
              val resp = jsonResponse(Status.Ok, userJson(user))
              IO.pure(resp.putHeaders(Auth.setCookie(token)))
      }

    // POST /logout
    case req @ POST -> Root / "logout" =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(_) =>
          Auth.invalidate(req)
          IO.pure(jsonResponse(Status.Ok, Json.obj()))

    // GET /me
    case req @ GET -> Root / "me" =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) => IO.pure(jsonResponse(Status.Ok, userJson(user)))

    // PUT /password
    case req @ PUT -> Root / "password" =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          parseJsonBody[ChangePasswordReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(ChangePasswordReq(oldp, newp)) =>
              State.changePassword(user.id, oldp, newp) match
                case Left(err) => IO.pure(err)
                case Right(_) => IO.pure(jsonResponse(Status.Ok, Json.obj()))
          }

    // GET /todos
    case req @ GET -> Root / "todos" =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          val list = State.listTodos(user.id).map { t =>
            Json.obj(
              "id" -> Json.fromInt(t.id),
              "title" -> Json.fromString(t.title),
              "description" -> Json.fromString(t.description),
              "completed" -> Json.fromBoolean(t.completed),
              "created_at" -> Json.fromString(t.created_at),
              "updated_at" -> Json.fromString(t.updated_at)
            )
          }
          IO.pure(jsonResponse(Status.Ok, Json.fromValues(list)))

    // POST /todos
    case req @ POST -> Root / "todos" =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          parseJsonBody[CreateTodoReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(CreateTodoReq(title, desc)) =>
              State.createTodo(user.id, title, desc) match
                case Left(err) => IO.pure(err)
                case Right(t) => IO.pure(jsonResponse(Status.Created, todoJsonPublic(t)))
          }

    // GET /todos/:id
    case req @ GET -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          State.getTodo(user.id, id) match
            case Left(err) => IO.pure(err)
            case Right(t) => IO.pure(jsonResponse(Status.Ok, todoJsonPublic(t)))

    // PUT /todos/:id
    case req @ PUT -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          parseJsonBody[UpdateTodoReq](req).flatMap {
            case Left(err) => IO.pure(err)
            case Right(patch) =>
              State.updateTodo(user.id, id, patch) match
                case Left(err) => IO.pure(err)
                case Right(t) => IO.pure(jsonResponse(Status.Ok, todoJsonPublic(t)))
          }

    // DELETE /todos/:id
    case req @ DELETE -> Root / "todos" / IntVar(id) =>
      Auth.requireAuth(req) match
        case Left(err) => IO.pure(err)
        case Right(user) =>
          State.deleteTodo(user.id, id) match
            case Left(err) => IO.pure(err)
            case Right(_) =>
              // 204 with no body and no Content-Type
              IO.pure(Response[IO](Status.NoContent))
  }

  private def todoJsonPublic(t: Todo): Json =
    Json.obj(
      "id" -> Json.fromInt(t.id),
      "title" -> Json.fromString(t.title),
      "description" -> Json.fromString(t.description),
      "completed" -> Json.fromBoolean(t.completed),
      "created_at" -> Json.fromString(t.created_at),
      "updated_at" -> Json.fromString(t.updated_at)
    )

  def app: HttpApp[IO] =
    val httpApp = routes.orNotFound
    Kleisli { (req: Request[IO]) =>
      httpApp(req).map { resp =>
        if resp.status == Status.NoContent then resp
        else
          // Ensure Content-Type: application/json on all non-DELETE responses
          val hasCt = resp.headers.get[headers.`Content-Type`].nonEmpty
          if hasCt then resp
          else resp.withHeaders(resp.headers ++ Headers(contentJson))
      }
    }

  def run: IO[Unit] =
    for
      args <- IO(sys.args.toList)
      port =
        args match
          case "--port" :: p :: _ => p.toIntOption.getOrElse(8080)
          case _ => sys.env.get("PORT").flatMap(_.toIntOption).getOrElse(8080)
      _ <- EmberServerBuilder.default[IO]
        .withHost(ipv4"0.0.0.0")
        .withPort(Port.fromInt(port).get)
        .withHttpApp(app)
        .build
        .useForever
    yield ()

end Main
