// Prüft die Rechenlogik des Prototyps gegen feste Erwartungen: Risikostufen,
// Referenznummern, Terminnetz und kritischer Pfad, Ampel, Fortschritt,
// Ausgabeschutz, Kalenderdatei, Speicherstand, Wortschatz und Versionsstand.
//
//   node scripts/check-logic.mjs
//
// Der Prototyp ist eine Datei ohne Modulgrenzen; die Funktionen laufen deshalb
// im Browser, in dem sie auch sonst laufen. Jede Prüfung nennt Erwartung und
// Ist-Wert — wer eine Zahl ändert, sieht sofort, welche Regel er verschoben hat.
import { chromium } from 'playwright'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { existsSync, readdirSync, readFileSync } from 'node:fs'

const htmlPath = resolve(process.argv[2] ?? 'sandbox/Control-Center-Sandbox.html')
const html = readFileSync(htmlPath, 'utf8')

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
const eq = (name, got, want) => {
  checks++
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) findings.push(`✗ ${name}: erwartet ${w}, ist ${g}`)
}
const ok = (name, cond, detail = '') => {
  checks++
  if (!cond) findings.push(`✗ ${name}${detail ? ' — ' + detail : ''}`)
}

// ------------------------------------------------------ Dateien im Repo
// Versionsstand: eine Nummer, an vier Stellen. Weichen sie ab, ist die
// Fassung nicht sauber ausgeliefert.
const pkg = JSON.parse(readFileSync('package.json', 'utf8'))
const appVersion = (html.match(/const APP_VERSION = "([^"]+)"/) || [])[1]
eq('Versionsnummer im Prototyp = package.json', appVersion, pkg.version)
ok('Versionsnummer steht im Changelog', readFileSync('docs/CHANGELOG.md', 'utf8').includes(`## ${pkg.version} —`))
ok('Versionsnummer steht im Seed', readFileSync('supabase/seed.sql', 'utf8').includes(`('${pkg.version}',`))

// Wortschatz: jeder benutzte Schlüssel existiert, beide Sprachen sind
// deckungsgleich, kein Schlüssel ist doppelt.
{
  const iDe = html.indexOf('\nde:{'), iEn = html.indexOf('\nen:{', iDe)
  const block = (a, b) => html.slice(a, b)
  const keysOf = (b) => { const c = {}; for (const m of b.matchAll(/^\s{2}([a-z0-9_]+):/gm)) c[m[1]] = (c[m[1]] || 0) + 1; return c }
  const de = keysOf(block(iDe, iEn)), en = keysOf(block(iEn, html.indexOf('\n}', iEn + 5) + 2))
  const used = new Set([...html.matchAll(/\bt\("([a-z0-9_]+)"/g)].map((m) => m[1]))
  const prefixes = [...html.matchAll(/\bt\("([a-z0-9_]+)"\s*\+/g)].map((m) => m[1])
  const missing = [...used].filter((k) => !de[k] && !prefixes.includes(k))
  eq('Alle benutzten Textschlüssel sind auf Deutsch vorhanden', missing, [])
  eq('Englisch kennt jeden deutschen Schlüssel', Object.keys(de).filter((k) => !en[k]), [])
  eq('Deutsch kennt jeden englischen Schlüssel', Object.keys(en).filter((k) => !de[k]), [])
  eq('Kein Schlüssel doppelt (de)', Object.keys(de).filter((k) => de[k] > 1), [])
  eq('Kein Schlüssel doppelt (en)', Object.keys(en).filter((k) => en[k] > 1), [])
  ok('Der Wortschatz ist nicht geschrumpft', Object.keys(de).length >= 430, `${Object.keys(de).length}`)
}

// ------------------------------------------------------ Logik im Browser
const browser = await chromium.launch({ executablePath: findChromium() })
const page = await browser.newPage()
page.on('pageerror', (e) => findings.push(`✗ Laufzeitfehler: ${e.message}`))
await page.goto(pathToFileURL(htmlPath).href)
await page.waitForTimeout(300)
const run = (fn, arg) => page.evaluate(fn, arg)

// Risikostufen: die Grenzen aus der Matrixerklärung
eq('Risikostufen an den Grenzen', await run(() => [1, 4, 5, 9, 10, 14, 15, 25].map(rLevel)),
  [1, 1, 2, 2, 3, 3, 4, 4])
eq('Risikostufe hat vier Klassen', await run(() => [1, 5, 10, 15].map(rLevelCls)), ['l', 'm', 'h', 'x'])

// Referenznummern zählen je Präfix weiter, auch über Lücken
eq('Erste Referenz', await run(() => nextRef([], 'T')), 'T-1')
eq('Referenz nach Lücke', await run(() => nextRef([{ ref: 'T-3' }, { ref: 'T-10' }, { ref: 'R-99' }], 'T')), 'T-11')
eq('Referenz je Präfix', await run(() => nextRef([{ ref: 'T-3' }, { ref: 'R-99' }], 'R')), 'R-100')

// Arbeitstage: Freitag + 1 ist Montag, Montag − 1 ist Freitag
eq('Arbeitstag über das Wochenende', await run(() => addBusinessDays('2026-09-18', 1)), '2026-09-21')
eq('Arbeitstag rückwärts über das Wochenende', await run(() => addBusinessDays('2026-09-21', -1)), '2026-09-18')
eq('Fünf Arbeitstage sind eine Woche', await run(() => addBusinessDays('2026-09-14', 5)), '2026-09-21')

// Terminnetz: Ende-Anfang, Anfang-Anfang, Verzug, Puffer, Kreise. Ein
// Nachfolger darf am Tag beginnen, an dem der Vorgänger endet.
const netz = {
  start: '2026-09-01', end: '2026-09-30', ms: [],
  tasks: [
    { id: 'a', ref: 'T-1', title: 'A', start: '2026-09-01', due: '2026-09-10', status: 'in_progress' },
    { id: 'b', ref: 'T-2', title: 'B', start: '2026-09-10', due: '2026-09-30', status: 'not_started' },
    { id: 'c', ref: 'T-3', title: 'C', start: '2026-09-01', due: '2026-09-05', status: 'not_started' },
    { id: 'd', ref: 'T-4', title: 'D', start: '2026-09-08', due: '2026-09-12', status: 'not_started' },
  ],
  links: [
    { from: 'a', to: 'b', kind: 'fs', lag: 0 },
    { from: 'a', to: 'd', kind: 'fs', lag: 0 },
  ],
}
{
  const s = await run((p) => pSchedule(p), netz)
  eq('A und B sind kritisch', [s.a.critical, s.b.critical], [true, true])
  eq('A hat keinen Puffer', s.a.slack, 0)
  eq('C hat 25 Tage Puffer bis Projektende', s.c.slack, 25)
  ok('C ist nicht kritisch', !s.c.critical)
  eq('Verzug: D beginnt zwei Tage vor dem Ende von A', await run((p) => linkConflict(p, p.links[1]), netz), 2)
  eq('Kein Verzug bei A→B', await run((p) => linkConflict(p, p.links[0]), netz), 0)
  eq('Anfang-Anfang mit Vorlauf', await run((p) => linkEarliest(p, { from: 'a', to: 'c', kind: 'ss', lag: 3 }), netz), '2026-09-04')
  eq('Erreichbarkeit im Netz', await run((p) => [reaches(p, 'a', 'd'), reaches(p, 'd', 'a'), reaches(p, 'c', 'a')], netz),
    [true, false, false])
  eq('Kreis über zwei Kanten wird erkannt', await run((p) => {
    const q = Object.assign({}, p, { links: p.links.concat([{ from: 'd', to: 'a', kind: 'fs', lag: 0 }]) })
    return reaches(q, 'a', 'a') && reaches(q, 'd', 'a')
  }, netz), true)
}

// Ampel: rot ist Leitungsebene, gelb ist Aufmerksamkeit
{
  const heute = await run(() => today())
  const gestern = await run(() => addDays(today(), -1))
  const base = { status: 'on_track', tasks: [], risks: [], ms: [] }
  const h = (p) => run((x) => pHealth(x), Object.assign({}, base, p))
  eq('Abgeschlossen ist grün', await h({ status: 'completed', ms: [{ date: gestern, status: 'planned' }] }), 'green')
  eq('Verzögert ist rot', await h({ status: 'delayed' }), 'red')
  eq('Ein überfälliger Meilenstein ist rot', await h({ ms: [{ date: gestern, status: 'planned' }] }), 'red')
  eq('Ein erledigter Meilenstein in der Vergangenheit ist grün', await h({ ms: [{ date: gestern, status: 'completed' }] }), 'green')
  eq('Ein kritisches Risiko ist gelb', await h({ risks: [{ prob: 5, imp: 3, status: 'open' }] }), 'amber')
  eq('Zwei kritische Risiken sind rot', await h({ risks: [{ prob: 5, imp: 3, status: 'open' }, { prob: 4, imp: 4, status: 'monitoring' }] }), 'red')
  eq('Ein geschlossenes kritisches Risiko zählt nicht', await h({ risks: [{ prob: 5, imp: 5, status: 'closed' }] }), 'green')
  eq('Eine überfällige Aufgabe ist gelb', await h({ tasks: [{ due: gestern, status: 'in_progress' }] }), 'amber')
  eq('Eine heute fällige Aufgabe ist noch nicht überfällig', await h({ tasks: [{ due: heute, status: 'in_progress' }] }), 'green')
  eq('Gefährdet ist gelb', await h({ status: 'at_risk' }), 'amber')
}

// Fortschritt: Erledigtes zählt 100, Abgebrochenes gar nicht
const T = (o) => Object.assign({ id: 'x' + Math.random().toString(36).slice(2), parent: null, progress: 0 }, o)
eq('Fortschritt ohne Aufgaben', await run(() => pProgress({ tasks: [] })), 0)
eq('Fortschritt mittelt über offene und erledigte Aufgaben', await run((ts) => pProgress({ tasks: ts }),
  [T({ status: 'in_progress', progress: 50 }), T({ status: 'completed' }), T({ status: 'cancelled' })]), 75)
eq('Fortschritt rundet', await run((ts) => pProgress({ tasks: ts }), [
  T({ status: 'in_progress', progress: 33 }), T({ status: 'in_progress', progress: 34 }), T({ status: 'not_started' })]), 22)

// Teilaufgaben: eine Aufgabe ist so weit, wie ihre Teile fertig sind
{
  const eltern = T({ id: 'p1', status: 'in_progress', progress: 10 })
  const k1 = T({ id: 'k1', parent: 'p1', status: 'in_progress', progress: 50 })
  const k2 = T({ id: 'k2', parent: 'p1', status: 'completed' })
  const k3 = T({ id: 'k3', parent: 'p1', status: 'cancelled' })
  const proj = { tasks: [eltern, k1, k2, k3] }
  eq('Der Fortschritt kommt aus den Teilaufgaben, nicht aus dem eigenen Wert',
    await run((pr) => pTaskProgress(pr, pr.tasks[0]), proj), 75)
  eq('Abgebrochene Teilaufgaben zählen nicht mit',
    await run((pr) => pTaskProgress(pr, { id: 'p1', status: 'in_progress', progress: 10 }),
      { tasks: [k1, k2] }), 75)
  eq('Eine abgeschlossene Aufgabe steht auf 100, auch mit offener Teilaufgabe',
    await run((pr) => pTaskProgress(pr, pr.tasks[0]),
      { tasks: [T({ id: 'p2', status: 'completed' }), T({ id: 'k4', parent: 'p2', status: 'in_progress', progress: 0 })] }), 100)
  eq('Ohne Teilaufgaben gilt der eigene Wert',
    await run((pr) => pTaskProgress(pr, pr.tasks[0]), { tasks: [T({ status: 'in_progress', progress: 42 })] }), 42)
  eq('Eine Aufgabe ohne Elternteil ist niemals Teilaufgabe einer anderen',
    await run((pr) => pKids(pr, pr.tasks[0]).length, { tasks: [T({ id: 'a' }), T({ id: 'b' })] }), 0)
  // Zerlegte Aufgaben wiegen nicht doppelt: gemittelt wird über die Hauptaufgaben.
  eq('Teilaufgaben zählen im Projektfortschritt nicht doppelt',
    await run((pr) => pProgress(pr), proj), 75)
  eq('Zwei Hauptaufgaben werden gleich gewichtet',
    await run((pr) => pProgress(pr), { tasks: proj.tasks.concat([T({ status: 'not_started' })]) }), 38)
}

// Ausgabeschutz: nichts, was Excel als Formel liest
eq('Formeln werden entschärft', await run(() => ['=SUM(A1)', '+1', '-1', '@cmd', 'Text', '', null].map(tsvSafe)),
  ["'=SUM(A1)", "'+1", "'-1", "'@cmd", 'Text', '', ''])
eq('Tabulator und Zeilenumbruch werden ersetzt', await run(() => tsvSafe('a\tb\nc')), 'a b c')
eq('HTML wird maskiert', await run(() => esc('<b onerror="x">&')), '&lt;b onerror=&quot;x&quot;&gt;&amp;')

// Kalenderdatei: Sonderzeichen maskiert, Zeilenumbrüche entfernt, ein Tag lang
{
  const ics = await run(() => icsText([{ key: 'PRF', ms: [{ id: 'm1', ref: 'M-1', name: 'A, B;\nC', date: '2026-10-05', status: 'planned', owner: null }],
    tasks: [{ id: 't1', ref: 'T-1', title: 'Fertig', due: '2026-10-06', status: 'completed' },
            { id: 't2', ref: 'T-2', title: 'Offen', due: '2026-10-07', status: 'in_progress', assignee: null }] }]))
  const lines = ics.split('\r\n')
  ok('Kalender beginnt und endet korrekt', lines[0] === 'BEGIN:VCALENDAR' && lines[lines.length - 1] === 'END:VCALENDAR')
  eq('Erledigte Aufgaben stehen nicht im Kalender', lines.filter((l) => l === 'BEGIN:VEVENT').length, 2)
  ok('Sonderzeichen sind maskiert', lines.includes('SUMMARY:PRF · M-1 A\\, B\\; C'), lines.find((l) => l.startsWith('SUMMARY:')))
  ok('Kein Zeilenumbruch zerreißt einen Eintrag', !/\n(?!$)/.test(ics.replace(/\r\n/g, '\n').replace(/\n/g, '\r\n').replace(/\r\n/g, '')))
  ok('Ganztägig: Ende ist der Folgetag', lines.includes('DTSTART;VALUE=DATE:20261005') && lines.includes('DTEND;VALUE=DATE:20261006'))
  ok('Einträge sind nach Datum sortiert', ics.indexOf('20261005') < ics.indexOf('20261007'))
}

// Excel-Datei: ein gültiges Zip mit stimmenden Prüfsummen, ein Blatt je
// Abschnitt, Zahlen als Zahlen, Text als Text — auch wenn er wie eine Formel
// aussieht. Die Prüfsumme rechnet der Test selbst, unabhängig von der App.
{
  const b64 = await run(async () => {
    const blob = xlsxBlob({ title: 'Prüf <Titel>', meta: [['Anzahl', 2]], sections: [
      { h: 'A/B: Eins', cols: ['Nr', 'Text'], rows: [[1, '=SUM(A1)'], [2.5, '<img src=x>']] },
      { h: 'A/B: Eins', cols: ['x'], rows: [] }] })
    const u = new Uint8Array(await blob.arrayBuffer()); let s = ''
    for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return btoa(s)
  })
  const buf = Buffer.from(b64, 'base64')
  const tbl = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
  const crc = (b) => { let c = 0xFFFFFFFF; for (const x of b) c = tbl[(c ^ x) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0 }
  ok('Die Excel-Datei beginnt wie ein Zip', buf.readUInt32LE(0) === 0x04034B50)
  const entries = {}; let off = 0, badCrc = 0
  while (buf.readUInt32LE(off) === 0x04034B50) {
    const c = buf.readUInt32LE(off + 14), size = buf.readUInt32LE(off + 18), nl = buf.readUInt16LE(off + 26), xl = buf.readUInt16LE(off + 28)
    const name = buf.toString('utf8', off + 30, off + 30 + nl)
    const data = buf.subarray(off + 30 + nl + xl, off + 30 + nl + xl + size)
    if (crc(data) !== c) badCrc++
    entries[name] = data.toString('utf8'); off += 30 + nl + xl + size
  }
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4B, 5, 6]))
  eq('Alle Prüfsummen stimmen', badCrc, 0)
  eq('Das Inhaltsverzeichnis zählt alle Einträge', buf.readUInt16LE(eocd + 10), Object.keys(entries).length)
  eq('Zentrales Verzeichnis beginnt nach den Daten', buf.readUInt32LE(eocd + 16), off)
  eq('Ein Blatt je Abschnitt', Object.keys(entries).filter((n) => n.startsWith('xl/worksheets/')).length, 2)
  ok('Blattnamen ohne verbotene Zeichen und eindeutig',
    entries['xl/workbook.xml'].includes('name="A B Eins"') && entries['xl/workbook.xml'].includes('name="A B Eins 2"'), entries['xl/workbook.xml'])
  const s1 = entries['xl/worksheets/sheet1.xml']
  ok('Zahlen stehen als Zahlen', s1.includes('<c r="A6"><v>1</v></c>') && s1.includes('<v>2.5</v>'), s1.slice(0, 400))
  ok('Formeln bleiben Text', s1.includes('<t xml:space="preserve">=SUM(A1)</t>') && !s1.includes('<f>'))
  ok('HTML ist im XML maskiert', s1.includes('&lt;img src=x&gt;') && s1.includes('Prüf &lt;Titel&gt;'))
  ok('Titel und Spalten sind fett', s1.includes('<c r="A1" t="inlineStr" s="1"') && s1.includes('<c r="A5" t="inlineStr" s="1"'))
  ok('Der Stand steht in Zeile 2', s1.includes('<c r="A2" t="inlineStr"><is><t xml:space="preserve">Stand</t>'))
  ok('Jede Datei nennt das Blatt im Inhaltstyp', entries['[Content_Types].xml'].includes('/xl/worksheets/sheet2.xml'))
}

// Speicherstand: die Zeitreise wird nie mitgespeichert, die Fassung schon
{
  const snap = await run(() => { CLOCK = 12; const s = storeSnapshot(); CLOCK = 0; return Object.keys(s) })
  ok('Die Zeitreise steht nicht im Speicher', !snap.includes('clock'), snap.join(','))
  ok('Der Speicher kennt Projekte, Verlauf, Personen und Fassung',
    ['projects', 'log', 'people', 'version', 'rev'].every((k) => snap.includes(k)), snap.join(','))
  eq('Die Fassung im Speicher ist die der Anwendung', await run(() => storeSnapshot().version === APP_VERSION), true)
}

// Verlaufstexte: Schlüssel werden übersetzt, alte Freitexte bleiben
eq('Verlaufstext aus Schlüssel', await run(() => evText({ k: 'ev_discard', x: 'T-1' })), 'Verworfen: T-1')
eq('Verlaufstext als Freitext', await run(() => evText('Alt')), 'Alt')
eq('Leerer Verlaufstext', await run(() => evText(null)), '')

// Rechte: ohne Teamzugang wird nichts geschrieben, archiviert auch nicht
eq('Rechte je Zugang', await run(() => {
  const keep = ACCESS; const out = []
  ACCESS = 'viewer'; out.push(pCanEdit({ archived: false }))
  ACCESS = 'team'; out.push(pCanEdit({ archived: false }), pCanEdit({ archived: true }))
  ACCESS = keep; return out
}), [false, true, false])

// Suche: ab zwei Zeichen, findet Projektschlüssel
eq('Suche ignoriert ein Zeichen', await run(() => gSearch('q').length), 0)
ok('Suche findet den Projektschlüssel', (await run(() => gSearch(PROJECTS[0].key).length)) > 0)
ok('Suche findet nichts Erfundenes', (await run(() => gSearch('zzzznichtsda').length)) === 0)

await browser.close()

console.log(`${checks} Logikprüfungen durchlaufen.`)
if (findings.length) {
  console.error('\n' + findings.join('\n'))
  console.error(`\n${findings.length} Befund(e).`)
  process.exit(1)
}
console.log('Keine Befunde: Rechenregeln, Ausgaben, Wortschatz und Versionsstand stimmen.')
