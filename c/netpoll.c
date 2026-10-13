/* A readiness loop of our own, entered from Lean through @[extern].
 *
 * The design point: the poll thread is a *Lean* thread (created with IO.asTask), so this file never enters Lean
 * itself — it performs syscalls and returns. That is safer than calling back through lean_apply_* from a foreign
 * thread, and simpler: a completion is delivered by Lean code that was blocked in `np_epoll_wait`.
 *
 * Nothing here uses Std.Async, IO.Promise or Lean's socket layer. The descriptors are ours, made with socket(2).
 */
#define _GNU_SOURCE
#include <lean/lean.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define OK_U32(v) lean_io_result_mk_ok(lean_box_uint32((uint32_t)(v)))
#define BAD_U32() lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu))

static void np_nonblocking(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Listen on the loopback interface; returns the listener descriptor, or 0 on failure. */
LEAN_EXPORT lean_object *np_listen(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return OK_U32(0);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = htons(port);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) return OK_U32(0);
  if (listen(fd, 1024) != 0) return OK_U32(0);
  np_nonblocking(fd);
  return OK_U32(fd);
}

LEAN_EXPORT lean_object *np_epoll_create(void) {
  int fd = epoll_create1(EPOLL_CLOEXEC);
  return OK_U32(fd < 0 ? 0 : fd);
}

/* Register `fd`, tagged so the waiter can tell which descriptor is ready. */
LEAN_EXPORT lean_object *np_epoll_add(uint32_t epfd, uint32_t fd, uint64_t tag) {
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  ev.events = EPOLLIN;
  ev.data.u64 = tag;
  return OK_U32(epoll_ctl((int)epfd, EPOLL_CTL_ADD, (int)fd, &ev) == 0 ? 1 : 0);
}

LEAN_EXPORT lean_object *np_epoll_del(uint32_t epfd, uint32_t fd) {
  return OK_U32(epoll_ctl((int)epfd, EPOLL_CTL_DEL, (int)fd, NULL) == 0 ? 1 : 0);
}

/* Wait for readiness, returning the ready tags as an array of UInt64 (the listener is tagged 0, a connection
   under its own descriptor). */
LEAN_EXPORT lean_object *np_epoll_wait(uint32_t epfd, uint32_t timeoutMs) {
  struct epoll_event evs[256];
  int n = epoll_wait((int)epfd, evs, 256, (int)timeoutMs);
  if (n < 0) n = 0;
  lean_object *arr = lean_mk_empty_array_with_capacity(lean_box((size_t)n));
  for (int i = 0; i < n; i++)
    arr = lean_array_push(arr, lean_box_uint64(evs[i].data.u64));
  return lean_io_result_mk_ok(arr);
}

/* Accept without blocking: the new descriptor, or 0 when there is nothing to accept. */
LEAN_EXPORT lean_object *np_accept(uint32_t lfd) {
  int fd = accept4((int)lfd, NULL, NULL, SOCK_NONBLOCK);
  return OK_U32(fd <= 0 ? 0 : fd);
}

/* Read into `buf`: the byte count, 0 at end of input, or -1 when the read would block. */
LEAN_EXPORT lean_object *np_recv(uint32_t fd, lean_object *buf, uint32_t max) {
  size_t cap = lean_sarray_size(buf);
  if (max > cap) max = (uint32_t)cap;
  ssize_t r = read((int)fd, lean_sarray_cptr(buf), max);
  if (r == 0) return OK_U32(0);
  if (r < 0) return OK_U32(0xFFFFFFFFu);
  return OK_U32(r);
}

LEAN_EXPORT lean_object *np_send(uint32_t fd, lean_object *buf, uint32_t len) {
  size_t cap = lean_sarray_size(buf);
  if (len > cap) len = (uint32_t)cap;
  ssize_t r = write((int)fd, lean_sarray_cptr(buf), len);
  return OK_U32(r < 0 ? 0xFFFFFFFFu : (uint32_t)r);
}

LEAN_EXPORT lean_object *np_close(uint32_t fd) {
  close((int)fd);
  return lean_io_result_mk_ok(lean_box(0));
}
