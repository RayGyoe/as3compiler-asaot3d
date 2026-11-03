// Build every app under apps/ as a browser page (`--target wasm --package web`).
//
//   node tools/build-web.cjs                  # all demos -> site/<dir>/index.html
//   node tools/build-web.cjs --only ocean-m34,walk-m26
//   node tools/build-web.cjs --jobs 2         # emcc is RAM hungry; 2-4 is sane
//   node tools/build-web.cjs --clean          # wipe site/ and temp/web-app first
//
// WHY A STAGED COPY OF EACH APP AND NOT THE APP DIRECTORY ITSELF.
// `--air-app` packs the app directory into the page's virtual FS (that is how
// `app:/assets/...` finds files in a browser, which has no such directory). Packing
// is directory-granular, so building in place ships the whole 8 MB assets/ tree into
// every single .data — including the 6.9 MB of models that only two demos read. The
// staged copy holds the descriptor, src/ and only the asset files this demo actually
// names, so `site/` stays close to one wasm per demo instead of wasm + 8 MB each.
//
// The staged copy also keeps the repository clean: the generated .c, the
// `--air-app` manifest and the wasm objects land under temp/, never next to the
// sources (the same [no-src-litter] rule the compiler's own example harness holds).
//
// PRUNING IS DRIVEN BY THE SOURCES, THEN PROVEN BY RUNNING. A grep for `assets/...`
// string literals decides what to copy, which is a static approximation — so the
// verification pass in tools/verify-web.cjs reads the runtime's own stdout for
// ioError/load failures. A demo whose assets were pruned one file too far shows up
// there, not as a blank canvas nobody notices.
'use strict';
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const COMPILER = path.resolve(ROOT, '..', 'as3compiler', 'src', 'index.ts');
const CATALOG = path.join(__dirname, 'web-demos.json');
const STAGE_APPS = path.join(ROOT, 'temp', 'web-app');
const LOGS = path.join(ROOT, 'temp', 'web-build');
const FONT_SRC = path.resolve(ROOT, '..', 'as3compiler', 'examples', 'web', 'fonts', 'Arial.ttf');

const argv = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = argv.indexOf(name);
  return i < 0 ? dflt : argv[i + 1];
};
const jobs = Math.max(1, parseInt(argOf('--jobs', '3'), 10));
const outDir = path.resolve(ROOT, argOf('--out', 'site'));
const only = (argOf('--only', '') || '').split(',').map((s) => s.trim()).filter(Boolean);

const catalog = JSON.parse(fs.readFileSync(CATALOG, 'utf8'));
const demos = catalog.demos.filter((d) => only.length === 0 || only.includes(d.dir));

const say = (s) => process.stdout.write(s + '\n');
const mb = (n) => (n / 1048576).toFixed(2) + ' MB';

// EMSDK_HOME must be ABSOLUTE. emcc compares the SDK root it resolves against the
// one recorded in its cache and, when they differ by spelling rather than location
// (`../build-tools/emsdk` vs the resolved path), decides the *configuration changed*
// -- it then clears the shared cache and rewrites its sanity stamp. Concurrently that
// is fatal and silent: the four child processes take turns invalidating each other's
// cache, and emcc exits non-zero after the last warning with no error line at all
// (measured: 24/24 demos "FAIL" with a log that ends mid-warning).
if (process.env.EMSDK_HOME) process.env.EMSDK_HOME = path.resolve(ROOT, process.env.EMSDK_HOME);

if (argv.includes('--clean')) {
  for (const d of [outDir, STAGE_APPS]) fs.rmSync(d, { recursive: true, force: true });
}

// ------------------------------------------------------------------ descriptors

// One descriptor per demo named <Main>-app.xml, next to src/<Main>.as (the same
// derivation tools/build-demo.sh uses, and for the same reason: parsing XML buys
// nothing when the file name already carries the answer, and the .as check turns a
// rename into a clear error here rather than a confusing one inside the compiler).
function readApp(dir) {
  const abs = path.join(ROOT, 'apps', dir);
  if (!fs.existsSync(abs)) throw new Error('catalog names apps/' + dir + ', which does not exist');
  const descriptors = fs.readdirSync(abs).filter((f) => f.endsWith('-app.xml'));
  if (descriptors.length !== 1) {
    throw new Error('apps/' + dir + ': expected exactly one *-app.xml, found ' + descriptors.length);
  }
  const main = descriptors[0].replace(/-app\.xml$/, '');
  const mainSrc = path.join(abs, 'src', main + '.as');
  if (!fs.existsSync(mainSrc)) throw new Error('apps/' + dir + ': descriptor says ' + main + ' but src/' + main + '.as is missing');
  const classPaths = [];
  const cpFile = path.join(abs, 'class-paths');
  if (fs.existsSync(cpFile)) {
    for (const raw of fs.readFileSync(cpFile, 'utf8').split('\n')) {
      const line = raw.replace(/#.*$/, '').trim();
      if (line) classPaths.push(line);
    }
  }
  return { abs, descriptor: descriptors[0], main, classPaths, ...onePerLine(abs) };
}

// `<demo>/features` and `<demo>/extra-roots`: the same two files tools/build-demo.sh
// reads for the native build, one value per line, `#` starts a comment. They are read
// here too, and that is what lets a demo which needs an enhancement build on BOTH
// backends from one source of truth -- a hard-coded list in this script would drift
// the moment a demo turns a feature on.
//
// `extra-roots` matters specifically for `--air-app`: the native renderer is reached
// only through a getDefinitionByName STRING (RendererFactory probes for it), so the
// reachability closure cannot see an edge and would drop the source file. That is the
// same reason the native build passes it (docs/zh-cn/native-shader.md §6.7).
function onePerLine(abs) {
  const list = (name) => {
    const file = path.join(abs, name);
    if (!fs.existsSync(file)) return [];
    return fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .map((l) => l.replace(/#.*$/, '').trim())
      .filter(Boolean);
  };
  return { features: list('features'), extraRoots: list('extra-roots') };
}

// ---------------------------------------------------------------------- assets
//
// Which asset files this demo reads. Everything under src/ plus the extra class-path
// roots it links (a shared library may name assets too), matched on the literal
// `assets/...` spellings. A reference to a directory (`assets/ocean/`) or to the
// whole tree (`assets/`) copies that subtree, which is the honest reading of the
// source: the demo walks it at runtime.
function referencedAssets(demo) {
  const roots = [path.join(demo.abs, 'src'), ...demo.classPaths.map((p) => path.resolve(ROOT, p))];
  const refs = new Set();
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.as')) {
        // Comments are prose, not data: several demos explain themselves with
        // sentences like "copied into assets/ so the port runs on the same bytes",
        // and a `//`-stripped scan is what keeps that from being read as "this demo
        // walks the whole asset tree" (measured: walk-m26 packed all 8 MB of models
        // into its .data because of one such comment).
        const text = stripComments(fs.readFileSync(p, 'utf8'));
        for (const m of text.matchAll(/assets\/[A-Za-z0-9_./-]*/g)) refs.add(m[0]);
      }
    }
  };
  for (const r of roots) walk(r);
  // `assets/` alone (or a ref truncated at a quote) means "the whole tree".
  return [...refs].filter((r) => !r.endsWith('/...')).sort();
}

// Drop `//` line comments and `/* */` blocks. Deliberately naive about string
// literals: over-stripping can only LOSE a reference (this scan is an
// approximation, and the runtime check is the proof), while treating a comment as
// data costs megabytes in every published page.
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/.*$/gm, '$1');
}

// Copy one reference into the staged app dir, preserving the relative layout.
// Parent-directory rule: a file format that names its siblings (glTF's .bin +
// textures, OBJ's .mtl) is copied as a directory, because copying only the .gltf
// leaves a parse that fails at runtime with a look-alike "asset missing" symptom.
const DIR_FORMATS = new Set(['.gltf', '.obj', '.mtl', '.fbx']);
function copyAsset(ref, srcRoot, dstRoot) {
  const rel = ref.replace(/^assets\//, '');
  const src = path.join(srcRoot, 'assets', rel);
  if (!fs.existsSync(src)) return { ref, copied: false };
  const stat = fs.statSync(src);
  const ext = path.extname(rel).toLowerCase();
  const wantsDir = stat.isDirectory() || rel === '' || DIR_FORMATS.has(ext);
  const from = wantsDir ? (stat.isDirectory() ? src : path.dirname(src)) : src;
  const to = path.join(dstRoot, 'assets', wantsDir ? (stat.isDirectory() ? rel : path.dirname(rel)) : rel);
  fs.mkdirSync(path.dirname(to), { recursive: true });
  if (fs.existsSync(from) && fs.statSync(from).isDirectory()) {
    fs.cpSync(from, to, { recursive: true });
  } else {
    fs.copyFileSync(from, to);
  }
  return { ref, copied: true };
}

// --------------------------------------------------------------------- staging

function stageApp(dir) {
  const demo = readApp(dir);
  const stage = path.join(STAGE_APPS, dir);
  fs.rmSync(stage, { recursive: true, force: true });
  fs.mkdirSync(stage, { recursive: true });
  fs.copyFileSync(path.join(demo.abs, demo.descriptor), path.join(stage, demo.descriptor));
  fs.cpSync(path.join(demo.abs, 'src'), path.join(stage, 'src'), { recursive: true });
  const refs = referencedAssets(demo);
  const copied = [];
  for (const ref of refs) {
    const r = copyAsset(ref, demo.abs, stage);
    if (r.copied) copied.push(ref);
  }
  return { demo, stage, refs, copied };
}

// ----------------------------------------------------------------------- build

function buildOne(dir, meta) {
  const started = Date.now();
  const result = { dir, title: meta.title, group: meta.group, blurb: meta.blurb, status: 'failed', bytes: 0, ms: 0 };
  if (meta.nativeOnly) {
    result.status = 'native-only';
    result.reason = meta.nativeOnly;
    result.ms = 0;
    return result;
  }
  fs.mkdirSync(LOGS, { recursive: true });
  const logPath = path.join(LOGS, dir + '.log');
  let staged;
  try {
    staged = stageApp(dir);
  } catch (e) {
    result.reason = String(e.message || e);
    fs.writeFileSync(logPath, result.reason + '\n');
    return result;
  }
  result.assets = staged.copied.length;
  const outBase = path.join(outDir, dir, 'index');
  fs.mkdirSync(path.dirname(outBase), { recursive: true });
  const args = [
    COMPILER,
    '--air-app', path.relative(ROOT, path.join(staged.stage, staged.demo.descriptor)),
    '--main-class', staged.demo.main,
    '--as-class-path', 'seam',
    '--as-class-path', 'kit',
    ...staged.demo.classPaths.flatMap((p) => ['--as-class-path', p]),
    // Per-demo enhancements, from the demo's own `features` file. `native-shader` is a
    // real wasm feature now: WebGL2 compiles the author's GLSL ES 3.00 as written and
    // the reflection comes from the driver, so the web arm links no cross-compiler at
    // all (as3compiler docs/zh-cn/native-shader.md §5).
    '--features', staged.demo.features.length ? staged.demo.features.join(',') : 'none',
    ...(staged.demo.extraRoots.length ? ['--extra-roots', staged.demo.extraRoots.join(',')] : []),
    '--target', 'wasm',
    '--package', 'web',
    '-o', path.relative(ROOT, outBase),
  ];
  const t = Date.now();
  try {
    execFileSync(process.execPath, args, {
      cwd: ROOT,
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 64 * 1024 * 1024,
      env: process.env,
    });
    result.ms = Date.now() - t;
    result.status = 'ok';
  } catch (e) {
    result.ms = Date.now() - t;
    const out = String((e.stdout || '') + (e.stderr || ''));
    fs.writeFileSync(logPath, out);
    // Keep the LAST lines: emcc failures announce themselves at the end, after
    // thousands of warnings from the generated C.
    result.reason = out.trim().split('\n').slice(-6).join('\n');
    return result;
  }
  // The published page must not carry the generated C (5 MB per demo, and it is a
  // build input, not a visitor's download).
  for (const ext of ['.c', '.o']) {
    const p = outBase + ext;
    if (fs.existsSync(p)) fs.rmSync(p);
  }
  // Fonts: the page's FONT_URLS list is the one thing this tool edits in generated
  // output, and it has to. A browser has no system fonts, so every TextField (the
  // stats HUD in every demo, the asaotui panel labels in M24/M34) renders blank
  // unless bytes are injected — and the compiler's own font discovery only looks
  // INSIDE the app directory, where a font would be excluded from the FS image by
  // definition (`preload-excludes`) and, for a demo with no other assets, leaves an
  // empty preload root that fails the link outright (measured). So the font ships
  // once at the site root and every page points at it relatively.
  const htmlPath = path.join(path.dirname(outBase), 'index.html');
  rewriteFontUrls(htmlPath, 'FONT_URLS', ['../' + catalog.font]);
  polishPage(htmlPath, meta);
  const files = fs.readdirSync(path.dirname(outBase));
  result.bytes = files.reduce((n, f) => n + fs.statSync(path.join(path.dirname(outBase), f)).size, 0);
  result.files = files.sort();
  result.wallMs = Date.now() - started;
  return result;
}

// Two things every generated page needs before it can be published, both of them
// consequences of the payload size rather than of the program:
//   * the shell's <title> is literally "index" (it is written by the packager, which
//     knows nothing about the demo), so a tab, a bookmark and the gallery's
//     "新窗口" button would all be indistinguishable;
//   * a demo's wasm is ~8 MB, ~3 MB compressed (a Skia floor, not this demo's code),
//     so on a slow link the page sits black and silent for seconds. The overlay says
//     what is loading, and turns into the first page-level error if one arrives —
//     a spinner that lies is worse than none.
function polishPage(htmlPath, meta) {
  let html = fs.readFileSync(htmlPath, 'utf8');
  const title = meta.title + ' · asaot3d';
  if (!html.includes('<title>index</title>')) throw new Error('generated page title changed shape: ' + htmlPath);
  html = html.replace('<title>index</title>', '<title>' + escapeHtml(title) + '</title>');

  const overlay =
    '<div id="asc-loading"><b>' + escapeHtml(meta.title) + '</b><span id="asc-loading-msg">载入中…（wasm 约 3 MB）</span></div>';
  if (!html.includes('<canvas id="canvas"')) throw new Error('generated page has no canvas: ' + htmlPath);
  html = html.replace('<canvas id="canvas"', overlay + '\n<canvas id="canvas"');

  const style =
    '<style>#asc-loading{position:fixed;inset:0;display:flex;flex-direction:column;gap:10px;' +
    'align-items:center;justify-content:center;font:15px/1.5 -apple-system,"Helvetica Neue",sans-serif;' +
    'color:#c9d1d9;background:#0f1115;z-index:9}#asc-loading b{font-size:20px;color:#e6edf3}' +
    '</style>';
  html = html.replace('</head>', style + '\n</head>');

  const hook =
    '<script>\n' +
    '(function(){\n' +
    '  var el = document.getElementById("asc-loading"), msg = document.getElementById("asc-loading-msg");\n' +
    '  var hide = function(){ if (el) el.style.display = "none"; };\n' +
    // Module exists by now (index.js runs synchronously) but the runtime does not:
    // emcc reads Module.onRuntimeInitialized at fire time, so wrapping works.
    '  if (window.Module && Module.onRuntimeInitialized) {\n' +
    '    var prev = Module.onRuntimeInitialized;\n' +
    '    Module.onRuntimeInitialized = function(){ hide(); return prev.apply(this, arguments); };\n' +
    '  } else { hide(); }\n' +
    // A failed load never reaches the runtime, so report the first captured error
    // instead of spinning for ever.
    '  setInterval(function(){\n' +
    '    if (window.__ascErrors && window.__ascErrors.length) { msg.textContent = window.__ascErrors[0]; msg.style.color = "#f85149"; }\n' +
    '  }, 1000);\n' +
    '})();\n' +
    '</script>\n</body>';
  if (!html.includes('</body>')) throw new Error('generated page has no </body>: ' + htmlPath);
  html = html.replace('</body>', hook);
  fs.writeFileSync(htmlPath, html);
}

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Replace `var FONT_URLS = [...];` in a generated page. Asserting the pattern exists
// keeps this from silently doing nothing after an emitter change (the same trap the
// asaotui publisher documents for its staged font).
function rewriteFontUrls(htmlPath, varName, urls) {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const re = new RegExp('var ' + varName + ' = \\[[^\\]]*\\];');
  if (!re.test(html)) throw new Error('generated page has no `var ' + varName + ' = [...];`: ' + htmlPath);
  fs.writeFileSync(htmlPath, html.replace(re, 'var ' + varName + ' = ' + JSON.stringify(urls) + ';'));
}

// ------------------------------------------------------------------------ pool

async function run() {
  if (!fs.existsSync(COMPILER)) {
    throw new Error('as-aot front end not found at ' + COMPILER + ' (asaot3d expects a sibling checkout)');
  }
  if (!process.env.EMSDK_HOME) {
    say('build-web: EMSDK_HOME is not set — a `web` build needs the Emscripten SDK (bin/emcc).');
  }
  fs.mkdirSync(outDir, { recursive: true });

  const results = [];
  let next = 0;
  const worker = async () => {
    while (next < demos.length) {
      const meta = demos[next++];
      const r = await new Promise((resolve) => {
        // execFileSync blocks the event loop, so each demo runs in a child of its own:
        // that is what makes --jobs real (emcc spends most of its time in a
        // subprocess, and 3 concurrent C++ compiles are already CPU-bound here).
        const child = spawn(
          process.execPath,
          [
            __filename,
            '--one', meta.dir,
            '--out', path.relative(ROOT, outDir),
            ...(only.length ? ['--only', only.join(',')] : []),
          ],
          { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] }
        );
        let buf = '';
        child.stdout.on('data', (d) => (buf += d));
        child.stderr.on('data', (d) => (buf += d));
        child.on('close', () => {
          const line = buf.split('\n').reverse().find((l) => l.startsWith('{'));
          try {
            resolve(JSON.parse(line));
          } catch {
            resolve({ dir: meta.dir, title: meta.title, status: 'failed', reason: buf.slice(-500), ms: 0, bytes: 0 });
          }
        });
      });
      results.push(r);
      say(
        (r.status === 'ok' ? '  ok    ' : r.status === 'native-only' ? '  skip  ' : '  FAIL  ') +
          r.dir.padEnd(16) +
          (r.status === 'ok' ? mb(r.bytes).padStart(9) + '  ' + (r.ms / 1000).toFixed(1) + ' s' : r.reason.split('\n')[0])
      );
    }
  };
  await Promise.all(Array.from({ length: Math.min(jobs, demos.length) }, worker));

  // Report in catalog order, not completion order: the gallery lists what the
  // catalog says, and a stable report makes two builds diffable.
  const order = new Map(demos.map((d, i) => [d.dir, i]));
  results.sort((a, b) => order.get(a.dir) - order.get(b.dir));
  // A `--only` run rebuilds a few demos; it must not shrink the site. The report is
  // what the gallery reads, so entries it did not touch are carried over from the
  // previous build -- otherwise `--only ocean-m34` leaves a one-item gallery.
  let reported = results;
  if (only.length) {
    const prevPath = path.join(outDir, 'demos.json');
    const prev = fs.existsSync(prevPath) ? JSON.parse(fs.readFileSync(prevPath, 'utf8')) : { demos: [] };
    const fresh = new Map(results.map((r) => [r.dir, r]));
    const keep = new Map((prev.demos || []).map((d) => [d.dir, d]));
    reported = catalog.demos.map((d) => fresh.get(d.dir) || keep.get(d.dir)).filter(Boolean);
  }
  const report = {
    generated: new Date().toISOString(),
    font: catalog.font,
    groups: catalog.groups,
    demos: reported,
  };
  fs.writeFileSync(path.join(outDir, 'demos.json'), JSON.stringify(report, null, 2) + '\n');

  const ok = results.filter((r) => r.status === 'ok');
  const total = ok.reduce((n, r) => n + r.bytes, 0);
  say('');
  say('built ' + ok.length + '/' + results.length + ' demos, ' + mb(total) + ' in ' + outDir);
  // The gallery is not an extra: a directory of pages with no index is not a site,
  // and the index must be regenerated from THIS report or it lists a stale catalog.
  if (reported.some((r) => r.status === 'ok')) {
    execFileSync(process.execPath, [path.join(__dirname, 'gen-gallery.cjs'), '--out', path.relative(ROOT, outDir)], {
      cwd: ROOT,
      stdio: ['ignore', 'inherit', 'inherit'],
    });
  }
  const failed = results.filter((r) => r.status === 'failed');
  if (failed.length) {
    say('failed: ' + failed.map((r) => r.dir).join(', ') + ' (logs: temp/web-build/<dir>.log)');
    process.exitCode = 1;
  }
}

// --one runs a single demo and prints its result as one JSON line: the pool above
// spawns this so a demo's build cannot block the others' progress reporting.
const oneIdx = argv.indexOf('--one');
if (oneIdx >= 0) {
  const dir = argv[oneIdx + 1];
  const meta = catalog.demos.find((d) => d.dir === dir);
  if (!meta) {
    say('{"status":"failed","reason":"not in catalog","dir":"' + dir + '"}');
    process.exit(1);
  }
  const r = buildOne(dir, meta);
  say(JSON.stringify(r));
  process.exit(r.status === 'failed' ? 1 : 0);
} else {
  prepareSiteRoot();
  run().catch((e) => {
    console.error('build-web: ' + (e && e.message ? e.message : e));
    process.exit(1);
  });
}

// The font ships once at the site root (see rewriteFontUrls). A missing font is
// invisible on the canvas -- text simply renders blank -- so it is checked here
// rather than left for a human to notice on the published page.
// `[Embed(source='../../../assets/...')]` resolves against the DECLARING FILE's own
// directory, so staging has to keep that depth meaningful. An app lives at
// apps/<demo>/src in the repo and at temp/web-app/<demo>/src here -- both three levels
// below their root -- so `../../../` lands in temp/ instead of the repo root. One
// symlink named after the only directory such embeds name (`assets/`) restores the
// repo's meaning; copying the tree instead would add ~8 MB to every staged demo, and
// rewriting the paths would make the staged source differ from the shipped one.
// (The runtime `app:/assets/...` contract is separate and handled by copyAsset.)
function linkStagedAssets() {
  const link = path.join(STAGE_APPS, '..', 'assets');
  const target = path.join(ROOT, 'assets');
  if (!fs.existsSync(target)) return;
  let st = null;
  try { st = fs.lstatSync(link); } catch { /* absent */ }
  if (st) {
    if (!st.isSymbolicLink()) return;   // a real dir: somebody staged it on purpose
    fs.unlinkSync(link);
  }
  fs.symlinkSync(target, link, 'dir');
}

function prepareSiteRoot() {
  linkStagedAssets();
  if (!fs.existsSync(FONT_SRC)) {
    console.error(
      'build-web: font not found at ' + FONT_SRC + '\n' +
        '           every page needs one TTF injected into the wasm sandbox (docs/web-gallery.md)'
    );
    process.exit(1);
  }
  fs.mkdirSync(path.join(outDir, 'fonts'), { recursive: true });
  fs.copyFileSync(FONT_SRC, path.join(outDir, catalog.font));
}