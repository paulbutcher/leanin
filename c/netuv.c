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
 *   np_uv_run_once()         apply the queued submissions, then one loop iteration (uv_run, UV_RUN_ONCE);
 *                            returns 1 while the loop has anything left to do and 0 once it is stopped and
 *                            drained, which is the loop thread's exit condition
 *   np_uv_events()           drain the event queue: (kind, conn, arg) triples, flat in one Array
 *   np_uv_take(idx)          the bytes accumulated on that connection, clearing them
 *   np_uv_read(idx, size)    begin one read, holding the read to at most `size` bytes
 *   np_uv_write(idx, bytes)  one write, copying the bytes into memory the write request owns
 *   np_uv_shutdown(idx)      uv_shutdown, then close the handle on its completion, then report it
 *   np_uv_close(idx)         close a connection whose completion was an error
 *   np_uv_stop()             ask the loop to stop and drain; callable from any thread
 *   np_uv_err_name(code)     the libuv name of an error code, for a message Lean builds
 *
 * Event kinds: 1 = accepted (the connection index), 2 = read completed (arg = the byte count, 0 for end of
 * stream, negative for a failure -- the negated libuv error code), 3 = write completed (arg = the status),
 * 4 = shutdown completed (arg = the status), 5 = the event queue could not be grown (an allocation failure, the
 * only way an event is ever dropped), 6 = no free connection slot. Read
 * end-of-stream arrives from libuv as `UV_EOF` (-4095) rather than as a zero length, and the shim normalizes it
 * to 0 so that a closed peer is not reported as a failure. A failed accept (ECONNABORTED and its relatives) is
 * deliberately *not* an event: it is the client's own departure, and there is no connection to report.
 *
 * Two threads, and one rule between them. The operations (`np_uv_read`/`np_uv_write`/`np_uv_shutdown`/
 * `np_uv_close`) are called from the runtime's carrier threads, and **all connection state is touched by the
 * loop thread only**: a submission appends a record to the queue under `g_sub_lock` and wakes the loop with
 * `uv_async_send`, and the loop thread applies the queue at the top of `np_uv_run_once`, before `uv_run`.
 * Submissions are applied in arrival order, which is what keeps the bytes of two writes on one connection in the
 * order the caller made them.
 *
 * One read per submission. `on_read` stops reading as soon as it has something to report, so bytes are only ever
 * read where Lean asked for them, and the read callback hands back exactly one read's worth. The read path
 * copies nothing: `alloc_cb` hands libuv the tail of the connection's own buffer, so the kernel reads straight
 * into it and `on_read` only advances a length. `np_uv_take` is called from the loop thread alone, so the bytes
 * a completion names are still that connection's bytes when they are copied into Lean.
 *
 * Slot reuse, and the order that makes it safe. A connection's index is its slot in `g_conns`, and a slot is
 * marked free only in `on_close`, after its handle is closed. libuv delivers a pending read callback (with
 * UV_ECANCELED) *before* the close callback of the same handle, and both happen inside one loop iteration, so
 * every event naming a slot is drained by Lean before that slot can be handed out again.
 *
 * What this shim does not do: it installs no signal handler. A process has one disposition per signal, and
 * Lean's own event loop -- the one behind `Std.Async.Signal`, in a *different* copy of libuv -- installs its own
 * handlers for SIGINT and SIGTERM. A handler here would replace that one (the later `sigaction` wins) or be
 * replaced by it, and `Runtime.awaitSignal` would stop seeing the signal it waits for. `np_uv_stop` is how this
 * loop is stopped, called by Lean; a process-level signal keeps its default disposition.
 */
#define _GNU_SOURCE
#include <lean/lean.h>
#include <uv.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

#define MAX_CONN 4096
#define MAX_SUBMIT 8192
#define READ_CHUNK 16384
#define MAX_READ 65536

#define EV_ACCEPT 1
#define EV_READ 2
#define EV_WRITE 3
#define EV_SHUTDOWN 4
#define EV_OVERFLOW 5
#define EV_NO_SLOT 6

#define SUB_READ 1
#define SUB_WRITE 2
#define SUB_SHUTDOWN 3
#define SUB_CLOSE 4
#define SUB_WRITEV 5

typedef struct {
  uv_tcp_t handle;
  char *buf;
  size_t len, cap;
  size_t want;
  int idx;
  int used;
  int shutting;      /* SUB_SHUTDOWN was applied: the write side is going away, so a close must drain first */
} conn_t;

typedef struct {
  int kind;
  uint32_t conn;
  char *p;
  char *buf;         /* SUB_WRITEV: the one block the buffers were copied into */
  size_t n;
  size_t want;
} submit_t;

typedef struct { uv_write_t req; conn_t *c; char *p; } write_req_t;
typedef struct { uv_shutdown_t req; conn_t *c; } shutdown_req_t;

/* A connection taken off the backlog when no slot was free, so the listener does not spin on it. Heap-allocated
   because the handle outlives the callback that created it: libuv closes it in a later pass. */
typedef struct { uv_tcp_t handle; } reject_t;

static uv_loop_t *g_loop = NULL;
static uv_tcp_t g_server;
static uv_async_t g_async;
static conn_t g_conns[MAX_CONN];
/* The event queue grows: it holds the events of one loop iteration, and an iteration's worth of events is set by
   how many connections are ready at once, not by anything the shim can bound in advance. A fixed ring would have
   to drop events when it filled, and a dropped event is a completion a parked operation never receives. */
static uint64_t (*g_ev)[3] = NULL;
static size_t g_ev_cap = 0;
static int g_ev_n = 0;
static int g_ev_dropped = 0;

/* Set while the loop thread is inside a *non-blocking* iteration. A submission made by a carrier while this is set
   need not wake the loop: another iteration follows immediately in the same call, and it re-applies the queue
   after that one, so the submission is found without a wake. The *parking* poll leaves the flag clear on purpose
   -- a submission that arrives while the loop is parked there is exactly the one `uv_async_send` exists for, and
   the queue is only re-checked after the poll returns, which is what needed the wake. `uv_async_send` is
   level-triggered, so a wake raised in the window between an iteration and the poll is serviced, not lost. */
static int g_loop_running = 0;
static submit_t g_sub[MAX_SUBMIT];
static int g_sub_head = 0, g_sub_n = 0;
static uv_mutex_t g_sub_lock;
static int g_mutex_up = 0;
/* Per-kind operation counters, and the loop's own progress. Held unconditionally -- an increment is three
   instructions -- and reported from the loop thread every few seconds as `npuv ops` when NPUV_OPS is set, so a
   measurement does not need a graceful exit to read them. Off by default, and the environment is consulted once. */
#define CNT_ACCEPT 0
#define CNT_READ 1
#define CNT_WRITE 2
#define CNT_WRITEV 3
#define CNT_SHUTDOWN 4
#define CNT_CLOSE 5
#define CNT_EVENTS 6
#define CNT_ITER 7
static uint64_t g_cnt[8];
static uint64_t g_last_report_ms = 0;
/* The report is off unless NPUV_OPS is set, and the environment is read once, at the first iteration. */
static int g_ops_report = -1;

static uint64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static void report_counts(void) {
  if (g_ops_report < 0) g_ops_report = getenv("NPUV_OPS") != NULL ? 1 : 0;
  if (!g_ops_report) return;
  uint64_t now = now_ms();
  if (g_last_report_ms == 0) { g_last_report_ms = now; return; }
  if (now - g_last_report_ms < 2000) return;
  g_last_report_ms = now;
  dprintf(2, "npuv ops accept=%llu read=%llu write=%llu writev=%llu shutdown=%llu close=%llu events=%llu iters=%llu\n",
          (unsigned long long)g_cnt[CNT_ACCEPT], (unsigned long long)g_cnt[CNT_READ],
          (unsigned long long)g_cnt[CNT_WRITE], (unsigned long long)g_cnt[CNT_WRITEV],
          (unsigned long long)g_cnt[CNT_SHUTDOWN], (unsigned long long)g_cnt[CNT_CLOSE],
          (unsigned long long)g_cnt[CNT_EVENTS], (unsigned long long)g_cnt[CNT_ITER]);
}

static int g_stopping = 0;
static int g_listening = 0;
static int g_async_up = 0;

static void push_ev(uint64_t kind, uint64_t conn, uint64_t arg) {
  if ((size_t)g_ev_n == g_ev_cap) {
    size_t cap = g_ev_cap ? g_ev_cap * 2 : 4096;
    uint64_t (*grown)[3] = realloc(g_ev, cap * sizeof(uint64_t[3]));
    if (grown == NULL) {
      /* Out of memory, which is the one failure this queue cannot absorb: reported once, as kind 5, when there is
         room to report it. Nothing else drops an event. */
      g_ev_dropped = 1;
      return;
    }
    g_ev = grown; g_ev_cap = cap;
  }
  g_ev[g_ev_n][0] = kind; g_ev[g_ev_n][1] = conn; g_ev[g_ev_n][2] = arg; g_ev_n++;
}

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *out);
static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *b);
static void on_close(uv_handle_t *h);

/* **Read whatever the peer still has, and only then close.**
 *
 * Closing a socket whose receive buffer holds unread data makes the kernel send RST rather than a clean FIN, so
 * the peer sees the connection reset instead of the end of the stream -- a failed request on its side rather than
 * a late one. Nothing else in this file reads the peer's FIN: reading stops at the header terminator, so the
 * receive side is nearly always dirty at the moment a connection is retired. This drain is the whole of that fix:
 * one read that ends at the peer's own end of stream, or at whatever it sent after our FIN, after which the
 * buffer is empty and the close is clean. */
static void on_drain(uv_stream_t *s, ssize_t nread, const uv_buf_t *b) {
  (void)nread;
  (void)b;
  conn_t *c = (conn_t *)s->data;
  uv_read_stop(s);
  if (!uv_is_closing((uv_handle_t *)&c->handle))
    uv_close((uv_handle_t *)&c->handle, on_close);
}
static void apply_submits(void);
static void close_all(void);
static void destroy_loop(void);

static conn_t *slot_alloc(void) {
  for (int i = 0; i < MAX_CONN; i++)
    if (!g_conns[i].used) {
      memset(&g_conns[i], 0, sizeof(conn_t));
      g_conns[i].used = 1;
      g_conns[i].idx = i;
      return &g_conns[i];
    }
  return NULL;
}

static void on_close(uv_handle_t *h) {
  conn_t *c = (conn_t *)h->data;
  free(c->buf);
  c->buf = NULL; c->len = 0; c->cap = 0; c->want = 0; c->used = 0;
}

static void on_reject_close(uv_handle_t *h) {
  free(h);
}

static void on_async(uv_async_t *h) {
  /* Nothing to do here: the wake only ends the poll, and `np_uv_run_once` applies the queue before the next
     `uv_run` whether or not this callback ran. A callback that did the work would be a second place submissions
     are applied, and only one of the two could be the one that ran. */
  (void)h;
}

static void on_conn(uv_stream_t *server, int status) {
  if (status < 0) return;   /* the client left before we took it: nothing to report and no connection */
  conn_t *c = slot_alloc();
  if (c == NULL) {
    /* No free slot. Take the connection off the backlog anyway -- leaving it there would keep the listening
       socket readable and spin this callback -- and report it, so the accept waiting for it fails loudly. */
    reject_t *r = malloc(sizeof(reject_t));
    if (r != NULL) {
      uv_tcp_init(g_loop, &r->handle);
      r->handle.data = NULL;
      uv_accept(server, (uv_stream_t *)&r->handle);
      uv_close((uv_handle_t *)&r->handle, on_reject_close);
    }
    push_ev(EV_NO_SLOT, 0, 0);
    return;
  }
  uv_tcp_init(g_loop, &c->handle);
  c->handle.data = c;
  if (uv_accept(server, (uv_stream_t *)&c->handle) != 0) {
    uv_close((uv_handle_t *)&c->handle, on_close);
    return;
  }
  /* Nagle off, as the listener this replaces did: `noDelay` on a listening socket is inherited by everything
     `accept` returns, and the shim has no listener handle of its own to set it on. A response written as more
     than one segment otherwise waits on the peer's delayed ACK, which is tens of milliseconds on loopback. */
  uv_tcp_nodelay(&c->handle, 1);
  g_cnt[CNT_ACCEPT]++;
  push_ev(EV_ACCEPT, (uint64_t)c->idx, 0);
}

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *out) {
  (void)suggested;
  conn_t *c = (conn_t *)h->data;
  size_t want = c->want ? c->want : READ_CHUNK;
  if (want > MAX_READ) want = MAX_READ;
  if (c->cap < want) {
    char *p = realloc(c->buf, want);
    if (p == NULL) { out->base = NULL; out->len = 0; return; }
    c->buf = p; c->cap = want;
  }
  out->base = c->buf + c->len;
  out->len = (c->cap - c->len < want) ? (c->cap - c->len) : want;
}

static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *b) {
  (void)b;
  conn_t *c = (conn_t *)s->data;
  /* One read per submission: stop here, and the next `np_uv_read` starts the next one. */
  uv_read_stop(s);
  c->want = 0;
  if (nread > 0) {
    c->len += (size_t)nread;
    push_ev(EV_READ, (uint64_t)c->idx, (uint64_t)nread);
  } else if (nread == 0 || nread == UV_EOF) {
    /* End of stream, and it arrives as `UV_EOF` rather than as a zero length: libuv's `uv__stream_eof` calls the
       read callback with `UV_EOF` (-4095), which is a *negative* code and so would otherwise read as a failure.
       A zero length is treated the same way, because for a stream it can only mean the same thing. */
    push_ev(EV_READ, (uint64_t)c->idx, 0);
  } else {
    push_ev(EV_READ, (uint64_t)c->idx, (uint64_t)(int64_t)nread);  /* a failure, the negated libuv code */
  }
}

static void on_write(uv_write_t *req, int status) {
  write_req_t *w = (write_req_t *)req;
  conn_t *c = w->c;
  free(w->p);
  free(w);
  push_ev(EV_WRITE, (uint64_t)c->idx, (uint64_t)(int64_t)status);
}

static void on_shutdown(uv_shutdown_t *req, int status) {
  shutdown_req_t *sh = (shutdown_req_t *)req;
  conn_t *c = sh->c;
  free(sh);
  /* The write side is done, so the peer can read the FIN. The handle is **not** closed here: closing it while the
     peer still has bytes in flight is what turns this clean end of stream into a reset. The close comes from
     `SUB_CLOSE`, which drains first (see `on_drain`). */
  push_ev(EV_SHUTDOWN, (uint64_t)c->idx, (uint64_t)(int64_t)status);
}

/* Append one submission. Returns 1 when it was queued, 0 when the queue is full or the loop is gone -- a caller
   that sees 0 must fail its operation rather than wait for a completion that was never asked for. */
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

static void apply_submit(submit_t *s) {
  if (s->conn >= MAX_CONN) { free(s->p); return; }
  conn_t *c = &g_conns[s->conn];
  int dead = !c->used || uv_is_closing((uv_handle_t *)&c->handle);
  switch (s->kind) {
    case SUB_READ:
      g_cnt[CNT_READ]++;
      if (dead) { push_ev(EV_READ, s->conn, (uint64_t)(int64_t)UV_ECANCELED); break; }
      c->want = s->want ? s->want : READ_CHUNK;
      if (uv_read_start((uv_stream_t *)&c->handle, alloc_cb, on_read) != 0) {
        c->want = 0;
        push_ev(EV_READ, s->conn, (uint64_t)(int64_t)UV_EIO);
      }
      break;
    case SUB_WRITEV: {
      g_cnt[CNT_WRITEV]++;
      /* one write for several buffers: copied into one block here, so the peer reads one segment rather than one
         per buffer. Two segments would be two writes back to back, which is exactly what Nagle holds back. */
      if (s->buf == NULL || s->n == 0) { free(s->buf); push_ev(EV_WRITE, s->conn, 0); break; }
      if (dead) { free(s->buf); push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_ECANCELED); break; }
      write_req_t *wv = malloc(sizeof(write_req_t));
      if (wv == NULL) { free(s->buf); push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_ENOMEM); break; }
      wv->c = c; wv->p = s->buf;
      uv_buf_t bv = uv_buf_init(s->buf, (unsigned int)s->n);
      if (uv_write(&wv->req, (uv_stream_t *)&c->handle, &bv, 1, on_write) != 0) {
        free(wv->p); free(wv);
        push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_EIO);
      }
      break;
    }
    case SUB_WRITE: {
      g_cnt[CNT_WRITE]++;
      if (s->n == 0) { free(s->p); push_ev(EV_WRITE, s->conn, 0); break; }   /* nothing to write is written */
      if (dead) { free(s->p); push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_ECANCELED); break; }
      write_req_t *w = malloc(sizeof(write_req_t));
      if (w == NULL) { free(s->p); push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_ENOMEM); break; }
      w->c = c; w->p = s->p;
      uv_buf_t b = uv_buf_init(s->p, (unsigned int)s->n);
      if (uv_write(&w->req, (uv_stream_t *)&c->handle, &b, 1, on_write) != 0) {
        free(w->p); free(w);
        push_ev(EV_WRITE, s->conn, (uint64_t)(int64_t)UV_EIO);
      }
      break;
    }
    case SUB_SHUTDOWN: {
      g_cnt[CNT_SHUTDOWN]++;
      if (dead) { push_ev(EV_SHUTDOWN, s->conn, (uint64_t)(int64_t)UV_ECANCELED); break; }
      c->shutting = 1;
      shutdown_req_t *sh = malloc(sizeof(shutdown_req_t));
      if (sh == NULL) { push_ev(EV_SHUTDOWN, s->conn, (uint64_t)(int64_t)UV_ENOMEM); break; }
      sh->c = c;
      if (uv_shutdown(&sh->req, (uv_stream_t *)&c->handle, on_shutdown) != 0) {
        free(sh);
        push_ev(EV_SHUTDOWN, s->conn, (uint64_t)(int64_t)UV_EIO);
      }
      break;
    }
    case SUB_CLOSE:
      g_cnt[CNT_CLOSE]++;
      /* A connection whose write side has already been shut down is drained before it is closed, so the peer
         reads a clean end of stream; one that never got that far is closed here and now. */
      if (c->used && !uv_is_closing((uv_handle_t *)&c->handle)) {
        if (c->shutting) { c->want = 0; uv_read_start((uv_stream_t *)&c->handle, alloc_cb, on_drain); }
        else uv_close((uv_handle_t *)&c->handle, on_close);
      }
      break;
    default:
      break;
  }
}

/* The loop thread's half of the queue. Submissions are applied in arrival order, and one arriving while this
   runs is picked up in the same pass: the lock is held only for the take, never across a libuv call. */
static void apply_submits(void) {
  for (;;) {
    uv_mutex_lock(&g_sub_lock);
    if (g_sub_head >= g_sub_n) { g_sub_n = 0; g_sub_head = 0; uv_mutex_unlock(&g_sub_lock); return; }
    submit_t s = g_sub[g_sub_head++];
    uv_mutex_unlock(&g_sub_lock);
    apply_submit(&s);
  }
}

static void close_all(void) {
  if (g_async_up) { uv_close((uv_handle_t *)&g_async, NULL); g_async_up = 0; }
  if (g_listening) { uv_close((uv_handle_t *)&g_server, NULL); g_listening = 0; }
  for (int i = 0; i < MAX_CONN; i++)
    if (g_conns[i].used && !uv_is_closing((uv_handle_t *)&g_conns[i].handle))
      uv_close((uv_handle_t *)&g_conns[i].handle, on_close);
}

static void destroy_loop(void) {
  if (uv_loop_close(g_loop) == 0) free(g_loop);   /* a loop that will not close is leaked rather than freed */
  g_loop = NULL;
  g_stopping = 0;
}

LEAN_EXPORT lean_object *np_uv_start(uint32_t port) {
  if (g_loop != NULL) return lean_io_result_mk_ok(lean_box_uint32(0));   /* one loop at a time */
  g_loop = malloc(sizeof(uv_loop_t));
  if (g_loop == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
  if (uv_loop_init(g_loop) != 0) { free(g_loop); g_loop = NULL; return lean_io_result_mk_ok(lean_box_uint32(0)); }
  if (!g_mutex_up) {
    if (uv_mutex_init(&g_sub_lock) != 0) { uv_loop_close(g_loop); free(g_loop); g_loop = NULL;
                                           return lean_io_result_mk_ok(lean_box_uint32(0)); }
    g_mutex_up = 1;
  }
  uv_async_init(g_loop, &g_async, on_async);
  g_async_up = 1;
  uv_tcp_init(g_loop, &g_server);
  struct sockaddr_in addr;
  uv_ip4_addr("127.0.0.1", (int)port, &addr);
  if (uv_tcp_bind(&g_server, (const struct sockaddr *)&addr, 0) != 0 ||
      uv_listen((uv_stream_t *)&g_server, 511, on_conn) != 0) {
    g_listening = 1;
    g_stopping = 1;
    close_all();
    while (uv_run(g_loop, UV_RUN_NOWAIT) != 0) { }
    destroy_loop();
    return lean_io_result_mk_ok(lean_box_uint32(0));
  }
  g_listening = 1;
  int len = sizeof(addr);
  uv_tcp_getsockname(&g_server, (struct sockaddr *)&addr, &len);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)ntohs(addr.sin_port)));
}

LEAN_EXPORT lean_object *np_uv_run_once(void) {
  if (g_loop == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
  g_cnt[CNT_ITER]++;
  report_counts();
  apply_submits();
  if (g_stopping) {
    /* The stopped loop is closed and drained here, never by the thread that asked for the stop: the close
       callbacks would otherwise be run by a `uv_run` racing this one on the same loop. Everything is already
       closed, so the poll is given a zero timeout -- what is left to do is run those callbacks, and a poll with
       nothing to wait for must not be allowed to wait. */
    close_all();
    int active = 1;
    for (int i = 0; i < 8 && active != 0; i++) active = uv_run(g_loop, UV_RUN_NOWAIT);
    if (active == 0) destroy_loop();
    return lean_io_result_mk_ok(lean_box_uint32(active ? 1 : 0));
  }
  /* Non-blocking iterations while submissions are queued: a submission landing during one is found by the next
     `apply_submits` in this same call, which is what makes skipping its wake safe. The blocking poll below runs
     with the flag clear, because a submission arriving while the loop is parked there must wake it. */
  for (;;) {
    int queued;
    uv_mutex_lock(&g_sub_lock);
    queued = g_sub_head < g_sub_n;
    uv_mutex_unlock(&g_sub_lock);
    if (!queued) break;
    g_loop_running = 1;
    uv_run(g_loop, UV_RUN_NOWAIT);
    g_loop_running = 0;
    apply_submits();
  }
  int active = uv_run(g_loop, UV_RUN_ONCE);
  return lean_io_result_mk_ok(lean_box_uint32(active ? 1 : 0));
}

LEAN_EXPORT lean_object *np_uv_events(void) {
  if (g_ev_dropped && g_ev_n == 0) { push_ev(EV_OVERFLOW, 0, 0); g_ev_dropped = 0; }
  lean_object *arr = lean_mk_empty_array_with_capacity(lean_box((size_t)(3 * g_ev_n)));
  for (int i = 0; i < g_ev_n; i++) {
    arr = lean_array_push(arr, lean_box_uint64(g_ev[i][0]));
    arr = lean_array_push(arr, lean_box_uint64(g_ev[i][1]));
    arr = lean_array_push(arr, lean_box_uint64(g_ev[i][2]));
  }
  g_cnt[CNT_EVENTS] += (uint64_t)g_ev_n;
  g_ev_n = 0;
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_take(uint32_t idx) {
  conn_t *c = (idx < MAX_CONN) ? &g_conns[idx] : NULL;
  size_t n = (c != NULL && c->used) ? c->len : 0;
  lean_object *arr = lean_alloc_sarray(1, n, n);
  if (n > 0) memcpy(lean_sarray_cptr(arr), c->buf, n);
  if (c != NULL) c->len = 0;
  return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_object *np_uv_read(uint32_t idx, uint64_t size) {
  /* The cap one read may return, as the caller asked for it: the read is held to `size` bytes at the alloc site,
     which is where holding it costs nothing. A cap of zero or beyond the shim's own limit becomes the limit. */
  size_t want = (size_t)size;
  if (want == 0 || want > MAX_READ) want = MAX_READ;
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_READ, idx, NULL, 0, want)));
}

LEAN_EXPORT lean_object *np_uv_write(uint32_t idx, lean_object *bytes) {
  size_t n = lean_sarray_size(bytes);
  char *p = NULL;
  if (n > 0) {
    p = malloc(n);
    if (p == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
    memcpy(p, lean_sarray_cptr(bytes), n);
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)push_submit(SUB_WRITE, idx, p, n, 0)));
}

/* One write carrying every buffer of `chunks`, in order. The buffers are copied into one block, so the request
   owns one segment and the caller's array can go away immediately. */
LEAN_EXPORT lean_object *np_uv_writev(uint32_t idx, lean_object *chunks) {
  size_t total = 0;
  size_t k = lean_array_size(chunks);
  for (size_t i = 0; i < k; i++) total += lean_sarray_size(lean_array_get_core(chunks, i));
  char *p = NULL;
  if (total > 0) {
    p = malloc(total);
    if (p == NULL) return lean_io_result_mk_ok(lean_box_uint32(0));
    size_t off = 0;
    for (size_t i = 0; i < k; i++) {
      lean_object *b = lean_array_get_core(chunks, i);
      size_t n = lean_sarray_size(b);
      if (n > 0) { memcpy(p + off, lean_sarray_cptr(b), n); off += n; }
    }
  }
  if (g_loop == NULL || !g_mutex_up) { free(p); return lean_io_result_mk_ok(lean_box_uint32(0)); }
  uv_mutex_lock(&g_sub_lock);
  if (g_sub_n >= MAX_SUBMIT) { uv_mutex_unlock(&g_sub_lock); free(p);
                               return lean_io_result_mk_ok(lean_box_uint32(0)); }
  g_sub[g_sub_n].kind = SUB_WRITEV; g_sub[g_sub_n].conn = idx;
  g_sub[g_sub_n].p = NULL; g_sub[g_sub_n].buf = p; g_sub[g_sub_n].n = total;
  g_sub[g_sub_n].want = 0; g_sub_n++;
  uv_mutex_unlock(&g_sub_lock);
  if (!g_stopping && g_async_up && !g_loop_running) uv_async_send(&g_async);
  return lean_io_result_mk_ok(lean_box_uint32(1));
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
    if (g_async_up) uv_async_send(&g_async);   /* end the poll the loop thread is parked in */
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *np_uv_err_name(uint32_t code) {
  return lean_io_result_mk_ok(lean_mk_string(uv_err_name(-(int)code)));
}
