// load.mjs <port> <connections> <durationSec> [path]
// Keep-alive sequential request-response per connection: send, await the full response, send the next.
// Reports completed requests/second and p50 latency. Used for both the leanin and Node servers.
import net from 'node:net';

const port = Number(process.argv[2] || 8080);
const C = Number(process.argv[3] || 1);
const dur = Number(process.argv[4] || 5);
const path = process.argv[5] || '/';

const req = Buffer.from(`GET ${path} HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n`);

let completed = 0;
let errors = 0;
const latencies = [];
let stopped = false;

function worker() {
  const sock = net.connect(port, '127.0.0.1');
  let buf = Buffer.alloc(0);
  let t0 = 0n;
  sock.on('connect', send);
  function send() {
    if (stopped) { sock.end(); return; }
    t0 = process.hrtime.bigint();
    sock.write(req);
  }
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (true) {
      const idx = buf.indexOf('\r\n\r\n');
      if (idx < 0) break;
      const head = buf.subarray(0, idx).toString('latin1');
      const m = /content-length:\s*(\d+)/i.exec(head);
      const len = m ? Number(m[1]) : 0;
      const total = idx + 4 + len;
      if (buf.length < total) break;
      buf = buf.subarray(total);
      completed++;
      latencies.push(Number(process.hrtime.bigint() - t0) / 1000); // µs
      send();
    }
  });
  sock.on('error', () => { errors++; });
}

for (let i = 0; i < C; i++) worker();

setTimeout(() => {
  stopped = true;
  latencies.sort((a, b) => a - b);
  const p50 = latencies.length ? latencies[Math.floor(latencies.length * 0.5)] : 0;
  const p99 = latencies.length ? latencies[Math.floor(latencies.length * 0.99)] : 0;
  const rps = Math.round(completed / dur);
  console.log(`rps=${rps} completed=${completed} errors=${errors} p50us=${p50.toFixed(0)} p99us=${p99.toFixed(0)}`);
  process.exit(0);
}, dur * 1000);
