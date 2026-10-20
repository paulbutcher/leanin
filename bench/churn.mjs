// churn.mjs <port> <connections> <durationSec> [path]
// Connection-per-request: each worker opens a fresh connection, sends one request, reads the full response,
// closes, and repeats for the duration. Measures connection setup/teardown and the close path, which the
// keep-alive client (load.mjs) never exercises.
import net from 'node:net';

const port = Number(process.argv[2] || 8080);
const C = Number(process.argv[3] || 1);
const dur = Number(process.argv[4] || 5);
const path = process.argv[5] || '/';

const req = Buffer.from(`GET ${path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);

let completed = 0;
let errors = 0;
const latencies = [];
let stopped = false;

function worker() {
  if (stopped) return;
  const t0 = process.hrtime.bigint();
  const sock = net.connect(port, '127.0.0.1');
  let buf = Buffer.alloc(0);
  let done = false;
  sock.on('connect', () => sock.write(req));
  sock.on('data', (d) => {
    if (done) return;
    buf = Buffer.concat([buf, d]);
    const idx = buf.indexOf('\r\n\r\n');
    if (idx < 0) return;
    const head = buf.subarray(0, idx).toString('latin1');
    const m = /content-length:\s*(\d+)/i.exec(head);
    const len = m ? Number(m[1]) : 0;
    if (buf.length < idx + 4 + len) return;
    done = true;
    completed++;
    latencies.push(Number(process.hrtime.bigint() - t0) / 1000);
    sock.destroy();
  });
  sock.on('error', () => {
    if (!done) errors++;
    done = true;
  });
  sock.on('close', () => {
    if (!done) errors++;
    done = true;
    if (!stopped) setImmediate(worker); else workerDone();
  });
}

let active = 0;
for (let i = 0; i < C; i++) { active++; worker(); }
function workerDone() { active--; }

setTimeout(() => {
  stopped = true;
  latencies.sort((a, b) => a - b);
  const p50 = latencies.length ? latencies[Math.floor(latencies.length * 0.5)] : 0;
  const p99 = latencies.length ? latencies[Math.floor(latencies.length * 0.99)] : 0;
  const rps = Math.round(completed / dur);
  console.log(`rps=${rps} completed=${completed} errors=${errors} p50us=${p50.toFixed(0)} p99us=${p99.toFixed(0)}`);
  process.exit(0);
}, dur * 1000);
