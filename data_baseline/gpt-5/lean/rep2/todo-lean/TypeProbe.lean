#eval show IO Unit from do
  let b : ByteArray := "hi".toUTF8
  -- can't easily use reflection; but pattern match to see constructor names
  let s? := String.fromUTF8? b
  -- If it's Option, pattern 'some' compiles, otherwise doesn't
  pure ()
