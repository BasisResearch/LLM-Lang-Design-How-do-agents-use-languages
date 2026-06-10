//> using scala "2.13"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-blaze-server:0.23.17"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
//> using dep "io.circe::circe-parser:0.14.15"

import cats.effect._
import cats.implicits._
import org.http4s._
import org.http4s.dsl.Http4sDsl
import org.http4s.server.blaze.BlazeServerBuilder
import org.http4s.server.middleware.CORS
import org.http4s.circe.CirceEntityDecoder._
import org.http4s.circe.CirceEntityEncoder._
import io.circe.generic.auto._
import io.circe.syntax._
import io.circe.{Encoder, Decoder}

import java.time.format.DateTimeFormatter
import java.time.{Instant, ZoneOffset}
import scala.collection.mutable
import java.util.UUID
import java.util.regex.Pattern

// Model definitions
case class User(id: Int, username: String, passwordHash: String = "")

case class NewUser(username: String, password: String)

case class LoginCredentials(username: String, password: String)

case class PasswordChange(old_password: String, new_password: String)

case class NewTodo(title: String, description: String = "")

case class UpdateTodo(title: Option[String], description: Option[String], completed: Option[Boolean])

case class Todo(
  id: Int,
  title: String,
  description: String,
  completed: Boolean = false,
  created_at: String,
  updated_at: String,
  userId: Int
)

case class AuthUser(id: Int, username: String)

case class Error(error: String)

object Error {
  implicit val errorEncoder: Encoder[Error] = io.circe.generic.semiauto.deriveEncoder[Error]
  implicit val errorEntityEncoder: EntityEncoder[IO, Error] = org.http4s.circe.jsonEncoderOf[IO, Error]
}

class InMemoryStorage {
  private val users = mutable.Map.empty[String, User]
  private var nextUserId = 1
  
  private val todos = mutable.Map.empty[Int, Todo]
  private var nextTodoId = 1
  
  private val sessions = mutable.Map.empty[String, Int]  // sessionId -> userId mapping
  
  def registerUser(username: String, passwordHash: String): User = {
    val user = User(nextUserId, username, passwordHash)
    users.put(username, user)
    nextUserId += 1
    user
  }
  
  def findUserByUsername(username: String): Option[User] = {
    users.get(username)
  }
  
  def getUserById(id: Int): Option[User] = {
    users.values.find(_.id == id)
  }
  
  def getUserBySession(sessionId: String): Option[User] = {
    for {
      userId <- sessions.get(sessionId)
      user <- getUserById(userId)
    } yield user
  }
  
  def createTodo(title: String, description: String, userId: Int): Todo = {
    val now = getCurrentTimestamp()
    val todo = Todo(nextTodoId, title, description, completed = false, now, now, userId)
    todos.put(nextTodoId, todo)
    nextTodoId += 1
    todo
  }
  
  def getTodosByUserId(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }
  
  def getTodoById(id: Int): Option[Todo] = {
    todos.get(id)
  }
  
  def getTodosForUser(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }
  
  def getUserTodo(userId: Int, todoId: Int): Option[Todo] = {
    getTodoById(todoId).filter(_.userId == userId)
  }
  
  def getUserTodoIfExists(userId: Int, todoId: Int): Option[Todo] = {
    todos.get(todoId).filter(_.userId == userId)
  }
  
  def updateTodo(todoId: Int, title: Option[String], description: Option[String], completed: Option[Boolean], userId: Int): Option[Todo] = {
    val existingTodoOpt = todos.get(todoId).filter(_.userId == userId)
    existingTodoOpt.map { existingTodo =>
      val newTitle = title.getOrElse(existingTodo.title)
      val newDescription = description.getOrElse(existingTodo.description)
      val newCompleted = completed.getOrElse(existingTodo.completed)
      val now = getCurrentTimestamp()
      
      val updatedTodo = existingTodo.copy(
        title = newTitle,
        description = newDescription,
        completed = newCompleted,
        updated_at = now
      )
      
      todos.update(todoId, updatedTodo)
      updatedTodo
    }
  }
  
  def deleteTodo(todoId: Int, userId: Int): Boolean = {
    val todo = todos.get(todoId)
    if (todo.exists(_.userId == userId)) {
      todos.remove(todoId)
      true
    } else {
      false
    }
  }
  
  def createSession(userId: Int): String = {
    val sessionId = UUID.randomUUID().toString
    sessions.put(sessionId, userId)
    sessionId
  }
  
  def validateSessionAndGetUser(sessionId: String): Option[User] = {
    getUserBySession(sessionId)
  }
  
  def invalidateSession(sessionId: String): Boolean = {
    sessions.remove(sessionId).isDefined
  }
  
  def changePassword(username: String, oldPassword: String, newPassword: String): Boolean = {
    val userOpt = findUserByUsername(username)
    if (userOpt.exists(_.passwordHash == hashPassword(oldPassword))) {
      val user = userOpt.get
      users.update(username, user.copy(passwordHash = hashPassword(newPassword)))
      true
    } else {
      false
    }
  }
  
  private def getCurrentTimestamp(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
  
  private def hashPassword(password: String): String = {
    // For security, you'd want proper hashing (like bcrypt) but for this exercise, use simple hash
    password.hashCode.toString
  }
}

class TodoService(storage: InMemoryStorage) extends Http4sDsl[IO] {

  private def getSessionId(request: Request[IO]): Option[String] = {
    request.cookies.find(_.name == "session_id").map(_.content)
  }

  private val UsernamePattern = Pattern.compile("^[a-zA-Z0-9_]+$")
  
  def routes = HttpRoutes.of[IO] {
    
    case req @ POST -> Root / "register" =>
      req.as[NewUser].flatMap { newUser =>
        // Validate username - must be 3-50 chars and alphanumeric + underscore only
        if (newUser.username.length < 3 || newUser.username.length > 50 || !UsernamePattern.matcher(newUser.username).matches()) {
          Ok(Error("Invalid username").asJson).map(_.withStatus(Status.BadRequest))
        } else if (newUser.password.length < 8) {
          Ok(Error("Password too short").asJson).map(_.withStatus(Status.BadRequest))
        } else if (storage.findUserByUsername(newUser.username).isDefined) {
          Ok(Error("Username already exists").asJson).map(_.withStatus(Status.Conflict))
        } else {
          val hashedPassword = newUser.password.hashCode.toString
          val user = storage.registerUser(newUser.username, hashedPassword)
          Ok(AuthUser(user.id, user.username).asJson).map(_.withStatus(Status.Created))
        }
      }
    
    case req @ POST -> Root / "login" =>
      req.as[LoginCredentials].flatMap { creds =>
        val userOpt = storage.findUserByUsername(creds.username)
        if (userOpt.isDefined && userOpt.get.passwordHash == creds.password.hashCode.toString) {
          val sessionId = storage.createSession(userOpt.get.id)
          Ok(AuthUser(userOpt.get.id, userOpt.get.username).asJson).map { response =>
            response.addCookie(ResponseCookie(
              name = "session_id",
              content = sessionId,
              path = Some("/"),
              httpOnly = true
            ))
          }
        } else {
          Ok(Error("Invalid credentials").asJson).map(_.withStatus(Status.Unauthorized))
        }
      }
    
    case req @ POST -> Root / "logout" =>
      authenticateRequest(req) { user =>
        getSessionId(req) match {
          case Some(sessionId) =>
            storage.invalidateSession(sessionId)
            Ok(io.circe.JsonObject.empty.asJson)
          case None =>
            Ok(Error("Authentication required").asJson).map(_.withStatus(Status.Unauthorized))
        }
      }
    
    case req @ GET -> Root / "me" =>
      authenticateRequest(req) { user =>
        Ok(AuthUser(user.id, user.username).asJson)
      }
    
    case req @ PUT -> Root / "password" =>
      authenticateRequest(req) { user =>
        req.as[PasswordChange].flatMap { change =>
          if (user.passwordHash != change.old_password.hashCode.toString) {
            Ok(Error("Invalid credentials").asJson).map(_.withStatus(Status.Unauthorized))
          } else if (change.new_password.length < 8) {
            Ok(Error("Password too short").asJson).map(_.withStatus(Status.BadRequest))
          } else {
            storage.changePassword(user.username, change.old_password, change.new_password)
            Ok(io.circe.JsonObject.empty.asJson)
          }
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
            Ok(Error("Title is required").asJson).map(_.withStatus(Status.BadRequest))
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
            Ok(Error("Todo not found").asJson).map(_.withStatus(Status.NotFound))
        }
      }
    
    case req @ PUT -> Root / "todos" / IntVar(todoId) =>
      authenticateRequest(req) { user =>
        req.as[UpdateTodo].flatMap { updateInfo =>
          // Validate if title is provided and is empty
          if (updateInfo.title.isDefined && updateInfo.title.get.isEmpty) {
            Ok(Error("Title is required").asJson).map(_.withStatus(Status.BadRequest))
          } else {
            storage.updateTodo(todoId, updateInfo.title, updateInfo.description, updateInfo.completed, user.id) match {
              case Some(updatedTodo) =>
                Ok(updatedTodo.asJson)
              case None =>
                Ok(Error("Todo not found").asJson).map(_.withStatus(Status.NotFound))
            }
          }
        }
      }
    
    case req @ DELETE -> Root / "todos" / IntVar(todoId) =>
      authenticateRequest(req) { user =>
        if (storage.deleteTodo(todoId, user.id)) {
          Response[IO](Status.NoContent).pure[IO]
        } else {
          Ok(Error("Todo not found").asJson).map(_.withStatus(Status.NotFound))
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
        Ok(Error("Authentication required").asJson).map(_.withStatus(Status.Unauthorized))
    }
  }
}

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