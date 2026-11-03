// Load every page in site/ in a real browser and report what came out.
//
//   node tools/verify-web.cjs                 # all demos, own headless Chrome
//   node tools/verify-web.cjs --only walk-m26 --shots
//   node tools/verify-web.cjs --cdp 54604     # drive an already-running Chrome
//   node tools/verify-web.cjs --headed        # watch it happen
//
// WHY IT LAUNCHES ITS OWN BROWSER BY DEFAULT. The first version borrowed whatever
// Chrome happened to expose a DevTools port, which made the run depend on a
// stranger's tab state and -- measured -- could wedge indefinitely: a demo that
// blocks its main thread never answers `Runtime.evaluate`, and a promise with no
// timeout waits forever. Here every CDP call carries a deadline and the browser is
// ours to kill, so "the harness hangs" is no longer a possible outcome.

// WHY THIS EXISTS AND WHY IT IS NOT "the build succeeded". A wasm page that fails at
// run time is a *blank canvas*: the build is green, the HTTP server returns 200 for
// every byte, and nothing in the toolchain complains. The only witness is the
// runtime itself, and it already keeps one — the generated page captures `trace()`
// into `window.__ascStdout` and uncaught throws into `window.__ascErrors` (see the
// page's own header comment). This tool reads both, plus a screenshot so a blank
// page cannot pass as "loaded fine".
//
// It serves site/ itself instead of trusting whatever static server is around,
// because the MIME type of .wasm is load-bearing: `application/octet-stream` makes
// Chrome fall back to ArrayBuffer instantiation (benign, but it also hides a
// genuinely missing/incorrect artifact behind a slower path).
'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');
const { execFileSync, spawn } = require('child_process');
const os = require('os');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);
const argOf = (n, d) => {
  const i = argv.indexOf(n);
  return i < 0 ? d : argv[i + 1];
};
const SITE = path.resolve(ROOT, argOf('--out', 'site'));
const PORT = parseInt(argOf('--port', '8991'), 10);
const WAIT_MS = parseInt(argOf('--wait', '20000'), 10);
const only = (argOf('--only', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const shots = argv.includes('--shots');
const headed = argv.includes('--headed');
const CDP_TIMEOUT = parseInt(argOf('--cdp-timeout', '20000'), 10);
const SHOT_DIR = path.join(ROOT, 'temp', 'web-shots');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.ttf': 'font/ttf',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
};

function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let rel = decodeURIComponent(req.url.split('?')[0]);
      if (rel.endsWith('/')) rel += 'index.html';
      const file = path.join(SITE, path.normalize(rel).replace(/^[\\/]+/, ''));
      if (!file.startsWith(SITE) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
        res.writeHead(404, { 'content-type': 'text/plain' });
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
    });
    server.listen(PORT, '127.0.0.1', () => resolve(server));
  });
}

// Which Chrome? `--cdp` wins (an already-running browser the caller owns), otherwise
// we take a disposable profile of our own below. We deliberately do NOT scrape
// `ps` for a DevTools port any more: that silently drove somebody else's tab.
function findCdp() {
  const explicit = argOf('--cdp', '');
  return explicit ? [parseInt(explicit, 10)] : [];
}

const CHROME_CANDIDATES = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
];

function chromePath() {
  const explicit = argOf('--chrome', '');
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Error('--chrome ' + explicit + ' does not exist');
    return explicit;
  }
  return CHROME_CANDIDATES.find((p) => fs.existsSync(p)) || null;
}

// A browser of our own: disposable profile, port 0 (the OS picks one), and the port
// arrives through the profile's DevToolsActivePort file -- the supported way, where
// scraping stdout is not. `--headless=new` still composits a real GL surface, which
// these pages need; WebGL falls back to SwiftShader when no GPU is available.
async function launchOwnChrome() {
  const bin = chromePath();
  if (!bin) return null;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'asc-web-verify-'));
  const flags = [
    '--remote-debugging-port=0',
    '--user-data-dir=' + profile,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-timer-throttling',
    '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows',
    '--hide-scrollbars',
    '--mute-audio',
    '--window-size=1280,800',
    'about:blank',
  ];
  if (!headed) flags.unshift('--headless=new');
  const child = spawn(bin, flags, { stdio: 'ignore' });
  const marker = path.join(profile, 'DevToolsActivePort');
  const t0 = Date.now();
  while (Date.now() - t0 < 20000) {
    if (fs.existsSync(marker)) {
      const port = parseInt(fs.readFileSync(marker, 'utf8').split('\n')[0], 10);
      if (Number.isFinite(port) && port > 0) return { port, child, profile };
    }
    await sleep(150);
  }
  try { child.kill('SIGKILL'); } catch { /* already gone */ }
  fs.rmSync(profile, { recursive: true, force: true });
  return null;
}

// Do the screenshot's pixels say anything? A page that failed to render is the
// failure mode this whole tool exists for, and "canvas element exists" does not
// catch it. Decoding Chrome's PNG (8-bit, non-interlaced, RGB or RGBA) is enough;
// we only need a colour census, not an image.
function pngStats(buf) {
  let pos = 8; // signature
  let w = 0, h = 0, bits = 0, color = 0, interlace = 0;
  const idat = [];
  while (pos + 8 <= buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      bits = data[8];
      color = data[9];
      interlace = data[12];
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  if (!w || !h || bits !== 8 || interlace !== 0 || (color !== 2 && color !== 6)) return null;
  const ch = color === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  const out = Buffer.alloc(h * stride);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const cur = out.subarray(y * stride, (y + 1) * stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= ch ? cur[x - ch] : 0;
      const b = prev[x];
      const c = x >= ch ? prev[x - ch] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      cur[x] = v & 0xff;
    }
    prev = cur;
  }
  // Census on a coarse grid: distinct colours and the darkest/brightest ink.
  const seen = new Set();
  let lo = 255, hi = 0;
  const stepY = Math.max(1, Math.floor(h / 120));
  const stepX = Math.max(1, Math.floor(w / 160));
  for (let y = 0; y < h; y += stepY) {
    for (let x = 0; x < w; x += stepX) {
      const i = y * stride + x * ch;
      const r = out[i], g = out[i + 1], bl = out[i + 2];
      seen.add((r << 16) | (g << 8) | bl);
      const lum = (r * 299 + g * 587 + bl * 114) / 1000 | 0;
      if (lum < lo) lo = lum;
      if (lum > hi) hi = lum;
    }
  }
  return { w, h, colors: seen.size, lumMin: lo, lumMax: hi };
}

async function jsonGet(port, rel) {
  const r = await fetch('http://127.0.0.1:' + port + rel);
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function pickTarget(port) {
  const list = await jsonGet(port, '/json/list');
  const pages = list.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!pages.length) return null;
  // Prefer a tab this tool can take over: about:blank or one of our own pages.
  return pages.find((t) => /^about:blank|127\.0\.0\.1:\d+\//.test(t.url)) || pages[0];
}

function cdpSession(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let seq = 0;
  const pending = new Map();
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    }
  });
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', reject);
  });
  // Every call has a deadline. A demo that spins its main thread answers nothing,
  // and without this the driver would wait on it for ever (measured: it did).
  const send = (method, params = {}, timeoutMs = CDP_TIMEOUT) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      const timer = setTimeout(() => {
        if (pending.delete(id)) reject(new Error('CDP timeout ' + timeoutMs + ' ms on ' + method));
      }, timeoutMs);
      pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      ws.send(JSON.stringify({ id, method, params }));
    });
  return { ws, ready, send };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function evalJson(send, expression) {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + (r.exceptionDetails.exception || {}).description);
  return r.result.value;
}

// The probe: everything the page itself knows about its run. Trimmed to a few
// entries per field because some demos print a PARITY report of 40+ lines.
const PROBE = `(() => {
  const out = window.__ascStdout || [];
  return JSON.stringify({
    ok: true,
    errors: (window.__ascErrors || []).slice(0, 6),
    stdout: out.slice(0, 12),
    tail: out.slice(-6),
    lines: out.length,
    canvas: (() => { const c = document.querySelector('canvas'); return c ? { w: c.width, h: c.height } : null; })(),
    title: document.title
  });
})()`;

const NOISE = /^(Stage3DApp ready|AGALRenderer|NativeShaderRenderer|.*instructions)/;

async function verifyOne(send, demo) {
  const url = 'http://127.0.0.1:' + PORT + '/' + demo.dir + '/index.html';
  await send('Page.navigate', { url });
  const t0 = Date.now();
  let lines = 0;
  while (Date.now() - t0 < WAIT_MS) {
    await sleep(500);
    try {
      lines = await evalJson(send, 'JSON.stringify((window.__ascStdout||[]).length)');
      lines = JSON.parse(lines);
    } catch {
      lines = 0; // mid-navigation evaluate races the new document
    }
    if (lines > 0) break;
  }
  // One more beat: a demo that prints on frame 1 can still throw on frame 3.
  await sleep(1500);
  const raw = await evalJson(send, PROBE);
  const probe = JSON.parse(raw);
  const result = {
    dir: demo.dir,
    title: demo.title,
    loaded: probe.lines > 0,
    lines: probe.lines,
    canvas: probe.canvas,
    errors: probe.errors,
    startup: probe.stdout.filter((l) => !NOISE.test(l)).slice(0, 6),
    tail: probe.tail,
    ms: Date.now() - t0,
  };
  // What "failed" means, spelled out rather than inferred from one signal:
  //   - the page recorded an uncaught error or an unhandled rejection,
  //   - nothing ever reached stdout (the runtime never got to main()),
  //   - a loader error was printed (pruned assets, a 404 in the virtual FS).
  const bad = [];
  if (probe.errors.length) bad.push('page error: ' + probe.errors[0]);
  if (!result.loaded) bad.push('no stdout within ' + WAIT_MS + ' ms');
  const loadFail = probe.tail.concat(probe.stdout).find((l) => /\b(ioError|#2032|#2044|cannot load|not found|failed to (load|open))\b/i.test(l));
  if (loadFail) bad.push('load error: ' + loadFail);
  // A page whose pixels are one flat colour is a blank page, however chatty its
  // stdout was -- the exact failure a build-only check cannot see.
  if (result.pixels && result.pixels.colors < 3) bad.push('blank page: ' + result.pixels.colors + ' distinct colour(s) in ' + result.pixels.w + 'x' + result.pixels.h);
  result.pass = bad.length === 0;
  result.bad = bad;
  if (shots) {
    fs.mkdirSync(SHOT_DIR, { recursive: true });
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    const bytes = Buffer.from(shot.data, 'base64');
    const file = path.join(SHOT_DIR, demo.dir + '.png');
    fs.writeFileSync(file, bytes);
    result.shot = path.relative(ROOT, file);
    result.shotBytes = fs.statSync(file).size;
    result.pixels = pngStats(bytes);
  }
  return result;
}

(async () => {
  const report = JSON.parse(fs.readFileSync(path.join(SITE, 'demos.json'), 'utf8'));
  const demos = report.demos.filter((d) => d.status === 'ok' && (only.length === 0 || only.includes(d.dir)));
  if (!demos.length) {
    console.error('verify-web: no built demos in ' + path.join(SITE, 'demos.json') + ' (run tools/build-web.cjs)');
    process.exit(1);
  }
  const server = await serve();

  // Browser: an explicit --cdp port, else our own disposable headless Chrome.
  let target = null;
  let cdpPort = 0;
  let own = null;
  for (const port of findCdp()) {
    try {
      target = await pickTarget(port);
      if (target) {
        cdpPort = port;
        break;
      }
    } catch {
      /* not this one */
    }
  }
  if (!target) {
    own = await launchOwnChrome();
    if (own) {
      cdpPort = own.port;
      try {
        target = await pickTarget(own.port);
      } catch (e) {
        target = null;
      }
    }
  }
  const cleanup = () => {
    server.close();
    if (own) {
      try { own.child.kill('SIGKILL'); } catch { /* already gone */ }
      try { fs.rmSync(own.profile, { recursive: true, force: true }); } catch { /* in use */ }
    }
  };
  if (!target) {
    cleanup();
    console.error(
      'verify-web: no browser to drive.\n' +
        '            pass --chrome <path> (looked for ' + CHROME_CANDIDATES.join(', ') + ')\n' +
        '            or --cdp <port> for a Chrome already started with --remote-debugging-port'
    );
    process.exit(1);
  }
  console.log('serving ' + path.relative(ROOT, SITE) + ' on http://127.0.0.1:' + PORT + '/  (CDP ' + cdpPort + (own ? ', own headless' : ', borrowed') + ')');

  const { ws, ready, send } = cdpSession(target.webSocketDebuggerUrl);
  await ready;
  await send('Page.enable');
  await send('Runtime.enable');

  const results = [];
  for (const demo of demos) {
    let r;
    try {
      r = await verifyOne(send, demo);
    } catch (e) {
      r = { dir: demo.dir, title: demo.title, pass: false, bad: ['driver: ' + (e.message || e)], ms: 0 };
    }
    results.push(r);
    const shotNote = r.shotBytes ? '  shot ' + String(Math.round(r.shotBytes / 1024)).padStart(5) + ' KB' : '';
    console.log(
      (r.pass ? '  PASS  ' : '  FAIL  ') + r.dir.padEnd(16) +
        String(r.lines || 0).padStart(4) + ' lines' +
        (r.canvas ? '  ' + r.canvas.w + 'x' + r.canvas.h : '  no canvas') +
        '  ' + (r.ms / 1000).toFixed(1) + ' s' + shotNote +
        (r.pass ? '' : '\n         ' + r.bad.join('\n         '))
    );
  }
  ws.close();
  cleanup();

  const pass = results.filter((r) => r.pass).length;
  const out = { generated: new Date().toISOString(), port: PORT, cdp: cdpPort, results };
  fs.mkdirSync(path.join(ROOT, 'temp'), { recursive: true });
  fs.writeFileSync(path.join(ROOT, 'temp', 'web-verify.json'), JSON.stringify(out, null, 2) + '\n');
  console.log('');
  console.log(pass + '/' + results.length + ' pages PASS  (report: temp/web-verify.json)');
  if (pass !== results.length) process.exitCode = 1;
})();