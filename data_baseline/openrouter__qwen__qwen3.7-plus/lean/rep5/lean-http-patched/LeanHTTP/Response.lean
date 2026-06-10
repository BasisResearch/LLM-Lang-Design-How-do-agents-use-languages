import LeanHTTP.Types

namespace LeanHTTP

namespace HttpResponse

def statusTextFor (status : Nat) : String :=
  match status with
  | 200 => "OK"
  | 201 => "Created"
  | 204 => "No Content"
  | 400 => "Bad Request"
  | 404 => "Not Found"
  | 405 => "Method Not Allowed"
  | 408 => "Request Timeout"
  | 413 => "Payload Too Large"
  | 429 => "Too Many Requests"
  | 301 => "Moved Permanently"
  | 302 => "Found"
  | 307 => "Temporary Redirect"
  | 308 => "Permanent Redirect"
  | 500 => "Internal Server Error"
  | 503 => "Service Unavailable"
  | 504 => "Gateway Timeout"
  | _ => "Unknown"

def ok (body : String) : HttpResponse :=
  { status := 200, statusText := "OK",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def created (body : String) : HttpResponse :=
  { status := 201, statusText := "Created",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def noContent : HttpResponse :=
  { status := 204, statusText := "No Content",
    headers := #[],
    body := ByteArray.empty }

def badRequest (body : String) : HttpResponse :=
  { status := 400, statusText := "Bad Request",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def notFound : HttpResponse :=
  { status := 404, statusText := "Not Found",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString "Not Found".utf8ByteSize)],
    body := "Not Found".toUTF8 }

def methodNotAllowed : HttpResponse :=
  { status := 405, statusText := "Method Not Allowed",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString "Method Not Allowed".utf8ByteSize)],
    body := "Method Not Allowed".toUTF8 }

def methodNotAllowedWith (methods : Array String) : HttpResponse :=
  let allow := ", ".intercalate methods.toList
  { status := 405, statusText := "Method Not Allowed",
    headers := #[("Allow", allow), ("Content-Type", "text/plain"),
                 ("Content-Length", toString "Method Not Allowed".utf8ByteSize)],
    body := "Method Not Allowed".toUTF8 }

def internalServerError (body : String) : HttpResponse :=
  { status := 500, statusText := "Internal Server Error",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def json (status : Nat) (body : String) : HttpResponse :=
  { status := status, statusText := statusTextFor status,
    headers := #[("Content-Type", "application/json"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def requestTimeout : HttpResponse :=
  { status := 408, statusText := "Request Timeout",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString "Request Timeout".utf8ByteSize)],
    body := "Request Timeout".toUTF8 }

def payloadTooLarge (msg : String := "Payload Too Large") : HttpResponse :=
  { status := 413, statusText := "Payload Too Large",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString msg.utf8ByteSize)],
    body := msg.toUTF8 }

def serviceUnavailable : HttpResponse :=
  { status := 503, statusText := "Service Unavailable",
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString "Service Unavailable".utf8ByteSize)],
    body := "Service Unavailable".toUTF8 }

def redirect (url : String) (status : Nat := 302) : HttpResponse :=
  { status := status, statusText := statusTextFor status,
    headers := #[("Location", url), ("Content-Length", "0")],
    body := ByteArray.empty }

def movedPermanently (url : String) : HttpResponse := redirect url 301
def found (url : String) : HttpResponse := redirect url 302
def temporaryRedirect (url : String) : HttpResponse := redirect url 307
def permanentRedirect (url : String) : HttpResponse := redirect url 308

def html (status : Nat) (body : String) : HttpResponse :=
  { status := status, statusText := statusTextFor status,
    headers := #[("Content-Type", "text/html; charset=utf-8"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

def text (status : Nat) (body : String) : HttpResponse :=
  { status := status, statusText := statusTextFor status,
    headers := #[("Content-Type", "text/plain"), ("Content-Length", toString body.utf8ByteSize)],
    body := body.toUTF8 }

end HttpResponse

-- Serialize HTTP response to wire format
def HttpResponse.toByteArray (resp : HttpResponse) : ByteArray :=
  let statusLine := s!"HTTP/1.1 {resp.status} {resp.statusText}\r\n"
  let headers := resp.headers.foldl (fun acc (k, v) => acc ++ s!"{k}: {v}\r\n") ""
  let head := statusLine ++ headers ++ "\r\n"
  head.toUTF8 ++ resp.body

end LeanHTTP
