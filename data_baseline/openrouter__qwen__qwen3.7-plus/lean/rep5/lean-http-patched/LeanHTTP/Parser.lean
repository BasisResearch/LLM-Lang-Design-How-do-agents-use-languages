import LeanHTTP.Types
import Std.Data.HashMap

namespace LeanHTTP

/-- Parser configuration for security limits -/
structure ParseConfig where
  maxHeaderSize : Nat := 8192      -- 8KB
  maxBodySize : Nat := 1048576     -- 1MB

/-- Find position of \r\n\r\n in ByteArray (marks end of headers) -/
private def findHeaderEnd (data : ByteArray) : Option Nat :=
  let rec go (i : Nat) : Option Nat :=
    if i + 3 >= data.size then none
    else if data.get! i == 13 && data.get! (i + 1) == 10 &&
            data.get! (i + 2) == 13 && data.get! (i + 3) == 10 then
      some i
    else go (i + 1)
  go 0

/-- Parse method string to HttpMethod -/
private def parseMethod (s : String) : Option HttpMethod :=
  match s with
  | "GET" => some .GET
  | "POST" => some .POST
  | "PUT" => some .PUT
  | "DELETE" => some .DELETE
  | "PATCH" => some .PATCH
  | "HEAD" => some .HEAD
  | "OPTIONS" => some .OPTIONS
  | _ => none

/-- Convert hex character to Nat (0-15), or none -/
private def hexCharToNat (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

/-- Decode percent-encoded string: %20 → space, etc. -/
private def decodePercent (s : String) : String :=
  let rec go (chars : List Char) (acc : List Char) : List Char :=
    match chars with
    | '%' :: h1 :: h2 :: rest =>
      match hexCharToNat h1, hexCharToNat h2 with
      | some n1, some n2 => go rest (Char.ofNat (n1 * 16 + n2) :: acc)
      | _, _ => go (h1 :: h2 :: rest) ('%' :: acc)
    | c :: rest => go rest (c :: acc)
    | [] => acc.reverse
  String.ofList (go s.toList [])

/-- Decode query string value: same as decodePercent but also + → space -/
private def decodeQueryValue (s : String) : String :=
  decodePercent (s.replace "+" " ")

/-- Normalize path: resolve //, /./, /../ segments. Returns none if path escapes root -/
private def normalizePath (path : String) : Option String :=
  let segments := path.splitOn "/"
  let rec go (segs : List String) (stack : List String) : Option (List String) :=
    match segs with
    | [] => some stack.reverse
    | seg :: rest =>
      if seg == "" || seg == "." then
        go rest stack
      else if seg == ".." then
        match stack with
        | [] => none
        | _ :: tail => go rest tail
      else
        go rest (seg :: stack)
  match go segments [] with
  | none => none
  | some [] => some "/"
  | some segs => some ("/" ++ "/".intercalate segs)

/-- Parse query string: key1=val1&key2=val2, with percent-decoding -/
private def parseQueryString (qs : String) : Std.HashMap String String :=
  if qs.isEmpty then
    {}
  else
    let pairs := qs.splitOn "&"
    pairs.foldl (fun (acc : Std.HashMap String String) pair =>
      match pair.splitOn "=" with
      | [k, v] => acc.insert (decodeQueryValue k) (decodeQueryValue v)
      | [k] => acc.insert (decodeQueryValue k) ""
      | _ => acc
    ) {}

/-- Parse the request line: "GET /path?query HTTP/1.1" -/
private def parseRequestLine (line : String) : Option (HttpMethod × String × String) := do
  let parts := line.splitOn " "
  match parts with
  | [methodStr, uri, _version] =>
    let method ← parseMethod methodStr
    let (path, query) := match uri.splitOn "?" with
      | [p, q] => (p, q)
      | [p] => (p, "")
      | _ => (uri, "")
    some (method, path, query)
  | _ => none

/-- Parse headers from lines -/
private def parseHeaders (lines : List String) : Array (String × String) :=
  lines.foldl (fun acc line =>
    if line.isEmpty then acc
    else
      -- Find first ": " or ":"
      match line.splitOn ": " with
      | k :: rest =>
        if rest.isEmpty then
          match line.splitOn ":" with
          | [] => acc
          | [_] => acc
          | k :: rest => acc.push (k, ":".intercalate rest)
          else acc.push (k, ": ".intercalate rest)
      | _ => acc
  ) #[]

/-- Get Content-Length from headers, validating uniqueness and format -/
private def getContentLength (headers : Array (String × String)) : Option Nat :=
  let clHeaders := headers.filter (fun (k, _) => k.toLower == "content-length")
  if clHeaders.size > 1 then none
  else if h : clHeaders.size > 0 then
    let (_, v) := clHeaders[0]
    v.trimAscii.toString.toNat?
  else some 0

/-- Main HTTP/1.1 request parser with configurable limits -/
def parseRequest (data : ByteArray) (config : ParseConfig := {}) : Option HttpRequest := do
  let headerEnd ← findHeaderEnd data
  -- Check header size limit
  if headerEnd > config.maxHeaderSize then none
  let headerBytes := data.extract 0 headerEnd
  let headerStr := String.fromUTF8! headerBytes
  let lines := headerStr.splitOn "\r\n"
  match lines with
  | [] => none
  | requestLine :: headerLines =>
    let (method, rawPath, queryStr) ← parseRequestLine requestLine
    -- Decode percent-encoding on path
    let decodedPath := decodePercent rawPath
    -- Normalize path (reject traversal)
    let path ← normalizePath decodedPath
    let headers := parseHeaders headerLines
    let contentLength ← getContentLength headers
    -- Check body size limit
    if contentLength > config.maxBodySize then none
    let bodyStart := headerEnd + 4
    let body := if contentLength > 0 && bodyStart + contentLength <= data.size then
      data.extract bodyStart (bodyStart + contentLength)
    else
      ByteArray.empty
    let query := parseQueryString queryStr
    some {
      method := method
      path := path
      headers := headers
      body := body
      params := {}
      query := query
      context := {}
    }

end LeanHTTP
