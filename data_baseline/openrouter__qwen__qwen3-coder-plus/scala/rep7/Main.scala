//> using scala "2.13"
//> using lib "org.http4s::http4s-dsl_2.13:0.23.7"
//> using lib "org.http4s::http4s-blaze-server_2.13:0.23.7"
//> using lib "org.http4s::http4s-circe_2.13:0.23.7"
//> using lib "io.circe::circe-generic:0.14.3"
//> using lib "io.circe::circe-parser:0.14.3"
//> using lib "com.github.etaty:rediscala_2.13:1.8.0"

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
import io.circe.{Json, JsonObject}

import java.time.format.DateTimeFormatter
import java.time.{Instant, ZoneOffset}
import scala.collection.mutable
import java.util.UUID
import scala.util.matching.Regex

object Main extends IOApp {
  
  // Model definitions
  case class User(id: Int, username: String, hash: String = "")
  
  case class NewUser(username: String, password: String)
  
  case class LoginCredentials(username: String, password: String)
  
  case class PasswordChange(oldPassword: String, newPassword: String)
  
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
  
  // Storage layer
  class InMemoryStorage {
    private val users = mutable.Map.empty[String, User]
    private var nextUserId = 1
    
    private val todos = mutable.Map.empty[Int, Todo]
    private var nextTodoId = 1
    
    private val passwords = mutable.Map.empty[String, String]  // session_id -> user_hash mapping
    
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
    
    def updateTodo(todoId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = {
      val existingTodoOpt = getTodoById(todoId)
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
    
    def deleteTodo(todoId: Int): Boolean = {
      if (todos.contains(todoId)) {
        todos.remove(todoId)
        true
      } else {
        false
      }
    }
    
    def storeSession(sessionId: String, passwordHash: String): Unit = {
      passwords.put(sessionId, passwordHash)
    }
    
    def validateSession(sessionId: String, expectedHash: String): Boolean = {
      passwords.get(sessionId).contains(expectedHash)
    }
    
    def removeSession(sessionId: String): Boolean = {
      passwords.remove(sessionId).isDefined
    }
    
    private def getCurrentTimestamp(): String = {
      Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    }
  }
  
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
  
  class TodoService(storage: InMemoryStorage) extends Http4sDsl[IO] {
    
    implicit val errorEncoder: io.circe.Encoder[Error] = io.circe.generic.semiauto.deriveEncoder[Error]
    
    // Helper for hashing passwords (for simplicity, we'll use plain comparison in memory)
    def hashPassword(password: String): String = password
    
    private def authenticate(sessionId: String, username: String, password: String): IO[Option[User]] = {
      val passwordHash = hashPassword(password)
      IO(storage.validateSession(sessionId, passwordHash)).flatMap { isValid =>
        if (isValid) {
          IO(storage.findUserByUsername(username)).map(userOpt => userOpt.filter(_.hash == passwordHash))
        } else {
          IO.pure(None)
        }
      }
    }
    
    // Extract session ID from request
    private def getSessionId(request: Request[IO]): Option[String] = {
      request.cookies.find(_.name == "session_id").map(_.content)
    }
    
    private def authenticateRequest(req: Request[IO]): IO[Either[Response[IO], User]] = {
      getSessionId(req) match {
        case Some(sessionId) =>
          // We need to extract the username from the context where the session was stored
          // For proper validation, we'll validate by checking if the session ID maps to a valid user password hash
          // So let's store user-id against session in addition to password hash
          
          IO.pure(Left(Response(status = Status.Unauthorized).withEntity(Error("Authentication required"))))
        case None =>
          IO.pure(Left(Response(status = Status.Unauthorized).withEntity(Error("Authentication required"))))
      }
    }
    
    object WithSession {
      def unapply(req: Request[IO]): Option[(String, Request[IO])] = {
        getSessionId(req).map((_, req))
      }
    }
    
    def routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
      
      // Helper function for handling authentication
      def withAuthentication(req: Request[IO])(op: User => IO[Response[IO]]): IO[Response[IO]] = {
        getSessionId(req) match {
          case Some(sessionId) =>
            // Here we need a mapping between sessionId and user, but we didn't set one up yet
            // We need to iterate over stored sessions to find a match
            // For more efficient handling, we should also map user ID to session
            
            // Let's add a session-to-userId mapping
            val userLookupBySessionId: Map[String, Int] = ???
            
            // For now, let's temporarily enhance our storage to map sessions to user IDs
            IO.pure(Response(status = Status.Unauthorized).withEntity(Error("Authentication required")))
          case None =>
            IO.pure(Response(status = Status.Unauthorized).withEntity(Error("Authentication required")))
        }
      }
    
      // Helper for authentication with temporary implementation
      def isAuthenticated(req: Request[IO]): Option[User] = {
        implicit class StorageWithUserIdMap(st: InMemoryStorage) {
          def getUserIdBySessionId(sessionId: String): Option[Int] = {
            // We'll temporarily simulate an in-memory map for this purpose
            // Since we can't actually do this without extending the InMemoryStorage,
            // let's approach differently by storing a mapping in companion object
            // which is not ideal for thread-safety but will work for this simple solution
            
            // Actually, let's just directly update InMemoryStorage class to include this capability
            ???
          }
        }
        None // placeholder
      }
    
      // Update our InMemoryStorage to include session handling
      trait SessionCapableStorage {
        def getUserIdBySession(sessionId: String): Option[Int]
        def getUserBySessionId(sessionId: String): Option[User] = {
          getUserIdBySession(sessionId).flatMap(getUserById)
        }
      }
    }
  }
}