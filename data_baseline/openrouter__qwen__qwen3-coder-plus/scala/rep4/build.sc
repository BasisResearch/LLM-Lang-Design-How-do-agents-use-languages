import mill._
import mill.scalalib._

object TodoApp extends ScalaModule {
  def scalaVersion = "3.3.0"
  def ivyDeps = Agg(
    ivy"dev.zio::zio:2.0.15",
    ivy"dev.zio::zio-http:3.0.0-RC2",
    ivy"dev.zio::zio-json:0.7.0"
  )
}