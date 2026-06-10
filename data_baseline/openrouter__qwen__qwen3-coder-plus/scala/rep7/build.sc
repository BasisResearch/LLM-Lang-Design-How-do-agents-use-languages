//build.sc
import mill._
import mill.scalalib._

object todoapp extends ScalaModule {
  def scalaVersion = "2.13.10"
  
  def ivyDeps = Agg(
    ivy"org.http4s::http4s-dsl:0.23.7",
    ivy"org.http4s::http4s-blaze-server:0.23.7", 
    ivy"org.http4s::http4s-circe:0.23.7",
    ivy"io.circe::circe-generic:0.14.3",
    ivy"io.circe::circe-parser:0.14.3",
    ivy"com.github.etaty:rediscala_2.13:1.8.0"
  )
}