import { chromium } from 'playwright';
const file = 'file:///home/user/AAA-Flow/sandbox/Control-Center-Sandbox.html';
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const errs = [];
async function run(width, height, label, userIndex) {
  const page = await browser.newPage({ viewport: { width, height } });
  page.on('pageerror', e => errs.push(`[${label}] PAGEERROR: ` + e.message));
  page.on('console', m => { if (m.type() === 'error' && !m.text().includes('ERR_CERT')) errs.push(`[${label}] CONSOLE: ` + m.text()); });
  await page.goto(file); await page.waitForTimeout(300);
  await page.screenshot({ path: `/tmp/login-${label}.png` });
  const logins = await page.$$('[data-login]');
  await logins[userIndex % logins.length].click(); await page.waitForTimeout(300);
  const views = await page.$$eval('[data-v]', els => [...new Set(els.map(e => e.dataset.v))]);
  for (const v of views) {
    const el = await page.$(`[data-v="${v}"]:visible`); if (!el) continue;
    await el.click(); await page.waitForTimeout(200);
    const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (over > 2) errs.push(`[${label}] Überlauf in ${v}: ${over}px`);
    if (v === 'dash') await page.screenshot({ path: `/tmp/dash-${label}.png` });
  }
  await (await page.$('[data-v="projects"]:visible'))?.click(); await page.waitForTimeout(200);
  const row = await page.$('[data-pp]:visible');
  if (row) { await row.click(); await page.waitForTimeout(300);
    const tabs = await page.$$eval('[data-ptab]', e => [...new Set(e.map(x => x.dataset.ptab))]);
    for (const tb of tabs) { const el = await page.$(`[data-ptab="${tb}"]:visible`); if (!el) continue;
      await el.click(); await page.waitForTimeout(150);
      const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      if (over > 2) errs.push(`[${label}] Überlauf im Reiter ${tb}: ${over}px`); }
    await page.screenshot({ path: `/tmp/detail-${label}.png` }); }
  await page.close();
}
await run(1440, 900, 'desktop', 0);
await run(1024, 768, 'tablet', 2);
await run(390, 844, 'phone', 5);
console.log(errs.length ? errs.join('\n') : 'KEINE FEHLER');
await browser.close();
