package todoapp

import cats.effect._
import cats.implicits._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.server.blaze.BlazeServerBuilder
import org.http4s.server.middleware.CORS
import org.http4s.circe.CirceEntityCodec._
import org.http4s.circe._
import io.circe.generic.auto._
import io.circe.syntax._

import java.util.regex.Pattern
import scala.util.control.NonFatal


object Main extends IOApp {
  def run(args: List[String]): IO[ExitCode] = {
    val portOption = args.sliding(2, 2).find(_(0) == "--port").map(_(1))
    val port = portOption.flatMap(_.toIntOption).getOrElse(8080)
    
    val storage = new InMemoryStorage()
    
    val httpApp = CORS.policy.withAllowCredentials(false)(new TodoService(storage).routes.orNotFound)
    
    BlazeServerBuilder[IO]
      .bindHttp(port, "0.0.0.0")
      .withHttpApp(httpApp)
      .serve
      .compile
      .drain
      .as(ExitCode.Success)
  }
}

class TodoService(storage: InMemoryStorage) extends Http4sDsl[IO] {
  
  import scala.language.implicitConversions
  implicit def errorToEntityEncoder: EntityEncoder[IO, Error] = jsonEncoderOf[IO, Error]

  private def getSessionId(request: Request[IO]): Option[String] = {
    request.cookies.find(_.name == "session_id").map(_.content)
  }

  private val UsernamePattern = Pattern.compile("^[a-zA-Z0-9_]+$")
  
  def routes = HttpRoutes.of[IO] {
    
    case req @ POST -> Root / "register" =>
      req.as[NewUser].flatMap { newUser =>
        // Validate username
        if (newUser.username.length < 3 || newUser.username.length > 50 || !UsernamePattern.matcher(newUser.username).matches()) {
          Ok(Error("Invalid username").asJson)
            .map(_.withStatus(Status.BadRequest))
        } else if (newUser.password.length < 8) {
          Ok(Error("Password too short").asJson)
            .map(_.withStatus(Status.BadRequest))
        } else if (storage.findUserByUsername(newUser.username).isDefined) {
          Ok(Error("Username already exists").asJson)
            .map(_.withStatus(Status.Conflict))
        } else {
          val hashedPassword = s"${newUser.password.hashCode}"
          val user = storage.registerUser(newUser.username, hashedPassword)
          Ok(AuthUser(user.id, user.username).asJson)
            .map(_.withStatus(Status.Created))
        }
      }
    
    case req @ POST -> Root / "login" =>
      req.as[LoginCredentials].flatMap { creds =>
        val userOpt = storage.findUserByUsername(creds.username)
        if (userOpt.isDefined && userOpt.get.passwordHash == s"${creds.password.hashCode}") {
          val sessionId = storage.createSession(userOpt.get.id)
          val response = Ok(AuthUser(userOpt.get.id, userOpt.get.username).asJson)
          Ok(response.body).map { resp =>
            resp.addCookie(ResponseCookie(
              name = "session_id",
              content = sessionId,
              path = Some("/"),
              httpOnly = true
            ))
          }
        } else {
          Ok(Error("Invalid credentials").asJson)
            .map(_.withStatus(Status.Unauthorized))
        }
      }
    
    case req @ POST -> Root / "logout" =>
      authenticateRequest(req) { user =>
        getSessionId(req) match {
          case Some(sessionId) =>
            storage.invalidateSession(sessionId)
            Ok(JsonObject.empty.asJson)
          case None =>
            Ok(Error("Authentication required").asJson)
              .map(_.withStatus(Status.Unauthorized))
        }
      }
    
    case req @ GET -> Root / "me" =>
      authenticateRequest(req) { user =>
        Ok(AuthUser(user.id, user.username).asJson)
      }
    
    case req @ PUT -> Root / "password" =>
      req.as[PasswordChange].flatMap { change =>
        getSessionId(req) match {
          case Some(_) =>
            val currentUserOpt = getCurrentUser(req)
            currentUserOpt match {
              case Some(currentUser) =>
                if (currentUser.passwordHash != s"${change.oldPassword.hashCode}") {
                  Ok(Error("Invalid credentials").asJson)
                    .map(_.withStatus(Status.Unauthorized))
                } else if (change.newPassword.length < 8) {
                  Ok(Error("Password too short").asJson)
                    .map(_.withStatus(Status.BadRequest))
                } else {
                  storage.changePassword(currentUser.username, change.oldPassword, change.newPassword)
                  Ok(JsonObject.empty.asJson)
                }
              case None =>
                Ok(Error("Authentication required").asJson)
                  .map(_.withStatus(Status.Unauthorized))
            }
          case None =>
            Ok(Error("Authentication required").asJson)
              .map(_.withStatus(Status.Unauthorized))
        }
      }
    
    case req @ GET -> Root / "todos" =>
      authenticateRequest(req) { user =>
        val todos = storage.getTodosForUser(user.id)
        Ok(todos.asJson)
      }
    
    case req @ POST -> Root / "todos" =>
      authenticateRequest(req) { user =>
        req.as[NewTodo].flatMap { newTodo =>
          if (newTodo.title.isEmpty) {
            Ok(Error("Title is required").asJson)
              .map(_.withStatus(Status.BadRequest))
          } else {
            val todo = storage.createTodo(newTodo.title, newTodo.description, user.id)
            Ok(todo.asJson).map(_.withStatus(Status.Created))
          }
        }
      }
    
    case req @ GET -> Root / "todos" / IntVar(todoId) =>
      authenticateRequest(req) { user =>
        storage.getUserTodoIfExists(user.id, todoId) match {
          case Some(todo) =>
            Ok(todo.asJson)
          case None =>
            Ok(Error("Todo not found").asJson)
              .map(_.withStatus(Status.NotFound))
        }
      }
    
    case req @ PUT -> Root / "todos" / IntVar(todoId) =>
      authenticateRequest(req) { user =>
        req.as[UpdateTodo].flatMap { updateInfo =>
          // Validate if title is provided and is empty
          if (updateInfo.title.isDefined && updateInfo.title.get.isEmpty) {
            Ok(Error("Title is required").asJson)
              .map(_.withStatus(Status.BadRequest))
          } else {
            storage.updateTodo(todoId, updateInfo.title, updateInfo.description, updateInfo.completed, user.id) match {
              case Some(updatedTodo) =>
                Ok(updatedTodo.asJson)
              case None =>
                Ok(Error("Todo not found").asJson)
                  .map(_.withStatus(Status.NotFound))
            }
          }
        }
      }
    
    case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
      authenticateRequest(req) { user =>
        if (storage.deleteTodo(todoId, user.id)) {
          Response[IO](Status.NoContent).pure[IO]
        } else {
          Ok(Error("Todo not found").asJson)
            .map(_.withStatus(Status.NotFound))
        }
      }
  }
  
  private def getCurrentUser(req: Request[IO]): Option[User] = {
    getSessionId(req) match {
      case Some(sessionId) => storage.validateSessionAndGetUser(sessionId)
      case None => None
    }
  }
  
  private def authenticateRequest(req: Request[IO])(handler: User => IO[Response[IO]]): IO[Response[IO]] = {
    getCurrentUser(req) match {
      case Some(user) => handler(user)
      case None => 
        Ok(Error("Authentication required").asJson)
          .map(_.withStatus(Status.Unauthorized))
    }
  }
}