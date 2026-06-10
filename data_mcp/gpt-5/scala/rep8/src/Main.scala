import java.net.InetSocketAddress
import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer}
import java.util.UUID
import java.util.concurrent.{ConcurrentHashMap, Executors}
import java.util.concurrent.atomic.AtomicInteger
import scala.jdk.CollectionConverters._
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.security.MessageDigest
import java.util.Base64

object Main {
  // Models
  final case class User(id: Int, username: String, passwordHash: String, salt: String)
  final case class TodoRecord(
      id: Int,
      userId: Int,
      title: String,
      description: String,
      completed: Boolean,
      createdAt: Instant,
      updatedAt: Instant
  )

  // Stores
  private val usersByUsername = new ConcurrentHashMap[String, User]()
  private val usersById = new ConcurrentHashMap[Int, User]()
  private val sessions = new ConcurrentHashMap[String, Int]() // token -> userId
  private val todosById = new ConcurrentHashMap[Int, TodoRecord]()

  private val userIdSeq = new AtomicInteger(0)
  private val todoIdSeq = new AtomicInteger(0)

  // Config
  private val SessionCookieName = "session_id"
  private val UsernameRegex = "^[a-zA-Z0-9_]{3,50}$".r
  private val isoFmt = DateTimeFormatter.ISO_INSTANT

  // Utils
  private def nowInstant(): Instant = Instant.now().truncatedTo(ChronoUnit.SECONDS)
  private def sha256(s: String): String = {
    val md = MessageDigest.getInstance("SHA-256")
    val bytes = md.digest(s.getBytes("UTF-8"))
    Base64.getEncoder.encodeToString(bytes)
  }
  private def newSalt(): String = UUID.randomUUID().toString.replaceAll("-", "")
  private def hashPassword(password: String, salt: String): String = sha256(password + ":" + salt)
  private def verifyPassword(password: String, user: User): Boolean = hashPassword(password, user.salt) == user.passwordHash

  private def readBody(ex: HttpExchange): String = {
    val is = ex.getRequestBody
    val sb = new StringBuilder
    val buf = new Array[Byte](8192)
    var n = is.read(buf)
    while (n != -1) { sb.append(new String(buf, 0, n, "UTF-8")); n = is.read(buf) }
    sb.toString
  }

  private def setJsonContentType(ex: HttpExchange): Unit = {
    ex.getResponseHeaders.set("Content-Type", "application/json")
  }

  private def writeJson(ex: HttpExchange, status: Int, json: String): Unit = {
    setJsonContentType(ex)
    val bytes = json.getBytes("UTF-8")
    ex.sendResponseHeaders(status, bytes.length)
    val os = ex.getResponseBody
    os.write(bytes)
    os.flush()
    os.close()
  }

  private def writeEmpty(ex: HttpExchange, status: Int): Unit = {
    ex.sendResponseHeaders(status, -1)
    ex.close()
  }

  private def jsonEscape(s: String): String = {
    val sb = new StringBuilder
    s.foreach {
      case '"' => sb.append("\\\"")
      case '\\' => sb.append("\\\\")
      case '\n' => sb.append("\\n")
      case '\r' => sb.append("\\r")
      case '\t' => sb.append("\\t")
      case c if c < ' ' => sb.append(f"\\u${c.toInt}%04x")
      case c => sb.append(c)
    }
    sb.toString
  }

  private def jsonStr(s: String): String = '"' + jsonEscape(s) + '"'
  private def jsonNum(i: Int): String = i.toString
  private def jsonBool(b: Boolean): String = if (b) "true" else "false"
  private def jsonObj(fields: Seq[(String, String)]): String = {
    val body = fields.map { case (k, v) => jsonStr(k) + ":" + v }.mkString(",")
    "{" + body + "}"
  }
  private def jsonArr(elems: Seq[String]): String = elems.mkString("[", ",", "]")

  private def jsonError(msg: String): String = jsonObj(Seq("error" -> jsonStr(msg)))

  private def cookieHeaderValue(token: String): String = s"$SessionCookieName=$token; Path=/; HttpOnly"

  private def parseCookies(ex: HttpExchange): Map[String, String] = {
    val headers = ex.getRequestHeaders
    val cookies = headers.getOrDefault("Cookie", java.util.Collections.emptyList()).asScala.toList
    cookies
      .flatMap(_.split("; ").toList)
      .flatMap { kv =>
        kv.split("=", 2) match { case Array(k, v) => Some(k.trim -> v.trim); case _ => None }
      }
      .toMap
  }

  private def getAuthedUser(ex: HttpExchange): Option[(User, String)] = {
    val cookies = parseCookies(ex)
    cookies.get(SessionCookieName).flatMap { token =>
      Option(sessions.get(token)).flatMap(uid => Option(usersById.get(uid)).map(u => (u, token)))
    }
  }

  private def requireAuth(ex: HttpExchange)(f: (User, String) => Unit): Unit = {
    getAuthedUser(ex) match {
      case Some((user, token)) => f(user, token)
      case None => writeJson(ex, 401, jsonError("Authentication required"))
    }
  }

  private def publicUser(u: User): String = jsonObj(Seq(
    "id" -> jsonNum(u.id),
    "username" -> jsonStr(u.username)
  ))

  private def todoJson(t: TodoRecord): String = jsonObj(Seq(
    "id" -> jsonNum(t.id),
    "title" -> jsonStr(t.title),
    "description" -> jsonStr(t.description),
    "completed" -> jsonBool(t.completed),
    "created_at" -> jsonStr(isoFmt.format(t.createdAt)),
    "updated_at" -> jsonStr(isoFmt.format(t.updatedAt))
  ))

  // Minimal JSON parser for flat objects with string/bool fields
  sealed trait JVal
  case class JStr(v: String) extends JVal
  case class JNum(v: Double) extends JVal
  case class JBool(v: Boolean) extends JVal
  case object JNull extends JVal
  case class JObject(fields: Map[String, JVal]) extends JVal

  private class Parser(s: String) {
    private var i = 0
    private def peek: Char = if (i < s.length) s.charAt(i) else 0.toChar
    private def next(): Char = { val c = peek; i += 1; c }
    private def skipWs(): Unit = { while (i < s.length && s.charAt(i).isWhitespace) i += 1 }
    private def expect(ch: Char): Unit = { skipWs(); if (next() != ch) throw new RuntimeException("Expected '"+ch+"'") }

    def parse(): JVal = { skipWs(); val v = parseValue(); skipWs(); v }

    private def parseValue(): JVal = {
      skipWs()
      peek match {
        case '"' => JStr(parseString())
        case '{'  => parseObject()
        case 't'  => parseTrue()
        case 'f'  => parseFalse()
        case 'n'  => parseNull()
        case '-' | '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' => JNum(parseNumber())
        case _    => throw new RuntimeException("Unexpected character")
      }
    }

    private def parseString(): String = {
      expect('"')
      val sb = new StringBuilder
      var done = false
      while (!done) {
        val c = next()
        c match {
          case '"' => done = true
          case '\\' =>
            val e = next()
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
                val hex = s.substring(i, i+4)
                i += 4
                sb.append(Integer.parseInt(hex, 16).toChar)
              case _ => throw new RuntimeException("Invalid escape")
            }
          case ch => sb.append(ch)
        }
      }
      sb.toString
    }

    private def parseObject(): JObject = {
      expect('{')
      skipWs()
      var done = false
      val m = scala.collection.mutable.Map.empty[String, JVal]
      if (peek == '}') { next(); return JObject(m.toMap) }
      while (!done) {
        skipWs()
        val key = parseString()
        skipWs(); expect(':')
        val value = parseValue()
        m += (key -> value)
        skipWs()
        peek match {
          case ',' => next()
          case '}' => next(); done = true
          case _   => throw new RuntimeException("Expected ',' or '}'")
        }
      }
      JObject(m.toMap)
    }

    private def parseNumber(): Double = {
      val start = i
      if (peek == '-') i += 1
      while (i < s.length && Character.isDigit(s.charAt(i))) i += 1
      if (i < s.length && s.charAt(i) == '.') { i += 1; while (i < s.length && Character.isDigit(s.charAt(i))) i += 1 }
      if (i < s.length && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
        i += 1
        if (i < s.length && (s.charAt(i) == '+' || s.charAt(i) == '-')) i += 1
        while (i < s.length && Character.isDigit(s.charAt(i))) i += 1
      }
      s.substring(start, i).toDouble
    }

    private def parseTrue(): JBool = { if (s.substring(i, (i+4) min s.length) != "true") throw new RuntimeException("bad true"); i += 4; JBool(true) }
    private def parseFalse(): JBool = { if (s.substring(i, (i+5) min s.length) != "false") throw new RuntimeException("bad false"); i += 5; JBool(false) }
    private def parseNull(): JVal = { if (s.substring(i, (i+4) min s.length) != "null") throw new RuntimeException("bad null"); i += 4; JNull }
  }

  private def parseJsonObject(s: String): Option[JObject] = {
    try {
      new Parser(s).parse() match {
        case o: JObject => Some(o)
        case _ => None
      }
    } catch { case _: Throwable => None }
  }

  private def getString(o: JObject, key: String): Option[String] = o.fields.get(key) match { case Some(JStr(v)) => Some(v); case _ => None }
  private def getBool(o: JObject, key: String): Option[Boolean] = o.fields.get(key) match { case Some(JBool(v)) => Some(v); case _ => None }

  private def handle(ex: HttpExchange): Unit = {
    try {
      val method = ex.getRequestMethod
      val path = ex.getRequestURI.getPath

      (method, path) match {
        // POST /register
        case ("POST", "/register") =>
          parseJsonObject(readBody(ex)) match {
            case None => writeJson(ex, 400, jsonError("Invalid JSON"))
            case Some(json) =>
              val usernameOpt = getString(json, "username")
              val passwordOpt = getString(json, "password")
              (usernameOpt, passwordOpt) match {
                case (Some(username), Some(password)) =>
                  val validUsername = UsernameRegex.pattern.matcher(username).matches()
                  if (!validUsername) writeJson(ex, 400, jsonError("Invalid username"))
                  else if (password.length < 8) writeJson(ex, 400, jsonError("Password too short"))
                  else if (usersByUsername.containsKey(username)) writeJson(ex, 409, jsonError("Username already exists"))
                  else {
                    val id = userIdSeq.incrementAndGet()
                    val salt = newSalt()
                    val ph = hashPassword(password, salt)
                    val user = User(id, username, ph, salt)
                    usersByUsername.put(username, user)
                    usersById.put(id, user)
                    writeJson(ex, 201, publicUser(user))
                  }
                case _ => writeJson(ex, 400, jsonError("Invalid JSON"))
              }
          }

        // POST /login
        case ("POST", "/login") =>
          parseJsonObject(readBody(ex)) match {
            case None => writeJson(ex, 400, jsonError("Invalid JSON"))
            case Some(json) =>
              (getString(json, "username"), getString(json, "password")) match {
                case (Some(username), Some(password)) =>
                  Option(usersByUsername.get(username)) match {
                    case Some(u) if verifyPassword(password, u) =>
                      val token = UUID.randomUUID().toString.replaceAll("-", "")
                      sessions.put(token, u.id)
                      ex.getResponseHeaders.add("Set-Cookie", cookieHeaderValue(token))
                      writeJson(ex, 200, publicUser(u))
                    case _ => writeJson(ex, 401, jsonError("Invalid credentials"))
                  }
                case _ => writeJson(ex, 400, jsonError("Invalid JSON"))
              }
          }

        // POST /logout
        case ("POST", "/logout") =>
          requireAuth(ex) { case (_, token) =>
            sessions.remove(token)
            writeJson(ex, 200, jsonObj(Seq()))
          }

        // GET /me
        case ("GET", "/me") =>
          requireAuth(ex) { case (user, _) =>
            writeJson(ex, 200, publicUser(user))
          }

        // PUT /password
        case ("PUT", "/password") =>
          requireAuth(ex) { case (user, _) =>
            parseJsonObject(readBody(ex)) match {
              case None => writeJson(ex, 400, jsonError("Invalid JSON"))
              case Some(json) =>
                (getString(json, "old_password"), getString(json, "new_password")) match {
                  case (Some(oldp), Some(newp)) =>
                    if (!verifyPassword(oldp, user)) writeJson(ex, 401, jsonError("Invalid credentials"))
                    else if (newp.length < 8) writeJson(ex, 400, jsonError("Password too short"))
                    else {
                      val salt = newSalt()
                      val ph = hashPassword(newp, salt)
                      val updated = user.copy(passwordHash = ph, salt = salt)
                      usersByUsername.put(user.username, updated)
                      usersById.put(user.id, updated)
                      writeJson(ex, 200, jsonObj(Seq()))
                    }
                  case _ => writeJson(ex, 400, jsonError("Invalid JSON"))
                }
            }
          }

        // GET /todos
        case ("GET", "/todos") =>
          requireAuth(ex) { case (user, _) =>
            val todos = todosById.values().asScala.toList.filter(_.userId == user.id).sortBy(_.id).map(todoJson)
            writeJson(ex, 200, jsonArr(todos))
          }

        // POST /todos
        case ("POST", "/todos") =>
          requireAuth(ex) { case (user, _) =>
            parseJsonObject(readBody(ex)) match {
              case None => writeJson(ex, 400, jsonError("Invalid JSON"))
              case Some(json) =>
                getString(json, "title") match {
                  case None => writeJson(ex, 400, jsonError("Title is required"))
                  case Some(titleRaw) =>
                    val title = Option(titleRaw).getOrElse("")
                    if (title.trim.isEmpty) writeJson(ex, 400, jsonError("Title is required"))
                    else {
                      val desc = getString(json, "description").getOrElse("")
                      val id = todoIdSeq.incrementAndGet()
                      val now = nowInstant()
                      val rec = TodoRecord(id, user.id, title.trim, desc, completed = false, createdAt = now, updatedAt = now)
                      todosById.put(id, rec)
                      writeJson(ex, 201, todoJson(rec))
                    }
                }
            }
          }

        // GET /todos/:id
        case ("GET", p) if p.startsWith("/todos/") =>
          requireAuth(ex) { case (user, _) =>
            toIntOpt(pathSegment(p, 2)) match {
              case None => writeJson(ex, 404, jsonError("Todo not found"))
              case Some(id) =>
                Option(todosById.get(id)).filter(_.userId == user.id) match {
                  case Some(rec) => writeJson(ex, 200, todoJson(rec))
                  case None => writeJson(ex, 404, jsonError("Todo not found"))
                }
            }
          }

        // PUT /todos/:id
        case ("PUT", p) if p.startsWith("/todos/") =>
          requireAuth(ex) { case (user, _) =>
            toIntOpt(pathSegment(p, 2)) match {
              case None => writeJson(ex, 404, jsonError("Todo not found"))
              case Some(id) =>
                Option(todosById.get(id)).filter(_.userId == user.id) match {
                  case None => writeJson(ex, 404, jsonError("Todo not found"))
                  case Some(rec) =>
                    parseJsonObject(readBody(ex)) match {
                      case None => writeJson(ex, 400, jsonError("Invalid JSON"))
                      case Some(json) =>
                        getString(json, "title") match {
                          case Some(t) if t.trim.isEmpty => writeJson(ex, 400, jsonError("Title is required"))
                          case _ =>
                            val newTitle = getString(json, "title").map(_.trim).filter(_.nonEmpty).getOrElse(rec.title)
                            val newDesc = getString(json, "description").getOrElse(rec.description)
                            val newCompleted = getBool(json, "completed").getOrElse(rec.completed)
                            val updated = rec.copy(title = newTitle, description = newDesc, completed = newCompleted, updatedAt = nowInstant())
                            todosById.put(id, updated)
                            writeJson(ex, 200, todoJson(updated))
                        }
                    }
                }
            }
          }

        // DELETE /todos/:id
        case ("DELETE", p) if p.startsWith("/todos/") =>
          requireAuth(ex) { case (user, _) =>
            toIntOpt(pathSegment(p, 2)) match {
              case None => writeJson(ex, 404, jsonError("Todo not found"))
              case Some(id) =>
                Option(todosById.get(id)).filter(_.userId == user.id) match {
                  case None => writeJson(ex, 404, jsonError("Todo not found"))
                  case Some(_) =>
                    todosById.remove(id)
                    writeEmpty(ex, 204)
                }
            }
          }

        case _ => writeJson(ex, 404, jsonError("Not found"))
      }
    } catch {
      case _: Throwable => try writeJson(ex, 500, jsonError("Internal server error")) catch { case _: Throwable => () }
    }
  }

  private def pathSegment(path: String, idx: Int): String = {
    val parts = path.split('/')
    if (idx < parts.length) parts(idx) else ""
  }

  private def toIntOpt(s: String): Option[Int] = try Some(s.toInt) catch { case _: Throwable => None }

  def main(args: Array[String]): Unit = {
    var port = 8080
    var bind = "0.0.0.0"
    var i = 0
    while (i < args.length) {
      args(i) match {
        case "--port" if i + 1 < args.length =>
          port = try args(i + 1).toInt catch { case _: Throwable => port }
          i += 2
        case "--bind" if i + 1 < args.length =>
          bind = args(i + 1)
          i += 2
        case _ => i += 1
      }
    }

    val server = HttpServer.create(new InetSocketAddress(bind, port), 0)
    server.createContext("/", new HttpHandler { def handle(ex: HttpExchange): Unit = Main.handle(ex) })
    val executor = Executors.newCachedThreadPool()
    server.setExecutor(executor)
    server.start()
    synchronized { wait() }
  }
}
