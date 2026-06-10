import mill._
import mill.scalalib._

object TodoApp extends ScalaModule {
  def scalaVersion = "2.13.10"
  def ivyDeps = Agg(
    ivy"com.typesafe.akka::akka-http:10.2.9",
    ivy"com.typesafe.akka::akka-actor-typed:2.6.19", 
    ivy"com.typesafe.akka::akka-stream:2.6.19",
    ivy"io.spray::spray-json:1.3.6"
  )
}