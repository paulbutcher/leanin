// node-server.mjs <port> — the Node baseline: keep-alive HTTP/1.1 server, the same hello response shape.
import http from 'node:http';

const port = Number(process.argv[2] || 8080);

http.createServer((req, res) => {
  const b = `hello from node\nmethod=${req.method} path=${req.url} version=HTTP/${req.httpVersion}\n`;
  res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': Buffer.byteLength(b) });
  res.end(b);
}).listen(port, '127.0.0.1', () => console.log(`node listening ${port}`));
