//> using scala "3.3.1"

import java.net.InetSocketAddress
import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer}
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID
import java.util.concurrent.{ConcurrentHashMap, Executors}
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._

object Main {
  // Models
  case class UserRec(id: Int, username: String, password: String)
  case class TodoRec(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: String,
      updatedAt: String
  )

  // In-memory storage
  object Store {
    val usersById = new ConcurrentHashMap[Int, UserRec]()
    val userIdByUsername = new ConcurrentHashMap[String, Integer]()
    val todosById = new ConcurrentHashMap[Int, TodoRec]()
    val sessions = new ConcurrentHashMap[String, Integer]() // token -> userId
    val nextUserId = new AtomicInteger(1)
    val nextTodoId = new AtomicInteger(1)
  }

  // Helpers
  def nowIso(): String = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString

  def readBody(is: InputStream): String = {
    val buf = new Array[Byte](8192)
    val sb = new StringBuilder
    var n = is.read(buf)
    while (n != -1) {
      sb.append(new String(buf, 0, n, StandardCharsets.UTF_8))
      n = is.read(buf)
    }
    sb.toString
  }

  def jsonEscape(s: String): String =
    s.flatMap {
      case '"' => "\\\""
      case '\\' => "\\\\"
      case '\n' => "\\n"
      case '\r' => "\\r"
      case '\t' => "\\t"
      case c if c.isControl => f"\\u${c.toInt}%04x"
      case c => c.toString
    }

  def sendJson(exchange: HttpExchange, code: Int, body: String): Unit = {
    val bytes = body.getBytes(StandardCharsets.UTF_8)
    val headers = exchange.getResponseHeaders
    headers.set("Content-Type", "application/json")
    exchange.sendResponseHeaders(code, bytes.length)
    val os = exchange.getResponseBody
    try os.write(bytes)
    finally os.close()
  }

  def sendNoContent(exchange: HttpExchange): Unit = {
    exchange.sendResponseHeaders(204, -1) // no body
    exchange.getResponseBody.close()
  }

  def jsonError(exchange: HttpExchange, code: Int, msg: String): Unit = {
    val body = s"{" + s"\"error\":\"${jsonEscape(msg)}\"" + "}"
    sendJson(exchange, code, body)
  }

  def parseCookie(header: String): Map[String, String] = {
    if (header == null) Map.empty
    else header.split(';').toList.flatMap { part =>
      val kv = part.trim.split("=", 2)
      if (kv.length == 2) Some(kv(0) -> kv(1)) else None
    }.toMap
  }

  def getSessionUser(exchange: HttpExchange): Option[UserRec] = {
    val cookieHeader = exchange.getRequestHeaders.getFirst("Cookie")
    val cookies = parseCookie(cookieHeader)
    cookies.get("session_id").flatMap { token =>
      val uidOpt = Option(Store.sessions.get(token)).map(_.intValue())
      uidOpt.flatMap { uid => Option(Store.usersById.get(uid)) }
    }
  }

  def setSessionCookie(exchange: HttpExchange, token: String): Unit = {
    exchange.getResponseHeaders.add("Set-Cookie", s"session_id=$token; Path=/; HttpOnly")
  }

  def parseJsonFieldStr(body: String, key: String): Option[String] = {
    val pattern = ("\\\"" + java.util.regex.Pattern.quote(key) + "\\\"\\s*:\\s*\\\"(.*?)\\\"").r
    pattern.findFirstMatchIn(body).map(_.group(1))
  }
  def parseJsonFieldBool(body: String, key: String): Option[Boolean] = {
    val pattern = ("\\\"" + java.util.regex.Pattern.quote(key) + "\\\"\\s*:\\s*(true|false)").r
    pattern.findFirstMatchIn(body).map(m => m.group(1) == "true")
  }

  def validateUsername(u: String): Boolean = u.matches("^[a-zA-Z0-9_]+$") && u.length >= 3 && u.length <= 50
  def validatePassword(p: String): Boolean = p != null && p.length >= 8

  def handle(exchange: HttpExchange): Unit = {
    try {
      val method = exchange.getRequestMethod
      val path = exchange.getRequestURI.getPath

      (method, path) match {
        case ("POST", "/register") =>
          val body = readBody(exchange.getRequestBody)
          val usernameOpt = parseJsonFieldStr(body, "username")
          val passwordOpt = parseJsonFieldStr(body, "password")
          (usernameOpt, passwordOpt) match {
            case (Some(username), Some(password)) =>
              if (!validateUsername(username)) jsonError(exchange, 400, "Invalid username")
              else if (!validatePassword(password)) jsonError(exchange, 400, "Password too short")
              else {
                val newId = Store.nextUserId.get()
                val existed = Option(Store.userIdByUsername.putIfAbsent(username, Integer.valueOf(newId))).isDefined
                if (existed) jsonError(exchange, 409, "Username already exists")
                else {
                  Store.nextUserId.incrementAndGet()
                  Store.usersById.put(newId, UserRec(newId, username, password))
                  val resp = s"{" + s"\"id\":$newId,\"username\":\"${jsonEscape(username)}\"" + "}"
                  sendJson(exchange, 201, resp)
                }
              }
            case _ => jsonError(exchange, 400, "Invalid JSON")
          }

        case ("POST", "/login") =>
          val body = readBody(exchange.getRequestBody)
          (parseJsonFieldStr(body, "username"), parseJsonFieldStr(body, "password")) match {
            case (Some(username), Some(password)) =>
              val uidOpt = Option(Store.userIdByUsername.get(username)).map(_.intValue())
              val userOpt = uidOpt.flatMap(id => Option(Store.usersById.get(id)))
              userOpt match {
                case Some(u) if u.password == password =>
                  val token = UUID.randomUUID().toString.replaceAll("-", "")
                  Store.sessions.put(token, Integer.valueOf(u.id))
                  setSessionCookie(exchange, token)
                  val resp = s"{" + s"\"id\":${u.id},\"username\":\"${jsonEscape(u.username)}\"" + "}"
                  sendJson(exchange, 200, resp)
                case _ => jsonError(exchange, 401, "Invalid credentials")
              }
            case _ => jsonError(exchange, 400, "Invalid JSON")
          }

        case ("POST", "/logout") =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(_) =>
              val cookieHeader = exchange.getRequestHeaders.getFirst("Cookie")
              val cookies = parseCookie(cookieHeader)
              cookies.get("session_id").foreach(tok => Store.sessions.remove(tok))
              sendJson(exchange, 200, "{}")
          }

        case ("GET", "/me") =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val resp = s"{" + s"\"id\":${u.id},\"username\":\"${jsonEscape(u.username)}\"" + "}"
              sendJson(exchange, 200, resp)
          }

        case ("PUT", "/password") =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val body = readBody(exchange.getRequestBody)
              (parseJsonFieldStr(body, "old_password"), parseJsonFieldStr(body, "new_password")) match {
                case (Some(oldp), Some(newp)) =>
                  if (u.password != oldp) jsonError(exchange, 401, "Invalid credentials")
                  else if (!validatePassword(newp)) jsonError(exchange, 400, "Password too short")
                  else {
                    Store.usersById.put(u.id, u.copy(password = newp))
                    sendJson(exchange, 200, "{}")
                  }
                case _ => jsonError(exchange, 400, "Invalid JSON")
              }
          }

        case (meth, p) if p == "/todos" && meth == "GET" =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val todos = Store.todosById.values().asScala.toList.filter(_.userId == u.id).sortBy(_.id)
              val arr = todos.map { t =>
                s"{" +
                  s"\"id\":${t.id}," +
                  s"\"title\":\"${jsonEscape(t.title)}\"," +
                  s"\"description\":\"${jsonEscape(t.description)}\"," +
                  s"\"completed\":${t.completed}," +
                  s"\"created_at\":\"${jsonEscape(t.createdAt)}\"," +
                  s"\"updated_at\":\"${jsonEscape(t.updatedAt)}\"" +
                "}"
              }.mkString(",")
              sendJson(exchange, 200, s"[${arr}]")
          }

        case (meth, p) if p == "/todos" && meth == "POST" =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val body = readBody(exchange.getRequestBody)
              val titleOpt = parseJsonFieldStr(body, "title").map(_.trim)
              val desc = parseJsonFieldStr(body, "description").getOrElse("")
              titleOpt match {
                case Some(t) if t.nonEmpty =>
                  val id = Store.nextTodoId.getAndIncrement()
                  val now = nowIso()
                  val rec = TodoRec(id, u.id, t, desc, false, now, now)
                  Store.todosById.put(id, rec)
                  val resp = s"{" +
                    s"\"id\":${rec.id}," +
                    s"\"title\":\"${jsonEscape(rec.title)}\"," +
                    s"\"description\":\"${jsonEscape(rec.description)}\"," +
                    s"\"completed\":${rec.completed}," +
                    s"\"created_at\":\"${jsonEscape(rec.createdAt)}\"," +
                    s"\"updated_at\":\"${jsonEscape(rec.updatedAt)}\"" +
                  "}"
                  sendJson(exchange, 201, resp)
                case _ => jsonError(exchange, 400, "Title is required")
              }
          }

        case (meth, p) if p.startsWith("/todos/") && meth == "GET" =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val idStr = p.stripPrefix("/todos/")
              val idOpt = idStr.toIntOption
              idOpt match {
                case None => jsonError(exchange, 404, "Todo not found")
                case Some(id) =>
                  val t = Store.todosById.get(id)
                  if (t == null || t.userId != u.id) jsonError(exchange, 404, "Todo not found")
                  else {
                    val resp = s"{" +
                      s"\"id\":${t.id}," +
                      s"\"title\":\"${jsonEscape(t.title)}\"," +
                      s"\"description\":\"${jsonEscape(t.description)}\"," +
                      s"\"completed\":${t.completed}," +
                      s"\"created_at\":\"${jsonEscape(t.createdAt)}\"," +
                      s"\"updated_at\":\"${jsonEscape(t.updatedAt)}\"" +
                    "}"
                    sendJson(exchange, 200, resp)
                  }
              }
          }

        case (meth, p) if p.startsWith("/todos/") && meth == "PUT" =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val idStr = p.stripPrefix("/todos/")
              idStr.toIntOption match {
                case None => jsonError(exchange, 404, "Todo not found")
                case Some(id) =>
                  val rec = Store.todosById.get(id)
                  if (rec == null || rec.userId != u.id) jsonError(exchange, 404, "Todo not found")
                  else {
                    val body = readBody(exchange.getRequestBody)
                    val titleOpt = parseJsonFieldStr(body, "title").map(_.trim)
                    titleOpt match {
                      case Some(t) if t.isEmpty => jsonError(exchange, 400, "Title is required")
                      case _ =>
                        val descOpt = parseJsonFieldStr(body, "description")
                        val compOpt = parseJsonFieldBool(body, "completed")
                        val updated = rec.copy(
                          title = titleOpt.getOrElse(rec.title),
                          description = descOpt.getOrElse(rec.description),
                          completed = compOpt.getOrElse(rec.completed),
                          updatedAt = nowIso()
                        )
                        Store.todosById.put(id, updated)
                        val resp = s"{" +
                          s"\"id\":${updated.id}," +
                          s"\"title\":\"${jsonEscape(updated.title)}\"," +
                          s"\"description\":\"${jsonEscape(updated.description)}\"," +
                          s"\"completed\":${updated.completed}," +
                          s"\"created_at\":\"${jsonEscape(updated.createdAt)}\"," +
                          s"\"updated_at\":\"${jsonEscape(updated.updatedAt)}\"" +
                        "}"
                        sendJson(exchange, 200, resp)
                    }
                  }
              }
          }

        case (meth, p) if p.startsWith("/todos/") && meth == "DELETE" =>
          getSessionUser(exchange) match {
            case None => jsonError(exchange, 401, "Authentication required")
            case Some(u) =>
              val idStr = p.stripPrefix("/todos/")
              idStr.toIntOption match {
                case None => jsonError(exchange, 404, "Todo not found")
                case Some(id) =>
                  val rec = Store.todosById.get(id)
                  if (rec == null || rec.userId != u.id) jsonError(exchange, 404, "Todo not found")
                  else { Store.todosById.remove(id); sendNoContent(exchange) }
              }
          }

        case _ =>
          jsonError(exchange, 404, "Not found")
      }
    } catch {
      case _: Throwable =>
        try jsonError(exchange, 500, "Internal server error")
        catch case _: Throwable => ()
    } finally {
      if (exchange.getRequestBody != null) try exchange.getRequestBody.close() catch { case _: Throwable => () }
    }
  }

  def parsePort(args: Array[String], default: Int = 8080): Int = {
    val arr = args.toList
    arr.sliding(2, 1).collectFirst { case List("--port", p) if p.forall(_.isDigit) => p.toInt }.getOrElse(default)
  }

  def main(args: Array[String]): Unit = {
    val port = parsePort(args)
    val server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0)
    server.createContext("/", new HttpHandler { def handle(exchange: HttpExchange): Unit = Main.handle(exchange) })
    val exec = Executors.newFixedThreadPool(Math.max(4, Runtime.getRuntime.availableProcessors()))
    server.setExecutor(exec)
    server.start()
    // Block forever
    println(s"Server started on 0.0.0.0:$port")
    val latch = new Object()
    latch.synchronized { latch.wait() }
  }
}
