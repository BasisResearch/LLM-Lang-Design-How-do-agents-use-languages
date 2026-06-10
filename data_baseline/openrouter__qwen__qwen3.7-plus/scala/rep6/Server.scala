//> using scala 3.8.3
//> using dep com.lihaoyi::upickle:4.4.3

import com.sun.net.httpserver._
import java.net.InetSocketAddress
import java.time.{ZoneOffset, ZonedDateTime}
import java.time.format.DateTimeFormatter
import java.util.UUID
import scala.collection.mutable
import upickle.default._

val df = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
def now(): String = ZonedDateTime.now(ZoneOffset.UTC).format(df)

case class User(id: Int, username: String, password: String)
case class Todo(id: Int, userId: Int, title: String, description: String, completed: Boolean, createdAt: String, updatedAt: String)

object Storage {
  var nextUserId = 1
  val users = mutable.Map[Int, User]()
  val usernameToId = mutable.Map[String, Int]()
  
  var nextTodoId = 1
  val todos = mutable.Map[Int, Todo]()

  val sessions = mutable.Map[String, Int]() // token -> userId
}

case class ErrorResponse(error: String)
implicit val errorRw: ReadWriter[ErrorResponse] = macroRW

case class UserResponse(id: Int, username: String)
implicit val userRw: ReadWriter[UserResponse] = macroRW

case class RegisterRequest(username: String, password: String)
implicit val registerRw: ReadWriter[RegisterRequest] = macroRW

case class LoginRequest(username: String, password: String)
implicit val loginRw: ReadWriter[LoginRequest] = macroRW

case class PasswordRequest(old_password: String, new_password: String)
implicit val passwordRw: ReadWriter[PasswordRequest] = macroRW

class TodoHandler extends HttpHandler {
  def handle(exchange: HttpExchange): Unit = {
    val method = exchange.getRequestMethod
    val path = exchange.getRequestURI.getPath

    try {
      (method, path) match {
        case ("POST", "/register") => handleRegister(exchange)
        case ("POST", "/login") => handleLogin(exchange)
        case ("POST", "/logout") => handleLogout(exchange)
        case ("GET", "/me") => handleMe(exchange)
        case ("PUT", "/password") => handlePassword(exchange)
        case ("GET", "/todos") => handleGetTodos(exchange)
        case ("POST", "/todos") => handleCreateTodo(exchange)
        case ("GET", p) if p.startsWith("/todos/") => handleGetTodo(exchange, p.drop(7).toInt)
        case ("PUT", p) if p.startsWith("/todos/") => handleUpdateTodo(exchange, p.drop(7).toInt)
        case ("DELETE", p) if p.startsWith("/todos/") => handleDeleteTodo(exchange, p.drop(7).toInt)
        case _ => 
          sendError(exchange, 404, "Not found")
      }
    } catch {
      case e: NumberFormatException => sendError(exchange, 400, "Invalid ID")
      case e: Exception => 
        e.printStackTrace()
        sendError(exchange, 500, "Internal server error")
    }
  }

  def getAuthUser(exchange: HttpExchange): Option[User] = {
    val cookies = exchange.getRequestHeaders.getFirst("Cookie")
    if (cookies == null) return None
    val sessionCookie = cookies.split(";").map(_.trim).find(_.startsWith("session_id="))
    sessionCookie match {
      case Some(c) =>
        val token = c.drop(11)
        Storage.synchronized {
          Storage.sessions.get(token).flatMap(userId => Storage.users.get(userId))
        }
      case None => None
    }
  }

  def requireAuth(exchange: HttpExchange): Option[User] = {
    getAuthUser(exchange) match {
      case Some(user) => Some(user)
      case None =>
        sendError(exchange, 401, "Authentication required")
        None
    }
  }

  def readBody(exchange: HttpExchange): String = {
    val len = exchange.getRequestHeaders.getFirst("Content-Length")
    if (len == null || len.toInt == 0) ""
    else new String(exchange.getRequestBody.readAllBytes(), "UTF-8")
  }

  def sendJson(exchange: HttpExchange, code: Int, body: String): Unit = {
    exchange.getResponseHeaders.set("Content-Type", "application/json")
    val bytes = body.getBytes("UTF-8")
    exchange.sendResponseHeaders(code, bytes.length)
    exchange.getResponseBody.write(bytes)
    exchange.close()
  }

  def sendError(exchange: HttpExchange, code: Int, msg: String): Unit = {
    sendJson(exchange, code, write(ErrorResponse(msg)))
  }

  def todoToJson(t: Todo): ujson.Obj = ujson.Obj(
    "id" -> t.id,
    "title" -> t.title,
    "description" -> t.description,
    "completed" -> t.completed,
    "created_at" -> t.createdAt,
    "updated_at" -> t.updatedAt
  )

  def handleRegister(exchange: HttpExchange): Unit = {
    val body = readBody(exchange)
    val reqOpt = try Some(upickle.default.read[RegisterRequest](body)) catch { case _: Exception => sendError(exchange, 400, "Invalid JSON"); None }
    
    reqOpt.foreach { req =>
      if (req.username.length < 3 || req.username.length > 50 || !req.username.matches("^[a-zA-Z0-9_]+$")) {
        sendError(exchange, 400, "Invalid username")
      } else if (req.password.length < 8) {
        sendError(exchange, 400, "Password too short")
      } else {
        Storage.synchronized {
          if (Storage.usernameToId.contains(req.username)) {
            sendError(exchange, 409, "Username already exists")
          } else {
            val id = Storage.nextUserId
            Storage.nextUserId += 1
            val user = User(id, req.username, req.password)
            Storage.users(id) = user
            Storage.usernameToId(req.username) = id
            sendJson(exchange, 201, write(UserResponse(id, req.username)))
          }
        }
      }
    }
  }

  def handleLogin(exchange: HttpExchange): Unit = {
    val body = readBody(exchange)
    val reqOpt = try Some(upickle.default.read[LoginRequest](body)) catch { case _: Exception => sendError(exchange, 400, "Invalid JSON"); None }
    
    reqOpt.foreach { req =>
      val userOpt = Storage.synchronized {
        Storage.usernameToId.get(req.username).flatMap(Storage.users.get)
      }
      
      userOpt match {
        case Some(user) if user.password == req.password =>
          val token = UUID.randomUUID().toString
          Storage.synchronized {
            Storage.sessions(token) = user.id
          }
          exchange.getResponseHeaders.set("Content-Type", "application/json")
          exchange.getResponseHeaders.set("Set-Cookie", s"session_id=$token; Path=/; HttpOnly")
          val bytes = write(UserResponse(user.id, user.username)).getBytes("UTF-8")
          exchange.sendResponseHeaders(200, bytes.length)
          exchange.getResponseBody.write(bytes)
          exchange.close()
        case _ =>
          sendError(exchange, 401, "Invalid credentials")
      }
    }
  }

  def handleLogout(exchange: HttpExchange): Unit = {
    val userOpt = requireAuth(exchange)
    userOpt.foreach { _ =>
      val cookies = exchange.getRequestHeaders.getFirst("Cookie")
      if (cookies != null) {
        val sessionCookie = cookies.split(";").map(_.trim).find(_.startsWith("session_id="))
        sessionCookie.foreach { c =>
          val token = c.drop(11)
          Storage.synchronized {
            Storage.sessions.remove(token)
          }
        }
      }
      sendJson(exchange, 200, "{}")
    }
  }

  def handleMe(exchange: HttpExchange): Unit = {
    requireAuth(exchange).foreach { user =>
      sendJson(exchange, 200, write(UserResponse(user.id, user.username)))
    }
  }

  def handlePassword(exchange: HttpExchange): Unit = {
    requireAuth(exchange).foreach { user =>
      val body = readBody(exchange)
      val reqOpt = try Some(upickle.default.read[PasswordRequest](body)) catch { case _: Exception => sendError(exchange, 400, "Invalid JSON"); None }
      
      reqOpt.foreach { req =>
        if (req.old_password != user.password) {
          sendError(exchange, 401, "Invalid credentials")
        } else if (req.new_password.length < 8) {
          sendError(exchange, 400, "Password too short")
        } else {
          Storage.synchronized {
            Storage.users(user.id) = user.copy(password = req.new_password)
          }
          sendJson(exchange, 200, "{}")
        }
      }
    }
  }

  def handleGetTodos(exchange: HttpExchange): Unit = {
    requireAuth(exchange).foreach { user =>
      val userTodos = Storage.synchronized {
        Storage.todos.values.filter(_.userId == user.id).toSeq.sortBy(_.id)
      }
      val responseTodos = userTodos.map(todoToJson)
      sendJson(exchange, 200, ujson.write(responseTodos))
    }
  }

  def handleCreateTodo(exchange: HttpExchange): Unit = {
    requireAuth(exchange).foreach { user =>
      val body = readBody(exchange)
      val jsonOpt = try Some(ujson.read(body)) catch { case _: Exception => sendError(exchange, 400, "Invalid JSON"); None }
      
      jsonOpt.foreach { json =>
        val titleOpt = json.obj.get("title").flatMap(_.strOpt)
        if (titleOpt.isEmpty || titleOpt.get.isEmpty) {
          sendError(exchange, 400, "Title is required")
        } else {
          val description = json.obj.get("description").flatMap(_.strOpt).getOrElse("")
          val nowStr = now()
          val newTodo = Storage.synchronized {
            val id = Storage.nextTodoId
            Storage.nextTodoId += 1
            val t = Todo(id, user.id, titleOpt.get, description, false, nowStr, nowStr)
            Storage.todos(id) = t
            t
          }
          
          val respBytes = ujson.write(todoToJson(newTodo)).getBytes("UTF-8")
          exchange.getResponseHeaders.set("Content-Type", "application/json")
          exchange.sendResponseHeaders(201, respBytes.length)
          exchange.getResponseBody.write(respBytes)
          exchange.close()
        }
      }
    }
  }

  def handleGetTodo(exchange: HttpExchange, id: Int): Unit = {
    requireAuth(exchange).foreach { user =>
      val todo = Storage.synchronized { Storage.todos.get(id) }
      todo match {
        case Some(t) if t.userId == user.id =>
          sendJson(exchange, 200, ujson.write(todoToJson(t)))
        case _ =>
          sendError(exchange, 404, "Todo not found")
      }
    }
  }

  def handleUpdateTodo(exchange: HttpExchange, id: Int): Unit = {
    requireAuth(exchange).foreach { user =>
      val body = readBody(exchange)
      val jsonOpt = try Some(ujson.read(body)) catch { case _: Exception => sendError(exchange, 400, "Invalid JSON"); None }
      
      jsonOpt.foreach { json =>
        val todoOpt = Storage.synchronized { Storage.todos.get(id) }
        todoOpt match {
          case Some(t) if t.userId == user.id =>
            if (json.obj.contains("title")) {
              val titleStr = json("title").strOpt.getOrElse("")
              if (titleStr.isEmpty) {
                sendError(exchange, 400, "Title is required")
              } else {
                val newTitle = json.obj.get("title").flatMap(_.strOpt).getOrElse(t.title)
                val newDesc = json.obj.get("description").flatMap(_.strOpt).getOrElse(t.description)
                val newCompleted = json.obj.get("completed").flatMap(_.boolOpt).getOrElse(t.completed)
                val nowStr = now()
                
                val updatedTodo = t.copy(
                  title = newTitle,
                  description = newDesc,
                  completed = newCompleted,
                  updatedAt = nowStr
                )
                
                Storage.synchronized {
                  Storage.todos(id) = updatedTodo
                }
                
                sendJson(exchange, 200, ujson.write(todoToJson(updatedTodo)))
              }
            } else {
              val newDesc = json.obj.get("description").flatMap(_.strOpt).getOrElse(t.description)
              val newCompleted = json.obj.get("completed").flatMap(_.boolOpt).getOrElse(t.completed)
              val nowStr = now()
              
              val updatedTodo = t.copy(
                description = newDesc,
                completed = newCompleted,
                updatedAt = nowStr
              )
              
              Storage.synchronized {
                Storage.todos(id) = updatedTodo
              }
              
              sendJson(exchange, 200, ujson.write(todoToJson(updatedTodo)))
            }
          case _ =>
            sendError(exchange, 404, "Todo not found")
        }
      }
    }
  }

  def handleDeleteTodo(exchange: HttpExchange, id: Int): Unit = {
    val userOpt = requireAuth(exchange)
    userOpt.foreach { user =>
      val todoOpt = Storage.synchronized { Storage.todos.get(id) }
      todoOpt match {
        case Some(t) if t.userId == user.id =>
          Storage.synchronized {
            Storage.todos.remove(id)
          }
          exchange.sendResponseHeaders(204, -1)
          exchange.close()
        case _ =>
          sendError(exchange, 404, "Todo not found")
      }
    }
  }
}

object Main {
  def main(args: Array[String]): Unit = {
    var port = 8080
    var i = 0
    while (i < args.length) {
      if (args(i) == "--port" && i + 1 < args.length) {
        port = args(i + 1).toInt
        i += 2
      } else {
        i += 1
      }
    }

    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)
    server.createContext("/", new TodoHandler())
    server.setExecutor(null)
    server.start()
    println(s"Server started on port $port")
  }
}