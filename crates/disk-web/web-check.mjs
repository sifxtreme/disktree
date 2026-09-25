// Browser-page harness: desktop light + phone dark, click in/out, no delete controls, no errors.
//   PLAYWRIGHT=<path to playwright/index.js> node crates/disk-web/web-check.mjs [url]
const pw = (await import(process.env.PLAYWRIGHT ?? "playwright")).default;
const { chromium } = pw;
const b = await chromium.launch(); const errs = []; let ok = true;
const check = (name, cond) => { console.log((cond ? 'PASS ' : 'FAIL ') + name); if (!cond) ok = false; };
for (const [vp, scheme] of [[{ width: 1440, height: 900 }, 'light'], [{ width: 390, height: 844 }, 'dark']]) {
  const p = await b.newPage({ viewport: vp, colorScheme: scheme });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await p.goto(process.argv[2] ?? 'http://127.0.0.1:7321/'); await p.waitForSelector('.tile', { timeout: 60000 }); await p.waitForTimeout(600);
  const tiles = await p.$$eval('.tile', t => t.length);
  check(`${vp.width}px ${scheme}: map draws (${tiles} tiles)`, tiles > 20);
  check(`${vp.width}px: no horizontal scroll`, !(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)));
  check(`${vp.width}px: no delete controls`, (await p.$$eval('#reviewbtn,#markcard,#scrim,.tile.marked', t => t.length)) === 0);
  // click into the largest top-level folder, then back out
  const before = await p.textContent('#trail');
  await p.dblclick('.tile.top', { position: { x: 30, y: 8 } }); await p.waitForTimeout(1200);
  const inside = await p.textContent('#trail');
  check(`${vp.width}px: double-click goes in`, inside !== before);
  await p.keyboard.press('Backspace'); await p.waitForTimeout(1200);
  check(`${vp.width}px: backspace comes back out`, (await p.textContent('#trail')) === before);
  const hosts = await p.$$eval('#hosts button', b => b.length);
  check(`${vp.width}px: both machines listed (${hosts})`, hosts === 2);
  await p.close();
}
check('no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''), errs.length === 0);
await b.close(); process.exit(ok ? 0 : 1);
