// Prüft die Darstellung auf allen Geräteklassen: läuft Text aus seinem Feld,
// überlagern sich zwei Beschriftungen, ragt etwas über den rechten Rand?
//
//   node scripts/check-layout.mjs [pfad/zur/sandbox.html]
//
// Der Anlass: auf dem Telefon fiel die Überschrift einer Karte auf null Breite
// zusammen und ihr Text lief quer über den Erklärungstext daneben. Ein Test,
// der nur den waagerechten Überlauf der Seite misst, sieht so etwas nicht —
// die Seite blieb ja innerhalb ihrer Breite. Deshalb wird hier die Geometrie
// jedes sichtbaren Textes geprüft.
import { chromium } from 'playwright'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { existsSync, readdirSync } from 'node:fs'

// Mit ?demo=1, damit jede Ansicht Inhalt trägt — leere Listen verdecken
// Darstellungsfehler.
const file = pathToFileURL(resolve(process.argv[2] ?? 'sandbox/Control-Center-Sandbox.html')).href + '?demo=1'

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

// Die Geräte, auf denen im Haus gearbeitet wird — vom großen Schirm im
// Besprechungsraum bis zum schmalsten Telefon, das noch im Umlauf ist.
const GERAETE = [
  { w: 1920, h: 1080, n: 'Großer Bildschirm' },
  { w: 1440, h: 900, n: 'Laptop' },
  { w: 1280, h: 800, n: 'Kleiner Laptop' },
  { w: 1180, h: 820, n: 'Tablet quer' },
  { w: 1024, h: 768, n: 'Tablet' },
  { w: 834, h: 1112, n: 'Tablet hoch' },
  { w: 768, h: 1024, n: 'Kleines Tablet' },
  { w: 430, h: 932, n: 'Telefon groß' },
  { w: 393, h: 852, n: 'Telefon' },
  { w: 375, h: 667, n: 'Telefon klein' },
  { w: 360, h: 740, n: 'Telefon schmal' },
]

const findings = []
let checks = 0
const ok = (name, cond, detail = '') => {
  checks++
  if (!cond) findings.push(`✗ ${name}${detail ? ' — ' + detail : ''}`)
}

/* Im Browser ausgewertet: Welcher Text steht wo, und wo stößt er an?
   Overlay-Schichten (Dialog, Druckansicht, Hinweis, Trefferliste) liegen
   absichtlich über der Seite und bleiben außen vor. */
const MESSUNG = () => {
  const OVERLAY = ['modal', 'print', 'toast', 'ghits', 'tip']
  const inOverlay = (el) => {
    for (let n = el; n; n = n.parentElement) {
      if (OVERLAY.includes(n.id) || n.classList.contains('tip')) return true
      const p = getComputedStyle(n).position
      if (p === 'absolute' || p === 'fixed' || p === 'sticky') return true
    }
    return false
  }
  const hatText = (el) => [...el.childNodes]
    .some((n) => n.nodeType === 3 && n.textContent.trim().length > 1)

  /* Ein Rechteck sagt noch nicht, was man sieht: was aus einem scrollenden
     Bereich herausragt, wird abgeschnitten. Deshalb jedes Rechteck an allen
     abschneidenden Vorfahren beschneiden — was danach nichts mehr übrig hat,
     ist unsichtbar und kann mit nichts kollidieren. */
  const sichtbarerTeil = (el) => {
    let r = el.getBoundingClientRect()
    let box = { left: r.left, right: r.right, top: r.top, bottom: r.bottom }
    for (let n = el.parentElement; n && n !== document.documentElement; n = n.parentElement) {
      const s = getComputedStyle(n)
      if (s.overflowX === 'visible' && s.overflowY === 'visible') continue
      const c = n.getBoundingClientRect()
      box = { left: Math.max(box.left, c.left), right: Math.min(box.right, c.right),
        top: Math.max(box.top, c.top), bottom: Math.min(box.bottom, c.bottom) }
      if (box.right <= box.left || box.bottom <= box.top) return null
    }
    box.width = box.right - box.left; box.height = box.bottom - box.top
    return box
  }

  /* Zwei Listen, weil zwei verschiedene Fragen gestellt werden.
     „alle" hält jedes Feld, das gerendert wird — auch eines, das auf null
     Breite zusammengefallen ist. Genau das ist der Fehlerfall: die Box misst
     nichts mehr, ihr Text steht trotzdem da und läuft quer über den Nachbarn.
     Wer solche Felder wegfiltert, prüft den Fehler weg. */
  const alle = [], kandidaten = []
  document.querySelectorAll('body *').forEach((el) => {
    if (!hatText(el) || inOverlay(el)) return
    const st = getComputedStyle(el)
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) return
    const roh = el.getBoundingClientRect()
    if (roh.height < 2) return
    alle.push({ el, roh, st })
    const r = sichtbarerTeil(el)
    if (r && r.width >= 2 && r.height >= 2) kandidaten.push({ el, r, roh, st })
  })

  const pfad = (el) => {
    const t = el.tagName.toLowerCase()
    const c = (el.className || '').toString().trim().split(/\s+/).filter(Boolean).slice(0, 2).join('.')
    return c ? `${t}.${c}` : t
  }
  const kurz = (el) => el.textContent.replace(/\s+/g, ' ').trim().slice(0, 28)

  // 1. Text, der aus seinem eigenen Feld läuft. Wo abgeschnitten oder
  //    gescrollt wird, ist das gewollt — dort wird nicht gemeldet.
  const raus = []
  alle.forEach(({ el, roh, st }) => {
    if (st.overflowX !== 'visible' || st.textOverflow === 'ellipsis') return
    const zuViel = el.scrollWidth - Math.ceil(roh.width)
    if (zuViel > 2) raus.push({ sel: pfad(el), text: kurz(el), px: zuViel, breite: Math.round(roh.width) })
  })

  // 2. Zwei Texte, die übereinanderliegen. Verwandte zählen nicht: ein
  //    hervorgehobenes Wort liegt naturgemäß in seinem Absatz.
  const verwandt = (a, b) => a.contains(b) || b.contains(a)
  const ueber = []
  for (let i = 0; i < kandidaten.length; i++) {
    for (let j = i + 1; j < kandidaten.length; j++) {
      const a = kandidaten[i], b = kandidaten[j]
      if (verwandt(a.el, b.el)) continue
      const x = Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left)
      const y = Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top)
      if (x <= 3 || y <= 3) continue
      const flaeche = x * y
      const kleiner = Math.min(a.r.width * a.r.height, b.r.width * b.r.height)
      if (flaeche < kleiner * 0.2) continue
      ueber.push({ a: pfad(a.el), at: kurz(a.el), b: pfad(b.el), bt: kurz(b.el), px: `${Math.round(x)}×${Math.round(y)}` })
      if (ueber.length > 12) return { raus, ueber, rand: [], seite: 0 }
    }
  }

  // 3. Was über den rechten Rand hinausragt, ist auf dem Telefon nicht lesbar.
  //    Ausgenommen, was in einem waagerecht scrollbaren Bereich steht — eine
  //    Reiterleiste oder eine breite Tabelle darf länger sein, als der Schirm
  //    ist; erreichbar bleibt sie trotzdem. Geprüft wird dann der Bereich selbst.
  const scrollAhn = (el) => {
    for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) {
      const o = getComputedStyle(n).overflowX
      if (o === 'auto' || o === 'scroll') return n
    }
    return null
  }
  const rand = []
  const grenze = document.documentElement.clientWidth
  kandidaten.forEach(({ el, r }) => {
    const sc = scrollAhn(el)
    const bis = sc ? Math.min(grenze, sc.getBoundingClientRect().right) : grenze
    if (sc) return                                  // der Bereich scrollt, das ist gewollt
    if (r.right - bis > 2) rand.push({ sel: pfad(el), text: kurz(el), px: Math.round(r.right - bis) })
  })

  return { raus, ueber, rand,
    seite: document.documentElement.scrollWidth - document.documentElement.clientWidth }
}

const browser = await chromium.launch({ executablePath: findChromium() })

async function pruefe(page, wo, label) {
  // Ein Klick kann den Bereich verschoben haben. Gemessen wird von oben.
  await page.evaluate(() => {
    window.scrollTo(0, 0)
    document.querySelectorAll('*').forEach((e) => { if (e.scrollTop) e.scrollTop = 0 })
  })
  await page.waitForTimeout(120)
  const m = await page.evaluate(MESSUNG)
  ok(`${label} · ${wo}: kein waagerechter Überlauf`, m.seite <= 2, `${m.seite} px`)
  ok(`${label} · ${wo}: kein Text läuft aus seinem Feld`, m.raus.length === 0,
    m.raus.slice(0, 3).map((x) => `${x.sel} „${x.text}" ${x.px} px zu breit (Feld ${x.breite} px)`).join('; '))
  ok(`${label} · ${wo}: keine zwei Texte übereinander`, m.ueber.length === 0,
    m.ueber.slice(0, 3).map((x) => `${x.a} „${x.at}" über ${x.b} „${x.bt}" (${x.px} px)`).join('; '))
  ok(`${label} · ${wo}: nichts ragt über den rechten Rand`, m.rand.length === 0,
    m.rand.slice(0, 3).map((x) => `${x.sel} „${x.text}" ${x.px} px`).join('; '))
}

for (const g of GERAETE) {
  // Deutsch und Englisch: die englischen Texte sind kürzer, die deutschen
  // Komposita länger — beide Fassungen können unterschiedlich brechen.
  for (const lang of ['de', 'en']) {
    const label = `${g.n} ${g.w}px ${lang.toUpperCase()}`
    const page = await browser.newPage({ viewport: { width: g.w, height: g.h } })
    page.on('pageerror', (e) => findings.push(`✗ [${label}] Laufzeitfehler: ${e.message}`))
    await page.goto(file)
    await page.waitForTimeout(250)
    if (lang === 'en') {
      const sw = await page.$('[data-l="en"]')
      if (sw) { await sw.click(); await page.waitForTimeout(200) }
    }
    await page.click('[data-access="team"]')
    await page.waitForTimeout(200)
    const leute = await page.$$('[data-login]')
    if (leute.length) await leute[0].click()
    await page.waitForTimeout(400)

    // Alle Hauptansichten
    const views = await page.$$eval('[data-v]', (els) => [...new Set(els.map((e) => e.dataset.v))])
    for (const v of views) {
      const el = await page.$(`[data-v="${v}"]:visible`)
      if (!el) continue
      await el.click()
      await page.waitForTimeout(220)
      await pruefe(page, `Ansicht ${v}`, label)
    }

    // Projektakte mit allen Reitern — hier steckt die meiste Information
    await (await page.$('[data-v="projects"]:visible')).click()
    await page.waitForTimeout(200)
    const karte = await page.$('[data-pp]:visible')
    if (karte) {
      await karte.click()
      await page.waitForTimeout(300)
      const tabs = await page.$$eval('[data-ptab]', (els) => [...new Set(els.map((e) => e.dataset.ptab))])
      for (const tb of tabs) {
        const el = await page.$(`[data-ptab="${tb}"]:visible`)
        if (!el) continue
        await el.click()
        await page.waitForTimeout(240)
        await pruefe(page, `Reiter ${tb}`, label)
      }
    }
    await page.close()
  }
}

await browser.close()

console.log(`${checks} Darstellungsprüfungen auf ${GERAETE.length} Geräteklassen in zwei Sprachen.`)
if (findings.length) {
  console.error('\n' + findings.join('\n'))
  console.error(`\n${findings.length} Befund(e).`)
  process.exit(1)
}
console.log('Keine Befunde: kein Überlauf, kein herauslaufender Text, keine Überlagerung.')
