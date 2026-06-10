import scala.collection.mutable
import java.util.UUID

// Simple in-memory session storage
class SessionManager {
  private val activeSessions = mutable.Map[String, Int]()  // sessionId -> userId
  
  def createSession(userId: Int): String = {
    val sessionId = generateSessionId()
    activeSessions.put(sessionId, userId)
    sessionId
  }
  
  def getUserIdForSession(sessionId: String): Option[Int] = {
    // In a real app, we'd also verify session expiration here
    activeSessions.get(sessionId)
  }
  
  def destroySession(sessionId: String): Unit = {
    activeSessions.remove(sessionId)
  }
  
  private def generateSessionId(): String = {
    UUID.randomUUID().toString
  }
}