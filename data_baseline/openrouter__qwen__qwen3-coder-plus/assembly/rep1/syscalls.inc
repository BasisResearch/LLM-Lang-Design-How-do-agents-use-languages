; System call numbers for Linux x86_64
SYS_READ         equ 0
SYS_WRITE        equ 1
SYS_OPEN         equ 2
SYS_CLOSE        equ 3
SYS_STAT         equ 4
SYS_FSTAT        equ 5
SYS_LSEEK        equ 8
SYS_MMAP         equ 9
SYS_MUNMAP       equ 11
SYS_SOCKET       equ 41
SYS_BIND         equ 49
SYS_LISTEN       equ 50
SYS_ACCEPT       equ 43
SYS_CONNECT      equ 42
SYS_RECVFROM     equ 45
SYS_SENDTO       equ 44
SYS_SETSOCKOPT   equ 54
SYS_GETSOCKOPT   equ 55
SYS_RECVMSG      equ 47
SYS_SENDMSG      equ 46
SYS_SHUTDOWN     equ 48
SYS_EXIT         equ 60
SYS_GETPID       equ 39
SYS_CLOCK_GETTIME equ 228

; Socket domain/protocol types
AF_UNSPEC        equ 0
AF_UNIX          equ 1
AF_INET          equ 2
AF_INET6         equ 10

SOCK_STREAM      equ 1
SOCK_DGRAM       equ 2
SOCK_RAW         equ 3

SOL_SOCKET       equ 1
SO_REUSEADDR     equ 2
SO_ERROR         equ 4
SO_BINDTODEVICE  equ 25

IPPROTO_IP       equ 0
IPPROTO_IPV6     equ 41
IPPROTO_TCP      equ 6
IPPROTO_UDP      equ 17

TCP_NODELAY      equ 1

; File descriptors
STDIN_FILENO     equ 0
STDOUT_FILENO    equ 1
STDERR_FILENO    equ 2

; Return constants
EAGAIN           equ 11
EWOULDBLOCK      equ 11
EFAULT           equ 14
EINVAL           equ 22

; mmap flags
MAP_PRIVATE      equ 2
MAP_SHARED       equ 1
MAP_ANONYMOUS    equ 0x20
MAP_FAILED       equ 0xffffffffffffffff

; mmap prot
PROT_READ        equ 1
PROT_WRITE       equ 2
PROT_EXEC        equ 4