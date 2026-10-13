/* The portable I/O path: our own libuv loop, driven from Lean, with no callback entering Lean.
 *
 * Portability is the reason this exists rather than the epoll shim beside it: libuv is epoll on Linux, kqueue on
 * the BSDs and macOS, and IOCP on Windows, while epoll is Linux alone.
 *
 * Shape. The loop belongs to us and runs on a *Lean* thread, one iteration at a time, driven by
 * `np_uv_run_once`. So every libuv callback below fires on a thread Lean already knows about, and crossing back
 * into Lean would be legal -- but none of them do. Each callback only records an event (and, for reads, leaves
 * the bytes in the connection's own buffer), and Lean drains that queue with `np_uv_events` and `np_uv_take`.
 * The file therefore never calls `lean_apply_*`, and never runs Lean code from a thread Lean did not create.
 *
 *   np_uv_start(port)        create our loop, bind, listen; returns the bound port (0 on failure)
 *   np_uv_run_once()         one loop iteration (uv_run, UV_RUN_ONCE); returns whether handles remain
 *   np_uv_events()           drain the event queue: pairs of (kind, conn index)
 *   np_uv_take(idx)          the bytes accumulated on that connection, clearing them
 *   np_uv_write(idx, bytes)  write a response on that connection
 *   np_uv_close(idx)         close a connection (after its write completed)
 *   np_uv_stop()             ask the loop to return
 *
 * Event kinds: 1 = a complete request has arrived, 2 = a write finished, 3 = the peer closed or errored.
 *
 * The read path copies nothing: `alloc_cb` hands libuv the tail of the connection's own buffer, so the kernel
 * reads straight into it and `on_read` only advances a length.
 */
#define _GNU_SOURCE
#include <lean/lean.h>
#include <uv.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CONN 4096
#define MAX_EV 16384
#define READ_CHUNK 16384

typedef struct {
  uv_tcp_t handle;
  char *buf;
  size_t len, cap;
  int idx;
  int used;
} conn_t;

typedef struct {
  uv_write_t req;
  char *p;
} write_req_t;

static uv_loop_t *g_loop = NULL;
static uv_tcp_t g_server;
static uv_signal_t g_sigint, g_sigterm;
static conn_t g_conns[MAX_CONN];
static uint64_t g_ev[MAX_EV][2];
static int g_ev_n = 0;

static void push_ev(uint64_t kind, uint64_t arg) {
  if (g_ev_n < MAX_EV) { g_ev[g_ev_n][0] = kind; g_ev[g_ev_n][1] = arg; g_ev_n++; }
}

/* The request is complete when the header terminator has arrived. Not HTTP parsing: this shim answers any bytes
   with a fixed response, and this is only how it decides a request is finished. */
static int complete(conn_t *c) {
  const char *t = "\r\n\r\n";
  if (c->len < 4) return 0;
  for (size_t i = 0; i + 4 <= c->len; i++)
    if (memcmp(c->buf + i, t, 4) == 0) return 1;
  return 0;
}

static conn_t *slot_alloc(void) {
  for (int i = 0; i < MAX_CONN; i++)
    if (!g_conns[i].used) {
      g_conns[i].used = 1;
      g_conns[i].idx = i;
      g_conns[i].len = 0;
      return &g_conns[i];
    }
  return NULL;
}

static void on_close(uv_handle_t *h) {
  conn_t *c = (conn_t *)h->data;
  free(c->buf);
  c->buf = NULL; c->len = 0; c->cap = 0; c->used = 0;
}

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *out);
static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *b);

static void on_conn(uv_stream_t *server, int status) {
  if (status < 0) return;
  conn_t *c = slot_alloc();
  if (c == NULL) return;
  uv_tcp_init(g_loop, &c->handle);
  c->handle.data = c;
  if (uv_accept(server, (uv_stream_t *)&c->handle) == 0) {
    uv_read_start((uv_stream_t *)&c->handle, alloc_cb, on_read);
  } else {
    uv_close((uv_handle_t *)&c->handle, on_close);
  }
}

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *out) {
  conn_t *c = (conn_t *)h->data;
  if (c->cap - c->len < READ_CHUNK) {
    size_t cap = c->cap ? c->cap * 2 : READ_CHUNK * 4;
    char *p = realloc(c->buf, cap);
    if (p == NULL) { out->base = NULL; out->len = 0; return; }
    c->buf = p; c->cap = cap;
  }
  out->base = c->buf + c->len;
  out->len = c->cap - c->len;
}

static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *b) {
  (void)b;
  conn_t *c = (conn_t *)s->data;
  if (nread > 0) {
    c->len += (size_t)nread;
    if (complete(c)) {
      uv_read_stop(s);
      push_ev(1, (uint64_t)c->idx);
    }
  } else if (nread < 0) {
    push_ev(3, (uint64_t)c->idx);
  }
}

static void on_write(uv_write_t *req, int status) {
  (void)status;
  write_req_t *w = (write_req_t *)req;
  conn_t *c = (conn_t *)req->handle->data;
  free(w->p);
  free(w);
  push_ev(2, (uint64_t)c->idx);
}

static void on_signal(uv_signal_t *h, int signum) {
  (void)h;
  /* Shut down through the same path Lean drives, so the loop stops and Lean can report what it served. */
  push_ev(5, (uint64_t)signum);
  uv_stop(g_loop);
}

LEAN_EXPORT lean_object *np_uv_start(uint32_t port) {
  g_loop = malloc(sizeof(uv_loop_t));
  if (uv_loop_init(g_loop) != 0) return lean_io_result_mk_ok(lean_box(0));
  uv_signal_init(g_loop, &g_sigint);
  uv_signal_start(&g_sigint, on_signal, SIGINT);
  uv_signal_init(g_loop, &g_sigterm);
  uv_signal_start(&g_sigterm, on_signal, SIGTERM);
  uv_tcp_init(g_loop, &g_server);
  struct sockaddr_in addr;
  uv_ip4_addr("127.0.0.1", (int)port, &addr);
  if (uv_tcp_bind(&g_server, (const struct sockaddr *)&addr, 0) != 0)
    return lean_io_result_mk_ok(lean_box(0));
  if (uv_listen((uv_stream_t *)&g_server, 511, on_conn) != 0)
    return lean_io_result_mk_ok(lean_box(0));
  int len = sizeof(addr);
  uv_tcp_getsockname(&g_server, (struct sockaddr *)&addr, &len);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ntohs(addr.sin_port)));
}

LEAN_EXPORT lean_object *np_uv_run_once(void) {
  int active = uv_run(g_loop, UV_RUN_ONCE);
  return lean_io_result_mk_ok(lean_box_uint32(active ? 1 : 0));
}

LEAN_EXPORT lean_object *np_uv_events(void) {
  lean_object *arr = lean_mk_empty_array_with_capacity(lean_box((size_t)(2 * g_ev_n)));
  for (int i = 0; i < g_ev_n; i++) {
    arr = lean_array_push(arr, lean_box_uint64(g_ev[i][0]));
    arr = lean_array_push(arr, lean_box_uint64(g_ev[i][1]));
  }
  g_ev_n = 0;
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_take(uint32_t idx) {
  conn_t *c = &g_conns[idx];
  size_t n = c->len;
  lean_object *arr = lean_alloc_sarray(1, n, n);
  if (n > 0) memcpy(lean_sarray_cptr(arr), c->buf, n);
  c->len = 0;
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_write(uint32_t idx, lean_object *bytes) {
  conn_t *c = &g_conns[idx];
  size_t n = lean_sarray_size(bytes);
  write_req_t *w = malloc(sizeof(write_req_t));
  w->p = malloc(n ? n : 1);
  memcpy(w->p, lean_sarray_cptr(bytes), n);
  uv_buf_t b = uv_buf_init(w->p, (unsigned int)n);
  int rc = uv_write(&w->req, (uv_stream_t *)&c->handle, &b, 1, on_write);
  if (rc != 0) { free(w->p); free(w); }
  return lean_io_result_mk_ok(lean_box_uint32(rc == 0 ? 1 : 0));
}

LEAN_EXPORT lean_object *np_uv_close(uint32_t idx) {
  conn_t *c = &g_conns[idx];
  if (c->used && !uv_is_closing((uv_handle_t *)&c->handle))
    uv_close((uv_handle_t *)&c->handle, on_close);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *np_uv_stop(void) {
  uv_stop(g_loop);
  uv_close((uv_handle_t *)&g_server, NULL);
  uv_close((uv_handle_t *)&g_sigint, NULL);
  uv_close((uv_handle_t *)&g_sigterm, NULL);
  for (int i = 0; i < MAX_CONN; i++)
    if (g_conns[i].used && !uv_is_closing((uv_handle_t *)&g_conns[i].handle))
      uv_close((uv_handle_t *)&g_conns[i].handle, on_close);
  while (uv_run(g_loop, UV_RUN_NOWAIT) != 0) { }
  uv_loop_close(g_loop);
  free(g_loop);
  g_loop = NULL;
  return lean_io_result_mk_ok(lean_box(0));
}
