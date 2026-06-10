//> using scala 3.3.3
//> using dep "dev.zio::zio-http:3.0.1"
//> using dep "io.circe::circe-core:0.14.10"
//> using dep "io.circe::circe-parser:0.14.10"

import zio.*
import zio.http.*
import zio.http.codec.PathCodec.string
import io.circe.*
import io.circe.parser.*
import io.circe.syntax.*
import java.time.{ZoneOffset, ZonedDateTime}
import java.time.format.DateTimeFormatter
import java.util.UUID

case class User(id: Int, username: String, password: String)

case class Todo(
  id: Int,
  userId: Int,
  title: String,
  description: String,
  completed: Boolean,
  created_at: String,
  updated_at: String
)

object Todo:
  def now: String = ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"))

case class State(
  nextUserId: Int,
  users: Map[Int, User],
  userByName: Map[String, User],
  nextTodoId: Int,
  todos: Map[Int, Todo],
  sessions: Map[String, Int]
)

val initial = State(1, Map.empty, Map.empty, 1, Map.empty, Map.empty)

@main def runServer(args: String*): Unit =
  val port = args.indexOf("--port") match
    case i if i >= 0 && i + 1 < args.length => args(i + 1).toInt
    case _ => 8080
  
  val runtime = Runtime.default
  Unsafe.unsafe { implicit unsafe =>
    runtime.unsafe.run {
      for
        stateRef <- Ref.make(initial)
        _ <- Server.serve(appRoutes(stateRef)).provide(
          Server.live,
          ZLayer.succeed(Server.Config.default.port(port))
        )
      yield ()
    } match
      case Exit.Success(_) => ()
      case Exit.Failure(cause) => 
        _root_.scala.Console.err.println(s"Server failed: $cause")
        _root_.java.lang.System.exit(1)
  }

def requireAuth(req: Request, stateRef: Ref[State]): ZIO[Any, Response, (User, State)] =
  val tokenOpt = req.headers.get("cookie").flatMap { cookieHeader =>
    cookieHeader.split(";").map(_.trim).find(_.startsWith("session_id=")).map(_.drop(11))
  }
  for
    token <- ZIO.fromOption(tokenOpt).orElseFail(Response.json("""{"error": "Authentication required"}""").status(Status.Unauthorized))
    state <- stateRef.get
    userId <- ZIO.fromOption(state.sessions.get(token)).orElseFail(Response.json("""{"error": "Authentication required"}""").status(Status.Unauthorized))
    user <- ZIO.fromOption(state.users.get(userId)).orElseFail(Response.json("""{"error": "Authentication required"}""").status(Status.Unauthorized))
  yield (user, state)

def handle(f: Request => ZIO[Any, Throwable | Response, Response]): RequestHandler[Any, Nothing] =
  handler { (req: Request) => 
    f(req).catchAll {
      case res: Response => ZIO.succeed(res)
      case _ => ZIO.succeed(Response.json("""{"error": "Internal server error"}""").status(Status.InternalServerError))
    }
  }

def appRoutes(stateRef: Ref[State]): Routes[Any, Nothing] = Routes(
  Method.POST / "register" -> handle { req =>
    for
      body <- req.body.asString
      json = parse(body).getOrElse(Json.Null)
      username <- ZIO.fromOption(json.hcursor.downField("username").as[String].toOption).orElseFail(Response.json("""{"error": "Invalid JSON"}""").status(Status.BadRequest))
      password <- ZIO.fromOption(json.hcursor.downField("password").as[String].toOption).orElseFail(Response.json("""{"error": "Invalid JSON"}""").status(Status.BadRequest))
      _ <- ZIO.unless(username.matches("^[a-zA-Z0-9_]{3,50}$")) {
        ZIO.fail(Response.json("""{"error": "Invalid username"}""").status(Status.BadRequest))
      }
      _ <- ZIO.unless(password.length >= 8) {
        ZIO.fail(Response.json("""{"error": "Password too short"}""").status(Status.BadRequest))
      }
      state <- stateRef.get
      _ <- ZIO.when(state.userByName.contains(username)) {
        ZIO.fail(Response.json("""{"error": "Username already exists"}""").status(Status.Conflict))
      }
      user = User(state.nextUserId, username, password)
      _ <- stateRef.update(s => s.copy(
        nextUserId = s.nextUserId + 1,
        users = s.users + (user.id -> user),
        userByName = s.userByName + (username -> user)
      ))
      userJson = Json.obj("id" -> user.id.asJson, "username" -> user.username.asJson)
    yield Response.json(userJson.noSpaces).status(Status.Created)
  },

  Method.POST / "login" -> handle { req =>
    for
      body <- req.body.asString
      json = parse(body).getOrElse(Json.Null)
      username <- ZIO.fromOption(json.hcursor.downField("username").as[String].toOption).orElseFail(Response.json("""{"error": "Invalid credentials"}""").status(Status.Unauthorized))
      password <- ZIO.fromOption(json.hcursor.downField("password").as[String].toOption).orElseFail(Response.json("""{"error": "Invalid credentials"}""").status(Status.Unauthorized))
      state <- stateRef.get
      userOpt = state.userByName.get(username).filter(_.password == password)
      user <- ZIO.fromOption(userOpt).orElseFail(Response.json("""{"error": "Invalid credentials"}""").status(Status.Unauthorized))
      token = UUID.randomUUID().toString.replace("-", "")
      _ <- stateRef.update(s => s.copy(sessions = s.sessions + (token -> user.id)))
      userJson = Json.obj("id" -> user.id.asJson, "username" -> user.username.asJson)
    yield Response.json(userJson.noSpaces).addHeader(Header.Custom("Set-Cookie", s"session_id=$token; Path=/; HttpOnly"))
  },

  Method.POST / "logout" -> handle { req =>
    for
      authRes <- requireAuth(req, stateRef)
      state = authRes._2
      tokenOpt = req.headers.get("cookie").flatMap(_.split(";").map(_.trim).find(_.startsWith("session_id=")).map(_.drop(11)))
      _ <- tokenOpt match
        case Some(token) => stateRef.update(s => s.copy(sessions = s.sessions - token))
        case None => ZIO.unit
    yield Response.json("{}")
  },

  Method.GET / "me" -> handle { req =>
    for
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      userJson = Json.obj("id" -> user.id.asJson, "username" -> user.username.asJson)
    yield Response.json(userJson.noSpaces)
  },

  Method.PUT / "password" -> handle { req =>
    for
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      body <- req.body.asString
      json = parse(body).getOrElse(Json.Null)
      oldPasswordOpt = json.hcursor.downField("old_password").as[String].toOption
      newPasswordOpt = json.hcursor.downField("new_password").as[String].toOption
      _ <- ZIO.unless(oldPasswordOpt.contains(user.password)) {
        ZIO.fail(Response.json("""{"error": "Invalid credentials"}""").status(Status.Unauthorized))
      }
      _ <- ZIO.unless(newPasswordOpt.exists(_.length >= 8)) {
        ZIO.fail(Response.json("""{"error": "Password too short"}""").status(Status.BadRequest))
      }
      _ <- stateRef.update(s => s.copy(
        users = s.users + (user.id -> user.copy(password = newPasswordOpt.get))
      ))
    yield Response.json("{}")
  },

  Method.GET / "todos" -> handle { req =>
    for
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      state = authRes._2
      todos = state.todos.values.filter(_.userId == user.id).toList.sortBy(_.id)
      todoJsons = todos.map(t => Json.obj(
        "id" -> t.id.asJson,
        "title" -> t.title.asJson,
        "description" -> t.description.asJson,
        "completed" -> t.completed.asJson,
        "created_at" -> t.created_at.asJson,
        "updated_at" -> t.updated_at.asJson
      ))
    yield Response.json(todoJsons.asJson.noSpaces)
  },

  Method.POST / "todos" -> handle { req =>
    for
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      state = authRes._2
      body <- req.body.asString
      json = parse(body).getOrElse(Json.Null)
      titleOpt = json.hcursor.downField("title").as[String].toOption
      _ <- ZIO.unless(titleOpt.exists(_.trim.nonEmpty)) {
        ZIO.fail(Response.json("""{"error": "Title is required"}""").status(Status.BadRequest))
      }
      description = json.hcursor.downField("description").as[String].toOption.getOrElse("")
      now = Todo.now
      todo = Todo(state.nextTodoId, user.id, titleOpt.getOrElse(""), description, false, now, now)
      _ <- stateRef.update(s => s.copy(
        nextTodoId = s.nextTodoId + 1,
        todos = s.todos + (todo.id -> todo)
      ))
      todoJson = Json.obj(
        "id" -> todo.id.asJson,
        "title" -> todo.title.asJson,
        "description" -> todo.description.asJson,
        "completed" -> todo.completed.asJson,
        "created_at" -> todo.created_at.asJson,
        "updated_at" -> todo.updated_at.asJson
      )
    yield Response.json(todoJson.noSpaces).status(Status.Created)
  },

  Method.GET / "todos" / string("id") -> handler { (idStr: String, req: Request) =>
    val effect: ZIO[Any, Throwable | Response, Response] = for
      id <- ZIO.attempt(idStr.toInt).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      state = authRes._2
      todo <- ZIO.fromOption(state.todos.get(id)).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      _ <- ZIO.unless(todo.userId == user.id) {
        ZIO.fail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      }
      todoJson = Json.obj(
        "id" -> todo.id.asJson,
        "title" -> todo.title.asJson,
        "description" -> todo.description.asJson,
        "completed" -> todo.completed.asJson,
        "created_at" -> todo.created_at.asJson,
        "updated_at" -> todo.updated_at.asJson
      )
    yield Response.json(todoJson.noSpaces)
    
    effect.catchAll {
      case res: Response => ZIO.succeed(res)
      case _ => ZIO.succeed(Response.json("""{"error": "Internal server error"}""").status(Status.InternalServerError))
    }
  },

  Method.PUT / "todos" / string("id") -> handler { (idStr: String, req: Request) =>
    val effect: ZIO[Any, Throwable | Response, Response] = for
      id <- ZIO.attempt(idStr.toInt).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      state = authRes._2
      todo <- ZIO.fromOption(state.todos.get(id)).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      _ <- ZIO.unless(todo.userId == user.id) {
        ZIO.fail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      }
      body <- req.body.asString
      json = parse(body).getOrElse(Json.Null)
      titleOpt = json.hcursor.downField("title").as[String].toOption
      _ <- ZIO.when(titleOpt.exists(_.trim.isEmpty)) {
        ZIO.fail(Response.json("""{"error": "Title is required"}""").status(Status.BadRequest))
      }
      descriptionOpt = json.hcursor.downField("description").as[String].toOption
      completedOpt = json.hcursor.downField("completed").as[Boolean].toOption
      now = Todo.now
      newTodo = todo.copy(
        title = titleOpt.getOrElse(todo.title),
        description = descriptionOpt.getOrElse(todo.description),
        completed = completedOpt.getOrElse(todo.completed),
        updated_at = now
      )
      _ <- stateRef.update(s => s.copy(todos = s.todos + (id -> newTodo)))
      todoJson = Json.obj(
        "id" -> newTodo.id.asJson,
        "title" -> newTodo.title.asJson,
        "description" -> newTodo.description.asJson,
        "completed" -> newTodo.completed.asJson,
        "created_at" -> newTodo.created_at.asJson,
        "updated_at" -> newTodo.updated_at.asJson
      )
    yield Response.json(todoJson.noSpaces)
    
    effect.catchAll {
      case res: Response => ZIO.succeed(res)
      case _ => ZIO.succeed(Response.json("""{"error": "Internal server error"}""").status(Status.InternalServerError))
    }
  },

  Method.DELETE / "todos" / string("id") -> handler { (idStr: String, req: Request) =>
    val effect: ZIO[Any, Throwable | Response, Response] = for
      id <- ZIO.attempt(idStr.toInt).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      authRes <- requireAuth(req, stateRef)
      user = authRes._1
      state = authRes._2
      todo <- ZIO.fromOption(state.todos.get(id)).orElseFail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      _ <- ZIO.unless(todo.userId == user.id) {
        ZIO.fail(Response.json("""{"error": "Todo not found"}""").status(Status.NotFound))
      }
      _ <- stateRef.update(s => s.copy(todos = s.todos - id))
    yield Response(Status.NoContent)
    
    effect.catchAll {
      case res: Response => ZIO.succeed(res)
      case _ => ZIO.succeed(Response.json("""{"error": "Internal server error"}""").status(Status.InternalServerError))
    }
  }
)