/*
 * neturing.c — the LeanIn socket shim on io_uring, with libuv retained only for the loop's wake, timers and
 * signals.
 *
 * The contract is `c/netuv.c`'s: carriers enqueue submissions under a mutex; the loop thread applies them to the
 * ring; completions are drained into the same `(kind, conn, arg)` event queue; `np_uv_take` copies a read's
 * bytes; `np_uv_run_once_timeout` parks the loop for the wheel.
 *
 * What changes is the network path. accept/recv/send/writev/shutdown/close are io_uring operations, not
 * epoll + read/write syscalls. libuv's loop is kept because it owns the cross-thread async wake, the wheel
 * timer and the signal watcher; an eventfd registered with the ring wakes a `uv_poll` on the loop when a
 * completion arrives, so the loop still has one parking point.
 *
 * Deliberately not ported yet: the libuv backend's always-armed read and its MAX_BUF backpressure. Here one
 * submitted read owns exactly one recv; the next read is a new submission. That is the same observable
 * one-completion-per-read contract, with less kernel work when the consumer is slow.
 */
#define _GNU_SOURCE
#include <lean/lean.h>
#include <uv.h>
#include <liburing.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_CONN 4096
#define MAX_SUBMIT 8192
#define READ_CHUNK 16384
#define MAX_READ 65536
#define MAX_BUF (256 * 1024)

#define EV_ACCEPT 1
#define EV_READ 2
#define EV_WRITE 3
#define EV_SHUTDOWN 4
#define EV_OVERFLOW 5
#define EV_NO_SLOT 6
#define EV_SIGNAL 7

#define SUB_READ 1
#define SUB_WRITE 2
#define SUB_SHUTDOWN 3
#define SUB_CLOSE 4
#define SUB_WRITEV 5
#define SUB_SIGNAL 6
#define SUB_CANCEL 7

/* user_data: 32 bits of slot generation, 8 bits of operation, 8 bits reserved, 16 bits connection. */
#define UD_OP(ud)   ((int)(((ud) >> 24) & 0xff))
#define UD_CONN(ud) ((uint32_t)((ud) & 0xffff))
#define UD_GEN(ud)  ((uint32_t)((ud) >> 32))
#define UD_MAKE(gen, op, conn) (((uint64_t)(gen) << 32) | ((uint64_t)(op) << 24) | (uint64_t)(conn))

typedef struct {
  int fd;
  char *buf;
  size_t len, cap;
  size_t want;
  int idx;
  int used;
  int closing;
  uint32_t gen;
  int shutting;
  int read_inflight;
  uint64_t read_ud;
  struct wbuf_s *wq;
  size_t wh, wn, wcap;
} conn_t;

typedef struct {
  int kind;
  uint32_t conn;
  char *p;
  char *buf;
  size_t n;
  size_t want;
} submit_t;

typedef struct wbuf_s { void *p; unsigned n; int vec; } wbuf_t;

static uv_loop_t *g_loop = NULL;
static uv_async_t g_async;
static uv_timer_t g_wheel_timer;
static int g_wheel_timer_up = 0;
static uv_signal_t g_signal;
static int g_signal_up = 0;
static uv_poll_t g_ring_poll;
static int g_ring_poll_up = 0;
static int g_efd = -1;
static struct io_uring g_ring;
static int g_ring_up = 0;
static int g_lfd = -1;
static int g_listening = 0;
static int g_stopping = 0;
static int g_async_up = 0;
static int g_loop_running = 0;
static volatile int g_loop_parked = 0;
static int g_signal_repeating = 0;
static conn_t g_conns[MAX_CONN];
static uint32_t g_slot_gen = 0;
static struct sockaddr_in g_accept_addr;
static socklen_t g_accept_len = sizeof(g_accept_addr);

static submit_t g_sub[MAX_SUBMIT];
static int g_sub_head = 0, g_sub_n = 0;
static uv_mutex_t g_sub_lock;
static int g_mutex_up = 0;

#define MAX_RAW (4 * MAX_CONN)
static lean_object *g_raw[MAX_RAW];
static size_t g_raw_live_count = 0;
static uv_mutex_t g_raw_lock;
static int g_raw_up = 0;

static uint64_t (*g_ev)[3] = NULL;
static size_t g_ev_cap = 0;
static int g_ev_n = 0;

static void push_ev(uint64_t kind, uint64_t conn, uint64_t arg) {
  if ((size_t)g_ev_n == g_ev_cap) {
    size_t cap = g_ev_cap ? g_ev_cap * 2 : 4096;
    uint64_t (*grown)[3] = realloc(g_ev, cap * sizeof(uint64_t[3]));
    if (grown == NULL) return;
    g_ev = grown; g_ev_cap = cap;
  }
  g_ev[g_ev_n][0] = kind; g_ev[g_ev_n][1] = conn; g_ev[g_ev_n][2] = arg; g_ev_n++;
}

LEAN_EXPORT lean_object *np_raw_register(uint32_t idx, uint32_t op, lean_object *k) {
  size_t i = (size_t)idx * 4 + op;
  if (i >= MAX_RAW || !g_raw_up) { lean_dec(k); return lean_io_result_mk_ok(lean_box_uint32(0)); }
  uv_mutex_lock(&g_raw_lock);
  lean_object *old = g_raw[i];
  if (old == NULL) g_raw_live_count++;
  g_raw[i] = k;
  uv_mutex_unlock(&g_raw_lock);
  if (old) lean_dec(old);
  return lean_io_result_mk_ok(lean_box_uint32(1));
}

LEAN_EXPORT lean_object *np_raw_count(void) {
  size_t n = 0;
  if (g_raw_up) { uv_mutex_lock(&g_raw_lock); n = g_raw_live_count; uv_mutex_unlock(&g_raw_lock); }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)n));
}

static void raw_drain(void) {
  if (!g_raw_up) return;
  uv_mutex_lock(&g_raw_lock);
  for (size_t i = 0; i < MAX_RAW; i++) {
    if (g_raw[i] != NULL) { lean_dec(g_raw[i]); g_raw[i] = NULL; }
  }
  g_raw_live_count = 0;
  uv_mutex_unlock(&g_raw_lock);
}

LEAN_EXPORT lean_object *np_raw_take(uint32_t idx, uint32_t op) {
  size_t i = (size_t)idx * 4 + op;
  lean_object *k = NULL;
  if (i < MAX_RAW && g_raw_up) {
    uv_mutex_lock(&g_raw_lock);
    k = g_raw[i];
    if (k != NULL) { g_raw[i] = NULL; g_raw_live_count--; }
    uv_mutex_unlock(&g_raw_lock);
  }
  lean_object *r;
  if (k != NULL) { r = lean_alloc_ctor(1, 1, 0); lean_ctor_set(r, 0, k); }
  else           { r = lean_alloc_ctor(0, 0, 0); }
  return lean_io_result_mk_ok(r);
}

LEAN_EXPORT lean_object *np_raw_live(void) {
  int live = 0;
  if (g_raw_up) {
    uv_mutex_lock(&g_raw_lock);
    live = g_raw_live_count != 0;
    uv_mutex_unlock(&g_raw_lock);
  }
  return lean_io_result_mk_ok(lean_box(live));
}

static int push_submit(int kind, uint32_t conn, char *p, size_t n, size_t want) {
  if (g_loop == NULL || !g_mutex_up) { free(p); return 0; }
  uv_mutex_lock(&g_sub_lock);
  if (g_sub_n >= MAX_SUBMIT) { uv_mutex_unlock(&g_sub_lock); free(p); return 0; }
  g_sub[g_sub_n].kind = kind; g_sub[g_sub_n].conn = conn; g_sub[g_sub_n].p = p;
  g_sub[g_sub_n].n = n; g_sub[g_sub_n].want = want;
  g_sub[g_sub_n].buf = NULL; g_sub_n++;
  uv_mutex_unlock(&g_sub_lock);
  if (!g_stopping && g_async_up && !g_loop_running) uv_async_send(&g_async);
  return 1;
}

static conn_t *slot_alloc(void) {
  for (int i = 0; i < MAX_CONN; i++)
    if (!g_conns[i].used) {
      memset(&g_conns[i], 0, sizeof(conn_t));
      g_conns[i].used = 1;
      g_conns[i].idx = i;
      g_conns[i].fd = -1;
      g_conns[i].gen = ++g_slot_gen;
      return &g_conns[i];
    }
  return NULL;
}

static void wq_push(conn_t *c, void *p, unsigned n, int vec) {
  if (c->wn == c->wcap) {
    size_t cap = c->wcap ? c->wcap * 2 : 8;
    wbuf_t *q = realloc(c->wq, cap * sizeof(wbuf_t));
    if (q == NULL) { free(p); return; }
    c->wq = q; c->wcap = cap;
  }
  c->wq[c->wn].p = p; c->wq[c->wn].n = n; c->wq[c->wn].vec = vec; c->wn++;
}

static void wq_pop(conn_t *c) {
  if (c->wh >= c->wn) return;
  wbuf_t w = c->wq[c->wh++];
  if (w.vec) {
    struct iovec *iov = (struct iovec *)w.p;
    for (unsigned i = 0; i < w.n; i++) free(iov[i].iov_base);
    free(iov);
  } else {
    free(w.p);
  }
}

static void slot_free(conn_t *c) {
  if (c->fd >= 0) { close(c->fd); c->fd = -1; }
  while (c->wh < c->wn) wq_pop(c);
  free(c->wq); c->wq = NULL; c->wh = c->wn = c->wcap = 0;
  free(c->buf);
  c->buf = NULL; c->len = c->cap = c->want = 0;
  c->used = 0; c->closing = 0; c->shutting = 0;
}

/* The loop's signal watcher is libuv's, unchanged: it coexists with Std.Async's handler and records one event. */
static void on_signal(uv_signal_t *h, int signum) {
  push_ev(EV_SIGNAL, (uint64_t)signum, 0);
  if (!g_signal_repeating) uv_signal_stop(h);
}

static void on_async(uv_async_t *h) { (void)h; }
static void on_wheel_timer(uv_timer_t *h) { (void)h; }

static void ensure_buf(conn_t *c, size_t want) {
  if (want == 0 || want > MAX_READ) want = READ_CHUNK;
  if (c->cap < want) {
    char *p = realloc(c->buf, want);
    if (p == NULL) return;
    c->buf = p; c->cap = want;
  }
}

static void arm_accept(void) {
  if (!g_ring_up || g_lfd < 0 || g_stopping) return;
  struct io_uring_sqe *sqe = io_uring_get_sqe(&g_ring);
  if (sqe == NULL) { io_uring_submit(&g_ring); sqe = io_uring_get_sqe(&g_ring); }
  if (sqe == NULL) return;
  g_accept_len = sizeof(g_accept_addr);
  io_uring_prep_accept(sqe, g_lfd, (struct sockaddr *)&g_accept_addr, &g_accept_len, SOCK_NONBLOCK);
  io_uring_sqe_set_data64(sqe, UD_MAKE(0, 0xF0, 0));
  io_uring_submit(&g_ring);
}

static int process_cqes(void) {
  if (!g_ring_up) return 0;
  struct io_uring_cqe *cqes[64];
  unsigned n = io_uring_peek_batch_cqe(&g_ring, cqes, 64);
  for (unsigned i = 0; i < n; i++) {
    struct io_uring_cqe *cqe = cqes[i];
    uint64_t ud = io_uring_cqe_get_data64(cqe);
    int op = UD_OP(ud);
    uint32_t idx = UD_CONN(ud);
    uint32_t gen = UD_GEN(ud);
    int res = cqe->res;
    io_uring_cqe_seen(&g_ring, cqe);
    if (op == 0xF0) {
      /* accept */
      if (res >= 0) {
        conn_t *c = slot_alloc();
        if (c == NULL) {
          close(res);
          push_ev(EV_NO_SLOT, 0, 0);
        } else {
          c->fd = res;
          push_ev(EV_ACCEPT, (uint64_t)c->idx, 0);
        }
      }
      arm_accept();
      continue;
    }
    if (idx >= MAX_CONN) continue;
    conn_t *c = &g_conns[idx];
    if (!c->used || c->gen != gen) continue;
    switch (op) {
      case SUB_READ:
        c->read_inflight = 0;
        if (res == 0) push_ev(EV_READ, idx, 0);
        else if (res < 0) push_ev(EV_READ, idx, (uint64_t)(int64_t)res);
        else { c->len = (size_t)res; push_ev(EV_READ, idx, (uint64_t)res); }
        break;
      case SUB_WRITE:
        wq_pop(c);
        push_ev(EV_WRITE, idx, (uint64_t)(int64_t)(res < 0 ? res : 0));
        break;
      case SUB_WRITEV:
        wq_pop(c);
        push_ev(EV_WRITE, idx, (uint64_t)(int64_t)(res < 0 ? res : 0));
        break;
      case SUB_SHUTDOWN:
        push_ev(EV_SHUTDOWN, idx, (uint64_t)(int64_t)(res < 0 ? res : 0));
        break;
      case SUB_CLOSE:
        slot_free(c);
        break;
      case SUB_CANCEL:
        /* The read no longer pins the file: close now and release the slot. */
        if (c->fd >= 0) { close(c->fd); c->fd = -1; }
        slot_free(c);
        break;
      default:
        break;
    }
  }
  return (int)n;
}

static void on_ring_poll(uv_poll_t *h, int status, int events) {
  (void)h; (void)status; (void)events;
  uint64_t v;
  if (g_efd >= 0) { ssize_t r = read(g_efd, &v, sizeof(v)); (void)r; }
  process_cqes();
}

static void apply_submit(submit_t *s) {
  if (s->kind == SUB_SIGNAL) {
    if (!g_signal_up) { uv_signal_init(g_loop, &g_signal); g_signal_up = 1; }
    g_signal_repeating = (int)s->n;
    uv_signal_start(&g_signal, on_signal, (int)s->want);
    free(s->p);
    return;
  }
  if (s->conn >= MAX_CONN) { free(s->p); free(s->buf); return; }
  conn_t *c = &g_conns[s->conn];
  if (!c->used || c->closing || g_stopping) {
    if (s->kind == SUB_READ) push_ev(EV_READ, s->conn, (uint64_t)(int64_t)(-125));
    if (s->kind == SUB_WRITE || s->kind == SUB_WRITEV) push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)(-125));
    if (s->kind == SUB_SHUTDOWN) push_ev(EV_SHUTDOWN, s->conn, (uint64_t)(int64_t)(-125));
    free(s->p); free(s->buf);
    return;
  }
  struct io_uring_sqe *sqe = io_uring_get_sqe(&g_ring);
  if (sqe == NULL) {
    /* The ring is full: submit what is queued and retry once. */
    io_uring_submit(&g_ring);
    sqe = io_uring_get_sqe(&g_ring);
  }
  if (sqe == NULL) {
    if (s->kind == SUB_READ) push_ev(EV_READ, s->conn, (uint64_t)(int64_t)(-11));
    if (s->kind == SUB_WRITE || s->kind == SUB_WRITEV) push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)(-11));
    free(s->p); free(s->buf);
    return;
  }
  switch (s->kind) {
    case SUB_READ:
      ensure_buf(c, s->want);
      if (c->buf == NULL) { push_ev(EV_READ, s->conn, (uint64_t)(int64_t)(-12)); break; }
      c->want = s->want ? s->want : READ_CHUNK;
      io_uring_prep_recv(sqe, c->fd, c->buf, c->want, 0);
      c->read_ud = UD_MAKE(c->gen, SUB_READ, s->conn);
      c->read_inflight = 1;
      io_uring_sqe_set_data64(sqe, c->read_ud);
      break;
    case SUB_WRITE:
      io_uring_prep_send(sqe, c->fd, s->p, s->n, 0);
      wq_push(c, s->p, 0, 0);
      io_uring_sqe_set_data64(sqe, UD_MAKE(c->gen, SUB_WRITE, s->conn));
      break;
    case SUB_WRITEV: {
      struct iovec *iov = (struct iovec *)s->p;
      unsigned k = (unsigned)s->n;
      io_uring_prep_writev(sqe, c->fd, iov, k, 0);
      wq_push(c, iov, k, 1);
      io_uring_sqe_set_data64(sqe, UD_MAKE(c->gen, SUB_WRITEV, s->conn));
      break;
    }
    case SUB_SHUTDOWN:
      io_uring_prep_shutdown(sqe, c->fd, SHUT_WR);
      io_uring_sqe_set_data64(sqe, UD_MAKE(c->gen, SUB_SHUTDOWN, s->conn));
      break;
    case SUB_CLOSE: {
      c->closing = 1;
      if (c->read_inflight) {
        /* io_uring's recv holds a file reference, so close(2) alone does not send FIN until that request
           completes. Cancel it; the cancel completion closes the fd and frees the slot. */
        io_uring_prep_cancel64(sqe, c->read_ud, 0);
        io_uring_sqe_set_data64(sqe, UD_MAKE(c->gen, SUB_CANCEL, s->conn));
      } else {
        int fd = c->fd;
        c->fd = -1;
        if (fd >= 0) close(fd);
        slot_free(c);
      }
      break;
    }
    default:
      break;
  }
}

static void apply_submits(void) {
  for (;;) {
    uv_mutex_lock(&g_sub_lock);
    if (g_sub_head >= g_sub_n) { g_sub_n = 0; g_sub_head = 0; uv_mutex_unlock(&g_sub_lock); break; }
    submit_t s = g_sub[g_sub_head++];
    uv_mutex_unlock(&g_sub_lock);
    apply_submit(&s);
  }
  if (g_ring_up) io_uring_submit(&g_ring);
}

static int init_ring(void) {
  if (g_ring_up) return 1;
  if (io_uring_queue_init(1024, &g_ring, 0) != 0) return 0;
  g_ring_up = 1;
  if (g_efd >= 0) io_uring_register_eventfd(&g_ring, g_efd);
  return 1;
}

static int ensure_loop(void) {
  if (g_loop != NULL) return init_ring();
  g_loop = malloc(sizeof(uv_loop_t));
  if (g_loop == NULL) return 0;
  if (uv_loop_init(g_loop) != 0) { free(g_loop); g_loop = NULL; return 0; }
  g_async_up = 1;
  uv_async_init(g_loop, &g_async, on_async);
  uv_unref((uv_handle_t *)&g_async);
  g_wheel_timer_up = 1;
  uv_timer_init(g_loop, &g_wheel_timer);
  uv_unref((uv_handle_t *)&g_wheel_timer);
  uv_mutex_init(&g_sub_lock);
  uv_mutex_init(&g_raw_lock);
  g_mutex_up = 1;
  g_raw_up = 1;
  g_efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (g_efd >= 0) {
    uv_poll_init(g_loop, &g_ring_poll, g_efd);
    uv_poll_start(&g_ring_poll, UV_READABLE, on_ring_poll);
    g_ring_poll_up = 1;
  }
  return init_ring();
}

LEAN_EXPORT lean_object *np_uv_start(uint32_t port) {
  if (g_listening) return lean_io_result_mk_ok(lean_box_uint32(0));
  if (!ensure_loop()) return lean_io_result_mk_ok(lean_box_uint32(0));
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) return lean_io_result_mk_ok(lean_box_uint32(0));
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((uint16_t)port);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 512) != 0) {
    close(fd);
    return lean_io_result_mk_ok(lean_box_uint32(0));
  }
  socklen_t len = sizeof(addr);
  getsockname(fd, (struct sockaddr *)&addr, &len);
  g_lfd = fd;
  g_listening = 1;
  arm_accept();
  io_uring_submit(&g_ring);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ntohs(addr.sin_port)));
}

LEAN_EXPORT lean_object *np_uv_run_once_timeout(uint32_t timeout_ms) {
  if (!ensure_loop()) return lean_io_result_mk_ok(lean_box_uint32(0));
  g_loop_running = 1;
  apply_submits();
  process_cqes();
  g_loop_running = 0;
  if (g_stopping) {
    if (g_lfd >= 0) { close(g_lfd); g_lfd = -1; }
    for (int i = 0; i < MAX_CONN; i++) if (g_conns[i].used) slot_free(&g_conns[i]);
    process_cqes();
    /* The ring is kept: a stop retires the listener and its slots, and a following bind reuses the same ring.
       Queue exit and re-entry between listeners invalidated the ring under libuv's poll. */
    g_listening = 0;
    g_stopping = 0;
    return lean_io_result_mk_ok(lean_box_uint32(2));
  }
  if (timeout_ms > 0) uv_timer_start(&g_wheel_timer, on_wheel_timer, timeout_ms, 0);
  g_loop_parked = 1;
  int active = uv_run(g_loop, timeout_ms > 0 ? UV_RUN_ONCE : UV_RUN_NOWAIT);
  g_loop_parked = 0;
  if (timeout_ms > 0) uv_timer_stop(&g_wheel_timer);
  process_cqes();
  /* A live listener or connection is ring work, and ring work is not a libuv handle: uv_run can report no
     active handles while a close or a read is still outstanding. Reporting that as inactive would park the
     driver on the executor's condvar and strand the completion. */
  int owned = g_listening;
  for (int i = 0; i < MAX_CONN && !owned; i++) if (g_conns[i].used) owned = 1;
  return lean_io_result_mk_ok(lean_box_uint32((active || owned) ? 1 : 0));
}

LEAN_EXPORT lean_object *np_uv_run_nowait(void) {
  if (!ensure_loop()) return lean_io_result_mk_ok(lean_box_uint32(0));
  g_loop_running = 1;
  apply_submits();
  process_cqes();
  uv_run(g_loop, UV_RUN_NOWAIT);
  process_cqes();
  g_loop_running = 0;
  return lean_io_result_mk_ok(lean_box_uint32(1));
}

LEAN_EXPORT lean_object *np_uv_wheel_wake(void) {
  if (g_loop != NULL && !g_stopping && g_async_up && g_loop_parked) uv_async_send(&g_async);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *np_uv_signal_watch(uint32_t signum, uint32_t repeating) {
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_SIGNAL, 0, NULL, repeating, signum)));
}

LEAN_EXPORT lean_object *np_uv_events(void) {
  lean_object *arr = lean_alloc_array((size_t)g_ev_n * 3, (size_t)g_ev_n * 3);
  for (int i = 0; i < g_ev_n; i++) {
    lean_array_set_core(arr, (size_t)i * 3, lean_box_uint32((uint32_t)g_ev[i][0]));
    lean_array_set_core(arr, (size_t)i * 3 + 1, lean_box_uint32((uint32_t)g_ev[i][1]));
    lean_array_set_core(arr, (size_t)i * 3 + 2, lean_box_uint32((uint32_t)g_ev[i][2]));
  }
  g_ev_n = 0;
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_take(uint32_t idx, uint64_t count) {
  conn_t *c = idx < MAX_CONN ? &g_conns[idx] : NULL;
  size_t n = (c != NULL && c->used) ? c->len : 0;
  if (count < n) n = (size_t)count;
  lean_object *arr = lean_alloc_sarray(1, n, n);
  if (n > 0) memcpy(lean_sarray_cptr(arr), c->buf, n);
  if (c != NULL) {
    if (n > 0 && n < c->len) memmove(c->buf, c->buf + n, c->len - n);
    c->len -= n;
    c->want = 0;
  }
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_read(uint32_t idx, uint64_t size) {
  size_t want = (size_t)size;
  if (want == 0 || want > MAX_READ) want = MAX_READ;
  int ok = push_submit(SUB_READ, idx, NULL, 0, want);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ok));
}

LEAN_EXPORT lean_object *np_uv_write(uint32_t idx, lean_object *bytes) {
  size_t n = lean_sarray_size(bytes);
  char *p = n ? malloc(n) : NULL;
  if (n && p == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
  if (n) memcpy(p, lean_sarray_cptr(bytes), n);
  int ok = push_submit(SUB_WRITE, idx, p, n, 0);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ok));
}

LEAN_EXPORT lean_object *np_uv_writev(uint32_t idx, lean_object *chunks) {
  size_t k = lean_array_size(chunks);
  if (k == 0) return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_WRITE, idx, NULL, 0, 0)));
  struct iovec *iov = malloc(k * sizeof(struct iovec));
  if (iov == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
  for (size_t i = 0; i < k; i++) {
    lean_object *ch = lean_array_get_core(chunks, i);
    size_t n = lean_sarray_size(ch);
    char *p = n ? malloc(n) : NULL;
    if (n && p == NULL) {
      for (size_t j = 0; j < i; j++) free(iov[j].iov_base);
      free(iov);
      return lean_io_result_mk_ok(lean_box_uint32(0));
    }
    if (n) memcpy(p, lean_sarray_cptr(ch), n);
    iov[i].iov_base = p; iov[i].iov_len = n;
  }
  int ok = push_submit(SUB_WRITEV, idx, (char *)iov, k, 0);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ok));
}

LEAN_EXPORT lean_object *np_uv_shutdown(uint32_t idx) {
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_SHUTDOWN, idx, NULL, 0, 0)));
}

LEAN_EXPORT lean_object *np_uv_close(uint32_t idx) {
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_CLOSE, idx, NULL, 0, 0)));
}

LEAN_EXPORT lean_object *np_uv_stop(void) {
  if (g_loop != NULL) {
    g_stopping = 1;
    if (g_async_up) uv_async_send(&g_async);
    if (g_efd >= 0) { uint64_t one = 1; ssize_t r = write(g_efd, &one, sizeof(one)); (void)r; }
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *np_uv_peer_ipv4(uint32_t idx) {
  if (idx >= MAX_CONN || !g_conns[idx].used) return lean_io_result_mk_ok(lean_box(0));
  struct sockaddr_in ss; socklen_t len = sizeof(ss);
  if (getpeername(g_conns[idx].fd, (struct sockaddr *)&ss, &len) != 0 || ss.sin_family != AF_INET)
    return lean_io_result_mk_ok(lean_box(0));
  return lean_io_result_mk_ok(lean_box_uint32(ntohl(ss.sin_addr.s_addr)));
}

LEAN_EXPORT lean_object *np_uv_peer_port(uint32_t idx) {
  if (idx >= MAX_CONN || !g_conns[idx].used) return lean_io_result_mk_ok(lean_box(0));
  struct sockaddr_in ss; socklen_t len = sizeof(ss);
  if (getpeername(g_conns[idx].fd, (struct sockaddr *)&ss, &len) != 0 || ss.sin_family != AF_INET)
    return lean_io_result_mk_ok(lean_box(0));
  return lean_io_result_mk_ok(lean_box_uint32(ntohs(ss.sin_port)));
}

LEAN_EXPORT lean_object *np_uv_err_name(uint32_t code) {
  return lean_io_result_mk_ok(lean_mk_string(uv_err_name(-(int)code)));
}
