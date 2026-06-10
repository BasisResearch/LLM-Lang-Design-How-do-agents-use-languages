import scala.collection.mutable
import java.util.concurrent.atomic.AtomicInteger

class TodoService {
  private val todos = mutable.Map[Int, Todo]()
  private val todoCounter = new AtomicInteger(1)

  // Helper methods for managing todos
  def createTodo(title: String, description: String, userId: Int): Todo = synchronized {
    val id = todoCounter.getAndIncrement()
    val now = DateTimeHelper.nowAsString()
    val todo = Todo(
      id = id,
      title = title,
      description = description,
      completed = false,
      createdAt = now,
      updatedAt = now,
      userId = userId
    )
    todos.put(id, todo)
    todo
  }

  def getTodosByUserId(userId: Int): List[Todo] = {
    todos.values.filter(_.userId == userId).toList.sortBy(_.id)
  }

  def getTodo(todoId: Int, userId: Int): Option[Todo] = {
    todos.get(todoId).filter(_.userId == userId)
  }

  def updateTodo(todoId: Int, userId: Int, title: Option[String], description: Option[String], completed: Option[Boolean]): Option[Todo] = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        val newTitle = title.getOrElse(todo.title)
        val newDescription = description.getOrElse(todo.description)
        val newCompleted = completed.getOrElse(todo.completed)
        val updatedTodo = todo.copy(
          title = newTitle,
          description = newDescription,
          completed = newCompleted,
          updatedAt = DateTimeHelper.nowAsString()
        )
        todos.update(todoId, updatedTodo)
        Some(updatedTodo)
      case _ => None
    }
  }

  def deleteTodo(todoId: Int, userId: Int): Boolean = synchronized {
    todos.get(todoId) match {
      case Some(todo) if todo.userId == userId =>
        todos.remove(todoId)
        true
      case _ => false
    }
  }
}