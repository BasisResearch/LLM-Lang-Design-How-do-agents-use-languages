import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer, Headers}
import java.net.InetSocketAddress
import java.util.UUID
import java.io.{InputStream, OutputStream}
import java.nio.charset.StandardCharsets
import java.time.{Instant, ZoneOffset, ZonedDateTime}
import java.time.format.DateTimeFormatter
import scala.collection.concurrent.TrieMap
import scala.jdk.CollectionConverters._
import scala.util.Try

object Main:
  case class User(id: Int, username: String, var password: String)
  case class Todo(
      id: Int,
      userId: Int,
      var title: String,
      var description: String,
      var completed: Boolean,
      var createdAt: String,
      var updatedAt: String
  )

  // In-memory stores
  private val usersById = TrieMap.empty[Int, User]
  private val usersByName = TrieMap.empty[String, User]
  private val sessions = TrieMap.empty[String, Int] // token -> userId
  private val todosById = TrieMap.empty[Int, Todo]

  // Atomic counters
  @volatile private var nextUserId = 1
  @volatile private var nextTodoId = 1
  private def genUserId(): Int = synchronized { val id = nextUserId; nextUserId += 1; id }
  private def genTodoId(): Int = synchronized { val id = nextTodoId; nextTodoId += 1; id }

  private val isoFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
  private def nowIso(): String = ZonedDateTime.ofInstant(Instant.now(), ZoneOffset.UTC).format(isoFormatter)

  def main(args: Array[String]): Unit =
    var port = 8080
    var i = 0
    while i < args.length do
      args(i) match
        case "--port" if i + 1 < args.length =>
          port = Try(args(i + 1).toInt).getOrElse(8080)
          i += 1
        case _ =>
      i += 1

    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)

    server.createContext("/register", exchange => handleJson(exchange) { handleRegister })
    server.createContext("/login", exchange => handleJson(exchange) { handleLogin })
    server.createContext("/logout", exchange => handleAuthJson(exchange) { (ex, user) => handleLogout(ex, user) })
    server.createContext("/me", exchange => handleAuthJson(exchange) { (ex, user) => handleMe(ex, user) })
    server.createContext("/password", exchange => handleAuthJson(exchange) { (ex, user) => handlePassword(ex, user) })
    server.createContext("/todos", exchange =>
      val method = exchange.getRequestMethod
      method match
        case "GET" => handleAuth(exchange) { (ex, user) => handleTodosList(ex, user) }
        case "POST" => handleAuthJson(exchange) { (ex, user) => handleTodosCreate(ex, user) }
        case _ => sendJson(exchange, 405, Map("error" -> "Method not allowed"))
    )
    server.createContext("/todos/", exchange => // for /todos/:id
      val method = exchange.getRequestMethod
      handleAuth(exchange) { (ex, user) =>
        val path = ex.getRequestURI.getPath
        val base = "/todos/"
        if !path.startsWith(base) || path.length <= base.length then
          sendJson(ex, 404, Map("error" -> "Not found"))
        else
          val idStr = path.substring(base.length)
          val idOpt = Try(idStr.toInt).toOption
          idOpt match
            case None => sendJson(ex, 404, Map("error" -> "Todo not found"))
            case Some(id) =>
              method match
                case "GET" => handleTodoGet(ex, user, id)
                case "PUT" =>
                  handleJsonBody(ex) { jsonStr => handleTodoUpdate(ex, user, id, jsonStr) }
                case "DELETE" => handleTodoDelete(ex, user, id)
                case _ => sendJson(ex, 405, Map("error" -> "Method not allowed"))
      }
    )

    server.setExecutor(null) // default
    println(s"Server listening on 0.0.0.0:$port")
    server.start()

  // Utilities
  private def readBody(exchange: HttpExchange): String =
    val is = exchange.getRequestBody
    val bytes = is.readAllBytes()
    new String(bytes, StandardCharsets.UTF_8)

  private def setJsonContentType(headers: Headers): Unit =
    headers.set("Content-Type", "application/json")

  private def sendRaw(exchange: HttpExchange, status: Int, body: Array[Byte], contentTypeJson: Boolean = true): Unit =
    if contentTypeJson then setJsonContentType(exchange.getResponseHeaders)
    exchange.sendResponseHeaders(status, body.length)
    val os = exchange.getResponseBody
    os.write(body)
    os.close()

  private def sendJson(exchange: HttpExchange, status: Int, obj: Any): Unit =
    val json = toJson(obj)
    sendRaw(exchange, status, json.getBytes(StandardCharsets.UTF_8))

  private def sendJsonNoBody(exchange: HttpExchange, status: Int): Unit =
    // For DELETE 204: no body and still must set Content-Type? Spec says except DELETE returns no body.
    exchange.getResponseHeaders.set("Content-Type", "application/json")
    exchange.sendResponseHeaders(status, -1)
    exchange.close()

  private def parseJsonObject(str: String): Map[String, Any] =
    // very small and safe JSON parser for simple objects (strings, bools)
    // Since environment is constrained, implement minimal parser
    import scala.util.parsing.json.*
    JSON.parseFull(str) match
      case Some(m: Map[?, ?]) => m.asInstanceOf[Map[String, Any]]
      case _ => Map.empty

  private def toJson(value: Any): String = value match
    case m: Map[?, ?] =>
      m.asInstanceOf[Map[String, Any]].map { case (k, v) => s"\"${escape(k)}\":${toJson(v)}" }.mkString("{", ",", "}")
    case l: List[?] => l.map(toJson).mkString("[", ",", "]")
    case s: String => s"\"${escape(s)}\""
    case i: Int => i.toString
    case b: Boolean => b.toString
    case u: User => toJson(Map("id" -> u.id, "username" -> u.username))
    case t: Todo =>
      toJson(
        Map(
          "id" -> t.id,
          "title" -> t.title,
          "description" -> t.description,
          "completed" -> t.completed,
          "created_at" -> t.createdAt,
          "updated_at" -> t.updatedAt
        )
      )
    case other => s"\"${escape(other.toString)}\""

  private def escape(s: String): String =
    s.flatMap {
      case '"' => "\\\""
      case '\\' => "\\\\"
      case '\n' => "\\n"
      case '\r' => "\\r"
      case '\t' => "\\t"
      case c => c.toString
    }

  // Request handling wrappers
  private def handleJson(exchange: HttpExchange)(f: (HttpExchange, Map[String, Any]) => Unit): Unit =
    try
      val body = readBody(exchange)
      val json = parseJsonObject(body)
      f(exchange, json)
    catch case e: Exception =>
      sendJson(exchange, 400, Map("error" -> "Invalid JSON"))

  private def handleJsonBody(exchange: HttpExchange)(f: String => Unit): Unit =
    try
      val body = readBody(exchange)
      f(body)
    catch case e: Exception =>
      sendJson(exchange, 400, Map("error" -> "Invalid JSON"))

  private def getSessionUser(exchange: HttpExchange): Option[User] =
    val cookies = Option(exchange.getRequestHeaders.getFirst("Cookie")).getOrElse("")
    val tokenOpt = cookies.split("; ").toList
      .flatMap(_.split("=", 2) match
        case Array(name, value) if name == "session_id" => Some(value)
        case _ => None
      ).headOption
    tokenOpt.flatMap(t => sessions.get(t)).flatMap(uid => usersById.get(uid))

  private def handleAuth(exchange: HttpExchange)(f: (HttpExchange, User) => Unit): Unit =
    getSessionUser(exchange) match
      case Some(user) => f(exchange, user)
      case None => sendJson(exchange, 401, Map("error" -> "Authentication required"))

  private def handleAuthJson(exchange: HttpExchange)(f: (HttpExchange, User, Map[String, Any]) => Unit): Unit =
    handleAuth(exchange) { (ex, user) =>
      handleJson(ex) { (ex2, json) => f(ex2, user, json) }
    }

  // Endpoint handlers
  private def handleRegister(exchange: HttpExchange, json: Map[String, Any]): Unit =
    val usernameOpt = json.get("username").collect { case s: String => s }
    val passwordOpt = json.get("password").collect { case s: String => s }
    (usernameOpt, passwordOpt) match
      case (Some(username), Some(password)) =>
        val validUsername = username.matches("^[a-zA-Z0-9_]{3,50}$")
        if !validUsername then
          sendJson(exchange, 400, Map("error" -> "Invalid username"))
        else if password.length < 8 then
          sendJson(exchange, 400, Map("error" -> "Password too short"))
        else if usersByName.contains(username) then
          sendJson(exchange, 409, Map("error" -> "Username already exists"))
        else
          val id = genUserId()
          val user = User(id, username, password)
          usersById.put(id, user)
          usersByName.put(username, user)
          sendJson(exchange, 201, user)
      case _ =>
        sendJson(exchange, 400, Map("error" -> "Invalid JSON"))

  private def handleLogin(exchange: HttpExchange, json: Map[String, Any]): Unit =
    val username = json.get("username").collect { case s: String => s }.getOrElse("")
    val password = json.get("password").collect { case s: String => s }.getOrElse("")
    usersByName.get(username) match
      case Some(user) if user.password == password =>
        val token = UUID.randomUUID().toString.replaceAll("-", "")
        sessions.put(token, user.id)
        val headers = exchange.getResponseHeaders
        headers.add("Set-Cookie", s"session_id=$token; Path=/; HttpOnly")
        sendJson(exchange, 200, user)
      case _ =>
        sendJson(exchange, 401, Map("error" -> "Invalid credentials"))

  private def handleLogout(exchange: HttpExchange, user: User): Unit =
    val cookies = Option(exchange.getRequestHeaders.getFirst("Cookie")).getOrElse("")
    val tokenOpt = cookies.split("; ").toList
      .flatMap(_.split("=", 2) match
        case Array(name, value) if name == "session_id" => Some(value)
        case _ => None
      ).headOption
    tokenOpt.foreach(t => sessions.remove(t))
    sendJson(exchange, 200, Map.empty[String, String])

  private def handleMe(exchange: HttpExchange, user: User): Unit =
    sendJson(exchange, 200, user)

  private def handlePassword(exchange: HttpExchange, user: User, json: Map[String, Any]): Unit =
    val oldPassword = json.get("old_password").collect { case s: String => s }.getOrElse("")
    val newPassword = json.get("new_password").collect { case s: String => s }.getOrElse("")
    if user.password != oldPassword then
      sendJson(exchange, 401, Map("error" -> "Invalid credentials"))
    else if newPassword.length < 8 then
      sendJson(exchange, 400, Map("error" -> "Password too short"))
    else
      user.password = newPassword
      sendJson(exchange, 200, Map.empty[String, String])

  private def todosForUser(uid: Int): List[Todo] =
    todosById.values.filter(_.userId == uid).toList.sortBy(_.id)

  private def handleTodosList(exchange: HttpExchange, user: User): Unit =
    val list = todosForUser(user.id)
    sendJson(exchange, 200, list)

  private def handleTodosCreate(exchange: HttpExchange, user: User, json: Map[String, Any]): Unit =
    val titleOpt = json.get("title").collect { case s: String => s }
    val descOpt = json.get("description").collect { case s: String => s }
    titleOpt match
      case Some(title) if title.trim.nonEmpty =>
        val id = genTodoId()
        val now = nowIso()
        val todo = Todo(id, user.id, title, descOpt.getOrElse(""), completed = false, createdAt = now, updatedAt = now)
        todosById.put(id, todo)
        sendJson(exchange, 201, todo)
      case _ =>
        sendJson(exchange, 400, Map("error" -> "Title is required"))

  private def getTodoOwned(user: User, id: Int): Option[Todo] =
    todosById.get(id).filter(_.userId == user.id)

  private def handleTodoGet(exchange: HttpExchange, user: User, id: Int): Unit =
    getTodoOwned(user, id) match
      case Some(todo) => sendJson(exchange, 200, todo)
      case None => sendJson(exchange, 404, Map("error" -> "Todo not found"))

  private def handleTodoUpdate(exchange: HttpExchange, user: User, id: Int, body: String): Unit =
    getTodoOwned(user, id) match
      case None => sendJson(exchange, 404, Map("error" -> "Todo not found"))
      case Some(todo) =>
        val json = parseJsonObject(body)
        val titleOpt = json.get("title").collect { case s: String => s }
        val descOpt = json.get("description").collect { case s: String => s }
        val compOpt = json.get("completed").collect { case b: Boolean => b }
        titleOpt.foreach { t => if t.trim.isEmpty then return sendJson(exchange, 400, Map("error" -> "Title is required")) }
        titleOpt.foreach(t => todo.title = t)
        descOpt.foreach(d => todo.description = d)
        compOpt.foreach(c => todo.completed = c)
        todo.updatedAt = nowIso()
        sendJson(exchange, 200, todo)

  private def handleTodoDelete(exchange: HttpExchange, user: User, id: Int): Unit =
    getTodoOwned(user, id) match
      case None => sendJson(exchange, 404, Map("error" -> "Todo not found"))
      case Some(todo) =>
        todosById.remove(id)
        // 204, no body
        exchange.getResponseHeaders.set("Content-Type", "application/json")
        exchange.sendResponseHeaders(204, -1)
        exchange.close()
