CC=gcc
CFLAGS=-O2 -Wall -Wextra -pthread
LDFLAGS=
LIBS=

all: server

server: server.c
	$(CC) $(CFLAGS) -o server server.c $(LIBS)

clean:
	rm -f server
