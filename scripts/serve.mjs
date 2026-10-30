import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml' };
const allowed = new Set(['/prototype/index.html', '/prototype/style.css', '/prototype/app.mjs', '/src/calendar.mjs']);
const server = http.createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://localhost').pathname;
  const file = pathname === '/' ? '/prototype/index.html' : pathname;
  if (!['GET', 'HEAD'].includes(request.method) || !allowed.has(file)) {
    response.writeHead(404); response.end('Not found'); return;
  }
  try {
    const data = await readFile(path.join(root, file));
    response.writeHead(200, {
      'Content-Type': types[path.extname(file)],
      'Cache-Control': 'no-store',
      'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer'
    });
    response.end(request.method === 'HEAD' ? undefined : data);
  } catch { response.writeHead(404); response.end('Not found'); }
});
server.listen(Number(process.env.CALENDULA_PORT || 4173), '127.0.0.1', () => console.log('Календула: http://127.0.0.1:4173'));
