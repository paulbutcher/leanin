#include <arpa/inet.h>
#include <netinet/in.h>
/* Fair E0 baseline: the same minimal HTTP/1.1 keep-alive server and response as uring-http.c, on libuv.
 *
 * Build: cc -O2 -o /tmp/libuv-http bench/libuv-http.c -luv
 * Run:   /tmp/libuv-http 8486
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define BUF_SIZE 16384
static const char response[] =
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";

typedef struct {
  uv_tcp_t handle;
  char *in;
  size_t in_len;
  int closing;
} conn_t;

static void on_close(uv_handle_t *h) {
  conn_t *c = (conn_t *)h->data;
  free(c->in);
  free(c);
}

static void on_write(uv_write_t *req, int status) {
  free(req->data);
  free(req);
  (void)status;
}

static void respond(conn_t *c) {
  uv_write_t *req = malloc(sizeof(*req));
  char *body = malloc(sizeof(response) - 1);
  if (!req || !body) { free(req); free(body); return; }
  memcpy(body, response, sizeof(response) - 1);
  req->data = body;
  uv_buf_t b = uv_buf_init(body, sizeof(response) - 1);
  if (uv_write(req, (uv_stream_t *)&c->handle, &b, 1, on_write) != 0) {
    free(body); free(req);
  }
}

static void consume(conn_t *c) {
  for (;;) {
    char *end = NULL;
    for (size_t i = 0; i + 3 < c->in_len; i++) {
      if (c->in[i] == '\r' && c->in[i + 1] == '\n' && c->in[i + 2] == '\r' && c->in[i + 3] == '\n') {
        end = c->in + i + 4;
        break;
      }
    }
    if (!end) return;
    size_t used = (size_t)(end - c->in);
    memmove(c->in, end, c->in_len - used);
    c->in_len -= used;
    respond(c);
    return;
  }
}

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *out) {
  (void)h; (void)suggested;
  out->base = malloc(BUF_SIZE);
  out->len = out->base ? BUF_SIZE : 0;
}

static void on_read(uv_stream_t *s, ssize_t n, const uv_buf_t *b) {
  conn_t *c = (conn_t *)s->data;
  if (n > 0) {
    if (c->in_len + (size_t)n < BUF_SIZE) {
      memcpy(c->in + c->in_len, b->base, (size_t)n);
      c->in_len += (size_t)n;
      consume(c);
    }
  } else if (n == UV_EOF || n < 0) {
    if (!c->closing) {
      c->closing = 1;
      uv_close((uv_handle_t *)&c->handle, on_close);
    }
  }
  free(b->base);
}

static void on_conn(uv_stream_t *server, int status) {
  if (status < 0) return;
  conn_t *c = calloc(1, sizeof(*c));
  if (!c) return;
  c->in = malloc(BUF_SIZE);
  if (!c->in) { free(c); return; }
  uv_tcp_init(server->loop, &c->handle);
  c->handle.data = c;
  if (uv_accept(server, (uv_stream_t *)&c->handle) != 0) {
    uv_close((uv_handle_t *)&c->handle, on_close);
    return;
  }
  uv_tcp_nodelay(&c->handle, 1);
  uv_read_start((uv_stream_t *)&c->handle, alloc_cb, on_read);
}

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 8486;
  uv_loop_t *loop = uv_default_loop();
  uv_tcp_t server;
  uv_tcp_init(loop, &server);
  uv_tcp_nodelay(&server, 1);
  struct sockaddr_in addr;
  uv_ip4_addr("127.0.0.1", port, &addr);
  if (uv_tcp_bind(&server, (const struct sockaddr *)&addr, 0) != 0 ||
      uv_listen((uv_stream_t *)&server, 512, on_conn) != 0) {
    fprintf(stderr, "bind/listen failed\n");
    return 1;
  }
  int len = sizeof(addr);
  uv_tcp_getsockname(&server, (struct sockaddr *)&addr, &len);
  printf("libuv-http listening on %d\n", ntohs(addr.sin_port));
  fflush(stdout);
  uv_run(loop, UV_RUN_DEFAULT);
  return 0;
}
