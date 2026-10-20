#!/usr/bin/env bash
# http-cancel-contract.sh — the HTTP cancellation contract at its public socket.
#
#   nix develop -c bash tests/http-cancel-contract.sh HC1
#   nix develop -c bash tests/http-cancel-contract.sh HC2
#
# Builds `leanioCancelContract`, starts it on a loopback port, and drives the scenario with a Python client.
# A failure before the scenario's own assertion — the build, the executable, startup, readiness, the interim
# `100 Continue`, the `/boom` control, a bounded read, or a reset standing in for end of stream — is a setup
# error with exit 2, so a fixture defect is never read as the scenario's result. A scenario assertion that
# does not hold exits 1 with its own text. The watchdog bounds the build and the client invocation, and the
# client bounds each socket read; a bounded wait is a setup error, never the scenario's result.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || { printf 'setup error: cannot enter %s\n' "$repo_root" >&2; exit 2; }

readonly WATCHDOG="${LEANIN_WATCHDOG:-300}"
port="${CANCEL_CONTRACT_PORT:-8791}"

setup_error() {
  printf 'http-cancel-contract: SETUP ERROR: %s\n' "$1" >&2
  shift
  for detail in "$@"; do printf '  %s\n' "$detail" >&2; done
  exit 2
}

scenario="${1:-HC1}"
case "$scenario" in
  HC1 | HC2) ;;
  *) setup_error "unknown scenario id: $scenario" "documented ids: HC1, HC2" ;;
esac

work="$(mktemp -d)" || setup_error "cannot create a temporary directory"
srv=""
cleanup() {
  if [ -n "$srv" ]; then
    kill "$srv" 2>/dev/null
    wait "$srv" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

bounded() { timeout "$WATCHDOG" "$@"; }

bounded lake build leanioCancelContract >"$work/build.log" 2>&1 || {
  status=$?
  if [ "$status" -eq 124 ]; then
    setup_error "the test executable's build did not finish within ${WATCHDOG}s" "a bounded wait, not a scenario result"
  fi
  setup_error "the test executable did not build" "$(tail -n 20 "$work/build.log")"
}

[ -x ./.lake/build/bin/leanioCancelContract ] || setup_error "the test executable is missing"

./.lake/build/bin/leanioCancelContract "$port" >"$work/server.log" 2>&1 &
srv=$!

# Readiness is a real connect to the service's own port, so it needs no listening-table tool and cannot
# report ready for a port nothing accepts on.
ready=""
for _ in $(seq 1 100); do
  kill -0 "$srv" 2>/dev/null || setup_error "the test service exited during startup" "$(tail -n 20 "$work/server.log")"
  if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1).close()
PY
  then
    ready=1
    break
  fi
  sleep 0.2
done
[ -n "$ready" ] || setup_error "the test service did not listen on port ${port} within 20s" "$(tail -n 20 "$work/server.log")"

bounded python3 - "$port" "$scenario" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
scenario = sys.argv[2]
READ_TIMEOUT = 5.0


class Setup(Exception):
    pass


class ResetBeforeEOF(Exception):
    pass


def setup_error(message, detail=""):
    raise Setup(f"{message}: {detail}" if detail else message)


def recv_some(sock):
    try:
        return sock.recv(65536)
    except socket.timeout:
        raise Setup(f"a bounded socket read expired (nothing arrived for {READ_TIMEOUT:g}s), so nothing is asserted either way")
    except ConnectionResetError as exc:
        raise ResetBeforeEOF(str(exc))


def connect():
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=READ_TIMEOUT)
    except OSError as exc:
        setup_error("the client could not connect to the test service", str(exc))
    sock.settimeout(READ_TIMEOUT)
    return sock


def send(sock, data):
    try:
        sock.sendall(data)
    except OSError as exc:
        setup_error("the client could not send its request", str(exc))


def status_code(data):
    """Parse an HTTP/1 status line at the start of `data`; None when there is none.

    The same detector reads the `/boom` control and the bytes a half-closed request receives after its
    interim response, so "no status" is an absence this run can see a status through.
    """
    line = data.split(b"\r\n", 1)[0]
    parts = line.split(b" ")
    if len(parts) < 2 or not parts[0].startswith(b"HTTP/1."):
        return None
    try:
        return int(parts[1])
    except ValueError:
        return None


def read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            chunk = recv_some(sock)
        except ResetBeforeEOF as exc:
            setup_error("the connection reset before a complete response head", str(exc))
        if not chunk:
            setup_error("the connection ended before a complete response head", repr(buf[:200]))
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head, rest


def read_body(sock, head, rest):
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            try:
                length = int(value.strip())
            except ValueError:
                setup_error("a response declared a malformed Content-Length", repr(line))
    while len(rest) < length:
        try:
            chunk = recv_some(sock)
        except ResetBeforeEOF as exc:
            setup_error("the connection reset before a response body was complete", str(exc))
        if not chunk:
            setup_error("the connection ended before a response body was complete",
                        f"read {len(rest)} of {length} bytes")
        rest += chunk
    return rest[:length]


def content_length(head):
    """The declared Content-Length of a response head, which a scenario parses rather than infers."""
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            try:
                return int(value.strip())
            except ValueError:
                setup_error("a response declared a malformed Content-Length", repr(line))
    setup_error("a response did not declare a Content-Length", repr(head[:200]))


def read_remaining(sock, rest):
    """Read after a response head to the end of a `Connection: close` stream, so the body is measured
    rather than assumed from the declared length."""
    buf = rest
    while True:
        try:
            chunk = recv_some(sock)
        except ResetBeforeEOF as exc:
            setup_error("the connection reset before an end of stream could be read", str(exc))
        if not chunk:
            return buf
        buf += chunk


def get(path):
    sock = connect()
    send(sock, f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    head, rest = read_head(sock)
    body = read_body(sock, head, rest)
    sock.close()
    return status_code(head), head, body


failures = []


def then_fail(message, detail=""):
    failures.append(f"{message}: {detail}" if detail else message)


def run_hc1():
    # The affirmative control: the same detector must find the ordinary 500 a failing handler produces.
    boom_status, boom_head, _ = get("/boom")
    if boom_status != 500:
        setup_error("the /boom control did not produce a status 500 for the status-line detector",
                    f"detector parsed {boom_status!r} from {boom_head[:200]!r}")

    # HC1: a declared body, an interim 100, part of the body, then a half-close with the read side open.
    probe = connect()
    send(probe, b"POST /cancel-probe HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n"
                b"Expect: 100-continue\r\n\r\n")
    interim_head, interim_rest = read_head(probe)
    interim_status = status_code(interim_head)
    if interim_status != 100:
        setup_error("the interim 100 Continue was not observed before the body was sent",
                    f"detector parsed {interim_status!r} from {interim_head[:200]!r}")
    send(probe, b"part")  # 4 of the 10 declared bytes
    try:
        probe.shutdown(socket.SHUT_WR)
    except OSError as exc:
        setup_error("the client could not half-close its write side", str(exc))

    after = interim_rest
    reset = None
    while True:
        try:
            chunk = recv_some(probe)
        except ResetBeforeEOF as exc:
            reset = str(exc)
            break
        if not chunk:
            break
        after += chunk
    probe.close()

    post_status = status_code(after)
    if post_status is not None:
        then_fail("HC1: after the interim 100 and the half-close the request receives no post-close status line",
                  f"the status-line detector parsed {post_status} from {after[:200]!r}")
    if after != b"":
        then_fail("HC1: after the interim 100 and the half-close the client receives zero response bytes",
                  f"read {len(after)} bytes: {after[:200]!r}")
    if reset is not None and after == b"":
        setup_error("the connection reset before an end of stream could be read", reset)

    # Recovery: a fresh connection after the cancelled one is answered normally.
    ping_status, ping_head, ping_body = get("/ping")
    if ping_status != 200:
        then_fail("HC1: a fresh connection after the half-closed request is answered 200",
                  f"detector parsed {ping_status!r} from {ping_head[:200]!r}")
    if ping_body != b"pong\n":
        then_fail("HC1: a fresh connection after the half-closed request carries the exact pong body",
                  f"read {ping_body!r}")


def run_hc2():
    # The reference: the independent /error-text route serializes the same named IO.Error value, so the
    # expected body is parsed from the service rather than retyped here.
    text_status, text_head, expected = get("/error-text")
    if text_status != 200:
        setup_error("the /error-text reference did not answer 200",
                    f"detector parsed {text_status!r} from {text_head[:200]!r}")
    if not expected:
        setup_error("the /error-text reference returned an empty body", repr(text_head[:200]))
    if b"Http: prefixed application sentinel" not in expected:
        setup_error("the /error-text reference body does not carry the named sentinel",
                    repr(expected[:200]))

    # The waiting client: hold one connection open while the scripted completion is released.
    parked = connect()
    send(parked, b"GET /prefixed-error HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")

    # Readiness handshake: the callback must be parked before release, observed through the public socket.
    registered = False
    last_ready = b""
    for _ in range(200):
        ready_status, ready_head, last_ready = get("/ready")
        if ready_status != 200:
            setup_error("the /ready control did not answer 200",
                        f"detector parsed {ready_status!r} from {ready_head[:200]!r}")
        if last_ready not in (b"ready\n", b"waiting\n"):
            setup_error("the /ready control answered an unexpected body", repr(last_ready[:200]))
        if last_ready == b"ready\n":
            registered = True
            break
        time.sleep(0.05)
    if not registered:
        setup_error("the parked success callback was not registered across the readiness handshake",
                    f"last /ready body: {last_ready!r}")

    # Release exactly once, through the route that owns the completion.
    rel_status, rel_head, rel_body = get("/release")
    if rel_status != 200:
        setup_error("the /release control did not answer 200",
                    f"detector parsed {rel_status!r} from {rel_head[:200]!r}")
    if rel_body != b"released\n":
        setup_error("the /release control did not resolve the parked callback once", repr(rel_body[:200]))

    parked_head, parked_rest = read_head(parked)
    parked_status = status_code(parked_head)
    if parked_status is None:
        setup_error("the /prefixed-error response head has no parseable status line",
                    repr(parked_head[:200]))
    length = content_length(parked_head)
    parked_body = read_remaining(parked, parked_rest)
    parked.close()

    # Recovery: a fresh connection after the released request is answered normally.
    ping_status, ping_head, ping_body = get("/ping")
    if ping_status != 200:
        then_fail("HC2: a fresh connection after the prefixed error is answered 200",
                  f"detector parsed {ping_status!r} from {ping_head[:200]!r}")
    if ping_body != b"pong\n":
        then_fail("HC2: a fresh connection after the prefixed error carries the exact pong body",
                  f"read {ping_body!r}")

    if parked_status != 500:
        then_fail("HC2: the parked prefixed error is answered status 500",
                  f"detector parsed {parked_status!r} from {parked_head[:200]!r}")
    if parked_body != expected:
        then_fail("HC2: the prefixed error response body is the exact /error-text bytes for the same error value",
                  f"expected {len(expected)} bytes {expected!r}, read {len(parked_body)} bytes {parked_body!r}")
    if length != len(parked_body):
        then_fail("HC2: the prefixed error response Content-Length agrees with the body it sent",
                  f"declared {length}, body {len(parked_body)} bytes")


def main():
    if scenario == "HC1":
        run_hc1()
    else:
        run_hc2()

    if failures:
        print(f"http-cancel-contract: {scenario} FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"http-cancel-contract: {scenario} passed")
    return 0


try:
    sys.exit(main())
except Setup as exc:
    print(f"http-cancel-contract: SETUP ERROR: {exc}", file=sys.stderr)
    sys.exit(2)
PY
status=$?
if [ "$status" -eq 124 ]; then
  setup_error "${scenario}: the client invocation did not finish within ${WATCHDOG}s" \
    "a bounded wait, not a scenario result"
fi
exit "$status"
