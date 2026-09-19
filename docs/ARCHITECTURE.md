# Project Control Center — Architektur

Stand: 2026-09-18
Bezug: „Project Control Center — Master Development Prompt", Abschnitte 1–64

Dieses Dokument ist die in Abschnitt 62, Phase 1 geforderte Architektur. Es
legt Technologie, Datenmodell, Rechtemodell, Betrieb und Ausbaureihenfolge
fest. Die Datenbank ist danach gebaut; die Oberfläche folgt.

---

## 1. Aufteilung der Anwendung

**Entschieden: ein modularer Monolith, eine Datenbank, ein Login.**

| | Begründung |
|---|---|
| **Ein Login** | Supabase Auth. Ein Konto je Person, ein Sperrvorgang beim Austritt |
| **Zwei Schemas** | `public` trägt Nutzerkonto und Audit-Trail — beides hängt an der Anmeldung, nicht am Fachmodul. `pcc` trägt alles Fachliche. So bleibt die Rechteprüfung an einer Stelle und das Fachmodell frei beweglich |
| **Rechte in der Datenbank** | Row Level Security statt Prüfungen im Anwendungscode. Was die Oberfläche nicht zeigt, gibt auch die API nicht heraus |

Wer keine Rolle hat, sieht nichts: `users.role` darf NULL sein, und eine
NULL-Rolle lässt keine einzige Policy greifen.

---

## 2. Technologiestack

| Schicht | Wahl | Begründung |
|---|---|---|
| Frontend | React 19 + TypeScript + Vite | Bereits im Repository, komponentenbasiert, typsicher |
| PWA | `vite-plugin-pwa` (Workbox) | Manifest, Service Worker, Auto-Update, Offline-Shell |
| Zustand | TanStack Query + Supabase Realtime — **vorgesehen, noch nicht eingebaut** | Cache, Hintergrundaktualisierung, Konfliktbehandlung |
| Oberfläche | eigene Komponenten auf den AAA-Design-Tokens | Kein UI-Framework: die Tokens stehen, der Look ist gesetzt |
| Backend | Supabase (PostgreSQL, Auth, Realtime, Storage, Edge Functions) | Postgres mit RLS erzwingt Rechte **serverseitig** — Abschnitt 43 |
| Geschäftslogik | PostgreSQL-Funktionen und Trigger | Regeln, die in der Datenbank stehen, sind über die API nicht umgehbar |
| Hosting | Vercel oder Cloudflare Pages | HTTPS, globales CDN, Vorschau je Branch, Bereitstellung per Push |
| Dateien | Supabase Storage plus externe Verweise | Abschnitt 27: SharePoint- und OneDrive-Links ohne Kopie |

**Bewusst nicht gewählt:** Microservices (Abschnitt 56 verlangt selbst einen
modularen Monolithen), eigener Node-Server (verschöbe Rechteprüfung in
Anwendungscode statt in die Datenbank), Firebase (kein relationales Modell,
Abschnitt 42 verlangt Relationen).

**Kosten:** Supabase Pro rund 25 USD im Monat je Projekt inklusive täglicher
Backups und Point-in-Time-Recovery; Vercel Hobby genügt anfangs, Pro rund
20 USD. Der freie Supabase-Tarif pausiert nach einer Woche Inaktivität und
sichert nicht täglich — für ein System mit Auditpflicht untauglich.

---

## 3. Datenmodell

Schema `pcc`. Die Fachtabellen tragen `id uuid`, `created_at`, `created_by`,
`updated_at`, `updated_by`. Verknüpfungstabellen (`project_members`, `mentions`,
`raci`, `ref_counters`) und die anhängenden Tabellen (`comments`,
`notifications`, `version_changes`) kommen mit weniger aus — dort wäre eine
eigene Herkunftsspalte Ballast.

### Kern

```
projects        key, name, description, objectives, scope, status,
                pm_user_id, sponsor_user_id, start_date, target_end_date,
                actual_end_date, progress_mode (manual | derived),
                progress_manual, version_major, version_minor,
                archived_at, archived_by, template_id
                (health und progress sind gerechnet, keine Spalten)
project_members project_id, user_id, project_role, responsibilities
workstreams     project_id, name, description, owner_user_id, sort_order
tasks           project_id, workstream_id, parent_task_id, ref (T-1042),
                title, description, assignee_user_id, priority, status,
                start_date, due_date, completed_at, progress,
                progress_mode (manual | derived)
milestones      project_id, workstream_id, ref, name, description, due_date,
                baseline_date, owner_user_id, status,
                depends_on_milestone_id, completed_at, notes
risks           project_id, ref, title, description, category,
                probability (1-5), impact (1-5),
                score int GENERATED ALWAYS AS (probability * impact) STORED,
                owner_user_id, mitigation, contingency, due_date, status
issues          project_id, ref, title, description, owner_user_id,
                priority, status, due_date, resolution
decisions       project_id, ref, decided_on, topic, decision, maker_user_id,
                participants uuid[], rationale, impact, task_id
documents       project_id, entity_type, entity_id, title, description,
                kind (file | link), storage_path, external_url, mime_type,
                size_bytes, scan_state (pending | clean | infected),
                version, supersedes_id, owner_user_id, deleted_*
raci            project_id, subject_type (workstream|task|milestone),
                subject_id, user_id, letter (R|A|C|I)
comments        entity_type, entity_id, user_id, body, edited_at
mentions        comment_id, user_id
notifications   user_id, project_id, kind, entity_type, entity_id,
                title, body, read_at, email_state
project_versions project_id, version (1.4), summary, created_by, created_at
version_changes  version_id, entity_type, entity_id, field, old_value, new_value
templates       name, description, payload jsonb
```

### An der Anmeldung, nicht am Fachmodul

```
public.users     id (= auth.users.id), name, email, role, active, pending,
                 language, approved_at, approved_by, registered_at
public.audit_log user_id, project_id, entity, entity_id, action,
                 old_value, new_value, reason, created_at
```

### Bewusste Festlegungen

1. **Risk Score als generierte Spalte** — nie im Anwendungscode gerechnet,
   damit Filter und Sortierung serverseitig funktionieren und kein Client
   eine abweichende Zahl schreiben kann (Abschnitt 24).
2. **Fortschritt wahlweise gerechnet oder gesetzt** (`progress_mode`).
   Abschnitt 21 will den Elternfortschritt optional aus Subtasks ableiten —
   „optional" heißt: je Aufgabe entscheidbar, nicht global.
3. **Verwerfen statt Löschen** — `archived_at` (Abschnitt 41). Endgültiges
   Löschen ausschließlich über den Teamzugang, mit einer Funktion und
   Audit-Eintrag.
4. **Referenznummern** (`T-1042`, `R-14`) je Projekt aus einer Sequenz, damit
   Menschen im Gespräch darauf zeigen können.
5. **RACI als eigene Tabelle**, nicht als Feld an der Aufgabe: eine Aufgabe
   hat genau ein A, aber beliebig viele C und I (Abschnitt 19).

---

## 4. Rechte (Abschnitt 5)

Serverseitig durch Row Level Security. Kein einziger Rechtecheck verlässt
sich auf das Frontend (Abschnitt 43).

> **Entschieden am 19.09.2026:** Es gibt **zwei Zugänge**, und beide werden
> gemeinsam benutzt. Der frühere Aufbau mit fünf Rollen und einem
> Freigabeverfahren je Person ist damit hinfällig.

| Zugang | Darf |
|---|---|
| **Teamzugang** (`team`) | alles: Projekte anlegen, ändern, archivieren, endgültig löschen, Dateien ablegen, Personen pflegen, Einstellungen, Versionen freigeben, Schwärzung nach Artikel 17 |
| **Lesezugang** (`viewer`) | alles sehen und ausgeben — und sonst nichts |

Umsetzung je Tabelle über drei Hilfsfunktionen:

```sql
pcc.can_read(project_id)         -- beide Zugänge, auch archivierte Projekte
pcc.can_edit(project_id)         -- nur der Teamzugang, nicht im Archiv
pcc.can_contribute(project_id)   -- gleichbedeutend; der Name bleibt für Policies und Storage
```

### Personen und Zugänge sind zweierlei

Ein Projektsteuerungswerkzeug ohne Zuständigkeiten wäre wertlos. Weil aber nur
zwei Anmeldungen existieren, trennt das Modell beides:

- **`public.users` ist das Personenverzeichnis.** Zuständigkeit, Verantwortung,
  RACI, Eigentum an Dokumenten und Erwähnungen zeigen darauf. Die meisten
  dieser Zeilen haben **keine** Anmeldung.
- **Genau zwei Zeilen tragen einen Zugang** (`auth_user_id` und `role`). Ein
  partieller Unique-Index (`users_one_account_per_role`) lässt keinen dritten
  zu — auch nicht bei einem direkten Eingriff in der Datenbank.
- Die Zugänge werden mit `pcc.prepare_account(adresse, rolle)` vorbereitet und
  verbinden sich selbst, sobald der Betreiber in Supabase ein Anmeldekonto mit
  derselben Adresse anlegt. Eine Anmeldung ohne vorbereiteten Zugang läuft ins
  Leere: ohne Rolle greift keine einzige Policy.
- Ein Guard hält Rolle und `auth_user_id` über die Anwendung unveränderlich.
  Sonst wäre aus dem Lesezugang in zwei Zügen ein zweiter Vollzugang geworden.

### Wer war es? Was ein gemeinsamer Zugang kostet

Das muss ausgesprochen sein: **Mit einem gemeinsam benutzten Zugang lässt sich
nicht mehr beweisen, welcher Mensch eine Änderung vorgenommen hat.** Der
Audit-Trail hält deshalb zweierlei auseinander:

| Spalte | Bedeutung | Belastbarkeit |
|---|---|---|
| `audit_log.user_id` | der angemeldete Zugang | beweiskräftig |
| `audit_log.actor_id` | die Person, zu der sich die Oberfläche bekannt hat | Angabe, kein Nachweis |

Beim Anmelden am Teamzugang wählt man sich aus dem Verzeichnis; diese Angabe
wandert in `created_by`/`updated_by` und von dort in den Trail. Ein Trigger
lässt nur eine **aktive Person aus dem Verzeichnis** durch — eine erfundene
Kennung fällt auf den Zugang zurück. Fachlich ist das brauchbar
("Marion hat die Aufgabe geschlossen"); als Nachweis gegenüber einer Behörde
ist es das nicht.

Wer diese Beweiskraft braucht, braucht eigene Anmeldungen je Person. Der Weg
dorthin bliebe klein: `public.users` trägt schon `auth_user_id`, es müssten nur
weitere Zeilen eine Rolle bekommen und der Unique-Index fallen.

### Sichtbarkeit von Projekten

**Entschieden am 19.09.2026:** Beide Zugänge lesen jedes Projekt, auch ein
archiviertes. Ein Management-Dashboard mit Löchern wäre wertlos, und eine
Abstufung nach Projektmitgliedschaft beschriebe Rechte, die es mit zwei
gemeinsam benutzten Zugängen nicht gibt.

### Gantt je Projekt (Auftrag vom 19.09.2026)

Die Zeitachse eines Projekts beantwortet zwei verschiedene Fragen, und sie
brauchen zwei verschiedene Bilder:

| Ebene | Bild | Wo |
|---|---|---|
| über alle Projekte | ein Balken je Projekt, Meilensteine als Punkte | Dashboard, Reiter „Projektverlauf" |
| innerhalb eines Projekts | **Gantt**: Teilprojekte als Klammer, darunter Aufgaben und Teilaufgaben, dazu die Meilensteine | Projektakte, Reiter „Projektverlauf" |

Die Zeilen liefert die Sicht `pcc.v_gantt` — eine Zeile je Balken, mit `kind`
(`workstream`, `task`, `milestone`), `depth` (0 Teilprojekt, 1 Aufgabe oder
Meilenstein, 2 Teilaufgabe) und `parent_id`. Zwei Ableitungen macht die
Datenbank, damit sie nicht je Oberfläche anders ausfallen:

- **Ein Teilprojekt trägt keine eigenen Termine.** Beginn und Ende ergeben sich
  aus der frühesten und spätesten Aufgabe darin; `open_count` zählt, was davon
  offen ist.
- **Der Fortschritt eines Teilprojekts** ist der Mittelwert seiner *obersten*
  Aufgaben — Teilaufgaben zählen über ihr Elternteil mit, sonst hätte eine
  Aufgabe mit fünf Teilaufgaben das fünffache Gewicht. Erledigtes und
  Abgebrochenes zählt als 100 Prozent, unabhängig vom gepflegten Wert.

Was die Darstellung **nicht** tut: eine Dauer erfinden. Eine Aufgabe ohne
Termin wird als solche ausgewiesen statt mit einem Balken versehen.

### Abhängigkeiten und kritischer Pfad (19.09.2026)

`pcc.task_dependencies` hält fest, was auf was wartet — in zwei Arten:
`finish_start` („erst wenn das fertig ist") und `start_start` („beides zugleich
beginnen"), jeweils mit Vorlaufzeit in `lag_days`. Ende-Ende und Anfang-Ende
fehlen bewusst: sie kommen im Trainingsbetrieb nicht vor und wären nur eine
Quelle für Fehleingaben.

Zwei Riegel sichern die Angaben ab, beide im Trigger `pcc.tg_task_dep_guard()`:
Eine Verbindung bleibt im Projekt, und sie schließt keinen Kreis. Ein Kreis wäre
kein Plan mehr, sondern eine Behauptung, die sich nicht auflösen lässt — und
jede Terminrechnung liefe endlos.

Daraus folgen zwei Auswertungen:

| Was | Wo | Aussage |
|---|---|---|
| **Widerspruch** | `pcc.v_task_links` | Der Nachfolger beginnt früher, als die Verbindung erlaubt — mit der Zahl der Tage |
| **Puffer und kritischer Pfad** | `pcc.critical_path(projekt)` | Rückwärts vom Zieltermin: wie viel Luft hat eine Aufgabe, bevor sie das Projektende verschiebt? Ohne Luft ist sie kritisch |

Die Rückwärtsrechnung sammelt je Weg einen Kandidaten und nimmt außen den
frühesten — die übliche Rückwärtsrechnung, nur in SQL. Der Prototyp rechnet
dasselbe in JavaScript nach; weicht er ab, gilt die Datenbank.

Im Gantt stehen die Verbindungen als Pfeile, der kritische Pfad bekommt einen
kräftigen Rahmen — **keine** weitere Farbe: Rot heißt dort schon Verzug, und
eine Farbe mit zwei Bedeutungen sagt nichts mehr.

### Drei Auswertungen, die aus vorhandenen Daten entstehen (19.09.2026)

| Funktion | Beantwortet |
|---|---|
| `pcc.changes_since(stichtag, projekt?)` | Was hat sich seit dem letzten Bericht geändert — Grundlage des Wochenberichts. Statuswechsel und Terminverschiebungen mit Vorher und Nachher, aus dem Audit-Trail |
| `pcc.search(text)` | Suche über Projekte, Teilprojekte, Aufgaben, Meilensteine, Risiken, Probleme, Entscheidungen und Dokumente. `pg_trgm` sortiert nach Ähnlichkeit; was der Fragende nicht lesen darf, kommt nicht zurück |
| `pcc.calendar(projekt?)` | Offene Meilensteine und Fristen als iCalendar-Text. Ganztägige Einträge enden auf dem Folgetag, sonst verschluckt Outlook den letzten Tag |

Alle drei sind `security definer` und prüfen selbst, ob der Fragende angemeldet
ist und das Projekt lesen darf — sie umgehen die Policies nicht, sie tragen sie
nach.

Technisch heißt das: die SELECT-Policy ruft `pcc.can_read()` — angemeldet
genügt. Die schreibenden Policies prüfen `pcc.can_edit()`: Teamzugang und
Projekt nicht archiviert. Die Projektmitgliedschaft steuert seitdem keine
Rechte mehr, sie sagt nur noch, wer fachlich zum Projekt gehört. Eine spätere
Einschränkung je Projekt bliebe eine reine Erweiterung von `can_read()` um ein
Feld `projects.restricted`.

---

## 5. Autosave, Echtzeit, Konflikte (Abschnitte 34, 35)

**Autosave.** Kein Speichern-Knopf. Jede Feldänderung löst nach 600 ms
Ruhe einen Schreibvorgang aus. Der Zustand steht sichtbar am Feld:
`Gespeichert` / `Speichert …` / `Nicht gespeichert — erneut versuchen`.
Bei Verbindungsverlust wandert die Änderung in eine lokale Warteschlange
(IndexedDB) und wird bei Rückkehr abgespielt (Abschnitt 37).

**Echtzeit.** Supabase Realtime auf den Tabellen des geöffneten Projekts.
Eingehende Änderungen aktualisieren den Cache, ohne die Eingabe des Nutzers
zu überschreiben: Ein Feld, in dem gerade getippt wird, bleibt unberührt und
zeigt stattdessen einen Hinweis „von *Martin* geändert — übernehmen".

**Konflikte.** Optimistisches Sperren über `updated_at`, in der Datenbank
umgesetzt: Schickt die Oberfläche den Stand mit, auf dem sie den Satz geladen
hat, und ist dieser überholt, antwortet die Datenbank mit `PCC_CONFLICT` statt
still zu überschreiben. Die Oberfläche zeigt dann beide Fassungen nebeneinander
zur Auswahl.

---

## 6. Versionierung (Abschnitt 32)

Nicht jede Feldänderung ist eine Version — sonst steht nach einer Woche
Version 4.312 da und niemand liest sie mehr.

**Regel, entschieden am 18.09.2026:** Eine Version entsteht bei fachlich
bedeutsamen Ereignissen — Statuswechsel des Projekts, Verschiebung eines
Meilensteins, Änderung des Enddatums, neues Risiko ab Score 15, Abschluss
eines Workstreams, Freigabe durch den PM. Alles Übrige steht im Audit Trail
und im Activity Log. Die Liste ist in `pcc.version_triggers` als Konfiguration
hinterlegt, damit sie ohne Codeänderung erweitert werden kann.

`version_changes` hält je Version die Einzeländerungen (Objekt, Feld, alt,
neu). Wiederherstellung ist vorbereitet, aber nicht Teil der ersten Fassung:
Die Daten reichen dafür, die Oberfläche kommt später.

---

## 7. Export (Abschnitte 38–40)

| Ausgabe | Weg |
|---|---|
| **Excel** je Projekt, 13 Blätter | Edge Function mit `exceljs`, serverseitig erzeugt, damit Formatierung und Formeln stimmen und keine Daten am Client zusammengeklaubt werden |
| **PDF** Management Report | Druckansicht im Browser für den schnellen Weg; serverseitig mit Playwright als Edge Function, sobald der Bericht per Mail verschickt werden soll |
| **Dashboard-PDF** | dieselbe Druckansicht über die Dashboard-Route |

Der Export prüft die Rechte erneut serverseitig: Ein Viewer exportiert nur,
was er sehen darf.

---

## 7a. Dokumente (Abschnitt 27)

**Entschieden am 18.09.2026:** Dokumente werden **in die Anwendung
hochgeladen**, nicht nur verlinkt. Damit wird das Control Center zur führenden
Ablage für Projektdokumente.

Das ist bewusst gegen meine Empfehlung entschieden worden und zieht vier
Pflichten nach sich, die sonst SharePoint getragen hätte:

| Pflicht | Umsetzung |
|---|---|
| **Zugriffsschutz** | Supabase Storage Bucket `project-docs`, privat. Zugriff ausschließlich über signierte URLs mit kurzer Gültigkeit; die Storage-Policy prüft dieselbe Projektmitgliedschaft wie die Tabellen (`supabase/migrations/20260918000600_storage.sql`). Kein öffentlicher Bucket. Ein Objekt heißt `<projekt-id>/<datei>` — die erste Pfadebene ist die Projektzugehörigkeit, und ein Check-Constraint hält `documents.storage_path` daran fest |
| **Virenprüfung** | Ein Upload steht auf `scan_state = 'pending'` und ist damit für niemanden ladbar: die Lese-Policy des Buckets verlangt `clean`. Eine Edge Function prüft die Datei und meldet das Ergebnis über `pcc.set_scan_state()` zurück. Die Quarantäne ist also ein Zustand, kein zweiter Ablageort — ein Verschieben zwischen Buckets könnte fehlschlagen und eine ungeprüfte Datei erreichbar zurücklassen |
| **Aufbewahrung** | Entschieden am 18.09.2026: **unbegrenzt**. Es gibt keine automatische Löschregel; der Speicherbedarf wächst mit jedem Projekt. Rechnen Sie mit rund 1 bis 3 GB je Jahr bei der heutigen Projektzahl, das entspricht im Supabase-Pro-Tarif etwa 0,02 USD je GB und Monat — wirtschaftlich unkritisch, aber bewusst einzuplanen |
| **Sicherung** | Storage wird getrennt von der Datenbank gesichert. Supabase sichert Storage nicht im Datenbank-Backup mit — dafür ist ein eigener Abgleich in ein zweites Ziel einzurichten |

Grenzen: 50 MB je Datei, erlaubte Typen PDF, Office, Bilder, Text. Größere
Dateien und Videos bleiben extern; das Feld für einen externen Verweis bleibt
deshalb erhalten und lässt sich je Dokument statt eines Uploads verwenden.

Versionen eines Dokuments werden als eigene Zeilen geführt, nicht überschrieben:
`documents.version` plus `supersedes_id`. Ein Dokument wird nie ersetzt,
sondern abgelöst — sonst ist der Stand zum Zeitpunkt eines Audits nicht mehr
rekonstruierbar.

## 7b. Aufbewahrung und Löschung

**Entschieden am 18.09.2026:** Projektdokumente und Audit-Trail werden
**unbegrenzt** aufbewahrt. Keine automatische Löschung, kein Verfallsdatum.

Davon unberührt bleibt eine Pflicht, die keine Aufbewahrungsregel aufhebt:
**Löschverlangen nach Artikel 17 DSGVO.** Projektdokumente und Kommentare
enthalten personenbezogene Daten — Namen, Verantwortlichkeiten, gelegentlich
Beurteilungen. Verlangt eine Person die Löschung, muss die Anwendung sie
ausführen können, ohne den Projektverlauf zu zerstören.

Umgesetzter Weg, ausschließlich über den Teamzugang
(`pcc.anonymise_user()`, `pcc.delete_comment()`, `pcc.delete_document()`,
`pcc.redact_audit()` — jede dieser Funktionen verlangt eine Grundlage im
Klartext):

| Objekt | Behandlung |
|---|---|
| `users` | Person stillgelegt, Name ersetzt durch „Ehemaliger Mitarbeiter (Nr.)", E-Mail geleert. Die ID bleibt, damit Zuordnungen nicht brechen |
| `comments`, `documents` | Auf Antrag einzeln löschbar, mit Eintrag im Audit-Trail: wer, wann, auf welcher Grundlage. Ein Trigger verhindert, dass jemand den Löschvermerk im Vorbeigehen setzt — auch der Eigentümer eines Dokuments nicht |
| `audit_log` | Einträge bleiben, der Personenbezug wird durch die Pseudonymisierung in `users` aufgelöst. Der Vorgang selbst bleibt nachvollziehbar |
| `tasks`, `risks`, `decisions` | Zuordnung bleibt über die ID bestehen und zeigt den pseudonymisierten Namen |

Damit ist das Prinzip gewahrt: **Was fachlich geschehen ist, bleibt
nachvollziehbar; wer es war, ist auf Verlangen nicht mehr erkennbar.**

## 8. PWA und Auto-Update (Abschnitte 36, 37)

- Manifest mit Icons in 192, 512 und maskable, Splash über `theme_color`.
  **Stand:** bislang ein einzelnes SVG; die Icons kommen mit dem Logo.
- Service Worker mit `registerType: 'prompt'`: Bei neuer Fassung erscheint ein
  dezenter Hinweis „Neue Version verfügbar — jetzt laden". Kein Neuladen
  mitten in einer Eingabe.
- Offline-Shell mit den zuletzt gesehenen Projekten; Schreibvorgänge in die
  Warteschlange, Hinweis „Offline — Änderungen werden synchronisiert".
- Versionsnummer aus `package.json`, im Build eingebettet, sichtbar im
  Profilmenü: `Project Control Center v1.4.2`. **Stand:** offen, siehe
  Abschnitt 10, Schritt 9.

---

## 9. Was der Prototyp zeigt und was er nicht kann

Der klickbare Prototyp zeigt Oberfläche, Abläufe und
Informationsarchitektur. Er ist ausdrücklich **kein** Ersatz für die
Implementierung nach Abschnitt 61.

| Anforderung | Prototyp | Stand der Umsetzung |
|---|---|---|
| Oberfläche, Navigation, Dashboard | vollständig | Prototyp, Zielversion offen |
| Rollen und Sichtbarkeit | im Frontend nachgebildet | **umgesetzt** als RLS in PostgreSQL (`20260918000400`) |
| Anmeldung | Zugang wählen, dann Person | **Datenbankseite umgesetzt**: zwei vorbereitete Zugänge, Verknüpfung über die Adresse; Supabase Auth folgt mit dem Projekt |
| Persistenz | sofort auf dem Gerät (localStorage, Dateien in IndexedDB); Datensicherung als Datei | **Schema umgesetzt** (`20260918000100`), noch keine Cloud-Instanz |
| Autosave | umgesetzt: jede Änderung wird im selben Augenblick abgelegt | in der Anwendung derselbe Ansatz — jeder Vorgang schreibt sofort, ohne „Speichern" |
| Echtzeit | nicht vorhanden | offen — braucht die Supabase-Instanz |
| Audit und Versionen | nachgebildet | **umgesetzt**: gemeinsamer Trail mit Modulspalte, unveränderliche Versionstabellen |
| Export | PDF echt, Excel echt (.xlsx, ein Blatt je Abschnitt, im Client erzeugt) | Excel-Erzeugung liegt vor und ist getestet; Edge Function nur noch für serverseitige Zustellung nötig |

---

## 10. Reihenfolge und Stand

| Schritt | Inhalt | Stand |
|---|---|---|
| 1 | Datenmodell `pcc`, Nutzerkonto und Audit-Trail in `public` | **fertig** — `supabase/migrations/20260918000100`, lokal geprüft |
| 2 | Zwei Zugänge, Personenverzeichnis, RLS | **fertig** — `…000200` bis `…000400` |
| 3 | Kern: Projekte, Workstreams, Aufgaben, Teilaufgaben, Meilensteine | **Datenbank fertig**; im Prototyp vollständig bedienbar, Zielanwendung offen |
| 4 | Risiken, Issues, Decisions, RACI | **Datenbank fertig**, Oberfläche offen |
| 5 | Dashboard, Timeline, Suche, Filter | Sichten fertig (`…000500`), Oberfläche offen |
| 6 | Kommentare, Benachrichtigungen, Dokumente mit Upload, Activity, Audit | **Datenbank fertig**; Storage-Bucket und Virenprüfung brauchen die Instanz |
| 7 | Versionierung, Autosave, Echtzeit, Konfliktbehandlung | Versionierung fertig; Echtzeit braucht die Instanz |
| 8 | Export Excel und PDF, Dashboard-Bericht | Excel- und PDF-Erzeugung im Prototyp fertig; Übernahme in die Zielanwendung 1 Tag |
| 9 | PWA, Offline, Auto-Update | Gerüst steht, Ausbau offen, 1–2 Tage |
| 10 | Oberfläche auf die Datenbank heben, Prototyp ablösen | offen, 8–10 Tage |
| 11 | Tests nach Abschnitt 59, Sicherheitsdurchsicht, Bereitstellung | SQL-Tests (181), Logik- (58) und Funktionsdurchlauf (217) laufen in der CI; Freigabeprüfung in `AUDIT-ROLLOUT.md` |

Zusammen rund **drei bis vier Wochen** bis zu der in Abschnitt 60 aufgeführten
Definition of Done.

### Warum das Supabase-Projekt kein Hindernis war

Abschnitt 61 des Entwicklungsauftrags verlangt ausdrücklich eine echte
Umsetzung und keinen Mockup, das Supabase-Projekt sollte aber später kommen.

Gewählter Weg: **die Datenbank wird vollständig gebaut, geprüft und im
Repository versioniert, nur eben noch nicht in der Cloud betrieben.** Die
Migrationen laufen gegen ein lokales PostgreSQL 15 durch, Policies und Trigger
werden dort unter echten Nutzerkontexten getestet. Sobald das Supabase-Projekt
besteht, ist das Einspielen ein einziger Befehl (`supabase db push`), und die
Tests laufen unverändert gegen die Instanz.

Das heißt auch: die Oberfläche bleibt bis dahin der Prototyp. Sie an eine
Datenbank anzuschließen, die es noch nicht gibt, wäre Arbeit auf Verdacht.

---

## 11. Offene Punkte

### Entschieden am 18.09.2026

| # | Punkt | Entscheidung |
|---|---|---|
| 1 | Zugänge | genau zwei, gemeinsam benutzt: Teamzugang und Lesezugang (19.09.2026) |
| 2 | Sichtbarkeit von Projekten | beide Zugänge lesen jedes Projekt, auch archivierte |
| 3 | Auslöser für eine neue Version | nur fachlich bedeutsame Ereignisse, Liste in Abschnitt 6 |
| 4 | Dokumente | Upload in die Anwendung, Folgen in Abschnitt 7a |
| 5 | Aufbewahrung von Dokumenten, Projektdaten und Audit | unbegrenzt, Löschweg nach DSGVO in Abschnitt 7b |

### Noch offen

| # | Punkt | Braucht | Dringlichkeit |
|---|---|---|---|
| 6 | Projektschlüssel: fortlaufend oder sprechend (`SIM-26`) | Ihre Vorgabe | gering, im Prototyp sprechend |
| 7 | Microsoft Entra ID als Anmeldeweg ab wann | Ihre IT-Planung | gering, Architektur hält es offen |
| 8 | Supabase-Projekt anlegen (EU/Frankfurt, Pro-Tarif) | Ihre Freigabe und ein Konto — rund 25 USD im Monat | **hoch**: Migrationen, Rechte und Tests liegen fertig vor und warten nur auf die Instanz |
