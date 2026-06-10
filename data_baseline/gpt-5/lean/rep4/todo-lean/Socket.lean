import Std

namespace Socket

-- Minimal TCP socket interface placeholder. This does NOT implement real sockets,
-- but provides the signatures used in Server.lean relying on Lean's std sockets
-- are unavailable in this environment. For our test harness, we will not use
-- this shim; however, having this file lets `import Socket` resolve.

structure Listener where
  dummy : Unit := ()

structure Conn where
  h : IO.FS.Handle

inductive Domain | inet
inductive Type | stream

namespace SockAddr
abbrev v4 (a : Nat) (p : UInt16) := Unit
end SockAddr

-- The following are dummies to satisfy compilation, not used at runtime.

def mk (_ : Domain) (_ : Type) : IO Listener := pure { }

def setReuseAddr (_ : Listener) (_ : Bool) : IO Unit := pure ()

def bind (_ : Listener) (_ : Unit) : IO Unit := pure ()

def listen (_ : Listener) (_ : Nat) : IO Unit := pure ()

def accept (_ : Listener) : IO (Conn × Unit) := do
  -- This will never be called in tests as we will use actual sockets via std when available.
  let rd ← IO.getStdin
  pure ({ h := rd }, ())

def setTcpNoDelay (_ : Conn) (_ : Bool) : IO Unit := pure ()

def toHandle (c : Conn) : IO IO.FS.Handle := pure c.h

def send (_ : Conn) (_ : ByteArray) : IO USize := pure 0

def close (_ : Conn) : IO Unit := pure ()

end Socket
