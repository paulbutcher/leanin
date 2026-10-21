/* E0: a minimal HTTP/1.1 keep-alive server on liburing, no Lean, no libuv.
 *
 * Purpose: isolate the io_uring architecture from the shim. Ring flags are the recommended
 * SINGLE_ISSUER|DEFER_TASKRUN; accept is multishot; recv is one-shot per request (multishot recv is E3).
 * One submit per loop after processing the CQEs, no eventfd, no epoll.
 *
 * Build: cc -O2 -o /tmp/uring-http bench/uring-http.c -luring
 * Run:   /tmp/uring-http 8480
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <liburing.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_CONN 4096
#define BUF_SIZE 16384
#define OP_ACCEPT 1
#define OP_RECV 2
#define OP_SEND 3
#define BGID 1
#define NBUF 256
#define BUFSZ 4096

#ifdef MULTISHOT_RECV
static struct io_uring_buf_ring *bufring;
static char *bufslab;
#endif

typedef struct {
  int fd;
  int used;
  int recv_armed;
  char *in;
  size_t in_len;
  char *out;
  size_t out_len;
} conn_t;

static struct io_uring ring;
static conn_t conns[MAX_CONN];
static int listen_fd = -1;
static const char response[] =
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";

static void submit_recv(conn_t *c);

static void multishot_accept(void) {
  struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
  if (!sqe) return;
  io_uring_prep_multishot_accept(sqe, listen_fd, NULL, NULL, SOCK_NONBLOCK);
  io_uring_sqe_set_data64(sqe, OP_ACCEPT);
}

static conn_t *conn_alloc(int fd) {
  for (int i = 0; i < MAX_CONN; i++) {
    if (!conns[i].used) {
      conn_t *c = &conns[i];
      memset(c, 0, sizeof(*c));
      c->used = 1;
      c->fd = fd;
      c->in = malloc(BUF_SIZE);
      if (!c->in) { close(fd); c->used = 0; return NULL; }
      return c;
    }
  }
  close(fd);
  return NULL;
}

static void conn_free(conn_t *c) {
  if (c->fd >= 0) close(c->fd);
  free(c->in);
  free(c->out);
  memset(c, 0, sizeof(*c));
  c->fd = -1;
}

static void submit_recv(conn_t *c) {
  if (!c->used || c->recv_armed || c->fd < 0) return;
  struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
  if (!sqe) return;
#ifdef MULTISHOT_RECV
  io_uring_prep_recv_multishot(sqe, c->fd, NULL, 0, 0);
  sqe->flags |= IOSQE_BUFFER_SELECT;
  sqe->buf_group = BGID;
#else
  c->in_len = 0;
  io_uring_prep_recv(sqe, c->fd, c->in, BUF_SIZE, 0);
#endif
  io_uring_sqe_set_data64(sqe, (uint64_t)(uintptr_t)c | OP_RECV);
  c->recv_armed = 1;
}

static void submit_send(conn_t *c) {
  struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
  if (!sqe) return;
  c->out = malloc(sizeof(response) - 1);
  if (!c->out) { conn_free(c); return; }
  memcpy(c->out, response, sizeof(response) - 1);
  c->out_len = sizeof(response) - 1;
  io_uring_prep_send(sqe, c->fd, c->out, c->out_len, MSG_NOSIGNAL);
  io_uring_sqe_set_data64(sqe, (uint64_t)(uintptr_t)c | OP_SEND);
}

/* Consume complete requests from c->in. One response per connection at depth 1; pipelined bytes are kept
   for the next read, and a second response is not started until the first send completes. */
static void process_input(conn_t *c) {
  for (;;) {
    char *end = NULL;
    for (size_t i = 0; i + 3 < c->in_len; i++) {
      if (c->in[i] == '\r' && c->in[i + 1] == '\n' && c->in[i + 2] == '\r' && c->in[i + 3] == '\n') {
        end = c->in + i + 4;
        break;
      }
    }
    if (!end) return;
    size_t consumed = (size_t)(end - c->in);
    memmove(c->in, end, c->in_len - consumed);
    c->in_len -= consumed;
    submit_send(c);
    return;
  }
}

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 8480;
  signal(SIGPIPE, SIG_IGN);

  struct io_uring_params p;
  memset(&p, 0, sizeof(p));
#ifdef SQPOLL
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_SQPOLL;
  p.sq_thread_idle = 1000;
#else
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
#endif
  p.cq_entries = 1024;
  int r = io_uring_queue_init_params(512, &ring, &p);
  if (r < 0) { fprintf(stderr, "queue_init: %d\n", r); return 1; }

  listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (listen_fd < 0) { perror("socket"); return 1; }
  int one = 1;
  setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((uint16_t)port);
  if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listen_fd, 512) != 0) {
    perror("bind/listen");
    return 1;
  }
  socklen_t alen = sizeof(addr);
  getsockname(listen_fd, (struct sockaddr *)&addr, &alen);
  printf("uring-http listening on %d\n", ntohs(addr.sin_port));
  fflush(stdout);

#ifdef MULTISHOT_RECV
  {
    size_t rsz = NBUF * sizeof(struct io_uring_buf);
    bufring = mmap(NULL, rsz, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    bufslab = malloc((size_t)NBUF * BUFSZ);
    if (!bufring || !bufslab) { fprintf(stderr, "buffer ring alloc\n"); return 1; }
    io_uring_buf_ring_init(bufring);
    int mask = io_uring_buf_ring_mask(NBUF);
    for (int i = 0; i < NBUF; i++)
      io_uring_buf_ring_add(bufring, bufslab + (size_t)i * BUFSZ, BUFSZ, (unsigned short)i, mask, i);
    io_uring_buf_ring_advance(bufring, NBUF);
    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof(reg));
    reg.ring_addr = (unsigned long)bufring;
    reg.ring_entries = NBUF;
    reg.bgid = BGID;
    if (io_uring_register_buf_ring(&ring, &reg, 0) != 0) { fprintf(stderr, "register_buf_ring\n"); return 1; }
  }
#endif
  multishot_accept();
  io_uring_submit(&ring);

  for (;;) {
    struct io_uring_cqe *cqe;
    r = io_uring_wait_cqe(&ring, &cqe);
    if (r < 0) {
      if (r == -EINTR) continue;
      fprintf(stderr, "wait_cqe: %d\n", r);
      break;
    }
    struct io_uring_cqe *batch[64];
    unsigned n = io_uring_peek_batch_cqe(&ring, batch, 64);
    for (unsigned i = 0; i < n; i++) {
      cqe = batch[i];
      uint64_t ud = io_uring_cqe_get_data64(cqe);
      int op = (int)(ud & 7);
      conn_t *c = (conn_t *)(uintptr_t)(ud & ~(uint64_t)7);
      int res = cqe->res;
      if (op == OP_ACCEPT) {
        if (res >= 0) {
          conn_t *nc = conn_alloc(res);
          if (nc) submit_recv(nc);
        }
        if (!(cqe->flags & IORING_CQE_F_MORE)) multishot_accept();
      } else if (c && c->used) {
        if (op == OP_RECV) {
#ifdef MULTISHOT_RECV
          if (res > 0) {
            unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
            char *b = bufslab + (size_t)bid * BUFSZ;
            size_t n = (size_t)res;
            if (c->in_len + n < BUF_SIZE) {
              memcpy(c->in + c->in_len, b, n);
              c->in_len += n;
              process_input(c);
            }
            io_uring_buf_ring_add(bufring, b, BUFSZ, (unsigned short)bid,
                                  io_uring_buf_ring_mask(NBUF), 0);
            io_uring_buf_ring_advance(bufring, 1);
          }
          if (res == 0 || res < 0 || !(cqe->flags & IORING_CQE_F_MORE)) {
            c->recv_armed = 0;
            if (res <= 0) conn_free(c);
          }
#else
          c->recv_armed = 0;
          if (res == 0) conn_free(c);
          else if (res < 0) conn_free(c);
          else {
            c->in_len += (size_t)res;
            process_input(c);
            if (c->used && c->out == NULL) submit_recv(c);
          }
#endif
        } else if (op == OP_SEND) {
          free(c->out); c->out = NULL; c->out_len = 0;
          if (res < 0) conn_free(c);
          else if (c->in_len > 0) { process_input(c); if (c->used && c->out == NULL) submit_recv(c); }
#ifndef MULTISHOT_RECV
          else submit_recv(c);
#endif
        }
      }
      io_uring_cqe_seen(&ring, cqe);
    }
    io_uring_submit(&ring);
  }
  return 0;
}
