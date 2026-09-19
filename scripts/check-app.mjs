// Geht den Prototyp durch wie ein Mensch, der alles anfasst: jeden Knopf,
// jeden Dialog, jeden Reiter, jede Ausgabe — in beiden Zugängen, und prüft
// danach, ob die Änderungen ein Neuladen überstehen.
//
//   node scripts/check-app.mjs [pfad/zur/sandbox.html]
//
// Meldet jeden Laufzeitfehler, jeden Knopf ohne Wirkung und jede Zusicherung,
// die nicht hält. Gedacht für den Einsatz vor jeder Weitergabe an das Team.
import { chromium } from 'playwright'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'

// Mit ?demo=1: der volle Beispieldatensatz. Die zehn echten Projekte stehen
// bewusst leer da; geprüft werden soll die Anwendung im vollen Betrieb.
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

const findings = []
let checks = 0
const ok = (name, cond, detail) => {
  checks++
  if (!cond) findings.push(`✗ ${name}${detail ? ' — ' + detail : ''}`)
}

const browser = await chromium.launch({ executablePath: findChromium() })
const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
const page = await ctx.newPage()
page.on('pageerror', (e) => findings.push(`✗ Laufzeitfehler: ${e.message}`))
page.on('console', (m) => {
  if (m.type() === 'error' && !m.text().includes('ERR_CERT') && !m.text().includes('favicon'))
    findings.push(`✗ Konsole: ${m.text()}`)
})

const wait = (ms = 220) => page.waitForTimeout(ms)
const $ = (sel) => page.$(`${sel}:visible`)

// Alles schließen, was über der Seite liegen könnte. Ein Prüfskript, das an
// einem offenen Fenster hängen bleibt, prüft ab da nichts mehr.
const frei = () => page.evaluate(() => {
  const pr = document.getElementById('print')
  if (pr) pr.classList.remove('on')
  const md = document.getElementById('modal')
  if (md && md.classList.contains('on')) { md.classList.remove('on'); dlg = null }
  const ts = document.getElementById('toast')
  if (ts) ts.classList.remove('on')
  const gh = document.getElementById('ghits')
  if (gh) { gh.hidden = true; gh.innerHTML = '' }
})

const click = async (sel, name) => {
  const el = await $(sel)
  if (!el) { ok(name || sel, false, 'nicht gefunden'); return false }
  try {
    await el.click({ timeout: 4000 })
  } catch (e) {
    ok(name || sel, false, 'nicht anklickbar: ' + String(e.message).split('\n')[0])
    return false
  }
  await wait()
  return true
}

// Eine Datei für den Upload-Versuch
const probe = '/tmp/pcc-probe.pdf'
writeFileSync(probe, '%PDF-1.4 Pruefdatei\n')

// ---------------------------------------------------------------- Anmeldung
await page.goto(file)
await wait(400)
ok('Anmeldung bietet beide Zugänge', (await page.$$('[data-access]')).length === 2)
ok('Sprachumschalter auf dem Anmeldebildschirm', !!(await $('[data-l="en"]')))

await click('[data-access="team"]', 'Teamzugang wählbar')
const people = await page.$$('[data-login]')
ok('Teamzugang bietet Personen zur Auswahl', people.length > 1, `${people.length} gefunden`)
ok('Rückweg zum Zugangsbildschirm vorhanden', !!(await $('#lgBack')))
await click('#lgBack', 'Zurück zum Zugang')
ok('Zurück führt auf die Zugangswahl', (await page.$$('[data-access]')).length === 2)

await click('[data-access="team"]')
await (await page.$$('[data-login]'))[0].click()
await wait(400)
ok('Nach der Personenwahl steht die Anwendung', !!(await $('.workspace')))

// ------------------------------------------------------------------ Aufbau
const state = () => page.evaluate(() => ({
  access: ACCESS, me, view: pv, project: pProject, tab: pTab,
  projekte: PROJECTS.length, rev: DATA_REV
}))

const views = await page.$$eval('[data-v]', (els) => [...new Set(els.map((e) => e.dataset.v))])
ok('Alle Bereiche erreichbar', views.length >= 8, views.join(', '))
for (const v of views) {
  const el = await $(`[data-v="${v}"]`)
  if (!el) continue
  await el.click()
  await wait(260)
  const s = await state()
  ok(`Bereich ${v} wechselt die Ansicht`, s.view === v, `steht auf ${s.view}`)
  const leer = await page.evaluate(() => document.getElementById('main').innerText.trim().length)
  ok(`Bereich ${v} zeigt Inhalt`, leer > 40, `${leer} Zeichen`)
  const over = await page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok(`Bereich ${v} ohne Überlauf`, over <= 2, `${over} px`)
}

// ------------------------------------------------------------------ Filter
await click('[data-v="projects"]')
const vorher = await page.$$eval('[data-pp]', (e) => e.length)
await page.fill('#pq', 'CL650')
await wait(300)
const gefiltert = await page.$$eval('[data-pp]', (e) => e.length)
ok('Die Suche im Filter grenzt ein', gefiltert < vorher && gefiltert > 0, `${vorher} → ${gefiltert}`)
await click('#pclear', 'Filter zurücksetzen')
ok('Zurücksetzen stellt die volle Liste her',
  (await page.$$eval('[data-pp]', (e) => e.length)) === vorher)
await page.selectOption('#pstatus', 'on_track')
await wait(260)
ok('Der Statusfilter greift',
  (await page.$$eval('[data-pp]', (e) => e.length)) < vorher)
await click('#pclear')

// --------------------------------------------------------------- Projektakte
await click('[data-pp]', 'Projekt öffnen')
ok('Projektakte offen', (await state()).project !== null)
const tabs = await page.$$eval('[data-ptab]', (e) => [...new Set(e.map((x) => x.dataset.ptab))])
ok('Alle Reiter der Projektakte da', tabs.length === 10, tabs.join(', '))
for (const tab of tabs) {
  const el = await $(`[data-ptab="${tab}"]`)
  if (!el) { ok(`Reiter ${tab}`, false, 'nicht klickbar'); continue }
  await el.click()
  await wait(260)
  const s = await state()
  ok(`Reiter ${tab} wechselt`, s.tab === tab, `steht auf ${s.tab}`)
  const text = await page.evaluate(() => document.getElementById('main').innerText.trim().length)
  ok(`Reiter ${tab} zeigt Inhalt`, text > 60, `${text} Zeichen`)
}

// -------------------------------------------------------------------- Gantt
await click('[data-ptab="timeline"]')
await wait(500)
const g = await page.evaluate(() => ({
  zeilen: document.querySelectorAll('.grow').length,
  balken: document.querySelectorAll('.gbar').length,
  pfeile: document.querySelectorAll('.glink').length,
  legende: !!document.querySelector('.tlleg'),
  heute: !!document.querySelector('.tlnowhd')
}))
ok('Gantt zeichnet Zeilen', g.zeilen > 5, `${g.zeilen}`)
ok('Gantt zeichnet Balken', g.balken > 3, `${g.balken}`)
ok('Gantt zeichnet Abhängigkeiten', g.pfeile > 0, `${g.pfeile}`)
ok('Gantt hat eine Zeichenerklärung', g.legende)
ok('Gantt zeigt die Heute-Linie', g.heute)

// ------------------------------------------------------------------ Dialoge
await frei()
// Abbrechen darf nichts verändern
await click('[data-ptab="tasks"]')
const vorAbbruch = await page.evaluate(() => pById(pProject).tasks.length)
await click('#pnewtask', 'Aufgabe anlegen öffnen')
ok('Dialog offen', await page.evaluate(() => !!dlg))
await click('#mCancel', 'Dialog abbrechen')
ok('Abbrechen schließt den Dialog', await page.evaluate(() => !dlg))
ok('Abbrechen legt nichts an',
  (await page.evaluate(() => pById(pProject).tasks.length)) === vorAbbruch)

// Pflichtfeldprüfung
await click('#pnewtask')
await click('#mOk', 'Leeren Dialog absenden')
ok('Leeres Pflichtfeld wird beanstandet',
  (await page.evaluate(() => document.getElementById('mErr').innerText.trim().length)) > 0)
ok('Dialog bleibt bei Fehlern offen', await page.evaluate(() => !!dlg))
await page.fill('[data-f="title"]', 'Prüfaufgabe aus dem Funktionstest')
const deps = await page.$$('[data-fm="deps"]')
if (deps.length) await deps[0].check()
await click('#mOk', 'Aufgabe anlegen')
ok('Aufgabe wurde angelegt',
  (await page.evaluate(() => pById(pProject).tasks.length)) === vorAbbruch + 1)
ok('Vorgänger wurde verknüpft', deps.length === 0 ||
  (await page.evaluate(() => pById(pProject).links.some((l) => {
    const t = pById(pProject).tasks.find((x) => x.title.startsWith('Prüfaufgabe'))
    return t && l.to === t.id
  }))))

// Risiko
await click('[data-ptab="risks"]')
const vorRisiko = await page.evaluate(() => pById(pProject).risks.length)
await click('#pnewrisk', 'Risiko anlegen öffnen')
await page.fill('[data-f="title"]', 'Prüfrisiko aus dem Funktionstest')
await click('#mOk')
ok('Risiko wurde angelegt',
  (await page.evaluate(() => pById(pProject).risks.length)) === vorRisiko + 1)

// Problem
await click('[data-ptab="issues"]')
const vorIssue = await page.evaluate(() => pById(pProject).issues.length)
await click('#pnewissue', 'Problem melden öffnen')
await page.fill('[data-f="title"]', 'Prüfproblem aus dem Funktionstest')
await click('#mOk')
ok('Problem wurde gemeldet',
  (await page.evaluate(() => pById(pProject).issues.length)) === vorIssue + 1)

// Projekt bearbeiten
await click('#pedit', 'Projekt bearbeiten öffnen')
ok('Bearbeiten-Dialog trägt den Projektnamen',
  (await page.inputValue('[data-f="name"]')).length > 3)
await click('#mCancel')

// Datei anhängen
await click('[data-ptab="tasks"]')
const vorDoc = await page.evaluate(() => pById(pProject).docs.length)
if (await click('[data-pup]', 'Datei an Aufgabe anhängen')) {
  await page.setInputFiles('[data-ff="file"]', probe)
  await wait(260)
  await page.fill('[data-f="title"]', 'Prüfdatei')
  await click('#mOk')
  ok('Datei wurde angehängt',
    (await page.evaluate(() => pById(pProject).docs.length)) === vorDoc + 1)
  ok('Die Aufgabe zeigt den Anhang', (await page.$$('[data-pdoc]')).length > 0)
}

// Erledigt und zurücknehmen
const offen = await page.$('[data-ptdone]:visible')
if (offen) {
  const id = await offen.getAttribute('data-ptdone')
  await offen.click()
  await wait(300)
  ok('Aufgabe wurde erledigt',
    await page.evaluate((i) => {
      const x = pById(pProject).tasks.find((t) => t.id === i)
      return x && x.status === 'completed'
    }, id))
  const undo = await page.$('.toast .undo')
  ok('Erledigt lässt sich zurücknehmen', !!undo)
  if (undo) {
    await undo.click()
    await wait(300)
    ok('Zurücknehmen stellt den Stand wieder her',
      await page.evaluate((i) => {
        const x = pById(pProject).tasks.find((t) => t.id === i)
        return x && x.status !== 'completed'
      }, id))
  }
}

// ----------------------------------------------------------------- Ausgaben
const kinds = await page.evaluate(() => {
  const set = new Set()
  document.querySelectorAll('[data-exp]').forEach((b) => set.add(b.dataset.exp))
  return [...set]
})
ok('Im Projekt gibt es Ausgaben', kinds.length > 0)

async function pruefeAusgabe(kind) {
  const okDoc = await page.evaluate((k) => {
    try {
      const d = docDef(k)
      return !!(d && d.title && Array.isArray(d.sections))
    } catch (e) { return 'FEHLER: ' + e.message }
  }, kind)
  ok(`Ausgabe ${kind} lässt sich erzeugen`, okDoc === true, String(okDoc))
}
const alleKinds = await page.evaluate(() => XLS_KINDS.slice())
await click('[data-ptab="overview"]')
for (const k of alleKinds) {
  if (k.startsWith('pcc_p') || k === 'pcc_report') continue // brauchen ein offenes Projekt, ist gegeben
  await pruefeAusgabe(k)
}
for (const k of alleKinds.filter((x) => x.startsWith('pcc_p') || x === 'pcc_report')) {
  await pruefeAusgabe(k)
}

// Druckansicht wirklich öffnen und schließen
await frei()
await click('[data-ptab="tasks"]')
if (await click('[data-exp^="pdf"]', 'PDF-Ansicht öffnen')) {
  await wait(400)
  ok('Druckansicht ist offen', await page.evaluate(() =>
    document.getElementById('print').classList.contains('on')))
  ok('Die Ausgabe nennt ihren Stand', await page.evaluate(() =>
    document.querySelector('#print .kv').innerText.includes('Änderung')))
  await click('#pClose', 'Druckansicht schließen')
  ok('Druckansicht ist geschlossen', await page.evaluate(() =>
    !document.getElementById('print').classList.contains('on')))
}
// Excel: Vorschau, Kopieren als Nebenweg, Herunterladen als echte .xlsx
if (await click('[data-exp^="xls"]', 'Excel-Auszug öffnen')) {
  const tsv = await page.inputValue('[data-f="data"]').catch(() => '')
  ok('Der Excel-Auszug enthält Zeilen', tsv.split('\n').length > 3, `${tsv.split('\n').length} Zeilen`)
  ok('Kopieren steht als zweiter Knopf bereit', !!(await $('#mExtra')))
  const [dl] = await Promise.all([
    page.waitForEvent('download', { timeout: 4000 }).catch(() => null),
    click('#mOk', 'Excel-Datei herunterladen')])
  ok('Es wird eine .xlsx-Datei geliefert', !!dl && dl.suggestedFilename().endsWith('.xlsx'), dl ? dl.suggestedFilename() : 'kein Download')
  if (dl) {
    const pfad = await dl.path().catch(() => null)
    ok('Die Datei ist ein Zip-Archiv', !!pfad && readFileSync(pfad).readUInt32LE(0) === 0x04034B50)
  }
  ok('Nach dem Herunterladen ist der Dialog zu', await page.evaluate(() => !dlg))
}

// ------------------------------------------------------------------- Suche
await frei()
await page.fill('#gq', 'qtg')
await wait(320)
const treffer = await page.$$eval('#ghits [data-gs]', (e) => e.length)
ok('Die Suche findet etwas', treffer > 0, `${treffer} Treffer`)
if (treffer) {
  await (await page.$('#ghits [data-gs]')).click()
  await wait(320)
  ok('Ein Treffer öffnet den Fundort', (await state()).project !== null)
}
await page.fill('#gq', 'zzzznichtsda')
await wait(300)
ok('Ohne Treffer steht eine Meldung', !!(await page.$('#ghits .none')))
await page.keyboard.press('Escape')
await wait(200)
ok('Escape schließt die Suche', await page.evaluate(() => document.getElementById('ghits').hidden))

// ----------------------------------------------------------- Berichte, ICS
await frei()
await page.evaluate(() => { pProject = null; pv = 'reports'; render() })
await wait(320)
ok('Wochenbericht lässt sich erzeugen', await page.evaluate(() => {
  try { const d = weeklyDef(); return d.sections.length === 5 } catch (e) { return false }
}))
await page.selectOption('#repdays', '30')
await wait(260)
ok('Der Rückblick lässt sich umstellen', await page.evaluate(() => REP_DAYS === 30))
ok('Kalenderdatei entsteht', await page.evaluate(() => {
  try {
    const s = icsText(pVisible())
    return s.startsWith('BEGIN:VCALENDAR') && s.trimEnd().endsWith('END:VCALENDAR') &&
      s.includes('BEGIN:VEVENT')
  } catch (e) { return false }
}))

// ----------------------------------------------------------------- Zeitreise
await frei()
const vorReise = await page.evaluate(() => today())
await click('[data-tr="8"]', 'Zeitreise +8 Tage')
const nachReise = await page.evaluate(() => today())
ok('Die Zeitreise verschiebt das Datum', vorReise !== nachReise, `${vorReise} → ${nachReise}`)
await click('[data-tr="1"]')
ok('Auch ein einzelner Tag geht', (await page.evaluate(() => CLOCK)) === 9)

// ---------------------------------------------------------------- Speichern
const revVorher = (await state()).rev
ok('Es wurde gespeichert', await page.evaluate(() => !!localStorage.getItem('pcc.sandbox.v1')))
await page.reload()
await wait(700)
const nachLaden = await state()
ok('Der Zugang übersteht das Neuladen', nachLaden.access === 'team')
ok('Die Person übersteht das Neuladen', !!nachLaden.me)
ok('Der Änderungsstand übersteht das Neuladen', nachLaden.rev >= revVorher,
  `${revVorher} → ${nachLaden.rev}`)
ok('Die angelegte Aufgabe ist noch da', await page.evaluate(() =>
  PROJECTS.some((p) => p.tasks.some((t) => t.title.startsWith('Prüfaufgabe')))))
ok('Die angehängte Datei ist noch da', await page.evaluate(() =>
  PROJECTS.some((p) => p.docs.some((d) => d.title === 'Prüfdatei'))))

/* Kennungen werden fortlaufend vergeben. Nach dem Neuladen stand der Zähler
   wieder auf dem Stand der Demodaten — die nächste Aufgabe bekam eine Kennung,
   die es schon gab. Verwerfen traf dann zwei Einträge auf einmal. */
const kennungen = await page.evaluate(() => {
  const alle = []
  PROJECTS.forEach((p) => ['tasks', 'risks', 'issues', 'ms', 'decisions', 'ws', 'docs']
    .forEach((k) => (p[k] || []).forEach((o) => alle.push(o.id))))
  PROJECTS.forEach((p) => alle.push(p.id))
  return { anzahl: alle.length, doppelt: alle.filter((x, i) => alle.indexOf(x) !== i) }
})
ok('Nach dem Neuladen ist jede Kennung eindeutig', kennungen.doppelt.length === 0,
  `${kennungen.anzahl} Kennungen, doppelt: ${kennungen.doppelt.join(', ')}`)
const frischeKennung = await page.evaluate(() => {
  const p = PROJECTS[0]
  const vorhanden = new Set()
  PROJECTS.forEach((q) => ['tasks', 'risks', 'issues', 'ms', 'decisions', 'ws', 'docs']
    .forEach((k) => (q[k] || []).forEach((o) => vorhanden.add(o.id))))
  const neu = mkTask(p, { title: 'Kennungsprobe' })
  const frei = !vorhanden.has(neu.id)
  p.tasks = p.tasks.filter((t) => t !== neu)
  return { id: neu.id, frei }
})
ok('Eine neu angelegte Aufgabe bekommt eine freie Kennung', frischeKennung.frei,
  `vergeben: ${frischeKennung.id}`)

// ------------------------------------------------------- Pflegedialoge
// Alles, was ein Team im Alltag ändert: Stand, Abschluss, Meilensteine,
// Teilprojekte, Entscheidungen, Team, Personen, Verwerfen, Archiv.
await frei()
await page.evaluate(() => { pProject = null; pv = 'projects'; render() })
await wait(300)
await click('[data-pp]', 'Projekt für die Pflegedialoge öffnen')
await click('[data-ptab="tasks"]')

// Aufgabe bearbeiten: Fortschritt außerhalb 0–100 wird abgewiesen.
// Gewählt wird eine Aufgabe ohne Teilaufgaben — bei zerlegten Aufgaben ist der
// Fortschritt abgeleitet und das Feld deshalb gesperrt.
const ohneKinder = await page.evaluate(() => {
  const p = pById(pProject)
  const x = p.tasks.find((t) => !t.parent && !pKids(p, t).length)
  return x ? x.id : null
})
if (ohneKinder && await click(`[data-ptedit="${ohneKinder}"]`, 'Aufgabe bearbeiten öffnen')) {
  const id = await page.evaluate(() => dlg && dlg.cfg.title.split(' · ')[0])
  await page.selectOption('[data-f="status"]', 'in_progress')
  await page.fill('[data-f="progress"]', '200')
  await click('#mOk')
  ok('Ein Fortschritt über 100 wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="progress"]', '50')
  await click('#mOk', 'Aufgabe speichern')
  ok('Die Aufgabe trägt den neuen Stand', await page.evaluate((ref) =>
    pById(pProject).tasks.some((x) => x.ref === ref && x.progress === 50 && x.status === 'in_progress'), id))
}
// Erledigt über den Dialog setzt Fortschritt und Datum
if (await click('[data-ptedit]')) {
  const id = await page.evaluate(() => dlg.cfg.title.split(' · ')[0])
  await page.selectOption('[data-f="status"]', 'completed')
  await click('#mOk')
  ok('Erledigt im Dialog setzt 100 % und ein Datum', await page.evaluate((ref) => {
    const x = pById(pProject).tasks.find((y) => y.ref === ref)
    return x && x.progress === 100 && !!x.done
  }, id))
}

// -------------------------------------------------------- Teilaufgaben
// Eine Aufgabe in Schritte zerlegen, die verschiedene Personen übernehmen.
await frei()
await click('[data-ptab="tasks"]')
const eltern = await page.evaluate(() => {
  const p = pById(pProject)
  const x = p.tasks.find((t) => !t.parent && !pKids(p, t).length && !pTaskDone(t))
  return x ? { id: x.id, ref: x.ref, ws: x.ws, prio: x.prio } : null
})
ok('Es gibt eine Aufgabe zum Zerlegen', !!eltern)
if (eltern) {
  const vorher = await page.evaluate(() => pById(pProject).tasks.length)
  ok('Hauptaufgaben tragen einen Knopf für Teilaufgaben', !!(await $(`[data-ptsub="${eltern.id}"]`)))
  await click(`[data-ptsub="${eltern.id}"]`, 'Teilaufgabe anlegen öffnen')
  await click('#mOk')
  ok('Eine Teilaufgabe ohne Titel wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="title"]', 'Prüf-Teilaufgabe eins')
  await page.selectOption('[data-f="status"]', 'completed')
  await click('#mOk', 'Erste Teilaufgabe anlegen')
  ok('Die Teilaufgabe wurde angelegt',
    (await page.evaluate(() => pById(pProject).tasks.length)) === vorher + 1)
  const k1 = await page.evaluate((pid) => {
    const p = pById(pProject)
    const k = p.tasks.find((t) => t.parent === pid)
    return k ? { ws: k.ws, prio: k.prio, progress: k.progress, done: !!k.done } : null
  }, eltern.id)
  ok('Sie erbt Teilprojekt und Priorität der Aufgabe',
    !!k1 && k1.ws === eltern.ws && k1.prio === eltern.prio, JSON.stringify(k1))
  ok('Erledigt angelegt heißt 100 % und ein Datum', !!k1 && k1.progress === 100 && k1.done)
  ok('Die Teilaufgabe steht eingerückt in der Liste', await page.evaluate(() =>
    !!document.querySelector('tr.sub') || document.getElementById('main').innerText.includes('↳')))

  // Zweite Teilaufgabe, offen: der Fortschritt der Aufgabe ist dann die Hälfte
  await click(`[data-ptsub="${eltern.id}"]`)
  await page.fill('[data-f="title"]', 'Prüf-Teilaufgabe zwei')
  await click('#mOk', 'Zweite Teilaufgabe anlegen')
  ok('Der Fortschritt der Aufgabe kommt aus den Teilaufgaben', await page.evaluate((pid) => {
    const p = pById(pProject)
    return pTaskProgress(p, p.tasks.find((t) => t.id === pid)) === 50
  }, eltern.id))
  const subInfo = await page.evaluate((pid) => {
    const p = pById(pProject)
    const kinder = p.tasks.filter((t) => t.parent === pid)
    return { anzahl: kinder.length,
      mitKnopf: kinder.filter((k) => !!document.querySelector(`[data-ptsub="${k.id}"]`)).map((k) => k.ref),
      refs: kinder.map((k) => k.ref) }
  }, eltern.id)
  ok('Eine Teilaufgabe bekommt selbst keine Teilaufgabe', subInfo.mitKnopf.length === 0,
    JSON.stringify(subInfo))
  // Das Fortschrittsfeld der zerlegten Aufgabe ist gesperrt
  await click(`[data-ptedit="${eltern.id}"]`, 'Zerlegte Aufgabe bearbeiten')
  ok('Der Fortschritt lässt sich dort nicht von Hand setzen',
    await page.evaluate(() => { const el = document.querySelector('[data-f="progress"]'); return !!el && el.disabled }))
  await click('#mCancel')
  // Verwerfen nimmt die Teilaufgaben mit
  const vorDisc = await page.evaluate((pid) => {
    const p = pById(pProject)
    return { gesamt: p.tasks.length, kinder: p.tasks.filter((t) => t.parent === pid).length }
  }, eltern.id)
  await click(`[data-pdisc="task|${eltern.id}"]`, 'Zerlegte Aufgabe verwerfen')
  await click('#mOk')
  const nachDisc = await page.evaluate(() => pById(pProject).tasks.length)
  ok('Verwerfen nimmt genau die Aufgabe und ihre Teilaufgaben mit',
    nachDisc === vorDisc.gesamt - (1 + vorDisc.kinder),
    `${vorDisc.gesamt} (davon ${vorDisc.kinder} Teilaufgaben) → ${nachDisc}`)
}

// Risiko schließen
await click('[data-ptab="risks"]')
if (await click('[data-predit]', 'Risiko bearbeiten öffnen')) {
  const id = await page.evaluate(() => dlg.cfg.title.split(' · ')[0])
  await page.selectOption('[data-f="status"]', 'closed')
  await click('#mOk', 'Risiko speichern')
  ok('Das Risiko ist geschlossen', await page.evaluate((ref) =>
    pById(pProject).risks.some((r) => r.ref === ref && r.status === 'closed'), id))
}

// Problem lösen: ohne Lösung kein Abschluss
await click('[data-ptab="issues"]')
if (await click('[data-piedit]', 'Problem bearbeiten öffnen')) {
  const id = await page.evaluate(() => dlg.cfg.title.split(' · ')[0])
  await page.selectOption('[data-f="status"]', 'resolved')
  await wait(200)
  await page.fill('[data-f="resolution"]', '')
  await click('#mOk')
  ok('Gelöst ohne Lösungstext wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="resolution"]', 'Im Funktionstest gelöst.')
  await click('#mOk', 'Problem speichern')
  ok('Das Problem ist gelöst und trägt die Lösung', await page.evaluate((ref) =>
    pById(pProject).issues.some((i) => i.ref === ref && i.status === 'resolved' && i.resolution.length > 5), id))
}

// Meilenstein anlegen und bearbeiten
await click('[data-ptab="timeline"]')
const vorMs = await page.evaluate(() => pById(pProject).ms.length)
if (await click('[data-pmsnew]', 'Meilenstein anlegen öffnen')) {
  await page.fill('[data-f="name"]', 'Prüfmeilenstein')
  await page.fill('[data-f="date"]', '')
  await click('#mOk')
  ok('Ein Meilenstein ohne Datum wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="date"]', '2026-12-15')
  await click('#mOk', 'Meilenstein anlegen')
  ok('Der Meilenstein wurde angelegt', (await page.evaluate(() => pById(pProject).ms.length)) === vorMs + 1)
}
if (await click('[data-pmsedit]', 'Meilenstein bearbeiten öffnen')) {
  await page.selectOption('[data-f="status"]', 'completed')
  await click('#mOk', 'Meilenstein speichern')
  ok('Der Meilenstein ist abgeschlossen', await page.evaluate(() =>
    pById(pProject).ms.some((m) => m.status === 'completed')))
}

// Teilprojekt: doppelter Name wird abgewiesen
const vorWs = await page.evaluate(() => pById(pProject).ws.length)
const ersterWs = await page.evaluate(() => pById(pProject).ws[0] && pById(pProject).ws[0].name)
if (await click('[data-pwsnew]', 'Teilprojekt anlegen öffnen')) {
  if (ersterWs) {
    await page.fill('[data-f="name"]', ersterWs)
    await click('#mOk')
    ok('Ein doppelter Teilprojektname wird abgewiesen', await page.evaluate(() => !!dlg))
  }
  await page.fill('[data-f="name"]', 'Prüf-Teilprojekt')
  await click('#mOk', 'Teilprojekt anlegen')
  ok('Das Teilprojekt wurde angelegt', (await page.evaluate(() => pById(pProject).ws.length)) === vorWs + 1)
  ok('Das Teilprojekt steht im Gantt', await page.evaluate(() =>
    document.getElementById('main').innerText.includes('Prüf-Teilprojekt')))
}
if (await click('[data-pwsedit]', 'Teilprojekt bearbeiten öffnen')) await click('#mCancel')

// Entscheidung
await click('[data-ptab="decisions"]')
const vorDec = await page.evaluate(() => pById(pProject).decisions.length)
if (await click('[data-pdecnew]', 'Entscheidung öffnen')) {
  await page.fill('[data-f="topic"]', 'Prüfentscheidung')
  await click('#mOk')
  ok('Eine Entscheidung ohne Text wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="decision"]', 'Wir prüfen automatisch vor jeder Version.')
  await click('#mOk', 'Entscheidung festhalten')
  ok('Die Entscheidung ist festgehalten',
    (await page.evaluate(() => pById(pProject).decisions.length)) === vorDec + 1)
}

// Team und Personen
await click('[data-ptab="team"]')
const vorTeam = await page.evaluate(() => pById(pProject).team.length)
if (await click('[data-ptmadd]', 'Mitglied aufnehmen öffnen')) {
  await click('#mOk')
  ok('Ein Mitglied ohne Rolle wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="role"]', 'Prüfrolle')
  await click('#mOk', 'Mitglied aufnehmen')
  ok('Das Mitglied ist im Team', (await page.evaluate(() => pById(pProject).team.length)) === vorTeam + 1)
}
const letzterRm = (await page.$$('[data-ptmrm]:visible')).pop()
if (letzterRm) {
  await letzterRm.click(); await wait(250)
  ok('Entfernen fragt nach', await page.evaluate(() => !!dlg))
  await click('#mOk', 'Entfernen bestätigen')
  ok('Das Mitglied ist wieder draußen', (await page.evaluate(() => pById(pProject).team.length)) === vorTeam)
}
const vorPersonen = await page.evaluate(() => USERS.length)
if (await click('#pperson', 'Person anlegen öffnen')) {
  await page.fill('[data-f="name"]', 'Einname')
  await click('#mOk')
  ok('Ein Name ohne Nachname wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="name"]', 'Prüf Person')
  await page.fill('[data-f="email"]', 'kein-mail')
  await click('#mOk')
  ok('Eine ungültige E-Mail wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="email"]', '')
  await click('#mOk', 'Person anlegen')
  ok('Die Person ist im Verzeichnis', (await page.evaluate(() => USERS.length)) === vorPersonen + 1)
  ok('Die Person hat eine abgeleitete Adresse', await page.evaluate(() =>
    /@/.test((USERS.find((u) => u.name === 'Prüf Person') || {}).email || '')))
}

// Eingaben werden nie als HTML ausgeführt
await click('[data-ptab="tasks"]')
const giftig = '<img src=x onerror="window.__xss=1"> Prüf'
if (await click('#pnewtask', 'Aufgabe mit HTML im Titel')) {
  await page.fill('[data-f="title"]', giftig)
  await click('#mOk')
  await wait(300)
  ok('HTML im Titel wird nicht ausgeführt', await page.evaluate(() => window.__xss === undefined))
  ok('HTML im Titel erscheint als Text', await page.evaluate(() =>
    document.getElementById('main').innerText.includes('<img src=x')))
  await click('[data-v="dash"]'); await wait(200)
  await page.fill('#gq', 'onerror'); await wait(400)
  ok('Auch die Suche zeigt HTML nur als Text', await page.evaluate(() => window.__xss === undefined))
  await frei()
  await click('[data-v="projects"]'); await click('[data-pp]'); await click('[data-ptab="tasks"]')
}

// Verwerfen: mit Rückfrage, samt Verbindungen
const giftId = await page.evaluate(() =>
  (pById(pProject).tasks.find((x) => x.title.includes('onerror')) || {}).id)
if (giftId) {
  const vorT = await page.evaluate(() => pById(pProject).tasks.length)
  await click(`[data-pdisc="task|${giftId}"]`, 'Aufgabe verwerfen')
  ok('Verwerfen fragt nach', await page.evaluate(() => !!dlg))
  await click('#mCancel')
  ok('Abbrechen behält die Aufgabe', (await page.evaluate(() => pById(pProject).tasks.length)) === vorT)
  await click(`[data-pdisc="task|${giftId}"]`)
  await click('#mOk', 'Verwerfen bestätigen')
  ok('Die Aufgabe ist verworfen', (await page.evaluate(() => pById(pProject).tasks.length)) === vorT - 1)
  ok('Keine Verbindung zeigt mehr auf sie', await page.evaluate((id) =>
    !(pById(pProject).links || []).some((l) => l.from === id || l.to === id), giftId))
}

// Archiv: Grund nötig, danach schreibgeschützt, wieder zu öffnen
const archKey = await page.evaluate(() => pById(pProject).key)
if (await click('#parchive', 'Archivieren öffnen')) {
  await click('#mOk')
  ok('Archivieren ohne Grund wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.fill('[data-f="reason"]', 'Funktionstest: Archiv prüfen')
  await click('#mOk', 'Archivieren')
  ok('Das Projekt ist archiviert', await page.evaluate((k) =>
    PROJECTS.find((p) => p.key === k).archived === true, archKey))
  ok('Archiviert schließt die Akte', (await state()).project === null)
  await click('[data-v="projects"]')
  ok('Archivierte sind standardmäßig ausgeblendet', await page.evaluate((k) =>
    !document.getElementById('main').innerText.includes(k), archKey))
  const schalter = await $('#parch')
  ok('Es gibt einen Schalter für Archivierte', !!schalter)
  if (schalter) {
    await schalter.click(); await wait(250)
    ok('Mit Schalter erscheint das Archivierte', await page.evaluate((k) =>
      document.getElementById('main').innerText.includes(k), archKey))
  }
  await page.evaluate((k) => { pProject = PROJECTS.find((p) => p.key === k).id; render() }, archKey)
  await wait(250)
  ok('Ein archiviertes Projekt ist schreibgeschützt', await page.evaluate(() => pCanEdit(pById(pProject)) === false))
  ok('Der Weg zurück ist da', !!(await $('#punarchive')))
  await click('#punarchive', 'Wieder öffnen')
  await click('#mOk', 'Wieder öffnen bestätigen')
  ok('Das Projekt ist wieder offen', await page.evaluate((k) =>
    PROJECTS.find((p) => p.key === k).archived === false, archKey))
  await page.evaluate(() => { PF.archived = false })
}

// Datensicherung
await frei()
await page.evaluate(() => { pProject = null; pv = 'reports'; render() })
await wait(300)
ok('Der Zeitstand wird nicht mitgespeichert', await page.evaluate(() => !('clock' in storeSnapshot())))
if (await click('#bkexport', 'Datensicherung herunterladen')) await wait(600)
const sicherung = await page.evaluate(() => JSON.stringify(Object.assign(
  { kind: 'pcc-backup', app: APP_VERSION, people: USERS.filter((u) => u.added), files: {} }, storeSnapshot())))
const vorImport = await state()
if (await click('#bkimport', 'Datensicherung einspielen öffnen')) {
  await click('#mOk')
  ok('Einspielen ohne Datei wird abgewiesen', await page.evaluate(() => !!dlg))
  await page.setInputFiles('[data-ff="file"]', { name: 'kaputt.json', mimeType: 'application/json', buffer: Buffer.from('{"kind":"x"}') })
  await click('#mOk')
  await wait(300)
  ok('Eine fremde Datei wird abgewiesen', (await state()).projekte === vorImport.projekte)
  await frei()
  await click('#bkimport')
  await page.setInputFiles('[data-ff="file"]', { name: 'halb.json', mimeType: 'application/json',
    buffer: Buffer.from('{"kind":"pcc-backup","projects":[{"id":"x","key":"X"}]}') })
  await click('#mOk')
  await wait(300)
  ok('Eine Sicherung mit kaputtem Projekt wird abgewiesen', (await state()).projekte === vorImport.projekte)
  ok('Die Anzeige steht danach noch', await page.evaluate(() => document.getElementById('main').innerText.trim().length > 60))
  await frei()
  await click('#bkimport')
  await page.setInputFiles('[data-ff="file"]', { name: 'sicherung.json', mimeType: 'application/json', buffer: Buffer.from(sicherung) })
  await click('#mOk', 'Sicherung einspielen')
  await wait(500)
  ok('Die Sicherung ist eingespielt', (await state()).projekte === vorImport.projekte)
}

// ------------------------------------------------------------- Zurücksetzen
await frei()
await click('#sbReset', 'Sandbox zurücksetzen')
ok('Zurücksetzen fragt nach', await page.evaluate(() => !!dlg))
await click('#mCancel')
ok('Abbrechen behält den Speicher', await page.evaluate(() => !!localStorage.getItem('pcc.sandbox.v1')))
await click('#sbReset')
await Promise.all([page.waitForNavigation({ waitUntil: 'load' }).catch(() => {}), click('#mOk', 'Zurücksetzen bestätigen')])
await wait(800)
ok('Zurücksetzen leert den Speicher', await page.evaluate(() =>
  !localStorage.getItem('pcc.sandbox.v1')))
ok('Nach dem Zurücksetzen steht die Anmeldung', (await page.$$('[data-access]')).length === 2)

// ------------------------------------------------------------- Lesezugang
await click('[data-access="viewer"]', 'Lesezugang wählbar')
await wait(400)
ok('Lesezugang ist angemeldet', (await state()).access === 'viewer')
await click('[data-v="projects"]')
await click('[data-pp]', 'Projekt im Lesezugang öffnen')
const lese = await page.evaluate(() => ({
  neu: !!document.getElementById('pnew'),
  aufgabe: !!document.getElementById('pnewtask'),
  risiko: !!document.getElementById('pnewrisk'),
  problem: !!document.getElementById('pnewissue'),
  upload: document.querySelectorAll('[data-pup]').length,
  erledigt: document.querySelectorAll('[data-ptdone]').length,
  bearbeiten: !!document.getElementById('pedit'),
  // Im Projektkopf heißen die Ausgabeknöpfe data-prep, in den Listen data-exp.
  ausgaben: document.querySelectorAll('[data-exp],[data-prep]').length
}))
ok('Lesezugang legt kein Projekt an', !lese.neu)
ok('Lesezugang legt keine Aufgabe an', !lese.aufgabe)
ok('Lesezugang legt kein Risiko an', !lese.risiko)
ok('Lesezugang meldet kein Problem', !lese.problem)
ok('Lesezugang hängt keine Datei an', lese.upload === 0)
ok('Lesezugang erledigt nichts', lese.erledigt === 0)
ok('Lesezugang bearbeitet kein Projekt', !lese.bearbeiten)
ok('Lesezugang darf ausgeben', lese.ausgaben > 0)
// Und auch nicht über den Umweg der Konsole, wenn die Oberfläche es anbietet
ok('Lesezugang hat kein Schreibrecht', await page.evaluate(() => pCanEdit(pById(pProject)) === false))

// alle Reiter auch im Lesezugang
for (const tab of tabs) {
  const el = await $(`[data-ptab="${tab}"]`)
  if (!el) continue
  await el.click()
  await wait(200)
  const text = await page.evaluate(() => document.getElementById('main').innerText.trim().length)
  ok(`Lesezugang: Reiter ${tab} zeigt Inhalt`, text > 60)
}

// ------------------------------------------------- Weitere Wege im Teamzugang
await frei()
await page.evaluate(() => { ACCESS = 'team'; me = 'u1'; pProject = null; pv = 'dash'; render() })
await wait(400)

// Projekt anlegen: Pflichtfelder, Schlüsselmuster, Doppelvergabe
const vorProjekte = (await state()).projekte
await click('#pnew', 'Neues Projekt öffnen')
await click('#mOk', 'Leeres Projekt absenden')
const fehler = await page.evaluate(() => document.getElementById('mErr').innerText)
ok('Das leere Projekt wird beanstandet', fehler.length > 10)
ok('Es werden mehrere Fehler auf einmal genannt',
  (await page.$$('#mErr li')).length >= 2, fehler.replace(/\n/g, ' | '))
ok('Pflichtfelder sind gekennzeichnet', (await page.$$('.fld .req')).length >= 4)
await page.fill('[data-f="name"]', 'Prüfprojekt aus dem Funktionstest')
await page.fill('[data-f="key"]', 'falsch')
await click('#mOk')
ok('Ein falsches Schlüsselmuster wird abgewiesen',
  (await page.evaluate(() => document.getElementById('mErr').innerText)).length > 5)
await page.fill('[data-f="key"]', 'SIM-26')
await click('#mOk')
ok('Ein doppelter Schlüssel wird abgewiesen',
  (await page.evaluate(() => document.getElementById('mErr').innerText)).includes('bereits'))
await page.fill('[data-f="key"]', 'PRF-27')
await click('#mOk', 'Projekt anlegen')
ok('Das Projekt wurde angelegt', (await state()).projekte === vorProjekte + 1)
ok('Nach dem Anlegen ist es geöffnet', (await state()).project !== null)

// Zurück zur Übersicht
await click('#pback', 'Zurück zur Übersicht')
ok('Zurück schließt die Projektakte', (await state()).project === null)

// Aufgabenliste über alle Projekte: die drei Filter
await click('[data-v="tasks"]')
const alleAufgaben = await page.evaluate(() =>
  document.querySelectorAll('.tblwrap tbody tr').length)
await page.selectOption('#tfstate', 'completed')
await wait(280)
const nurFertig = await page.evaluate(() =>
  document.querySelectorAll('.tblwrap tbody tr').length)
ok('Der Aufgabenstatus filtert', nurFertig !== alleAufgaben, `${alleAufgaben} → ${nurFertig}`)
await page.selectOption('#tfspan', 'late')
await wait(280)
ok('Auch der Zeitraum filtert', await page.evaluate(() => TF.span === 'late'))
const whoOpts = await page.$$eval('#tfwho option', (o) => o.length)
ok('Der Filter kennt die Zuständigen', whoOpts > 2, `${whoOpts} Einträge`)
await click('#pclear', 'Alle Filter zurücksetzen')
ok('Zurücksetzen räumt auch die Aufgabenfilter',
  await page.evaluate(() => TF.state === 'open' && TF.span === ''))

// Risiken: Matrix vorhanden und erklärt
await click('[data-v="risks"]')
const mx = await page.evaluate(() => ({
  zellen: document.querySelectorAll('.rmx td').length,
  achsen: !!document.querySelector('.mxy') && !!document.querySelector('.mxx'),
  zahlen: [...document.querySelectorAll('.rmx td b')].map((b) => b.textContent).join(''),
}))
ok('Die Risikomatrix hat 25 Felder', mx.zellen === 25, `${mx.zellen}`)
ok('Beide Achsen sind benannt', mx.achsen)
ok('Die Matrix zeigt Zahlen', mx.zahlen.length > 0)

// Dashboard: eine Zeile führt ins Projekt
await click('[data-v="dash"]')
if (await click('[data-pp]', 'Dashboardzeile öffnet das Projekt'))
  ok('Der Sprung aus dem Dashboard führt ins Projekt', (await state()).project !== null)
await click('#pback')

// Dokumente öffnen
await click('[data-v="projects"]')
await click('[data-pp]')
await click('[data-ptab="docs"]', 'Dokumentenreiter')
const docBtn = await page.$('[data-pdoc]:visible')
ok('Dokumente lassen sich öffnen', !!docBtn)
if (docBtn) { await docBtn.click(); await wait(400) }

// Kalender — der Knopf des Projekts sitzt im Projektverlauf
await frei()
await click('[data-ptab="timeline"]')
await click('#picsproj', 'Termine dieses Projekts')
await click('#pback')
await click('[data-v="reports"]')
await click('#icsall', 'Alle Termine in den Kalender')
// Projektbericht aus der Berichtsliste
const prep = await page.$('[data-prep^="pdf"]:visible')
ok('Der Projektbericht ist von den Berichten aus erreichbar', !!prep)
if (prep) {
  await prep.click()
  await wait(500)
  ok('Der Projektbericht öffnet sich', await page.evaluate(() =>
    document.getElementById('print').classList.contains('on')))
  ok('Der Projektbericht enthält das Gantt', await page.evaluate(() =>
    !!document.querySelector('#print .pgantt .gbar')))
  ok('Der Projektbericht hat Unterschriftszeilen', await page.evaluate(() =>
    !!document.querySelector('#print .sign')))
  await click('#pClose')
}

// Person und Zugang wechseln
await frei()
await click('#switchPerson', 'Person wechseln')
ok('Der Personenwechsel führt auf die Auswahl', (await page.$$('[data-login]')).length > 1)
await (await page.$$('[data-login]'))[1].click()
await wait(400)
ok('Nach dem Wechsel ist die Anwendung wieder da', !!(await $('.workspace')))
await click('#switchUser', 'Zugang wechseln')
ok('Der Zugangswechsel führt auf die Zugangswahl', (await page.$$('[data-access]')).length === 2)

// ----------------------------------------------------------- Englische Fassung
await click('[data-l="en"]', 'Auf Englisch umstellen')
await click('[data-access="team"]')
await (await page.$$('[data-login]'))[0].click()
await wait(400)
ok('Die Oberfläche steht auf Englisch', await page.evaluate(() => L === 'en'))
await click('[data-v="projects"]')
await click('[data-pp]')
for (const tab of ['overview', 'timeline', 'tasks', 'risks', 'docs']) {
  const el = await $(`[data-ptab="${tab}"]`)
  if (!el) continue
  await el.click()
  await wait(220)
  const raw = await page.evaluate(() =>
    (document.getElementById('main').innerText.match(/\b[a-z]{1,6}_[a-z0-9_]{2,}\b/g) || [])
      .filter((x) => !x.includes('@')))
  ok(`Englisch: Reiter ${tab} ohne rohe Textschlüssel`, raw.length === 0, raw.join(', '))
}
await click('[data-ptab="tasks"]')
await click('#pnewtask', 'Englisch: Aufgabendialog')
const dlgRaw = await page.evaluate(() => {
  const el = document.getElementById('modal')
  return (el.innerText.match(/\b[a-z]{1,6}_[a-z0-9_]{2,}\b/g) || []).filter((x) => !x.includes('@'))
})
ok('Englisch: der Dialog ist übersetzt', dlgRaw.length === 0, dlgRaw.join(', '))
await click('#mCancel')
await click('[data-l="de"]')

// ------------------------------------------------------------ Kleine Breiten
for (const [w, h, name] of [[1024, 768, 'Tablet'], [390, 844, 'Telefon']]) {
  await page.setViewportSize({ width: w, height: h })
  await wait(320)
  await frei()
  await page.evaluate(() => { pProject = null; pv = 'dash'; render() })
  await wait(320)
  const over = await page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok(`${name}: Dashboard ohne Überlauf`, over <= 2, `${over} px`)
  const nav = await page.$$('#mobnav [data-v]')
  ok(`${name}: Navigation erreichbar`, nav.length > 0 || w > 1100)
  await click('[data-v="projects"]')
  const karten = await page.evaluate(() => document.querySelectorAll('.cards .card').length)
  ok(`${name}: Projekte sind bedienbar`, karten > 0 || w > 760, `${karten} Karten`)
  if (await click('[data-pp]', `${name}: Projekt öffnen`)) {
    for (const tab of ['timeline', 'tasks']) {
      const el = await $(`[data-ptab="${tab}"]`)
      if (!el) continue
      await el.click()
      await wait(260)
      const o2 = await page.evaluate(() =>
        document.documentElement.scrollWidth - document.documentElement.clientWidth)
      ok(`${name}: Reiter ${tab} ohne Überlauf`, o2 <= 2, `${o2} px`)
    }
    await click('#pback')
  }
}
await page.setViewportSize({ width: 1440, height: 1000 })

await browser.close()

console.log(`${checks} Prüfungen durchlaufen.`)
if (findings.length) {
  console.error('\n' + findings.join('\n'))
  console.error(`\n${findings.length} Befund(e).`)
  process.exit(1)
}
console.log('Keine Befunde: Knöpfe, Dialoge, Ausgaben, Suche, Speicherung und Rechte tun, was sie sollen.')
