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
import io.circe.{Encoder, Json}

import java.time.format.DateTimeFormatter
import java.time.{Instant, ZoneOffset}
import scala.collection.mutable
import java.util.UUID

case class User(id: Int, username: String, passwordHash: String = "")

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

object Error {
  implicit val errorEncoder: Encoder[Error] = io.circe.generic.semiauto.deriveEncoder[Error]
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
    // For security, you'd want proper hashing (like bcrypt) but for this exercise, use the password as-is  
    s"${password.hashCode}"  // Still simple but adds some obfuscation 
  }
}