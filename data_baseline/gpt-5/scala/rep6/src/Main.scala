//> using scala "3.4.2"
//> using dep "com.lihaoyi::cask:0.11.3"
//> using dep "com.lihaoyi::ujson:4.4.3"
//> using option "-deprecation"
//> using option "-Xfatal-warnings"

import cask.MainRoutes
import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
import java.util.UUID
import scala.collection.concurrent.TrieMap
import scala.util.Try

object Util {
  private val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
  def nowIso(): String = fmt.format(Instant.now())
}

case class User(id: Int, username: String, passwordHash: String)
case class Todo(
    id: Int,
    userId: Int,
    title: String,
    description: String,
    completed: Boolean,
    created_at: String,
    updated_at: String
)

class AppServer(portArg: Int) extends MainRoutes {
  override def port: Int = portArg
  override def host: String = "0.0.0.0"

  private val usersById = TrieMap.empty[Int, User]
  private val usersByName = TrieMap.empty[String, User]
  @volatile private var nextUserId = 1

  private val todosById = TrieMap.empty[Int, Todo]
  @volatile private var nextTodoId = 1

  private val sessions = TrieMap.empty[String, Int] // sessionId -> userId

  private def jsonResponse(code: Int, body: ujson.Value, extraHeaders: Seq[(String, String)] = Nil): cask.Response[String] = {
    val headers = Seq("Content-Type" -> "application/json") ++ extraHeaders
    cask.Response(ujson.write(body), statusCode = code, headers = headers)
  }

  private def error(code: Int, msg: String): cask.Response[String] = jsonResponse(code, ujson.Obj("error" -> msg))

  private def validateUsername(username: String): Boolean = {
    username.length >= 3 && username.length <= 50 && username.matches("^[a-zA-Z0-9_]+$")
  }

  private def hash(pw: String): String = {
    val md = java.security.MessageDigest.getInstance("SHA-256")
    java.util.Base64.getEncoder.encodeToString(md.digest(pw.getBytes("UTF-8")))
  }

  private def extractSessionToken(request: cask.Request): Option[String] = {
    request.cookies.get("session_id").map(_.value)
  }

  private def withAuth(request: cask.Request)(f: User => cask.Response[String]): cask.Response[String] = {
    val maybeToken = extractSessionToken(request)
    maybeToken.flatMap(sessions.get) match {
      case None => error(401, "Authentication required")
      case Some(uid) => usersById.get(uid) match {
          case None => error(401, "Authentication required")
          case Some(u) => f(u)
        }
    }
  }

  private def userJson(u: User): ujson.Obj = ujson.Obj(
    "id" -> u.id,
    "username" -> u.username
  )

  private def todoJson(t: Todo): ujson.Obj = ujson.Obj(
    "id" -> t.id,
    "title" -> t.title,
    "description" -> t.description,
    "completed" -> t.completed,
    "created_at" -> t.created_at,
    "updated_at" -> t.updated_at
  )

  @cask.post("/register")
  def register(request: cask.Request): cask.Response[String] = {
    val body = ujson.read(request.text())
    val usernameOpt = body.obj.get("username").collect{ case ujson.Str(s) => s }
    val passwordOpt = body.obj.get("password").collect{ case ujson.Str(s) => s }

    (usernameOpt, passwordOpt) match {
      case (Some(username), Some(password)) =>
        if (!validateUsername(username)) {
          error(400, "Invalid username")
        } else if (password.length < 8) {
          error(400, "Password too short")
        } else {
          synchronized {
            if (usersByName.contains(username)) {
              error(409, "Username already exists")
            } else {
              val id = nextUserId; nextUserId += 1
              val user = User(id, username, hash(password))
              usersById(id) = user
              usersByName(username) = user
              jsonResponse(201, userJson(user))
            }
          }
        }
      case _ => error(400, "Invalid username")
    }
  }

  @cask.post("/login")
  def login(request: cask.Request): cask.Response[String] = {
    val body = ujson.read(request.text())
    val username = body.obj.get("username").collect{ case ujson.Str(s) => s }.getOrElse("")
    val password = body.obj.get("password").collect{ case ujson.Str(s) => s }.getOrElse("")
    usersByName.get(username) match {
      case Some(u) if u.passwordHash == hash(password) =>
        val token = UUID.randomUUID().toString.replaceAll("-", "")
        sessions(token) = u.id
        val setCookie = s"session_id=$token; Path=/; HttpOnly"
        jsonResponse(200, userJson(u), extraHeaders = Seq("Set-Cookie" -> setCookie))
      case _ => error(401, "Invalid credentials")
    }
  }

  @cask.post("/logout")
  def logout(request: cask.Request): cask.Response[String] = withAuth(request) { _ =>
    val maybeToken = extractSessionToken(request)
    maybeToken.foreach(tok => sessions.remove(tok))
    jsonResponse(200, ujson.Obj())
  }

  @cask.get("/me")
  def me(request: cask.Request): cask.Response[String] = withAuth(request) { user =>
    jsonResponse(200, userJson(user))
  }

  @cask.put("/password")
  def changePassword(request: cask.Request): cask.Response[String] = withAuth(request) { user =>
    val body = ujson.read(request.text())
    val oldPw = body.obj.get("old_password").collect{ case ujson.Str(s) => s }.getOrElse("")
    val newPw = body.obj.get("new_password").collect{ case ujson.Str(s) => s }.getOrElse("")
    if (hash(oldPw) != user.passwordHash) {
      error(401, "Invalid credentials")
    } else if (newPw.length < 8) {
      error(400, "Password too short")
    } else {
      val updated = user.copy(passwordHash = hash(newPw))
      usersById(updated.id) = updated
      usersByName(updated.username) = updated
      jsonResponse(200, ujson.Obj())
    }
  }

  private def findUserTodo(userId: Int, id: Int): Either[cask.Response[String], Todo] = {
    todosById.get(id) match {
      case Some(t) if t.userId == userId => Right(t)
      case _ => Left(error(404, "Todo not found"))
    }
  }

  @cask.get("/todos")
  def listTodos(request: cask.Request): cask.Response[String] = withAuth(request) { user =>
    val todos = todosById.values.filter(_.userId == user.id).toList.sortBy(_.id)
    val arr = ujson.Arr.from(todos.map(todoJson))
    jsonResponse(200, arr)
  }

  @cask.post("/todos")
  def createTodo(request: cask.Request): cask.Response[String] = withAuth(request) { user =>
    val body = ujson.read(request.text())
    val titleOpt = body.obj.get("title").collect{ case ujson.Str(s) => s }
    val desc = body.obj.get("description").collect{ case ujson.Str(s) => s }.getOrElse("")
    titleOpt match {
      case Some(t) if t.trim.nonEmpty =>
        val now = Util.nowIso()
        val id = synchronized { val i = nextTodoId; nextTodoId += 1; i }
        val todo = Todo(id, user.id, t, desc, completed = false, created_at = now, updated_at = now)
        todosById(id) = todo
        jsonResponse(201, todoJson(todo))
      case _ => error(400, "Title is required")
    }
  }

  @cask.get("/todos/:id")
  def getTodo(request: cask.Request, id: Int): cask.Response[String] = withAuth(request) { user =>
    findUserTodo(user.id, id) match {
      case Right(t) => jsonResponse(200, todoJson(t))
      case Left(err) => err
    }
  }

  @cask.put("/todos/:id")
  def updateTodo(request: cask.Request, id: Int): cask.Response[String] = withAuth(request) { user =>
    findUserTodo(user.id, id) match {
      case Left(err) => err
      case Right(t) =>
        val body = ujson.read(request.text())
        val titleField = body.obj.get("title").collect{ case ujson.Str(s) => s }
        val descField = body.obj.get("description").collect{ case ujson.Str(s) => s }
        val completedField = body.obj.get("completed").collect{ case ujson.Bool(b) => b }

        if (titleField.exists(_.trim.isEmpty)) {
          error(400, "Title is required")
        } else {
          val now = Util.nowIso()
          val updated = t.copy(
            title = titleField.getOrElse(t.title),
            description = descField.getOrElse(t.description),
            completed = completedField.getOrElse(t.completed),
            updated_at = now
          )
          todosById(id) = updated
          jsonResponse(200, todoJson(updated))
        }
    }
  }

  @cask.delete("/todos/:id")
  def deleteTodo(request: cask.Request, id: Int): cask.Response[String] = withAuth(request) { user =>
    findUserTodo(user.id, id) match {
      case Left(err) => err
      case Right(_) =>
        todosById.remove(id)
        cask.Response("", statusCode = 204, headers = Seq("Content-Type" -> "application/json"))
    }
  }

  // Initialize routes
  initialize()
}

object Main {
  def main(args: Array[String]): Unit = {
    val port = args.sliding(2,1).collectFirst { case Array("--port", p) => Try(p.toInt).getOrElse(8080) }.getOrElse(8080)
    val server = new AppServer(port)
    server.main(Array())
  }
}