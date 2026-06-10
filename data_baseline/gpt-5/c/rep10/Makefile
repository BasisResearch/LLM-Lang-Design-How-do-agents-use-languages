CC=gcc
CFLAGS=-O2 -Wall -Wextra -std=c11
LDFLAGS=
LIBS=-lmicrohttpd -ljansson -lpthread

all: server

server: server.c
	$(CC) $(CFLAGS) -o server server.c $(LIBS) $(LDFLAGS)

clean:
	rm -f server
