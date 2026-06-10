//> using scala "2.13.14"
//> using dep "org.http4s::http4s-dsl:0.23.34"
//> using dep "org.http4s::http4s-circe:0.23.34"
import cats.effect._
import org.http4s._
import org.http4s.dsl.io._
import org.http4s.circe.CirceEntityCodec._
import io.circe._
import io.circe.generic.semiauto._

object TestHttp4s extends IOApp.Simple {
  case class Err(error: String)
  implicit val errEncoder: Encoder[Err] = deriveEncoder
  
  def run: IO[Unit] = {
    val res1: IO[Response[IO]] = Response[IO](Status.Unauthorized).withEntity(Err("test"))
    val res2: IO[Response[IO]] = Status.Unauthorized.withEntity(Err("test2"))
    IO.println("It works!")
  }
}
