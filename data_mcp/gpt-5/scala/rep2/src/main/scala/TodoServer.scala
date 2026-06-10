import com.sun.net.httpserver.{HttpServer, HttpExchange, HttpHandler, Headers}
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.{ConcurrentHashMap, Executors}
import scala.jdk.CollectionConverters._
import java.nio.charset.StandardCharsets
import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
import scala.util.Try

object TodoServer {
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

  // Thread-safe state
  private val usersById = new ConcurrentHashMap[Int, User]().asScala
  private val usersByUsername = new ConcurrentHashMap[String, User]().asScala
  private val sessions = new ConcurrentHashMap[String, Int]().asScala // token -> userId
  private val todosById = new ConcurrentHashMap[Int, Todo]().asScala
  private val userTodos = new ConcurrentHashMap[Int, collection.concurrent.TrieMap[Int, Boolean]]().asScala // userId -> set of todoIds

  @volatile private var nextUserId: Int = 1
  @volatile private var nextTodoId: Int = 1

  private val isoFormatter: DateTimeFormatter = DateTimeFormatter
    .ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
    .withZone(ZoneOffset.UTC)

  private def nowIso(): String = isoFormatter.format(Instant.now())

  private def jsonEscape(s: String): String =
    s.flatMap {
      case '"' => "\\\""
      case '\\' => "\\\\"
      case '\n' => "\\n"
      case '\r' => "\\r"
      case '\t' => "\\t"
      case c if c < ' ' => f"\\u${c.toInt}%04x"
      case c => c.toString
    }

  private def parseJsonObject(body: String): Map[String, Any] = {
    // Minimal very-safe JSON object parser for our simple flat objects
    // Supports strings, booleans, and ignores whitespace
    // Not a full JSON parser, but sufficient for controlled test inputs
    val trimmed = body.trim
    if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return Map.empty
    val inner = trimmed.substring(1, trimmed.length - 1).trim
    if (inner.isEmpty) return Map.empty

    // Split by commas not inside quotes
    val tokens = scala.collection.mutable.ArrayBuffer[String]()
    val sb = new StringBuilder
    var inStr = false
    var esc = false
    var depth = 0
    inner.foreach { ch =>
      if (esc) { sb.append(ch); esc = false }
      else ch match {
        case '\\' if inStr => esc = true
        case '"' => inStr = !inStr; sb.append(ch)
        case ',' if !inStr && depth == 0 => tokens += sb.toString; sb.clear()
        case '{' if !inStr => depth += 1; sb.append(ch)
        case '}' if !inStr => depth -= 1; sb.append(ch)
        case other => sb.append(other)
      }
    }
    if (sb.nonEmpty) tokens += sb.toString

    def parseValue(v: String): Any = {
      val t = v.trim
      if (t.startsWith("\"") && t.endsWith("\"")) {
        // unescape minimal
        val raw = t.substring(1, t.length - 1)
        val out = new StringBuilder
        var i = 0
        while (i < raw.length) {
          val c = raw.charAt(i)
          if (c == '\\' && i + 1 < raw.length) {
            raw.charAt(i + 1) match {
              case '"' => out.append('"')
              case '\\' => out.append('\\')
              case '/' => out.append('/')
              case 'b' => out.append('\b')
              case 'f' => out.append('\f')
              case 'n' => out.append('\n')
              case 'r' => out.append('\r')
              case 't' => out.append('\t')
              case 'u' if i + 5 < raw.length =>
                val hex = raw.substring(i + 2, i + 6)
                Try(Integer.parseInt(hex, 16)).toOption match {
                  case Some(code) => out.append(code.toChar); i += 4
                  case None => // ignore
                }
              case other => out.append(other)
            }
            i += 2
          } else { out.append(c); i += 1 }
        }
        out.toString
      } else if (t == "true" || t == "false") t.toBoolean
      else if (t == "null") null
      else t
    }

    tokens.flatMap { kv =>
      val parts = kv.split(":", 2)
      if (parts.length != 2) None
      else {
        val keyRaw = parts(0).trim
        val key = if (keyRaw.startsWith("\"") && keyRaw.endsWith("\"")) keyRaw.substring(1, keyRaw.length - 1) else keyRaw
        val value = parseValue(parts(1))
        Some(key -> value)
      }
    }.toMap
  }

  private def readBody(ex: HttpExchange): String = {
    val bytes = ex.getRequestBody.readAllBytes()
    new String(bytes, StandardCharsets.UTF_8)
  }

  private def writeJson(ex: HttpExchange, status: Int, body: String, setCookie: Option[String] = None): Unit = {
    val headers = ex.getResponseHeaders
    headers.set("Content-Type", "application/json")
    setCookie.foreach(c => headers.add("Set-Cookie", c))
    val bytes = body.getBytes(StandardCharsets.UTF_8)
    ex.sendResponseHeaders(status, bytes.length)
    val os = ex.getResponseBody
    os.write(bytes)
    os.flush()
    os.close()
  }

  private def errorJson(msg: String): String = s"{\"error\": \"${jsonEscape(msg)}\"}"

  private def getCookie(ex: HttpExchange, name: String): Option[String] = {
    val cookies = Option(ex.getRequestHeaders.getFirst("Cookie")).getOrElse("")
    cookies.split("; ").toList.flatMap { pair =>
      val idx = pair.indexOf('=')
      if (idx > 0) Some(pair.substring(0, idx) -> pair.substring(idx + 1)) else None
    }.collectFirst { case (k, v) if k == name => v }
  }

  private def authenticate(ex: HttpExchange): Either[Unit, User] = {
    val tokenOpt = getCookie(ex, "session_id")
    tokenOpt.flatMap(t => sessions.get(t).flatMap(usersById.get)) match {
      case Some(u) => Right(u)
      case None =>
        writeJson(ex, 401, errorJson("Authentication required"))
        Left(())
    }
  }

  private def toUserJson(u: User): String = s"{" + s"\"id\": ${u.id}, \"username\": \"${jsonEscape(u.username)}\"" + "}"

  private def toTodoJson(t: Todo): String = {
    s"{" +
      s"\"id\": ${t.id}, " +
      s"\"title\": \"${jsonEscape(t.title)}\", " +
      s"\"description\": \"${jsonEscape(t.description)}\", " +
      s"\"completed\": ${t.completed}, " +
      s"\"created_at\": \"${t.createdAt}\", " +
      s"\"updated_at\": \"${t.updatedAt}\"" +
      s"}"
  }

  private def withJsonBody(ex: HttpExchange)(f: Map[String, Any] => Unit): Unit = {
    val bodyStr = readBody(ex)
    val json = parseJsonObject(bodyStr)
    f(json)
  }

  private def register(ex: HttpExchange): Unit = withJsonBody(ex) { json =>
    val usernameOpt = json.get("username").collect { case s: String => s.trim }
    val passwordOpt = json.get("password").collect { case s: String => s }

    val usernameValid = usernameOpt.exists(u => u.length >= 3 && u.length <= 50 && u.matches("[a-zA-Z0-9_]+"))
    if (!usernameValid) {
      writeJson(ex, 400, errorJson("Invalid username"))
    } else {
      val passwordValid = passwordOpt.exists(_.length >= 8)
      if (!passwordValid) {
        writeJson(ex, 400, errorJson("Password too short"))
      } else {
        val username = usernameOpt.get
        val password = passwordOpt.get
        if (usersByUsername.contains(username)) {
          writeJson(ex, 409, errorJson("Username already exists"))
        } else {
          val id = synchronized { val id = nextUserId; nextUserId += 1; id }
          val user = User(id, username, password)
          usersById.put(id, user)
          usersByUsername.put(username, user)
          writeJson(ex, 201, toUserJson(user))
        }
      }
    }
  }

  private def login(ex: HttpExchange): Unit = withJsonBody(ex) { json =>
    val username = json.get("username").collect { case s: String => s }.getOrElse("")
    val password = json.get("password").collect { case s: String => s }.getOrElse("")

    usersByUsername.get(username) match {
      case Some(user) if user.password == password =>
        val token = UUID.randomUUID().toString.replaceAll("-", "")
        sessions.put(token, user.id)
        val setCookie = s"session_id=${token}; Path=/; HttpOnly"
        writeJson(ex, 200, toUserJson(user), Some(setCookie))
      case _ =>
        writeJson(ex, 401, errorJson("Invalid credentials"))
    }
  }

  private def logout(ex: HttpExchange, user: User): Unit = {
    // invalidate the token used in this request, if any
    getCookie(ex, "session_id").foreach { token => sessions.remove(token) }
    writeJson(ex, 200, "{}")
  }

  private def me(ex: HttpExchange, user: User): Unit = {
    writeJson(ex, 200, toUserJson(user))
  }

  private def changePassword(ex: HttpExchange, user: User): Unit = withJsonBody(ex) { json =>
    val oldPw = json.get("old_password").collect { case s: String => s }.getOrElse("")
    val newPwOpt = json.get("new_password").collect { case s: String => s }

    if (user.password != oldPw) {
      writeJson(ex, 401, errorJson("Invalid credentials"))
    } else if (!newPwOpt.exists(_.length >= 8)) {
      writeJson(ex, 400, errorJson("Password too short"))
    } else {
      val updated = user.copy(password = newPwOpt.get)
      usersById.put(user.id, updated)
      usersByUsername.put(user.username, updated)
      writeJson(ex, 200, "{}")
    }
  }

  private def listTodos(ex: HttpExchange, user: User): Unit = {
    val ids = userTodos.getOrElseUpdate(user.id, collection.concurrent.TrieMap.empty).keys.toSeq.sorted
    val todos = ids.flatMap(todosById.get)
    val body = todos.map(toTodoJson).mkString("[", ",", "]")
    writeJson(ex, 200, body)
  }

  private def createTodo(ex: HttpExchange, user: User): Unit = withJsonBody(ex) { json =>
    val titleOpt = json.get("title").collect { case s: String => s.trim }
    val description = json.get("description").collect { case s: String => s }.getOrElse("")

    if (!titleOpt.exists(_.nonEmpty)) {
      writeJson(ex, 400, errorJson("Title is required"))
    } else {
      val id = synchronized { val id = nextTodoId; nextTodoId += 1; id }
      val ts = nowIso()
      val todo = Todo(id, user.id, titleOpt.get, description, completed = false, createdAt = ts, updatedAt = ts)
      todosById.put(id, todo)
      val set = userTodos.getOrElseUpdate(user.id, collection.concurrent.TrieMap.empty)
      set.put(id, true)
      writeJson(ex, 201, toTodoJson(todo))
    }
  }

  private def getTodo(ex: HttpExchange, user: User, id: Int): Unit = {
    todosById.get(id) match {
      case Some(todo) if todo.userId == user.id => writeJson(ex, 200, toTodoJson(todo))
      case _ => writeJson(ex, 404, errorJson("Todo not found"))
    }
  }

  private def updateTodo(ex: HttpExchange, user: User, id: Int): Unit = withJsonBody(ex) { json =>
    todosById.get(id) match {
      case Some(todo) if todo.userId == user.id =>
        json.get("title") match {
          case Some(s: String) if s.trim.isEmpty =>
            writeJson(ex, 400, errorJson("Title is required"))
          case _ =>
            val newTitle = json.get("title").collect { case s: String => s.trim }
            val newDesc = json.get("description").collect { case s: String => s }
            val newCompleted = json.get("completed").collect { case b: Boolean => b }

            val updated = todo.copy(
              title = newTitle.getOrElse(todo.title),
              description = newDesc.getOrElse(todo.description),
              completed = newCompleted.getOrElse(todo.completed),
              updatedAt = nowIso()
            )
            todosById.put(id, updated)
            writeJson(ex, 200, toTodoJson(updated))
        }
      case _ => writeJson(ex, 404, errorJson("Todo not found"))
    }
  }

  private def notFound(ex: HttpExchange): Unit = writeJson(ex, 404, errorJson("Not found"))

  private def methodNotAllowed(ex: HttpExchange): Unit = writeJson(ex, 405, errorJson("Method not allowed"))

  private def handleRequest(ex: HttpExchange): Unit = {
    try {
      val method = ex.getRequestMethod
      val path = ex.getRequestURI.getPath

      def requireAuth(f: User => Unit): Unit = authenticate(ex) match {
        case Right(u) => f(u)
        case Left(_) => ()
      }

      (method, path) match {
        case ("POST", "/register") => register(ex)
        case ("POST", "/login") => login(ex)
        case ("POST", "/logout") => requireAuth(u => logout(ex, u))
        case ("GET", "/me") => requireAuth(u => me(ex, u))
        case ("PUT", "/password") => requireAuth(u => changePassword(ex, u))
        case ("GET", "/todos") => requireAuth(u => listTodos(ex, u))
        case ("POST", "/todos") => requireAuth(u => createTodo(ex, u))
        case (m, p) if p.startsWith("/todos/") && p.count(_ == '/') == 2 =>
          val idStr = p.split("/").last
          val idOpt = Try(idStr.toInt).toOption
          idOpt match {
            case Some(id) =>
              (method: @unchecked) match {
                case "GET" => requireAuth(u => getTodo(ex, u, id))
                case "PUT" => requireAuth(u => updateTodo(ex, u, id))
                case "DELETE" => requireAuth(u => deleteTodo(ex, u, id))
                case _ => methodNotAllowed(ex)
              }
            case None => notFound(ex)
          }
        case _ => notFound(ex)
      }
    } catch {
      case _: Throwable =>
        writeJson(ex, 500, errorJson("Internal server error"))
    }
  }

  private def deleteTodo(ex: HttpExchange, user: User, id: Int): Unit = {
    todosById.get(id) match {
      case Some(todo) if todo.userId == user.id =>
        todosById.remove(id)
        userTodos.getOrElseUpdate(user.id, collection.concurrent.TrieMap.empty).remove(id)
        // Per spec: 204 no body
        val headers = ex.getResponseHeaders
        headers.set("Content-Type", "application/json")
        ex.sendResponseHeaders(204, -1)
        ex.close()
      case _ => writeJson(ex, 404, errorJson("Todo not found"))
    }
  }

  def main(args: Array[String]): Unit = {
    var port = 8080
    var i = 0
    while (i < args.length) {
      args(i) match {
        case "--port" | "-p" if i + 1 < args.length =>
          port = Try(args(i + 1).toInt).getOrElse(8080)
          i += 2
        case _ =>
          i += 1
      }
    }

    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)
    server.createContext("/", new HttpHandler { override def handle(ex: HttpExchange): Unit = TodoServer.handleRequest(ex) })
    val pool = Executors.newFixedThreadPool(8)
    server.setExecutor(pool)
    server.start()
    println(s"Server started on 0.0.0.0:$port")
  }
}
