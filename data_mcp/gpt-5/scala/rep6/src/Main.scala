//> using scala "2.13.12"

import java.net.InetSocketAddress
import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer, Headers}
import java.io.{InputStream, OutputStream}
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.{ConcurrentHashMap, Executors}
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

object Main {
  // Data API types
  final case class User(id: Int, username: String)
  final case class Todo(
      id: Int,
      title: String,
      description: String,
      completed: Boolean,
      created_at: String,
      updated_at: String
  )

  // Internal storage records
  final case class UserRecord(id: Int, username: String, var password: String)
  final case class TodoRecord(ownerId: Int, var todo: Todo)

  object Storage {
    val userId = new AtomicInteger(0)
    val todoId = new AtomicInteger(0)
    val usersById = new ConcurrentHashMap[Int, UserRecord]()
    val usernameToId = new ConcurrentHashMap[String, Int]()
    val sessions = new ConcurrentHashMap[String, Int]()
    val todos = new ConcurrentHashMap[Int, TodoRecord]()
    val registerLock = new AnyRef
  }

  private val UsernameRegex = "^[a-zA-Z0-9_]{3,50}$".r

  private def nowIso(): String = DateTimeFormatter.ISO_INSTANT.format(Instant.now().truncatedTo(ChronoUnit.SECONDS))

  private def readBody(is: InputStream): String = {
    val bytes = is.readAllBytes()
    new String(bytes, StandardCharsets.UTF_8)
  }

  private def writeResponse(exchange: HttpExchange, status: Int, body: String, isJson: Boolean = true): Unit = {
    val headers = exchange.getResponseHeaders
    if (isJson) headers.set("Content-Type", "application/json")
    val bytes = body.getBytes(StandardCharsets.UTF_8)
    exchange.sendResponseHeaders(status, bytes.length.toLong)
    val os = exchange.getResponseBody
    try os.write(bytes)
    finally os.close()
  }

  private def writeNoContent(exchange: HttpExchange, status: Int = 204): Unit = {
    // No body and no Content-Type header for DELETE 204
    exchange.sendResponseHeaders(status, -1)
    exchange.close()
  }

  // Minimal JSON utilities
  private def jsonEscape(s: String): String = {
    val sb = new StringBuilder
    sb.append('"')
    s.foreach {
      case '"' => sb.append("\\\"")
      case '\\' => sb.append("\\\\")
      case '\b' => sb.append("\\b")
      case '\f' => sb.append("\\f")
      case '\n' => sb.append("\\n")
      case '\r' => sb.append("\\r")
      case '\t' => sb.append("\\t")
      case c if c < ' ' => sb.append(f"\\u${c.toInt}%04x")
      case c => sb.append(c)
    }
    sb.append('"')
    sb.toString
  }

  private def userJson(u: UserRecord): String = s"{" + s"\"id\":${u.id},\"username\":${jsonEscape(u.username)}}"
  private def todoJson(t: Todo): String = {
    val b = new StringBuilder
    b.append('{')
    b.append(s"\"id\":${t.id},")
    b.append(s"\"title\":${jsonEscape(t.title)},")
    b.append(s"\"description\":${jsonEscape(t.description)},")
    b.append(s"\"completed\":${t.completed},")
    b.append(s"\"created_at\":${jsonEscape(t.created_at)},")
    b.append(s"\"updated_at\":${jsonEscape(t.updated_at)}")
    b.append('}')
    b.toString
  }
  private def todosJson(list: List[Todo]): String = list.map(todoJson).mkString("[", ",", "]")

  private def errorJson(msg: String): String = s"{" + s"\"error\":${jsonEscape(msg)}}"

  // Very small JSON object parser for flat objects with string, boolean values only
  private sealed trait JVal
  private case class JStr(v: String) extends JVal
  private case class JBool(v: Boolean) extends JVal
  private case object JNull extends JVal

  private def parseJsonObject(str: String): Either[String, Map[String, JVal]] = {
    var i = 0
    def skipWs(): Unit = { while (i < str.length && str.charAt(i).isWhitespace) i += 1 }
    def expect(ch: Char): Boolean = { skipWs(); if (i < str.length && str.charAt(i) == ch) { i += 1; true } else false }
    def parseString(): Option[String] = {
      skipWs(); if (i >= str.length || str.charAt(i) != '"') return None
      i += 1
      val sb = new StringBuilder
      while (i < str.length) {
        val c = str.charAt(i); i += 1
        c match {
          case '"' => return Some(sb.toString)
          case '\\' => if (i >= str.length) return None else {
              val e = str.charAt(i); i += 1
              e match {
                case '"' => sb.append('"')
                case '\\' => sb.append('\\')
                case '/' => sb.append('/')
                case 'b' => sb.append('\b')
                case 'f' => sb.append('\f')
                case 'n' => sb.append('\n')
                case 'r' => sb.append('\r')
                case 't' => sb.append('\t')
                case 'u' =>
                  if (i + 4 > str.length) return None
                  val hex = str.substring(i, i + 4)
                  try { sb.append(Integer.parseInt(hex, 16).toChar); i += 4 }
                  catch { case _: Throwable => return None }
                case _ => return None
              }
            }
          case other => sb.append(other)
        }
      }
      None
    }
    def parseBool(): Option[Boolean] = {
      skipWs()
      if (str.regionMatches(true, i, "true", 0, 4)) { i += 4; Some(true) }
      else if (str.regionMatches(true, i, "false", 0, 5)) { i += 5; Some(false) }
      else None
    }
    def parseNull(): Boolean = { skipWs(); if (str.regionMatches(true, i, "null", 0, 4)) { i += 4; true } else false }
    def parseValue(): Option[JVal] = {
      skipWs()
      if (i >= str.length) None
      else str.charAt(i) match {
        case '"' => parseString().map(JStr)
        case 't' | 'f' => parseBool().map(JBool)
        case 'n' => if (parseNull()) Some(JNull) else None
        case _ => None
      }
    }

    skipWs()
    if (!expect('{')) return Left("Invalid JSON")
    val map = scala.collection.mutable.Map.empty[String, JVal]
    skipWs()
    if (expect('}')) return Right(map.toMap)
    var cont = true
    while (cont) {
      val key = parseString().getOrElse(return Left("Invalid JSON"))
      if (!expect(':')) return Left("Invalid JSON")
      val value = parseValue().getOrElse(return Left("Invalid JSON"))
      map.update(key, value)
      skipWs()
      if (expect('}')) cont = false
      else if (expect(',')) cont = true
      else return Left("Invalid JSON")
    }
    skipWs()
    Right(map.toMap)
  }

  private def getCookie(exchange: HttpExchange, name: String): Option[String] = {
    val headers = exchange.getRequestHeaders
    val cookies = headers.getOrDefault("Cookie", java.util.Collections.emptyList()).asScala.toList
    cookies.view
      .flatMap(_.split(';').toList)
      .map(_.trim)
      .collectFirst { case s if s.startsWith(name + "=") => s.substring(name.length + 1) }
  }

  private def addSetCookie(headers: Headers, name: String, value: String, path: String = "/", httpOnly: Boolean = true): Unit = {
    val base = s"$name=$value; Path=$path" + (if (httpOnly) "; HttpOnly" else "")
    headers.add("Set-Cookie", base)
  }

  private def withAuth(exchange: HttpExchange)(f: (UserRecord, String) => Unit): Unit = {
    getCookie(exchange, "session_id") match {
      case None => writeResponse(exchange, 401, errorJson("Authentication required"))
      case Some(token) =>
        val uid = Storage.sessions.getOrDefault(token, 0)
        if (uid == 0) writeResponse(exchange, 401, errorJson("Authentication required"))
        else {
          val ur = Storage.usersById.get(uid)
          if (ur == null) writeResponse(exchange, 401, errorJson("Authentication required"))
          else f(ur, token)
        }
    }
  }

  private def handle(exchange: HttpExchange): Unit = {
    try {
      val method = exchange.getRequestMethod
      val path = exchange.getRequestURI.getPath

      def notFound(): Unit = writeResponse(exchange, 404, errorJson("Not found"))

      (method, path) match {
        // POST /register
        case ("POST", "/register") =>
          val body = readBody(exchange.getRequestBody)
          parseJsonObject(body) match {
            case Left(_) => writeResponse(exchange, 400, errorJson("Invalid JSON"))
            case Right(obj) =>
              val usernameOpt = obj.get("username").collect { case JStr(v) => v }
              val passwordOpt = obj.get("password").collect { case JStr(v) => v }
              val username = usernameOpt.getOrElse("")
              val password = passwordOpt.getOrElse(null.asInstanceOf[String])
              val validUsername = UsernameRegex.pattern.matcher(username).matches()
              if (!validUsername) { writeResponse(exchange, 400, errorJson("Invalid username")); return }
              if (password == null || password.length < 8) { writeResponse(exchange, 400, errorJson("Password too short")); return }
              var conflict = false
              var created: UserRecord = null
              Storage.registerLock.synchronized {
                if (Storage.usernameToId.containsKey(username)) conflict = true
                else {
                  val id = Storage.userId.incrementAndGet()
                  val ur = UserRecord(id, username, password)
                  Storage.usersById.put(id, ur)
                  Storage.usernameToId.put(username, id)
                  created = ur
                }
              }
              if (conflict) writeResponse(exchange, 409, errorJson("Username already exists"))
              else writeResponse(exchange, 201, userJson(created))
          }

        // POST /login
        case ("POST", "/login") =>
          val body = readBody(exchange.getRequestBody)
          parseJsonObject(body) match {
            case Left(_) => writeResponse(exchange, 400, errorJson("Invalid JSON"))
            case Right(obj) =>
              val usernameOpt = obj.get("username").collect { case JStr(v) => v }
              val passwordOpt = obj.get("password").collect { case JStr(v) => v }
              val username = usernameOpt.getOrElse("")
              val password = passwordOpt.getOrElse("")
              val uid = Storage.usernameToId.getOrDefault(username, 0)
              val ur = if (uid == 0) null else Storage.usersById.get(uid)
              if (ur == null || ur.password != password) {
                writeResponse(exchange, 401, errorJson("Invalid credentials"))
              } else {
                val token = UUID.randomUUID().toString.replaceAll("-", "")
                Storage.sessions.put(token, ur.id)
                addSetCookie(exchange.getResponseHeaders, "session_id", token, "/", httpOnly = true)
                writeResponse(exchange, 200, userJson(ur))
              }
          }

        // POST /logout
        case ("POST", "/logout") =>
          withAuth(exchange) { (_, token) =>
            Storage.sessions.remove(token)
            writeResponse(exchange, 200, "{}")
          }

        // GET /me
        case ("GET", "/me") =>
          withAuth(exchange) { (ur, _) =>
            writeResponse(exchange, 200, userJson(ur))
          }

        // PUT /password
        case ("PUT", "/password") =>
          withAuth(exchange) { (ur, _) =>
            val body = readBody(exchange.getRequestBody)
            parseJsonObject(body) match {
              case Left(_) => writeResponse(exchange, 400, errorJson("Invalid JSON"))
              case Right(obj) =>
                val oldp = obj.get("old_password").collect { case JStr(v) => v }.orNull
                val newp = obj.get("new_password").collect { case JStr(v) => v }.orNull
                if (oldp == null || ur.password != oldp) { writeResponse(exchange, 401, errorJson("Invalid credentials")); return }
                if (newp == null || newp.length < 8) { writeResponse(exchange, 400, errorJson("Password too short")); return }
                ur.password = newp
                writeResponse(exchange, 200, "{}")
            }
          }

        // GET /todos
        case ("GET", "/todos") =>
          withAuth(exchange) { (ur, _) =>
            val list = Storage.todos.values().asScala.toList
              .filter(_.ownerId == ur.id).map(_.todo).sortBy(_.id)
            writeResponse(exchange, 200, todosJson(list))
          }

        // POST /todos
        case ("POST", "/todos") =>
          withAuth(exchange) { (ur, _) =>
            val body = readBody(exchange.getRequestBody)
            parseJsonObject(body) match {
              case Left(_) => writeResponse(exchange, 400, errorJson("Invalid JSON"))
              case Right(obj) =>
                obj.get("title") match {
                  case None => writeResponse(exchange, 400, errorJson("Title is required"))
                  case Some(JStr(t)) if t.trim.isEmpty => writeResponse(exchange, 400, errorJson("Title is required"))
                  case Some(JStr(t)) =>
                    val id = Storage.todoId.incrementAndGet()
                    val now = nowIso()
                    val desc = obj.get("description").collect { case JStr(v) => v }.getOrElse("")
                    val todo = Todo(id, t, desc, completed = false, created_at = now, updated_at = now)
                    Storage.todos.put(id, TodoRecord(ur.id, todo))
                    writeResponse(exchange, 201, todoJson(todo))
                  case _ => writeResponse(exchange, 400, errorJson("Invalid JSON"))
                }
            }
          }

        // /todos/:id for GET, PUT, DELETE
        case (m, p) if p.startsWith("/todos/") =>
          val rest = p.stripPrefix("/todos/")
          val idOpt = try Some(rest.toInt) catch { case _: Throwable => None }
          idOpt match {
            case None => writeResponse(exchange, 404, errorJson("Todo not found"))
            case Some(tid) => m match {
              case "GET" =>
                withAuth(exchange) { (ur, _) =>
                  val rec = Storage.todos.get(tid)
                  if (rec == null || rec.ownerId != ur.id) writeResponse(exchange, 404, errorJson("Todo not found"))
                  else writeResponse(exchange, 200, todoJson(rec.todo))
                }
              case "PUT" =>
                withAuth(exchange) { (ur, _) =>
                  val rec = Storage.todos.get(tid)
                  if (rec == null || rec.ownerId != ur.id) { writeResponse(exchange, 404, errorJson("Todo not found")); return }
                  val body = readBody(exchange.getRequestBody)
                  parseJsonObject(body) match {
                    case Left(_) => writeResponse(exchange, 400, errorJson("Invalid JSON"))
                    case Right(obj) =>
                      obj.get("title") match {
                        case Some(JStr(t)) if t.trim.isEmpty => writeResponse(exchange, 400, errorJson("Title is required")); return
                        case _ => // ok
                      }
                      val old = rec.todo
                      val newTitle = obj.get("title").collect { case JStr(v) => v }.getOrElse(old.title)
                      val newDesc = obj.get("description").collect { case JStr(v) => v }.getOrElse(old.description)
                      val newCompleted = obj.get("completed").collect { case JBool(v) => v }.getOrElse(old.completed)
                      val updated = old.copy(title = newTitle, description = newDesc, completed = newCompleted, updated_at = nowIso())
                      rec.todo = updated
                      writeResponse(exchange, 200, todoJson(updated))
                  }
                }
              case "DELETE" =>
                withAuth(exchange) { (ur, _) =>
                  val rec = Storage.todos.get(tid)
                  if (rec == null || rec.ownerId != ur.id) writeResponse(exchange, 404, errorJson("Todo not found"))
                  else {
                    Storage.todos.remove(tid)
                    writeNoContent(exchange, 204)
                  }
                }
              case _ => notFound()
            }
          }

        case _ => notFound()
      }
    } catch {
      case _: Throwable =>
        try writeResponse(exchange, 500, errorJson("Internal server error"))
        catch { case _: Throwable => () }
    }
  }

  def main(args: Array[String]): Unit = {
    val defaultPort = 8080
    var port = defaultPort
    var i = 0
    while (i < args.length) {
      if (args(i) == "--port" && i + 1 < args.length) { port = args(i + 1).toInt; i += 2 }
      else i += 1
    }

    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)
    val exec = Executors.newFixedThreadPool(Runtime.getRuntime.availableProcessors().max(4))
    server.setExecutor(exec)
    server.createContext("/", new HttpHandler { def handle(ex: HttpExchange): Unit = Main.handle(ex) })
    server.start()
    // Keep the main thread alive
    println(s"Server started on 0.0.0.0:$port")
  }
}
