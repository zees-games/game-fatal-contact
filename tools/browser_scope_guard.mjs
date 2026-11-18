// Regression guard: in the WEB build, a scoped weapon's scope view is not blank and the first-person viewmodel is drawn.
// Real GPU only (staging02): `tools/gpu.sh cdp-run -- node tools/browser_scope_guard.mjs OUTDIR [URL]` (sets GPU_CDP_URL).
// Equips the Marksman Rifle from the loadout menu (B, third-row card), then ADS-cycles for up to ~80 s until it is alive and scoped.
// Pass needs, on one ADS frame: the OUTSIDE-lens bands dark (mode 2 blacks the surround; the broken lens mode left the whole un-zoomed world),
// the LENS interior not flat (it has an image) and different from the un-zoomed hip frame (it is magnified); and on a hip frame the
// viewmodel region holds hand-coloured pixels. Frames are kept as OUTDIR/hip_NN.png, ads_NN.png. Exit 0 pass, 1 fail, 2 could not run.
// The PNG decode runs in a blank page (canvas), so it needs nothing beyond playwright-core.
import fs from 'node:fs';
const pwPath = process.env.PLAYWRIGHT_CORE || '/home/gamedev/pw/node_modules/playwright-core/index.js';
const pw = (await import(pwPath)).default;
const out = process.argv[2] || 'scope-guard-out'; fs.mkdirSync(out, { recursive: true });
const url = process.argv[3] || 'https://tmcdevgames.net/godot/20261118-0343/embed.html?solo=gamemann%2Fgame-fatal-contact';
const W = 1280, H = 720, CX = W / 2, CY = H / 2;
const sleep = ms => new Promise(r => setTimeout(r, ms));

const browser = await pw.chromium.connectOverCDP(process.env.GPU_CDP_URL);
const ctx = await browser.newContext({ viewport: { width: W, height: H }, ignoreHTTPSErrors: true });
const page = await ctx.newPage();
const log = [];
page.on('console', m => log.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => log.push('[pageerror] ' + e.message));
const calc = await ctx.newPage(); await calc.goto('about:blank');

// Pixel stats of regions of a PNG buffer: [{name, rect|circle}] -> {mean luma, stddev, skin fraction, luma samples}.
async function analyse(buf) {
  return await calc.evaluate(async ({ b64, W, H, CX, CY }) => {
    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
    const bmp = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
    const cv = new OffscreenCanvas(W, H); const g = cv.getContext('2d', { willReadFrequently: true });
    g.drawImage(bmp, 0, 0, W, H);
    const px = g.getImageData(0, 0, W, H).data;
    const stat = (test) => {
      let n = 0, s = 0, s2 = 0, skin = 0; const samples = [];
      for (let y = 0; y < H; y += 2) for (let x = 0; x < W; x += 2) {
        if (!test(x, y)) continue;
        const i = (y * W + x) * 4, r = px[i], gg = px[i + 1], bl = px[i + 2];
        const l = 0.2126 * r + 0.7152 * gg + 0.0722 * bl; n++; s += l; s2 += l * l;
        if (r > 200 && gg > 150 && gg < 205 && bl > 110 && bl < 175 && r - gg > 20 && r - gg < 70) skin++;
        samples.push(l);
      }
      const mean = s / Math.max(n, 1);
      return { n, mean, std: Math.sqrt(Math.max(s2 / Math.max(n, 1) - mean * mean, 0)), skin: skin / Math.max(n, 1), samples };
    };
    return {
      // Left and top-bottom-left bands: well outside the lens circle (radius ~184 px), clear of the right-hand HUD.
      outside: stat((x, y) => x < 220 && y > 200 && y < 520),
      lens: stat((x, y) => Math.hypot(x - CX, y - CY) < 120),
      viewmodel: stat((x, y) => x > 880 && x < 1100 && y > 380 && y < 700),
    };
  }, { b64: buf.toString('base64'), W, H, CX, CY });
}
const strip = a => ({ mean: +a.mean.toFixed(1), std: +a.std.toFixed(1), skin: +a.skin.toFixed(3) });

await page.goto(url, { waitUntil: 'commit', timeout: 120000 });
for (let i = 0; i < 40; i++) { await sleep(5000); if (log.some(l => /gate open slow_frames/i.test(l))) break; }
await sleep(4000);
await page.mouse.click(CX, CY); await sleep(1500);
await page.keyboard.press('b'); await sleep(1500);
await page.mouse.click(466, 420); await sleep(500); await page.keyboard.press('Enter'); await sleep(800);
await page.keyboard.press('b'); await sleep(1500);
await page.mouse.click(CX, CY); await sleep(500);

const verdict = { viewmodel: false, outsideDark: false, lensImage: false, lensMagnified: false };
let hipLens = null; const detail = [];
for (let i = 0; i < 40 && !(verdict.viewmodel && verdict.outsideDark && verdict.lensImage && verdict.lensMagnified); i++) {
  await sleep(2000);
  const hip = await page.screenshot({ path: `${out}/hip_${String(i).padStart(2, '0')}.png` });
  const h = await analyse(hip);
  if (h.viewmodel.skin > 0.03 && h.viewmodel.std > 25) verdict.viewmodel = true;
  await page.mouse.move(CX, CY); await page.mouse.down({ button: 'right' }); await sleep(1800);
  const ads = await page.screenshot({ path: `${out}/ads_${String(i).padStart(2, '0')}.png` });
  await page.mouse.up({ button: 'right' });
  const a = await analyse(ads);
  detail.push({ i, hipVm: strip(h.viewmodel), adsOutside: strip(a.outside), adsLens: strip(a.lens) });
  // The ADS frame is "scoped" when the surround is dark; a lens-mode (broken) frame keeps the bright world outside, so it never passes.
  if (a.outside.mean < 30) {
    verdict.outsideDark = true;
    if (a.lens.std > 8) verdict.lensImage = true;
    let d = 0; for (let k = 0; k < a.lens.samples.length && k < h.lens.samples.length; k++) d += Math.abs(a.lens.samples[k] - h.lens.samples[k]);
    d /= Math.max(Math.min(a.lens.samples.length, h.lens.samples.length), 1);
    if (d > 6) verdict.lensMagnified = true;
  }
}
fs.writeFileSync(`${out}/console.log`, log.join('\n'));
fs.writeFileSync(`${out}/guard.json`, JSON.stringify({ verdict, detail }, null, 1));
await ctx.close();
const ok = Object.values(verdict).every(Boolean);
console.log(JSON.stringify(verdict), ok ? 'SCOPE GUARD PASS' : 'SCOPE GUARD FAIL');
process.exit(ok ? 0 : 1);
