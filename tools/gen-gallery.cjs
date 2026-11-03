// Write site/index.html: the one page a visitor lands on.
//
//   node tools/gen-gallery.cjs               # reads site/demos.json, writes site/index.html
//   node tools/gen-gallery.cjs --out site
//
// WHY THE LIST COMES FROM demos.json AND NOT FROM apps/. The gallery must agree with
// what was actually built, including the demos that were deliberately not built: a
// browser-only page cannot run the native-shader demos (Context3DNative has no WebGL2
// arm yet), and those still get a row -- with the reason -- rather than vanishing
// (AGENTS.md 1.5: never degrade quietly). build-web.cjs writes that report; this tool
// only lays it out.
//
// Each demo stays an <iframe> pointed at its own page. The alternative -- rewriting
// every demo's HTML into one SPA -- would mean one broken demo can take the whole
// gallery down, and the wasm instances could not be torn down between demos.
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);
const argOf = (n, d) => {
  const i = argv.indexOf(n);
  return i < 0 ? d : argv[i + 1];
};
const OUT = path.resolve(ROOT, argOf('--out', 'site'));

const report = JSON.parse(fs.readFileSync(path.join(OUT, 'demos.json'), 'utf8'));
const byGroup = new Map(report.groups.map((g) => [g.id, { ...g, demos: [] }]));
for (const demo of report.demos) {
  const g = byGroup.get(demo.group);
  if (!g) throw new Error('demo ' + demo.dir + ' names group "' + demo.group + '", which demos.json does not define');
  g.demos.push(demo);
}
const groups = [...byGroup.values()].filter((g) => g.demos.length);

const built = report.demos.filter((d) => d.status === 'ok');
const skipped = report.demos.filter((d) => d.status !== 'ok');
const totalMB = (built.reduce((n, d) => n + (d.bytes || 0), 0) / 1048576).toFixed(0);
const stamp = report.generated.slice(0, 16).replace('T', ' ');

const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function row(demo) {
  const ok = demo.status === 'ok';
  const ms = ok ? String(Math.round(demo.ms / 1000)) + 's' : '';
  const badge = ok ? '' : '<span class="badge">原生通道</span>';
  return `
      <a class="item${ok ? '' : ' off'}" href="#${demo.dir}" data-dir="${demo.dir}" title="${esc(demo.blurb)}">
        <span class="name">${esc(demo.title)}${badge}</span>
        <span class="meta">${esc(demo.dir)}${ms ? ' · ' + ms : ''}</span>
      </a>`;
}

function groupBlock(g) {
  return `
    <div class="group" data-group="${g.id}">
      <div class="group-title">${esc(g.title)}</div>${g.demos.map(row).join('')}
    </div>`;
}

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>asaot3d · 浏览器里的 AS3 复活</title>
<style>
  :root {
    --bg: #0f1115; --side: #14171d; --line: #232832; --text: #dfe3ea;
    --dim: #8b93a1; --accent: #5aa9ff; --ok: #45d17a;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body {
    background: var(--bg); color: var(--text);
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", sans-serif;
    display: grid; grid-template-columns: 286px 1fr; overflow: hidden;
  }
  aside {
    background: var(--side); border-right: 1px solid var(--line);
    display: flex; flex-direction: column; min-height: 0;
  }
  .brand { padding: 16px 16px 10px; border-bottom: 1px solid var(--line); }
  .brand h1 { margin: 0; font-size: 15px; letter-spacing: .2px; }
  .brand p { margin: 3px 0 0; color: var(--dim); font-size: 12px; }
  .search { padding: 10px 12px; border-bottom: 1px solid var(--line); }
  .search input {
    width: 100%; padding: 7px 10px; border-radius: 7px; border: 1px solid var(--line);
    background: #0c0e13; color: var(--text); font-size: 13px; outline: none;
  }
  .search input:focus { border-color: var(--accent); }
  nav { overflow: auto; padding: 8px 8px 24px; flex: 1; min-height: 0; }
  .group-title {
    color: var(--dim); font-size: 11px; text-transform: none; letter-spacing: .4px;
    padding: 12px 8px 5px; position: sticky; top: 0; background: var(--side); z-index: 1;
  }
  .item {
    display: block; padding: 7px 9px; border-radius: 7px; text-decoration: none;
    color: var(--text); border: 1px solid transparent;
  }
  .item:hover { background: #1b2029; }
  .item.active { background: #1d2733; border-color: #2b3a4d; }
  .item .name { display: flex; align-items: center; gap: 6px; font-size: 13px; }
  .item .meta { display: block; color: var(--dim); font-size: 11px; font-variant-numeric: tabular-nums; }
  .item.off .name { color: var(--dim); }
  .badge {
    font-size: 10px; padding: 1px 5px; border-radius: 4px; color: #f0b46a;
    background: rgba(240, 180, 106, .12); border: 1px solid rgba(240, 180, 106, .3);
  }
  main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  header {
    display: flex; align-items: center; gap: 12px; padding: 9px 14px;
    border-bottom: 1px solid var(--line); background: var(--side);
  }
  .titles { min-width: 0; flex: 1; }
  .titles h2 { margin: 0; font-size: 14px; font-weight: 600; }
  .titles p { margin: 2px 0 0; color: var(--dim); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  header a.btn, header button {
    font: inherit; font-size: 12px; color: var(--text); text-decoration: none; cursor: pointer;
    background: #1b2029; border: 1px solid var(--line); border-radius: 7px; padding: 5px 10px;
  }
  header a.btn:hover, header button:hover { border-color: #33404f; }
  .stage { flex: 1; min-height: 0; position: relative; background: #000; overflow: hidden; }
  iframe { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; }
  .notice {
    position: absolute; inset: 0; display: none; place-content: center; padding: 40px;
    text-align: center; color: var(--dim); line-height: 1.9;
  }
  .notice.show { display: grid; }
  .notice strong { color: #f0b46a; display: block; margin-bottom: 6px; font-size: 15px; }
  .notice code { color: var(--text); background: #1b2029; padding: 1px 5px; border-radius: 4px; }
  footer { padding: 6px 14px; border-top: 1px solid var(--line); color: var(--dim); font-size: 11px; }
  @media (max-width: 760px) {
    body { grid-template-columns: 1fr; grid-template-rows: 45vh 1fr; }
    aside { border-right: 0; border-bottom: 1px solid var(--line); }
  }
</style>
</head>
<body>
<aside>
  <div class="brand">
    <h1>asaot3d · 浏览器里的 AS3</h1>
    <p>${built.length} 个 demo 已上屏，${skipped.length} 个仅原生 · ${totalMB} MB wasm</p>
  </div>
  <div class="search"><input id="q" type="search" placeholder="筛选 demo（名字 / 目录）" autocomplete="off"></div>
  <nav id="nav">${groups.map(groupBlock).join('')}</nav>
</aside>
<main>
  <header>
    <div class="titles"><h2 id="title">载入中…</h2><p id="blurb"></p></div>
    <button id="reload" title="重新载入当前 demo">重新载入</button>
    <a class="btn" id="open" href="#" target="_blank" rel="noopener">新窗口</a>
  </header>
  <div class="stage">
    <iframe id="frame" title="demo" allow="fullscreen"></iframe>
    <div class="notice" id="notice"></div>
  </div>
  <footer>构建于 ${esc(stamp)} · 键盘 ↑ ↓ 切换 · <span id="pos">–</span></footer>
</main>
<script>
var DEMOS = ${JSON.stringify(
  report.demos.map((d) => ({
    dir: d.dir,
    title: d.title,
    group: d.group,
    blurb: d.blurb,
    ok: d.status === 'ok',
    reason: d.reason || '',
  }))
)};
var byDir = {};
DEMOS.forEach(function (d, i) { byDir[d.dir] = d; d.index = i; });

var frame = document.getElementById('frame');
var notice = document.getElementById('notice');
var titleEl = document.getElementById('title');
var blurbEl = document.getElementById('blurb');
var openEl = document.getElementById('open');
var posEl = document.getElementById('pos');
var current = null;

function ordered() { return DEMOS.filter(function (d) { return visible(d); }); }

function visible(d) {
  var q = (document.getElementById('q').value || '').toLowerCase();
  if (!q) return true;
  return (d.title + ' ' + d.dir + ' ' + d.blurb).toLowerCase().indexOf(q) >= 0;
}

function show(dir, push) {
  var d = byDir[dir];
  if (!d) d = DEMOS.filter(function (x) { return x.ok; })[0];
  if (!d) return;
  if (current === d.dir) return;
  current = d.dir;
  document.querySelectorAll('.item').forEach(function (el) {
    el.classList.toggle('active', el.dataset.dir === d.dir);
  });
  titleEl.textContent = d.title;
  blurbEl.textContent = d.blurb;
  openEl.href = d.dir + '/index.html';
  var list = ordered();
  var at = list.indexOf(d);
  posEl.textContent = d.ok ? (at >= 0 ? (at + 1) + ' / ' + list.length : '') : '仅原生';
  if (d.ok) {
    notice.classList.remove('show');
    frame.style.display = 'block';
    frame.src = d.dir + '/index.html';
  } else {    // Not a dead link and not a broken page: say exactly why this one is missing.
    frame.removeAttribute('src');
    frame.style.display = 'none';
    notice.classList.add('show');
    notice.innerHTML = '<div><strong>这个 demo 只在原生后端上屏</strong>' +
      (d.reason ? d.reason : '本后端不支持该 demo 需要的通道能力') +
      '<br><br>它在 macOS / Windows 上以 Metal / D3D 运行；<code>--target wasm</code> 侧还没有对应的通道。</div>';
  }
  if (push && location.hash.slice(1) !== d.dir) location.hash = d.dir;
}

function step(delta) {
  var list = ordered();
  var at = list.findIndex(function (d) { return d.dir === current; });
  if (at < 0) at = 0;
  var next = list[Math.min(list.length - 1, Math.max(0, at + delta))];
  if (next) show(next.dir, true);
}

document.getElementById('nav').addEventListener('click', function (ev) {
  var a = ev.target.closest('.item');
  if (!a) return;
  ev.preventDefault();
  show(a.dataset.dir, true);
});
document.getElementById('reload').addEventListener('click', function () {
  if (current && byDir[current] && byDir[current].ok) {
    frame.src = byDir[current].dir + '/index.html?t=' + Date.now();
  }
});
document.getElementById('q').addEventListener('input', function () {
  var q = this.value.toLowerCase();
  document.querySelectorAll('.group').forEach(function (g) {
    var any = false;
    g.querySelectorAll('.item').forEach(function (el) {
      var d = byDir[el.dataset.dir];
      var hit = !q || (d.title + ' ' + d.dir + ' ' + d.blurb).toLowerCase().indexOf(q) >= 0;
      el.style.display = hit ? 'block' : 'none';
      if (hit) any = true;
    });
    g.style.display = any ? 'block' : 'none';
  });
});
window.addEventListener('hashchange', function () { show(location.hash.slice(1), false); });
window.addEventListener('keydown', function (ev) {
  if (ev.target.tagName === 'INPUT') return;
  if (ev.key === 'ArrowDown' || ev.key === 'j') { ev.preventDefault(); step(1); }
  if (ev.key === 'ArrowUp' || ev.key === 'k') { ev.preventDefault(); step(-1); }
});

// Several demos fix their canvas at the size the native screenshots were taken at
// (panel-m24 / scene-m20 are 1200x900), which is WIDER than the stage area of a
// 1440-wide window -- unscaled, the demo's own panel hangs off the right edge. So
// once a page loads, read its canvas size and scale the whole frame down to fit
// (same origin, so this is just a read). Scaling never goes above 1: enlarging a
// 640x480 demo would only smear it.
function fitFrame() {
  var doc = frame.contentDocument;
  var canvas = doc && doc.querySelector('canvas');
  var stageEl = frame.parentElement;
  if (!canvas || !stageEl) return;
  var w = canvas.width, h = canvas.height;
  if (!w || !h) return;
  var fw = stageEl.clientWidth, fh = stageEl.clientHeight;
  var k = Math.min(1, fw / w, fh / h);
  frame.style.width = w + 'px';
  frame.style.height = h + 'px';
  frame.style.transformOrigin = 'top left';
  frame.style.transform = 'scale(' + k + ')';
  frame.style.left = Math.max(0, (fw - w * k) / 2) + 'px';
  frame.style.top = Math.max(0, (fh - h * k) / 2) + 'px';
}
frame.addEventListener('load', function () {
  fitFrame();
  // One more beat: the app sizes its canvas during main(), i.e. after load.
  setTimeout(fitFrame, 700);
});
window.addEventListener('resize', fitFrame);

show(location.hash.slice(1) || (DEMOS.filter(function (d) { return d.ok; })[0] || {}).dir, false);
</script>
</body>
</html>
`;

fs.writeFileSync(path.join(OUT, 'index.html'), html);
console.log('gallery: ' + path.relative(ROOT, path.join(OUT, 'index.html')) + '  (' + built.length + ' playable, ' + skipped.length + ' native-only)');