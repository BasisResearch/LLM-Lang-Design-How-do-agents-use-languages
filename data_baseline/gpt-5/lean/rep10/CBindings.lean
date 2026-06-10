@[extern "c_listen"]
opaque c_listen (host : @& String) (port : @& UInt16) : IO Int32

@[extern "c_accept"]
opaque c_accept (sockfd : @& Int32) : IO Int32

@[extern "c_read1"]
opaque c_read1 (fd : @& Int32) : IO Int32

@[extern "c_write"]
opaque c_write (fd : @& Int32) (buf : @& ByteArray) (n : @& USize) : IO Int32

@[extern "c_close"]
opaque c_close (fd : @& Int32) : IO Int32
