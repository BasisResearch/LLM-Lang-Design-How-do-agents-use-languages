CFLAGS=-O2 -Wall -Wextra -pedantic -std=c11
LDFLAGS=
LIBS=-lmicrohttpd -ljansson -lpthread

all: server

server: server.c
	gcc $(CFLAGS) -o server server.c $(LDFLAGS) $(LIBS)

clean:
	rm -f server
