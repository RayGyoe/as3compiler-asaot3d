// Serve site/ locally, with the MIME types the pages require.
//
//   node tools/serve-web.cjs              # http://127.0.0.1:8990/
//   node tools/serve-web.cjs --port 9000
//   node tools/serve-web.cjs --dir site
//
// WHY NOT `python3 -m http.server`. Its mime map has no `.wasm`, so Chrome receives
// `application/octet-stream` and silently takes the slower ArrayBuffer instantiation
// path -- which also hides a genuinely broken artifact behind that fallback. The
// gallery additionally needs `.data` and `.ttf` to come through unchanged.
'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);
const argOf = (n, d) => {
  const i = argv.indexOf(n);
  return i < 0 ? d : argv[i + 1];
};
const DIR = path.resolve(ROOT, argOf('--dir', 'site'));
const PORT = parseInt(argOf('--port', '8990'), 10);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8',
  '.ttf': 'font/ttf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.css': 'text/css; charset=utf-8',
};

http
  .createServer((req, res) => {
    let rel = decodeURIComponent(req.url.split('?')[0]);
    if (rel.endsWith('/')) rel += 'index.html';
    const file = path.join(DIR, path.normalize(rel).replace(/^[\\/]+/, ''));
    if (!file.startsWith(DIR) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('404\n');
      return;
    }
    const body = fs.readFileSync(file);
    res.writeHead(200, {
      'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'content-length': body.length,
      'cache-control': 'no-store',
    });
    res.end(body);
  })
  .listen(PORT, '127.0.0.1', () => {
    console.log('serving ' + path.relative(ROOT, DIR) + ' on http://127.0.0.1:' + PORT + '/');
  });