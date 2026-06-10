namespace TodoApp

/-- Simple UUID generation using timestamp - NOT a real UUID but serves our purpose for uniqueness -/
def generateSessionId : IO String := do
  let timestamp ← IO.monoMsNow
  let randomPart := toString (timestamp % 1000000000000)  -- Use microseconds to ensure variety
  return "sess_" ++ randomPart

end TodoApp