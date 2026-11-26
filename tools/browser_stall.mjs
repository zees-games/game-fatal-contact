// Frames of the FC web client in a real browser, split at the loading cover (needs ?cl_perf, which
// makes the client set window.gsWeb.publishedAt.arena_gate_open when the gate opens).
//
//   node tools/browser_stall.mjs [pageUrl] [--budget-ms N] [--runs N] [--phases] [--steady-s N]
//
// Connects over CDP to a Chrome on a GPU box (`gpu.sh cdp-run --serve 8099 -- node ...` sets
// GPU_CDP_URL; or CDP=..., default 127.0.0.1:9222); SwiftShader frame times say nothing. Per run it
// prints fps and the worst frame for the cover, the first 2 s of play and the rest, the content
// download's end (the page's .pck/.gs-pack responses), the cover drop, the time to the first smooth
// second (no frame of 50 ms or more for 1 s) and the worst frames after the drop, each named by the
// client's last load mark before it (arena_load / arena_after_open, published by FcLoadTimeline).
// --phases also prints the load marks on the page clock, after the boot marks (each .wasm/.pck/.js
// fetch with its size over the wire, wasm compile, the engine's first prints). Several runs end in a median line. Exits 1
// when a run's first 2 s of play hold a frame over --budget-ms (default 0, off). How to run it:
// docs/client.md.
//
// --steady-s N (default 0, off) is the frame bench: it plays N more seconds after the first 2 s and
// prints one BROWSER_BENCH line per run with the frame-time p50/p95/p99 over them, plus which engine
// the page ran (embed.html's __TMC_ENGINE__ threads|single, __TMC_NATIVES__ native|script) and
// whether it was cross-origin isolated. Against a server with 63 bots that is the 64-player number
// (docs/client.md, "A 64-player frame in the browser").
//
// --gl-count (needs --steady-s) wraps every WebGL2 call and prints one GL_COUNT line per run: GL calls and draw
// calls per frame over the steady window and the ten busiest entry points (getParameter is the stall to watch).
// --cpuprofile (needs --steady-s) records a CDP CPU profile over the same window and prints CPU_PROFILE: the top
// self-time functions. Wasm frames show as wasm-function[N] because the web export strips names; map N with
// wasm-objdump/`wasm-tools print` on a build that keeps its name section (the dlink threads engine's debug build).
//
// --first-use [S] (default 90 s) plays after the drop, pressing fire (left button) for 300 ms every 2 s so the client
// shoots, dies to the bots, sees the kill view and respawns, until FcLoadTimeline.first_use has published all of
// FIRST_USE or S seconds pass. Prints one FIRST_USE line per run: time to in-game (the drop) and, for each first
// moment, the worst browser frame from 50 ms before it to 700 ms after, with the client's own report (worst engine
// frame, pipelines compiled). Use solo mode with bots: `embed.html?solo=gamemann/game-fatal-contact&bot_quota=8&cl_perf=5`.
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/.local/share/mcp/playwright-mcp/node_modules/playwright-core/index.js')).default;
const args = process.argv.slice(2);
const num = (flag, dflt) => args.includes(flag) ? Number(args[args.indexOf(flag) + 1]) : dflt;
const budget = num('--budget-ms', 0);
const runs = num('--runs', 1);
const phases = args.includes('--phases');
const steadyS = num('--steady-s', 0);
const glCount = args.includes('--gl-count');
const cpuProf = args.includes('--cpuprofile');
const firstUse = args.includes('--first-use');
const firstUseS = firstUse && /^\d+$/.test(args[args.indexOf('--first-use') + 1] ?? '') ? Number(args[args.indexOf('--first-use') + 1]) : 90;
const FIRST_USE = ['shot', 'remote_shot', 'death', 'killview', 'respawn'];
if (!(steadyS >= 0)) { console.error('--steady-s needs seconds (0 is off)'); process.exit(2); }
const pct = (d, q) => +d[Math.min(d.length - 1, Math.floor(q * d.length))].toFixed(2);
const url = args.find(a => a.startsWith('http')) ?? 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6174&cl_perf=5';
const SMOOTH_MS = 50;
const browser = await pw.chromium.connectOverCDP(process.env.CDP ?? process.env.GPU_CDP_URL ?? 'http://127.0.0.1:9222');
const context = browser.contexts()[0] ?? await browser.newContext();
const stat = (a) => { if (!a.length) return null; const d = a.map(x => x[1]).sort((x, y) => x - y); const sum = a.reduce((s, x) => s + x[1], 0); return { n: a.length, fps: +(a.length / (sum / 1000)).toFixed(1), median: +d[d.length >> 1].toFixed(1), worst: +d[d.length - 1].toFixed(0) }; };
const median = (a) => { const s = a.filter(x => x != null).sort((x, y) => x - y); return s.length ? +s[s.length >> 1].toFixed(0) : null; };

// Load marks on the page clock: a published report's engine stamps shifted by its publish time.
function pageMarks(report, at) {
  if (!report || at == null) return [];
  const r = JSON.parse(report);
  return r.marks.map(([ms, frame, label]) => [at - (r.now_ms - ms), frame, label]);
}

async function run(i) {
  const page = await context.newPage();
  const errors = new Map(); const raw = [];
  page.on('console', (m) => { if (m.type() !== 'error' && m.type() !== 'warning') return; if (raw.length < 16 && /ERROR|Error|at: /.test(m.text()) && !raw.includes(m.text().slice(0, 240))) raw.push(m.text().slice(0, 240)); const k = m.text().replace(/uid:\/\/\w+/g, 'uid://*').replace(/res:\/\/\S+/g, 'res://*').slice(0, 140); errors.set(k, (errors.get(k) ?? 0) + 1); });
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.addInitScript(() => {
    window.__frames = []; let last = performance.now();
    const tick = (t) => { window.__frames.push([t, t - last]); last = t; requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    // Boot marks before the engine's own load marks exist: wasm compile and the first engine prints.
    window.__boot = []; const mark = (l) => window.__boot.push([performance.now(), l]);
    for (const f of ['instantiate', 'instantiateStreaming', 'compile', 'compileStreaming']) {
      const orig = WebAssembly[f]; if (!orig) continue;
      WebAssembly[f] = function (...a) { mark(`wasm ${f} begins`); const p = orig.apply(this, a); p.then(() => mark(`wasm ${f} done`), () => {}); return p; };
    }
    if (glCount) {
      window.__gl = { on: false, n: {} };
      for (const C of [window.WebGL2RenderingContext, window.WebGLRenderingContext]) if (C) for (const k of Object.getOwnPropertyNames(C.prototype)) {
        const d = Object.getOwnPropertyDescriptor(C.prototype, k); if (!d || typeof d.value !== 'function') continue;
        const orig = d.value; C.prototype[k] = function (...a) { if (window.__gl.on) window.__gl.n[k] = (window.__gl.n[k] ?? 0) + 1; return orig.apply(this, a); };
      }
    }
    let printed = 0;
    for (const f of ['log', 'info']) { const orig = console[f]; console[f] = function (...a) { if (printed < 4) { printed++; mark(`console: ${String(a[0]).slice(0, 80)}`); } return orig.apply(this, a); }; }
  });
  await page.goto(url, { waitUntil: 'load' });
  let open = null;
  for (let s = 0; s < 180 && open === null; s++) { await page.waitForTimeout(1000); open = await page.evaluate(() => window.gsWeb?.publishedAt?.arena_gate_open ?? null); }
  for (let s = 0; s < 12; s++) { await page.waitForTimeout(1000); if (await page.evaluate(() => window.gsWeb?.publishedAt?.arena_after_open != null)) break; }
  await page.waitForTimeout(1000);
  if (open !== null && firstUse) {
    const box = await page.locator('canvas').first().boundingBox();
    if (box) await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const until = Date.now() + firstUseS * 1000;
    while (Date.now() < until) {
      await page.mouse.down(); await page.waitForTimeout(300); await page.mouse.up();
      if (await page.evaluate((names) => names.every(n => window.gsWeb?.published?.[`fc_first_${n}_frames`] != null), FIRST_USE)) break;
      await page.waitForTimeout(1700);
    }
    await page.waitForTimeout(1000);
  }
  let cdp = null, frames0 = 0;
  if (open !== null && steadyS > 0 && (glCount || cpuProf)) {
    frames0 = await page.evaluate(() => { if (window.__gl) { window.__gl.n = {}; window.__gl.on = true; } return window.__frames.length; });
    if (cpuProf) { cdp = await context.newCDPSession(page); await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 1000 }); await cdp.send('Profiler.start'); }
  }
  if (open !== null && steadyS > 0) await page.waitForTimeout(Math.max(0, open + 2000 + steadyS * 1000 - await page.evaluate(() => performance.now())));
  let prof = null;
  if (cdp) prof = (await cdp.send('Profiler.stop')).profile;
  const gln = glCount ? await page.evaluate(() => { window.__gl.on = false; return { n: window.__gl.n, frames: window.__frames.length }; }) : null;
  const r = await page.evaluate(() => {
    const gl = document.createElement('canvas').getContext('webgl2');
    const packs = performance.getEntriesByType('resource').filter(e => /\.(pck|gs-pack|wasm)(\?|$)/.test(e.name));
    const w = window.gsWeb ?? { published: {}, publishedAt: {} };
    const MB = (b) => (b / 1048576).toFixed(1);
    const files = performance.getEntriesByType('resource').filter(e => /\.(pck|gs-pack|wasm|js)(\?|$)/.test(e.name))
      .flatMap(e => [[e.startTime, `fetch ${e.name.split('/').pop().split('?')[0]} begins`],
        [e.responseEnd, `fetch ${e.name.split('/').pop().split('?')[0]} done ${MB(e.decodedBodySize)} MB, ${MB(e.transferSize)} MB over the wire, ${(e.responseEnd - e.startTime).toFixed(0)} ms`]]);
    return { frames: window.__frames, gpu: gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL),
      download: packs.length ? Math.max(...packs.map(e => e.responseEnd)) : null,
      engine: window.__TMC_ENGINE__ ?? null, natives: window.__TMC_NATIVES__ ?? null, isolated: self.crossOriginIsolated === true,
      boot: [...performance.getEntriesByType('navigation').flatMap(n => [[n.requestStart, 'page request'], [n.responseEnd, 'page received'], [n.domContentLoadedEventEnd, 'page parsed']]), ...files, ...(window.__boot ?? [])], first: Object.fromEntries(Object.keys(w.publishedAt ?? {}).filter(k => k.startsWith('fc_first_')).map(k => [k, [w.publishedAt[k], w.published[k]]])), load: w.published.arena_load, loadAt: w.publishedAt.arena_load, after: w.published.arena_after_open, afterAt: w.publishedAt.arena_after_open };
  });
  await page.close();
  if (gln) {
    const fr = Math.max(1, gln.frames - frames0), tot = Object.values(gln.n).reduce((a, b) => a + b, 0);
    const draws = Object.entries(gln.n).filter(([k]) => /^draw/.test(k)).reduce((a, [, v]) => a + v, 0);
    const top = Object.entries(gln.n).sort((a, b) => b[1] - a[1]).slice(0, 10).map(([k, v]) => `${k}=${(v / fr).toFixed(1)}`);
    console.log('GL_COUNT', JSON.stringify({ run: i + 1, frames: fr, calls_per_frame: +(tot / fr).toFixed(0), draws_per_frame: +(draws / fr).toFixed(0), getParameter_per_frame: +((gln.n.getParameter ?? 0) / fr).toFixed(1), top }));
  }
  if (prof) {
    const self = new Map(), byId = new Map(prof.nodes.map(n => [n.id, n]));
    const dt = prof.timeDeltas; let total = 0;
    prof.samples.forEach((id, k) => { const cf = byId.get(id).callFrame; const key = `${cf.functionName || '(anon)'} ${cf.url.split('/').pop()}:${cf.lineNumber}`; self.set(key, (self.get(key) ?? 0) + (dt[k] ?? 0)); total += dt[k] ?? 0; });
    const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, v]) => `${(100 * v / Math.max(1, total)).toFixed(1)}% ${k}`);
    console.log('CPU_PROFILE', JSON.stringify({ run: i + 1, total_ms: +(total / 1000).toFixed(0), top }));
  }
  if (i === 0) console.log('gpu', r.gpu, 'url', url);
  if (open === null) { console.log(`run ${i + 1} FAIL the cover never dropped`); return null; }
  const marks = [...r.boot.map(([t, label]) => [t, 0, label]), ...pageMarks(r.load, r.loadAt), ...pageMarks(r.after, r.afterAt)].sort((a, b) => a[0] - b[0]);
  const nameAt = (t) => { let m = null; for (const x of marks) { if (x[0] <= t) m = x; else break; } return m ? m[2] : '?'; };
  const after = r.frames.filter(f => f[0] > open);
  let smooth = null;
  for (let k = 0; k < after.length && smooth === null; k++) {
    const start = after[k][0];
    if (after[k][1] >= SMOOTH_MS) continue;
    let ok = true, end = start;
    for (let j = k + 1; j < after.length && after[j][0] <= start + 1000; j++) { end = after[j][0]; if (after[j][1] >= SMOOTH_MS) { ok = false; break; } }
    if (ok && end >= start + 900) smooth = start;
  }
  const play = stat(r.frames.filter(f => f[0] > open && f[0] <= open + 2000));
  const worst = [...after].sort((a, b) => b[1] - a[1]).slice(0, 5);
  const out = { run: i + 1, download_ms: r.download && +r.download.toFixed(0), open_ms: +open.toFixed(0),
    open_after_download_ms: r.download && +(open - r.download).toFixed(0), first_smooth_after_open_ms: smooth && +(smooth - open).toFixed(0),
    first_smooth_ms: smooth && +smooth.toFixed(0), play2s: play, cover: stat(r.frames.filter(f => f[0] <= open)), after: stat(r.frames.filter(f => f[0] > open + 2000)) };
  console.log(JSON.stringify(out));
  if (steadyS > 0) {
    const d = r.frames.filter(f => f[0] > open + 2000 && f[0] <= open + 2000 + steadyS * 1000).map(f => f[1]).sort((x, y) => x - y);
    out.bench = d.length ? { frames: d.length, p50_ms: pct(d, 0.5), p95_ms: pct(d, 0.95), p99_ms: pct(d, 0.99), worst_ms: +d[d.length - 1].toFixed(1),
      fps: +(d.length / (d.reduce((s, x) => s + x, 0) / 1000)).toFixed(1), engine: r.engine, natives: r.natives, isolated: r.isolated } : null;
    console.log('BROWSER_BENCH', JSON.stringify({ run: i + 1, seconds: steadyS, ...(out.bench ?? { frames: 0 }) }));
  }
  if (firstUse) {
    const fu = { run: i + 1, engine: r.engine, isolated: r.isolated, in_game_ms: out.open_ms, download_ms: out.download_ms };
    for (const n of FIRST_USE) {
      const at = r.first[`fc_first_${n}`]?.[0]; const rep = r.first[`fc_first_${n}_frames`]?.[1];
      if (at == null) { fu[n] = null; continue; }
      const win = r.frames.filter(f => f[0] >= at - 50 && f[0] <= at + 700).map(f => f[1]);
      const own = rep ? JSON.parse(rep) : {};
      fu[n] = { at_ms: +(at - open).toFixed(0), worst_ms: win.length ? +Math.max(...win).toFixed(0) : null, engine_worst_ms: own.worst_frame_ms ?? null, pipelines: own.pipelines ?? null, worst_frame: own.worst_frame ?? null };
    }
    out.firstUse = fu;
    console.log('FIRST_USE', JSON.stringify(fu));
  }
  const errs = [...errors].sort((a, b) => b[1] - a[1]);
  console.log(`  console errors/warnings: ${errs.reduce((s, e) => s + e[1], 0)}`, errs.slice(0, 4).map(([k, n]) => `${n}x ${k}`).join(' | '));
  if (phases) for (const t of raw) console.log('    err:', t);
  console.log('  worst after open:', worst.map(f => `${f[1].toFixed(0)}ms@+${(f[0] - open).toFixed(0)} [${nameAt(f[0] - f[1])}]`).join('; '));
  if (phases) for (let k = 0; k < marks.length; k++) {
    const gap = k ? marks[k][0] - marks[k - 1][0] : 0;
    console.log(`  ${marks[k][0].toFixed(0).padStart(6)} (+${gap.toFixed(0).padStart(4)}, f${marks[k][1]}) ${marks[k][2]}`);
  }
  return out;
}

const all = [];
for (let i = 0; i < runs; i++) all.push(await run(i));
const ok = all.filter(Boolean);
if (runs > 1 && ok.length) console.log('median', JSON.stringify({ runs: ok.length, open_after_download_ms: median(ok.map(o => o.open_after_download_ms)),
  first_smooth_after_open_ms: median(ok.map(o => o.first_smooth_after_open_ms)), play2s_worst: median(ok.map(o => o.play2s?.worst)),
  play2s_fps: median(ok.map(o => o.play2s?.fps)), cover_worst: median(ok.map(o => o.cover?.worst)),
  ...(firstUse ? Object.fromEntries(FIRST_USE.map(n => [`first_${n}_worst_ms`, median(ok.map(o => o.firstUse?.[n]?.worst_ms))])) : {}),
  ...(steadyS > 0 ? { bench_p50_ms: median(ok.map(o => o.bench?.p50_ms)), bench_p95_ms: median(ok.map(o => o.bench?.p95_ms)) } : {}) }));
process.exit(ok.length < runs || (budget > 0 && ok.some(o => o.play2s && o.play2s.worst > budget)) ? 1 : 0);
