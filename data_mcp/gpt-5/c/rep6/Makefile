CC=gcc
CFLAGS=-O2 -Wall -Wextra -std=c11
LIBS=-lmicrohttpd -ljansson

all: server

server: server.c
	$(CC) $(CFLAGS) -o server server.c $(LIBS)

clean:
	rm -f server
