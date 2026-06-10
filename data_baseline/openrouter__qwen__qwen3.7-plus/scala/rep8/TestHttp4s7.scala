//> using scala "2.13.14"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
import cats.effect._
import cats.syntax.applicative._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.generic.semiauto._

object TestHttp4s extends IOApp.Simple {
  case class Err(error: String)
  implicit val errEncoder: Encoder[Err] = deriveEncoder
  
  def routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case GET -> Root / "a" => Ok(Err("test"))
    case GET -> Root / "b" => BadRequest(Err("test2"))
    case GET -> Root / "c" => NotFound(Err("test3"))
    case GET -> Root / "d" => Conflict(Err("test4"))
    case GET -> Root / "e" => Response[IO](Status.Unauthorized).withEntity(Err("test5")).pure[IO]
  }
  
  def run: IO[Unit] = IO.println("It works!")
}
