// Prüft den Prototyp im Browser: Laufzeitfehler, waagerechter Überlauf und
// erreichbare Ansichten — bei drei Bildschirmbreiten und in beiden Zugängen.
//
//   node scripts/check-sandbox.mjs [pfad/zur/sandbox.html]
//
// Braucht Chromium. Ist PLAYWRIGHT_BROWSERS_PATH gesetzt (wie in der
// Entwicklungsumgebung), wird der dortige Browser genommen.
import { chromium } from 'playwright'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { existsSync, readdirSync } from 'node:fs'

const file = pathToFileURL(resolve(process.argv[2] ?? 'sandbox/Control-Center-Sandbox.html')).href

/* Die Playwright-Fassung im Projekt und der vorinstallierte Browser müssen
   nicht dieselbe Nummer tragen. Liegt ein Chromium unter
   PLAYWRIGHT_BROWSERS_PATH, wird es genommen. */
function findChromium() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH
  if (!root || !existsSync(root)) return undefined
  for (const dir of readdirSync(root).filter((d) => d.startsWith('chromium-')).sort().reverse()) {
    const bin = join(root, dir, 'chrome-linux', 'chrome')
    if (existsSync(bin)) return bin
  }
  return undefined
}

const browser = await chromium.launch({ executablePath: findChromium() })
const findings = []

async function run(width, height, label, access, lang) {
  const page = await browser.newPage({ viewport: { width, height } })
  page.on('pageerror', (e) => findings.push(`[${label}] Laufzeitfehler: ${e.message}`))
  page.on('console', (m) => {
    // Web-Schriften laden in abgeschotteten Umgebungen nicht — kein Befund.
    if (m.type() === 'error' && !m.text().includes('ERR_CERT')) findings.push(`[${label}] Konsole: ${m.text()}`)
  })
  await page.goto(file)
  await page.waitForTimeout(300)

  // Anmeldung in zwei Schritten: Zugang, dann beim Teamzugang eine Person.
  const acc = await page.$(`[data-access="${access}"]`)
  if (!acc) { findings.push(`[${label}] Anmeldung zeigt den Zugang ${access} nicht`); await page.close(); return }
  await acc.click()
  await page.waitForTimeout(300)
  if (access === 'team') {
    const people = await page.$$('[data-login]')
    if (!people.length) findings.push(`[${label}] Teamzugang bietet keine Person zur Auswahl`)
    else await people[0].click()
    await page.waitForTimeout(300)
  }

  if (lang) {
    const sw = await page.$(`[data-l="${lang}"]:visible`)
    if (!sw) findings.push(`[${label}] Sprachumschalter ${lang} fehlt`)
    else { await sw.click(); await page.waitForTimeout(250) }
  }

  const overflow = () => page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth)

  const views = await page.$$eval('[data-v]', (els) => [...new Set(els.map((e) => e.dataset.v))])
  for (const v of views) {
    const el = await page.$(`[data-v="${v}"]:visible`)
    if (!el) continue
    await el.click()
    await page.waitForTimeout(180)
    const over = await overflow()
    if (over > 2) findings.push(`[${label}] Ansicht ${v} läuft ${over} px über den Rand`)
  }

  await (await page.$('[data-v="projects"]:visible'))?.click()
  await page.waitForTimeout(180)
  const row = await page.$('[data-pp]:visible')
  if (!row) { findings.push(`[${label}] kein Projekt anklickbar`); await page.close(); return }
  await row.click()
  await page.waitForTimeout(250)
  const tabs = await page.$$eval('[data-ptab]', (els) => [...new Set(els.map((e) => e.dataset.ptab))])
  for (const tab of tabs) {
    const el = await page.$(`[data-ptab="${tab}"]:visible`)
    if (!el) continue
    await el.click()
    await page.waitForTimeout(150)
    const over = await overflow()
    if (over > 2) findings.push(`[${label}] Reiter ${tab} läuft ${over} px über den Rand`)
    /* Dieser Durchlauf läuft ohne ?demo, also auf den echten Projekten — und
       die sind leer. Genau dieser Zustand ist der erste, den das Team sieht:
       Ein Reiter, der dabei nichts sagt, lässt ratlos zurück. */
    const text = await page.evaluate(() => document.getElementById('main').innerText.trim().length)
    if (text < 40) findings.push(`[${label}] Reiter ${tab} bleibt im leeren Projekt stumm (${text} Zeichen)`)
  }
  // Die Teilprojekte sind die einzige Struktur, die ein neues Projekt mitbringt.
  const tl = await page.$('[data-ptab="timeline"]:visible')
  if (tl) {
    await tl.click()
    await page.waitForTimeout(200)
    const txt = await page.evaluate(() => document.getElementById('main').innerText)
    const fehlen = ['TM Fertigstellung', 'Recurrent Training', 'SME'].filter((n) => !txt.includes(n))
    if (fehlen.length) findings.push(`[${label}] Teilprojekte fehlen im Projektverlauf: ${fehlen.join(', ')}`)
  }
  // Übrig gebliebene Textschlüssel fallen als Rohtext auf.
  const raw = await page.evaluate(() => (document.body.innerText.match(/\b[a-z]{1,6}_[a-z0-9_]{2,}\b/g) || [])
    .filter((x) => !x.includes('@')))
  if (raw.length) findings.push(`[${label}] mutmaßlich unübersetzte Schlüssel: ${[...new Set(raw)].join(', ')}`)

  /* Verlauf und Versionen entstehen aus Demodaten. Standen sie als fertige
     Sätze im Speicher, blieben sie nach dem Sprachwechsel deutsch. */
  if (lang === 'en') {
    await (await page.$('[data-ptab="activity"]:visible'))?.click()
    await page.waitForTimeout(200)
    const txt = await page.evaluate(() => document.body.innerText)
    for (const de of ['Projekt angelegt', 'Meilenstein erreicht', 'Aufgabe erledigt', 'Risiko angelegt']) {
      if (txt.includes(de)) findings.push(`[${label}] deutscher Verlaufstext in der englischen Fassung: ${de}`)
    }
    await (await page.$('[data-ptab="versions"]:visible'))?.click()
    await page.waitForTimeout(200)
    const vtxt = await page.evaluate(() => document.body.innerText)
    for (const de of ['Projekt angelegt', 'Projektstatus geändert', 'Meilenstein erreicht']) {
      if (vtxt.includes(de)) findings.push(`[${label}] deutscher Versionstext in der englischen Fassung: ${de}`)
    }
  }
  await page.close()
}

await run(1440, 900, 'Desktop Team', 'team')
await run(1024, 768, 'Tablet Team', 'team')
await run(390, 844, 'Telefon Lesezugang', 'viewer')
await run(1440, 900, 'Desktop EN', 'team', 'en')
await browser.close()

if (findings.length) {
  console.error(findings.join('\n'))
  process.exit(1)
}
console.log('Prototyp: keine Fehler, kein Überlauf bei 1440, 1024 und 390 Pixel Breite; englische Fassung ohne deutsche Reste.')
