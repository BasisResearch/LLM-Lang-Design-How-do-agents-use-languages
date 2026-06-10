//> using scala 3.3.1
//> using dep com.lihaoyi::upickle:3.1.4

import com.sun.net.httpserver.{HttpHandler, HttpExchange, HttpServer}
import java.net.InetSocketAddress
import scala.io.Source
import scala.jdk.CollectionConverters._
import java.util.concurrent.ConcurrentHashMap
import upickle.default._
import java.util.UUID

case class User(id: Int, username: String, password: String)
case class Todo(
  id: Int,
  userId: Int,
  title: String,
  description: String,
  completed: Boolean,
  createdAt: String,
  updatedAt: String
)

object State {
  val users = new ConcurrentHashMap[Int, User]()
  val sessions = new ConcurrentHashMap[String, Int]()
  val todos = new ConcurrentHashMap[Int, Todo]()
  
  @volatile var nextUserId = 1
  @volatile var nextTodoId = 1
  
  def getNextUserId(): Int = synchronized {
    val id = nextUserId
    nextUserId += 1
    id
  }
  
  def getNextTodoId(): Int = synchronized {
    val id = nextTodoId
    nextTodoId += 1
    id
  }
}

case class UserResp(id: Int, username: String)
object UserResp { implicit val rw: ReadWriter[UserResp] = macroRW }

case class TodoResp(
  id: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)
object TodoResp { implicit val rw: ReadWriter[TodoResp] = macroRW }

case class ErrorResp(error: String)
object ErrorResp { implicit val rw: ReadWriter[ErrorResp] = macroRW }

object Main {
  def nowIso(): String = {
    java.time.Instant.now().atZone(java.time.ZoneOffset.UTC).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  }

  def main(args: Array[String]): Unit = {
    val port = args match {
      case Array("--port", p) => p.toInt
      case _ => 8080
    }
    
    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)
    
    server.createContext("/register", new RegisterHandler)
    server.createContext("/login", new LoginHandler)
    server.createContext("/logout", new LogoutHandler)
    server.createContext("/me", new MeHandler)
    server.createContext("/password", new PasswordHandler)
    server.createContext("/todos", new TodosHandler)
    server.createContext("/todos/", new TodoByIdHandler)
    server.createContext("/", new NotFoundHandler)
    
    server.setExecutor(java.util.concurrent.Executors.newFixedThreadPool(10))
    server.start()
    println(s"Server started on port $port")
  }
}

abstract class JsonHandler extends HttpHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String])

  def getCookies(exchange: HttpExchange): Map[String, String] = {
    val cookieHeader = exchange.getRequestHeaders.getFirst("Cookie")
    if (cookieHeader == null) Map.empty
    else {
      cookieHeader.split(";").map(_.trim).flatMap { kv =>
        kv.split("=", 2) match {
          case Array(k, v) => Some(k -> v)
          case _ => None
        }
      }.toMap
    }
  }

  def requireAuth(exchange: HttpExchange): Option[Int] = {
    getCookies(exchange).get("session_id").flatMap { token =>
      Option(State.sessions.get(token))
    }
  }

  def getStrOpt(obj: ujson.Obj, key: String): Option[String] = {
    obj.value.get(key).flatMap {
      case ujson.Str(s) => Some(s)
      case _ => None
    }
  }

  def getBoolOpt(obj: ujson.Obj, key: String): Option[Boolean] = {
    obj.value.get(key).flatMap {
      case ujson.True => Some(true)
      case ujson.False => Some(false)
      case _ => None
    }
  }

  override def handle(exchange: HttpExchange): Unit = {
    try {
      val (status, body, cookieOpt) = handleInner(exchange)
      if (status != 204) {
        exchange.getResponseHeaders.add("Content-Type", "application/json")
      }
      cookieOpt.foreach { cookie =>
        exchange.getResponseHeaders.add("Set-Cookie", cookie)
      }
      val bytes = body.getBytes("UTF-8")
      exchange.sendResponseHeaders(status, if (status == 204) -1 else bytes.length)
      if (status != 204) {
        exchange.getResponseBody.write(bytes)
      }
      exchange.getResponseBody.close()
    } catch {
      case e: Exception =>
        exchange.getResponseHeaders.add("Content-Type", "application/json")
        val err = upickle.default.write(ErrorResp(e.getMessage))
        val bytes = err.getBytes("UTF-8")
        exchange.sendResponseHeaders(500, bytes.length)
        exchange.getResponseBody.write(bytes)
        exchange.getResponseBody.close()
    }
  }
}

class NotFoundHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    (404, upickle.default.write(ErrorResp("Not found")), None)
  }
}

class RegisterHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    if (exchange.getRequestMethod != "POST") return (405, upickle.default.write(ErrorResp("Method not allowed")), None)
    
    val body = Source.fromInputStream(exchange.getRequestBody).mkString
    val json = try {
      ujson.read(body).obj
    } catch {
      case _: Exception => return (400, upickle.default.write(ErrorResp("Invalid username")), None)
    }
    
    val username = getStrOpt(json, "username").getOrElse("")
    val password = getStrOpt(json, "password").getOrElse("")
    
    if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
      return (400, upickle.default.write(ErrorResp("Invalid username")), None)
    }
    if (password == null || password.length < 8) {
      return (400, upickle.default.write(ErrorResp("Password too short")), None)
    }
    
    State.synchronized {
      State.users.values().asScala.find(_.username == username) match {
        case Some(_) => (409, upickle.default.write(ErrorResp("Username already exists")), None)
        case None =>
          val id = State.getNextUserId()
          val user = User(id, username, password)
          State.users.put(id, user)
          (201, upickle.default.write(UserResp(id, username)), None)
      }
    }
  }
}

class LoginHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    if (exchange.getRequestMethod != "POST") return (405, upickle.default.write(ErrorResp("Method not allowed")), None)
    
    val body = Source.fromInputStream(exchange.getRequestBody).mkString
    val json = try {
      ujson.read(body).obj
    } catch {
      case _: Exception => return (401, upickle.default.write(ErrorResp("Invalid credentials")), None)
    }
    
    val username = getStrOpt(json, "username").getOrElse("")
    val password = getStrOpt(json, "password").getOrElse("")
    
    State.users.values().asScala.find(u => u.username == username && u.password == password) match {
      case Some(user) =>
        val token = UUID.randomUUID().toString
        State.sessions.put(token, user.id)
        val cookie = s"session_id=$token; Path=/; HttpOnly"
        (200, upickle.default.write(UserResp(user.id, user.username)), Some(cookie))
      case None =>
        (401, upickle.default.write(ErrorResp("Invalid credentials")), None)
    }
  }
}

class LogoutHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    if (exchange.getRequestMethod != "POST") return (405, upickle.default.write(ErrorResp("Method not allowed")), None)
    requireAuth(exchange) match {
      case Some(_) =>
        val token = getCookies(exchange)("session_id")
        State.sessions.remove(token)
        (200, "{}", None)
      case None =>
        (401, upickle.default.write(ErrorResp("Authentication required")), None)
    }
  }
}

class MeHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    if (exchange.getRequestMethod != "GET") return (405, upickle.default.write(ErrorResp("Method not allowed")), None)
    requireAuth(exchange) match {
      case Some(userId) =>
        State.users.get(userId) match {
          case null => (401, upickle.default.write(ErrorResp("Authentication required")), None)
          case user => (200, upickle.default.write(UserResp(user.id, user.username)), None)
        }
      case None =>
        (401, upickle.default.write(ErrorResp("Authentication required")), None)
    }
  }
}

class PasswordHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    if (exchange.getRequestMethod != "PUT") return (405, upickle.default.write(ErrorResp("Method not allowed")), None)
    requireAuth(exchange) match {
      case Some(userId) =>
        val body = Source.fromInputStream(exchange.getRequestBody).mkString
        val json = try {
          ujson.read(body).obj
        } catch {
          case _: Exception => return (400, upickle.default.write(ErrorResp("Invalid request")), None)
        }
        
        val oldPassword = getStrOpt(json, "old_password").getOrElse("")
        val newPassword = getStrOpt(json, "new_password").getOrElse("")
        
        State.synchronized {
          val user = State.users.get(userId)
          if (user == null || user.password != oldPassword) {
            return (401, upickle.default.write(ErrorResp("Invalid credentials")), None)
          }
          if (newPassword == null || newPassword.length < 8) {
            return (400, upickle.default.write(ErrorResp("Password too short")), None)
          }
          
          val updatedUser = user.copy(password = newPassword)
          State.users.put(userId, updatedUser)
          (200, "{}", None)
        }
        
      case None =>
        (401, upickle.default.write(ErrorResp("Authentication required")), None)
    }
  }
}

class TodosHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    requireAuth(exchange) match {
      case Some(userId) =>
        exchange.getRequestMethod match {
          case "GET" =>
            val todos = State.todos.values().asScala
              .filter(_.userId == userId)
              .toList
              .sortBy(_.id)
              .map(t => TodoResp(t.id, t.title, t.description, t.completed, t.createdAt, t.updatedAt))
            (200, upickle.default.write(todos), None)
            
          case "POST" =>
            val body = Source.fromInputStream(exchange.getRequestBody).mkString
            val json = try {
              ujson.read(body).obj
            } catch {
              case _: Exception => return (400, upickle.default.write(ErrorResp("Title is required")), None)
            }
            
            val title = getStrOpt(json, "title").getOrElse("")
            if (title.trim.isEmpty) {
              return (400, upickle.default.write(ErrorResp("Title is required")), None)
            }
            
            val desc = getStrOpt(json, "description").getOrElse("")
            val now = Main.nowIso()
            val id = State.getNextTodoId()
            val todo = Todo(id, userId, title, desc, false, now, now)
            State.todos.put(id, todo)
            
            (201, upickle.default.write(TodoResp(id, title, desc, false, now, now)), None)
            
          case _ =>
            (405, upickle.default.write(ErrorResp("Method not allowed")), None)
        }
      case None =>
        (401, upickle.default.write(ErrorResp("Authentication required")), None)
    }
  }
}

class TodoByIdHandler extends JsonHandler {
  def handleInner(exchange: HttpExchange): (Int, String, Option[String]) = {
    requireAuth(exchange) match {
      case Some(userId) =>
        val path = exchange.getRequestURI.getPath
        val idStr = path.stripPrefix("/todos/")
        val id = try {
          idStr.toInt
        } catch {
          case _: Exception => return (404, upickle.default.write(ErrorResp("Todo not found")), None)
        }
        
        val todo = State.todos.get(id)
        if (todo == null || todo.userId != userId) {
          return (404, upickle.default.write(ErrorResp("Todo not found")), None)
        }
        
        exchange.getRequestMethod match {
          case "GET" =>
            (200, upickle.default.write(TodoResp(todo.id, todo.title, todo.description, todo.completed, todo.createdAt, todo.updatedAt)), None)
            
          case "PUT" =>
            val body = Source.fromInputStream(exchange.getRequestBody).mkString
            val json = try {
              ujson.read(body).obj
            } catch {
              case _: Exception => return (400, upickle.default.write(ErrorResp("Invalid request")), None)
            }
            
            val newTitle = getStrOpt(json, "title").getOrElse(todo.title)
            if (newTitle.trim.isEmpty) {
              return (400, upickle.default.write(ErrorResp("Title is required")), None)
            }
            
            val newDesc = getStrOpt(json, "description").getOrElse(todo.description)
            val newCompleted = getBoolOpt(json, "completed").getOrElse(todo.completed)
            val now = Main.nowIso()
            
            val updatedTodo = todo.copy(
              title = newTitle,
              description = newDesc,
              completed = newCompleted,
              updatedAt = now
            )
            State.todos.put(id, updatedTodo)
            
            (200, upickle.default.write(TodoResp(updatedTodo.id, updatedTodo.title, updatedTodo.description, updatedTodo.completed, updatedTodo.createdAt, updatedTodo.updatedAt)), None)
            
          case "DELETE" =>
            State.todos.remove(id)
            (204, "", None)
            
          case _ =>
            (405, upickle.default.write(ErrorResp("Method not allowed")), None)
        }
        
      case None =>
        (401, upickle.default.write(ErrorResp("Authentication required")), None)
    }
  }
}