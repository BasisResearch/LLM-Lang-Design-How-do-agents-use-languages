//> using scala "3.4.2"
//> using dep "com.lihaoyi::ujson:4.4.3"

import com.sun.net.httpserver.{HttpExchange, HttpServer}
import java.net.{InetSocketAddress, URLDecoder}
import java.nio.charset.StandardCharsets
import java.time.{Instant, ZoneOffset}
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.Executors
import scala.util.Try
import scala.jdk.CollectionConverters.*

object TodoServer:
  case class User(id: Int, username: String, password: String)
  case class Todo(
      id: Int,
      ownerId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: String,
      updatedAt: String
  )

  private val lock = new Object()
  private var usersById = Map.empty[Int, User]
  private var usersByName = Map.empty[String, User]
  private var nextUserId = 1

  private var todosById = Map.empty[Int, Todo]
  private var nextTodoId = 1

  private var sessions = Map.empty[String, Int] // session_id -> userId

  private def nowIsoSeconds(): String =
    Instant.now().truncatedTo(ChronoUnit.SECONDS).atOffset(ZoneOffset.UTC).toInstant.toString

  private def parseJsonBody(exchange: HttpExchange): Option[ujson.Value] =
    val is = exchange.getRequestBody
    val bytes = is.readAllBytes()
    if bytes == null || bytes.isEmpty then Some(ujson.Obj())
    else
      val str = String(bytes, StandardCharsets.UTF_8)
      Try(ujson.read(str)).toOption

  private def getCookie(exchange: HttpExchange, name: String): Option[String] =
    val headers = exchange.getRequestHeaders
    val cookies = Option(headers.getFirst("Cookie")).toList.flatMap(_.split("; *").toList)
    cookies
      .map(s => s.split("=", 2))
      .collect { case Array(k, v) => (k.trim, v.trim) }
      .find(_._1 == name)
      .map(_._2)

  private def getSessionUser(exchange: HttpExchange): Option[User] =
    val sidOpt = getCookie(exchange, "session_id")
    sidOpt.flatMap { sid =>
      lock.synchronized {
        sessions.get(sid).flatMap(uid => usersById.get(uid))
      }
    }

  private def sendJson(exchange: HttpExchange, status: Int, body: ujson.Value): Unit =
    val bytes = body.render().getBytes(StandardCharsets.UTF_8)
    val headers = exchange.getResponseHeaders
    headers.set("Content-Type", "application/json")
    exchange.sendResponseHeaders(status, bytes.length)
    val os = exchange.getResponseBody
    os.write(bytes)
    os.flush()
    os.close()

  private def sendNoContent(exchange: HttpExchange): Unit =
    // No body for 204
    exchange.sendResponseHeaders(204, -1)
    exchange.close()

  private def notFound(exchange: HttpExchange): Unit =
    sendJson(exchange, 404, ujson.Obj("error" -> "Not found"))

  private def authRequired(exchange: HttpExchange): Unit =
    sendJson(exchange, 401, ujson.Obj("error" -> "Authentication required"))

  private def invalidCredentials(exchange: HttpExchange): Unit =
    sendJson(exchange, 401, ujson.Obj("error" -> "Invalid credentials"))

  private def usernameValid(username: String): Boolean =
    username.length >= 3 && username.length <= 50 && username.matches("[a-zA-Z0-9_]+")

  private def passwordValid(pw: String): Boolean = pw.length >= 8

  private def writeSetCookie(exchange: HttpExchange, token: String): Unit =
    exchange.getResponseHeaders.add("Set-Cookie", s"session_id=$token; Path=/; HttpOnly")

  private def parsePath(path: String): List[String] =
    path.split('/').toList.filter(_.nonEmpty).map(p => URLDecoder.decode(p, StandardCharsets.UTF_8))

  private def userToJson(u: User): ujson.Obj = ujson.Obj(
    "id" -> u.id,
    "username" -> u.username
  )

  private def todoToJson(t: Todo): ujson.Obj = ujson.Obj(
    "id" -> t.id,
    "title" -> t.title,
    "description" -> t.description,
    "completed" -> t.completed,
    "created_at" -> t.createdAt,
    "updated_at" -> t.updatedAt
  )

  private def handleRegister(exchange: HttpExchange): Unit =
    val bodyOpt = parseJsonBody(exchange)
    bodyOpt match
      case None => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))
      case Some(json) =>
        val usernameOpt = json.objOpt.flatMap(_.get("username")).flatMap(_.strOpt)
        val passwordOpt = json.objOpt.flatMap(_.get("password")).flatMap(_.strOpt)
        (usernameOpt, passwordOpt) match
          case (Some(username), Some(password)) =>
            if !usernameValid(username) then
              sendJson(exchange, 400, ujson.Obj("error" -> "Invalid username"))
            else if !passwordValid(password) then
              sendJson(exchange, 400, ujson.Obj("error" -> "Password too short"))
            else
              val result = lock.synchronized {
                if usersByName.contains(username) then Left("exists")
                else
                  val id = nextUserId
                  nextUserId += 1
                  val user = User(id, username, password)
                  usersById += (id -> user)
                  usersByName += (username -> user)
                  Right(user)
              }
              result match
                case Left(_) => sendJson(exchange, 409, ujson.Obj("error" -> "Username already exists"))
                case Right(user) =>
                  sendJson(exchange, 201, userToJson(user))
          case _ => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))

  private def handleLogin(exchange: HttpExchange): Unit =
    val bodyOpt = parseJsonBody(exchange)
    bodyOpt match
      case None => invalidCredentials(exchange)
      case Some(json) =>
        val usernameOpt = json.objOpt.flatMap(_.get("username")).flatMap(_.strOpt)
        val passwordOpt = json.objOpt.flatMap(_.get("password")).flatMap(_.strOpt)
        (usernameOpt, passwordOpt) match
          case (Some(username), Some(password)) =>
            val userOpt = lock.synchronized { usersByName.get(username) }
            userOpt match
              case Some(u) if u.password == password =>
                val token = UUID.randomUUID().toString.replaceAll("-", "")
                lock.synchronized { sessions += (token -> u.id) }
                writeSetCookie(exchange, token)
                sendJson(exchange, 200, userToJson(u))
              case _ => invalidCredentials(exchange)
          case _ => invalidCredentials(exchange)

  private def handleLogout(exchange: HttpExchange, user: User): Unit =
    val sid = getCookie(exchange, "session_id")
    sid.foreach { token => lock.synchronized { sessions -= token } }
    sendJson(exchange, 200, ujson.Obj())

  private def handleMe(exchange: HttpExchange, user: User): Unit =
    sendJson(exchange, 200, userToJson(user))

  private def handlePassword(exchange: HttpExchange, user: User): Unit =
    val bodyOpt = parseJsonBody(exchange)
    bodyOpt match
      case None => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))
      case Some(json) =>
        val oldPwOpt = json.objOpt.flatMap(_.get("old_password")).flatMap(_.strOpt)
        val newPwOpt = json.objOpt.flatMap(_.get("new_password")).flatMap(_.strOpt)
        (oldPwOpt, newPwOpt) match
          case (Some(oldp), Some(newp)) =>
            if oldp != user.password then invalidCredentials(exchange)
            else if !passwordValid(newp) then sendJson(exchange, 400, ujson.Obj("error" -> "Password too short"))
            else
              lock.synchronized {
                val updated = user.copy(password = newp)
                usersById += (user.id -> updated)
                usersByName += (user.username -> updated)
              }
              sendJson(exchange, 200, ujson.Obj())
          case _ => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))

  private def handleTodosList(exchange: HttpExchange, user: User): Unit =
    val todos = lock.synchronized {
      todosById.values.filter(_.ownerId == user.id).toList.sortBy(_.id)
    }
    val arr = ujson.Arr.from(todos.map(todoToJson))
    sendJson(exchange, 200, arr)

  private def handleTodosCreate(exchange: HttpExchange, user: User): Unit =
    val bodyOpt = parseJsonBody(exchange)
    bodyOpt match
      case None => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))
      case Some(json) =>
        val titleOpt = json.objOpt.flatMap(_.get("title")).flatMap(_.strOpt)
        val description = json.objOpt.flatMap(_.get("description")).flatMap(_.strOpt).getOrElse("")
        titleOpt match
          case Some(title) if title.trim.nonEmpty =>
            val ts = nowIsoSeconds()
            val todo = lock.synchronized {
              val id = nextTodoId
              nextTodoId += 1
              val t = Todo(id, user.id, title, description, false, ts, ts)
              todosById += (id -> t)
              t
            }
            sendJson(exchange, 201, todoToJson(todo))
          case _ => sendJson(exchange, 400, ujson.Obj("error" -> "Title is required"))

  private def withOwnedTodo(id: Int, user: User)(f: Todo => Unit)(notFoundHandler: => Unit): Unit =
    val todoOpt = lock.synchronized { todosById.get(id) }
    todoOpt match
      case Some(t) if t.ownerId == user.id => f(t)
      case _ => notFoundHandler

  private def handleTodosGet(exchange: HttpExchange, user: User, id: Int): Unit =
    withOwnedTodo(id, user) { t => sendJson(exchange, 200, todoToJson(t)) } {
      sendJson(exchange, 404, ujson.Obj("error" -> "Todo not found"))
    }

  private def handleTodosUpdate(exchange: HttpExchange, user: User, id: Int): Unit =
    val bodyOpt = parseJsonBody(exchange)
    bodyOpt match
      case None => sendJson(exchange, 400, ujson.Obj("error" -> "Invalid JSON"))
      case Some(json) =>
        withOwnedTodo(id, user) { t =>
          val objMap = json.objOpt.getOrElse(scala.collection.mutable.LinkedHashMap.empty[String, ujson.Value])
          val titlePresentEmpty = objMap.get("title").flatMap(_.strOpt).exists(_.trim.isEmpty)
          if titlePresentEmpty then
            sendJson(exchange, 400, ujson.Obj("error" -> "Title is required"))
          else
            val newTitle = objMap.get("title").flatMap(_.strOpt).getOrElse(t.title)
            val newDesc = objMap.get("description").flatMap(_.strOpt).getOrElse(t.description)
            val newCompleted = objMap.get("completed").flatMap(_.boolOpt).getOrElse(t.completed)
            val updated = t.copy(
              title = newTitle,
              description = newDesc,
              completed = newCompleted,
              updatedAt = nowIsoSeconds()
            )
            lock.synchronized { todosById += (id -> updated) }
            sendJson(exchange, 200, todoToJson(updated))
        } {
          sendJson(exchange, 404, ujson.Obj("error" -> "Todo not found"))
        }

  private def handleTodosDelete(exchange: HttpExchange, user: User, id: Int): Unit =
    withOwnedTodo(id, user) { t =>
      lock.synchronized { todosById -= id }
      sendNoContent(exchange)
    } {
      // For errors, still JSON body and content-type
      sendJson(exchange, 404, ujson.Obj("error" -> "Todo not found"))
    }

  private def route(exchange: HttpExchange): Unit =
    try
      val method = exchange.getRequestMethod
      val path = exchange.getRequestURI.getPath
      val parts = parsePath(path)

      def requireAuth(f: User => Unit): Unit =
        getSessionUser(exchange) match
          case Some(u) => f(u)
          case None    => authRequired(exchange)

      (method, parts) match
        case ("POST", List("register")) => handleRegister(exchange)
        case ("POST", List("login"))    => handleLogin(exchange)
        case ("POST", List("logout"))   => requireAuth(u => handleLogout(exchange, u))
        case ("GET", List("me"))        => requireAuth(u => handleMe(exchange, u))
        case ("PUT", List("password"))  => requireAuth(u => handlePassword(exchange, u))
        case ("GET", List("todos"))     => requireAuth(u => handleTodosList(exchange, u))
        case ("POST", List("todos"))    => requireAuth(u => handleTodosCreate(exchange, u))
        case ("GET", List("todos", idStr)) if idStr.forall(_.isDigit) =>
          requireAuth(u => handleTodosGet(exchange, u, idStr.toInt))
        case ("PUT", List("todos", idStr)) if idStr.forall(_.isDigit) =>
          requireAuth(u => handleTodosUpdate(exchange, u, idStr.toInt))
        case ("DELETE", List("todos", idStr)) if idStr.forall(_.isDigit) =>
          requireAuth(u => handleTodosDelete(exchange, u, idStr.toInt))
        case _ => notFound(exchange)
    catch
      case _: Throwable =>
        // Always ensure JSON content-type on errors
        sendJson(exchange, 500, ujson.Obj("error" -> "Internal server error"))
    finally
      ()

  def main(args: Array[String]): Unit =
    var port = 8080
    val it = args.iterator
    while it.hasNext do
      it.next() match
        case "--port" if it.hasNext =>
          Try(it.next().toInt).foreach(p => port = p)
        case _ => ()

    val server = HttpServer.create(InetSocketAddress("0.0.0.0", port), 0)
    server.createContext("/", (exchange: HttpExchange) => route(exchange))
    server.setExecutor(Executors.newCachedThreadPool())
    server.start()
    println(s"Server started on 0.0.0.0:$port")
