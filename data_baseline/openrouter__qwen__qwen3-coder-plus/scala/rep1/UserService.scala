import java.util.concurrent.atomic.AtomicInteger
import scala.collection.mutable
import scala.util.Random
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.ZoneOffset

object DateTimeHelper {
  def nowAsString(): String = {
    Instant.now().atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }
}

case class User(
                 id: Int,
                 username: String,
                 passwordHash: String // In a real app we'd hash passwords properly
               )

case class Todo(
                 id: Int,
                 title: String,
                 description: String = "",
                 completed: Boolean = false,
                 createdAt: String,
                 updatedAt: String,
                 userId: Int
               )

class UserService {
  private val users = mutable.Map[String, User]()
  private val userCounter = new AtomicInteger(1)
  
  def registerUser(username: String, password: String): Option[User] = synchronized {
    if (!username.matches("^[a-zA-Z0-9_]+$") || username.length < 3 || username.length > 50) {
      return None
    }
    
    if (password.length < 8) {
      return None
    }
    
    if (users.contains(username)) {
      return None
    }

    val id = userCounter.getAndIncrement()
    val user = User(id, username, password) // In real app, hash password
    users.put(username, user)
    Some(user)
  }

  def authenticateUser(username: String, password: String): Option[User] = {
    val maybeUser = users.get(username)
    maybeUser.filter(_.passwordHash == password)
  }

  def findUser(userId: Int): Option[User] = {
    users.values.find(_.id == userId)
  }

  def findUserByUsername(username: String): Option[User] = {
    users.get(username)
  }

  def updatePassword(userId: Int, oldPassword: String, newPassword: String): Boolean = synchronized {
    val existingUser = users.values.find(_.id == userId)
    existingUser match {
      case Some(user) =>
        if (user.passwordHash != oldPassword || newPassword.length < 8) {
          false
        } else {
          users.update(user.username, user.copy(passwordHash = newPassword))
          true
        }
      case None => false
    }
  }
}