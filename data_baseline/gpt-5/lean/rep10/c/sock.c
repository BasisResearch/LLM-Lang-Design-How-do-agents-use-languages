#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// Listen on 0.0.0.0:port
int c_listen(const char* host, unsigned short port) {
  int sockfd = socket(AF_INET, SOCK_STREAM, 0);
  if (sockfd < 0) return -1;
  int opt = 1;
  setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (host == NULL || strlen(host) == 0) {
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
  } else {
    if (strcmp(host, "0.0.0.0") == 0) {
      addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else {
      if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(sockfd);
        return -1;
      }
    }
  }
  if (bind(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    close(sockfd);
    return -1;
  }
  if (listen(sockfd, 128) < 0) {
    close(sockfd);
    return -1;
  }
  return sockfd;
}

int c_accept(int sockfd) {
  struct sockaddr_in cli;
  socklen_t len = sizeof(cli);
  int fd = accept(sockfd, (struct sockaddr*)&cli, &len);
  return fd;
}

int c_read1(int fd) {
  unsigned char c;
  ssize_t n = read(fd, &c, 1);
  if (n <= 0) return -1;
  return (int)c;
}

ssize_t c_write(int fd, const void* buf, size_t n) {
  size_t written = 0;
  const unsigned char* p = (const unsigned char*)buf;
  while (written < n) {
    ssize_t r = write(fd, p + written, n - written);
    if (r <= 0) return r;
    written += (size_t)r;
  }
  return (ssize_t)written;
}

int c_close(int fd) { return close(fd); }
