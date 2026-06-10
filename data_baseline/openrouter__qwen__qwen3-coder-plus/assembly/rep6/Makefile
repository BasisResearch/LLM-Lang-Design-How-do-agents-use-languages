# Complete Makefile for the assembly HTTP server

CC=nasm
CFLAGS=-f elf64
LD=ld
OBJECTS=main.o http_server.o util.o datastore.o auth.o json_helper.o cookie_utils.o endpoint_handlers.o
BINARY=server

.PHONY: all clean run test

all: $(BINARY)

$(BINARY): $(OBJECTS)
	$(LD) $(OBJECTS) -o $@
	chmod +x $@

main.o: main.asm
	$(CC) $(CFLAGS) $< -o $@

http_server.o: http_server.asm
	$(CC) $(CFLAGS) $< -o $@

util.o: util.asm
	$(CC) $(CFLAGS) $< -o $@

datastore.o: datastore.asm
	$(CC) $(CFLAGS) $< -o $@

auth.o: auth.asm
	$(CC) $(CFLAGS) $< -o $@

json_helper.o: json_helper.asm
	$(CC) $(CFLAGS) $< -o $@

cookie_utils.o: cookie_utils.asm
	$(CC) $(CFLAGS) $< -o $@

endpoint_handlers.o: endpoint_handlers.asm
	$(CC) $(CFLAGS) $< -o $@

# Convenience targets
clean:
	rm -f $(OBJECTS) $(BINARY)
	rm -f server_test.log

run: $(BINARY)
	./$(BINARY) --port 8080

test: $(BINARY)
	@echo "Testing server functionality..."
	@chmod +x test_server.sh
	@./test_server.sh

install-deps:
	@if ! command -v nasm &> /dev/null; then \
		echo "Installing nasm..."; \
		sudo apt-get update && sudo apt-get install -y nasm; \
	fi
	@if ! command -v ld &> /dev/null; then \
		echo "Installing binutils..."; \
		sudo apt-get update && sudo apt-get install -y binutils; \
	fi

debug-server: $(BINARY)
	strace -e trace=network,sendto,recvfrom,bind,listen,accept,socket ./$(BINARY) --port 8080