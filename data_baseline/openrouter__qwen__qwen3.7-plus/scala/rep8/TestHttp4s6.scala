//> using scala "2.13.14"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
//> using dep "io.circe::circe-generic:0.14.15"
import cats.effect._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.generic.semiauto._

object TestHttp4s extends IOApp.Simple {
  import cats.syntax.applicative._
  
  case class Err(error: String)
  implicit val errEncoder: Encoder[Err] = deriveEncoder
  
  def routes: HttpRoutes[IO] = HttpRoutes.of[IO] {
    case GET -> Root / "a" => Ok(Err("test"))
    case GET -> Root / "b" => Response[IO](Status.Unauthorized).withEntity(Err("test2")).pure[IO]
    case GET -> Root / "c" => Response[IO](Status.NotFound).withEntity(Err("test3")).pure[IO]
    case GET -> Root / "d" => Response[IO](Status.Conflict).withEntity(Err("test4")).pure[IO]
  }
  
  def run: IO[Unit] = IO.println("It works!")
}
