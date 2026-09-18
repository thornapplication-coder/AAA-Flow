# Project Control Center — Architektur (Phase 1)

Stand: 2026-09-18 · Entwurf zur Freigabe vor der Implementierung
Bezug: „Project Control Center — Master Development Prompt", Abschnitte 1–64

Dieses Dokument ist die in Abschnitt 62, Phase 1 geforderte Architektur. Es
legt Technologie, Datenmodell, Rechtemodell, Betrieb und Ausbaureihenfolge
fest. Implementiert wird erst nach Ihrer Freigabe.

---

## 1. Grundsatzentscheidung: eine Anwendung, zwei Produkte

Sie haben AAA Flow einbinden lassen und das Control Center darauf aufgesetzt.
Das ist keine Kosmetik, sondern eine Architekturentscheidung mit Folgen.

**Entschieden: ein Produkt, zwei Module, eine Datenbank, ein Login.**

| | Begründung |
|---|---|
| **Ein Login** | Dieselben Menschen arbeiten in beiden Modulen. Zwei Konten je Person wären eine Zumutung und ein Sicherheitsrisiko (doppelte Sperrlisten beim Austritt) |
| **Eine Datenbank** | Personen, Firmen und Muster existieren nur einmal. Ein Trainingsvorgang aus Flow lässt sich später als Aufgabe eines Projekts referenzieren, ohne Schnittstelle |
| **Getrennte Schemas** | `flow.*` und `pcc.*` in einer Supabase-Instanz. Gemeinsam genutzt wird nur `public.users` und `public.audit_log`. So bleiben die Module unabhängig deploybar und die Rechte sauber trennbar |
| **Getrennte Rollen** | Eine Person kann in Flow Mitarbeiter und im Control Center Project Manager sein. Rollen hängen am Modul, nicht am Konto |

**Umschaltung in der Oberfläche:** ein Produktwechsler in der Kopfzeile. Wer
in einem Modul keine Rolle hat, sieht es nicht.

---

## 2. Technologiestack

| Schicht | Wahl | Begründung |
|---|---|---|
| Frontend | React 19 + TypeScript + Vite | Bereits im Repository, komponentenbasiert, typsicher |
| PWA | `vite-plugin-pwa` (Workbox) | Manifest, Service Worker, Auto-Update, Offline-Shell |
| Zustand | TanStack Query + Supabase Realtime | Cache, Hintergrundaktualisierung, Konfliktbehandlung |
| Oberfläche | eigene Komponenten auf den AAA-Design-Tokens | Kein UI-Framework: die Tokens stehen, der Look ist gesetzt |
| Backend | Supabase (PostgreSQL, Auth, Realtime, Storage, Edge Functions) | Postgres mit RLS erzwingt Rechte **serverseitig** — Abschnitt 43 |
| Geschäftslogik | PostgreSQL-Funktionen und Trigger | Wie in Flow bewährt: Regeln sind nicht über die API umgehbar |
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

Schema `pcc`. Alle Tabellen mit `id uuid`, `created_at`, `created_by`,
`updated_at`, `updated_by`.

### Kern

```
projects        key, name, description, objectives, scope, status, health,
                pm_user_id, start_date, target_end_date, actual_end_date,
                progress_mode (manual | derived), progress_manual,
                archived_at, archived_by, template_id
project_members project_id, user_id, project_role, responsibilities
workstreams     project_id, name, description, owner_user_id, sort_order
tasks           project_id, workstream_id, parent_task_id, ref (T-1042),
                title, description, assignee_user_id, priority, status,
                start_date, due_date, completed_at, progress,
                progress_mode (manual | derived)
milestones      project_id, workstream_id, ref, name, description, date,
                owner_user_id, status, depends_on_milestone_id, notes
risks           project_id, ref, title, description, category,
                probability (1-5), impact (1-5),
                score int GENERATED ALWAYS AS (probability * impact) STORED,
                owner_user_id, mitigation, contingency, due_date, status
issues          project_id, ref, title, description, owner_user_id,
                priority, status, due_date, resolution
decisions       project_id, ref, decided_on, topic, decision, maker_user_id,
                participants uuid[], rationale, impact, task_id
documents       project_id, title, description, kind (file | link),
                storage_path, external_url, version, owner_user_id
raci            project_id, subject_type (workstream|task|milestone),
                subject_id, user_id, letter (R|A|C|I)
comments        entity_type, entity_id, user_id, body, edited_at
mentions        comment_id, user_id
notifications   user_id, kind, entity_type, entity_id, payload, read_at,
                email_status
project_versions project_id, version (1.4), summary, created_by, created_at
version_changes  version_id, entity_type, entity_id, field, old_value, new_value
templates       name, description, payload jsonb
```

### Gemeinsam mit Flow

```
public.users     id (= auth.users.id), name, email, active, invited,
                 language, flow_role, flow_department, pcc_role
public.audit_log user_id, module (flow|pcc), entity, entity_id, action,
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
   Löschen ausschließlich Super Admin, über eine Funktion mit Audit-Eintrag.
4. **Referenznummern** (`T-1042`, `R-14`) je Projekt aus einer Sequenz, damit
   Menschen im Gespräch darauf zeigen können.
5. **RACI als eigene Tabelle**, nicht als Feld an der Aufgabe: eine Aufgabe
   hat genau ein A, aber beliebig viele C und I (Abschnitt 19).

---

## 4. Rechte (Abschnitt 5)

Serverseitig durch Row Level Security. Kein einziger Rechtecheck verlässt
sich auf das Frontend (Abschnitt 43).

| Rolle | Projekte | Aufgaben, Risiken, Issues | Nutzer | System |
|---|---|---|---|---|
| **Super Admin** | alle, anlegen, archivieren, endgültig löschen | alle | freigeben, sperren, Rollen vergeben | Einstellungen, Versionen, Audit |
| **Admin** | alle, anlegen, archivieren | alle | bearbeiten, keine Rollenvergabe, keine Anlage | Exporte |
| **Project Manager** | eigene Projekte vollständig | in eigenen Projekten alles | Projektteam der eigenen Projekte | — |
| **Contributor** | Projekte mit Mitgliedschaft lesen | zugewiesene bearbeiten, Issues melden, kommentieren | — | — |
| **Viewer** | Projekte mit Mitgliedschaft lesen | lesen, exportieren | — | — |

Umsetzung je Tabelle über zwei Hilfsfunktionen, wie in Flow bewährt:

```sql
pcc.is_member(project_id)        -- Mitglied oder Admin-Ebene
pcc.can_edit(project_id)         -- PM des Projekts, Admin oder Super Admin
```

**Registrierung und Freigabe (Abschnitt 4):** Selbstregistrierung ist erlaubt,
erzeugt aber `active = false, pending = true`. Ohne Freigabe durch den Super
Admin greift keine einzige RLS-Policy — der Nutzer sieht nichts. Die Freigabe
läuft über eine Edge Function mit der Admin-API.

> **Entschieden am 18.09.2026:** Selbstregistrierung ist im Control Center
> erlaubt, in Flow bleibt sie ausgeschlossen. Wer sich registriert, erhält ein
> Konto ohne Flow-Rolle: nach Freigabe durch den Super Admin sieht er das
> Control Center, Flow erst, wenn ein Flow-Superadmin ihm dort zusätzlich eine
> Rolle vergibt. Technisch: `public.users` trägt `pcc_role` und `flow_role`
> getrennt, beide dürfen NULL sein; eine NULL-Rolle sperrt das jeweilige Modul
> vollständig, weil keine RLS-Policy greift.

### Sichtbarkeit von Projekten

**Entschieden am 18.09.2026:** Jeder freigegebene Nutzer liest alle nicht
archivierten Projekte. Abschnitt 5 gibt dem Viewer ausdrücklich Leserecht auf
Projekte, und ein Management-Dashboard mit Löchern wäre wertlos. Geändert wird
weiterhin nur nach Rolle.

Technisch heißt das: die SELECT-Policy prüft nur `active AND pcc_role IS NOT
NULL`, die INSERT-, UPDATE- und DELETE-Policies prüfen `pcc.can_edit()`. Eine
spätere Einschränkung je Projekt bliebe eine reine Erweiterung der
SELECT-Policy um ein Feld `projects.restricted`.

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

**Konflikte.** Optimistisches Sperren über `updated_at`. Schreibt jemand auf
einen veralteten Stand, weist die Funktion ab und die Oberfläche zeigt beide
Fassungen nebeneinander zur Auswahl. Kein stilles Überschreiben.

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
| **PDF** Management Report | Druckansicht im Browser (wie in Flow bewährt) für den schnellen Weg; serverseitig mit Playwright als Edge Function, sobald der Bericht per Mail verschickt werden soll |
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
| **Zugriffsschutz** | Supabase Storage Bucket `project-docs`, privat. Zugriff ausschließlich über signierte URLs mit kurzer Gültigkeit; die Storage-Policy prüft dieselbe Projektmitgliedschaft wie die Tabellen. Kein öffentlicher Bucket |
| **Virenprüfung** | Upload landet zuerst in `quarantine/`, eine Edge Function prüft und verschiebt erst danach nach `project-docs/`. Bis dahin ist das Dokument als „in Prüfung" gekennzeichnet und nicht herunterladbar |
| **Aufbewahrung** | Dokumente unterliegen jetzt der Aufbewahrungspflicht des Unternehmens. Die Frist ist noch zu benennen (offener Punkt 6); ohne sie gibt es keine Löschregel und der Speicher wächst unbegrenzt |
| **Sicherung** | Storage wird getrennt von der Datenbank gesichert. Supabase sichert Storage nicht im Datenbank-Backup mit — dafür ist ein eigener Abgleich in ein zweites Ziel einzurichten |

Grenzen: 50 MB je Datei, erlaubte Typen PDF, Office, Bilder, Text. Größere
Dateien und Videos bleiben extern; das Feld für einen externen Verweis bleibt
deshalb erhalten und lässt sich je Dokument statt eines Uploads verwenden.

Versionen eines Dokuments werden als eigene Zeilen geführt, nicht überschrieben:
`documents.version` plus `supersedes_id`. Ein Dokument wird nie ersetzt,
sondern abgelöst — sonst ist der Stand zum Zeitpunkt eines Audits nicht mehr
rekonstruierbar.

## 8. PWA und Auto-Update (Abschnitte 36, 37)

- Manifest mit Icons in 192, 512 und maskable, Splash über `theme_color`.
- Service Worker mit `registerType: 'prompt'`: Bei neuer Fassung erscheint ein
  dezenter Hinweis „Neue Version verfügbar — jetzt laden". Kein Neuladen
  mitten in einer Eingabe.
- Offline-Shell mit den zuletzt gesehenen Projekten; Schreibvorgänge in die
  Warteschlange, Hinweis „Offline — Änderungen werden synchronisiert".
- Versionsnummer aus `package.json`, im Build eingebettet, sichtbar im
  Profilmenü: `Project Control Center v1.4.2`.

---

## 9. Was der Prototyp zeigt und was er nicht kann

Der klickbare Prototyp im Flow-Stil zeigt Oberfläche, Abläufe und
Informationsarchitektur. Er ist ausdrücklich **kein** Ersatz für die
Implementierung nach Abschnitt 61.

| Anforderung | Prototyp | Zielversion |
|---|---|---|
| Oberfläche, Navigation, Dashboard | vollständig | dieselbe |
| Rollen und Sichtbarkeit | im Frontend nachgebildet | RLS in PostgreSQL |
| Anmeldung | Rollenwahl | Supabase Auth, Freigabe durch Super Admin |
| Persistenz | im Speicher, bis Neuladen | PostgreSQL |
| Echtzeit, Autosave | nicht vorhanden | Supabase Realtime, Warteschlange |
| Audit und Versionen | nachgebildet | unveränderliche Tabellen mit Triggern |
| Export | PDF echt, Excel als Text | beides als Datei |

---

## 10. Vorgeschlagene Reihenfolge

| Schritt | Inhalt | Aufwand |
|---|---|---|
| 1 | **Diese Architektur freigeben** | Ihre Entscheidung |
| 2 | Supabase-Projekt EU/Frankfurt, Schemas `flow` und `pcc`, `public.users` zusammenführen | 1 Tag |
| 3 | Auth, Registrierung, Freigabe durch Super Admin, Rollen, RLS für beide Module | 2–3 Tage |
| 4 | Control Center Kern: Projekte, Workstreams, Tasks, Subtasks, Meilensteine | 3–4 Tage |
| 5 | Risiken, Issues, Decisions, RACI | 2–3 Tage |
| 6 | Dashboard, Timeline, Suche, Filter | 2–3 Tage |
| 7 | Kommentare, Benachrichtigungen, Dokumente, Activity, Audit | 2–3 Tage |
| 8 | Versionierung, Autosave, Echtzeit, Konfliktbehandlung | 3 Tage |
| 9 | Export Excel und PDF, Dashboard-Bericht | 2 Tage |
| 10 | PWA, Offline, Auto-Update | 1–2 Tage |
| 11 | Tests nach Abschnitt 59, Sicherheitsdurchsicht, Bereitstellung | 3 Tage |

Zusammen rund **vier bis fünf Wochen** konzentrierter Arbeit für die in
Abschnitt 60 aufgeführte Definition of Done. AAA Flow bringt Schema,
Rechtemodell, Exportweg und Designsystem bereits mit — das ist der Grund,
warum die Schätzung nicht doppelt so hoch ausfällt.

---

## 11. Offene Punkte

### Entschieden am 18.09.2026

| # | Punkt | Entscheidung |
|---|---|---|
| 1 | Selbstregistrierung im Control Center | erlaubt, Zugang erst nach Freigabe durch den Super Admin; Flow bleibt geschlossen |
| 2 | Sichtbarkeit von Projekten | jeder freigegebene Nutzer liest alle nicht archivierten Projekte |
| 3 | Auslöser für eine neue Version | nur fachlich bedeutsame Ereignisse, Liste in Abschnitt 6 |
| 4 | Dokumente | Upload in die Anwendung, Folgen in Abschnitt 7a |

### Noch offen

| # | Punkt | Braucht | Dringlichkeit |
|---|---|---|---|
| 5 | **Aufbewahrungsfrist für Dokumente** | Ihre Vorgabe | **hoch** — durch die Entscheidung zum Upload trägt die Anwendung die Aufbewahrungspflicht selbst |
| 6 | Aufbewahrungsfristen für Projektdaten und Audit | Ihre Vorgabe | mittel |
| 7 | Projektschlüssel: fortlaufend oder sprechend (`SIM-26`) | Ihre Vorgabe | gering, im Prototyp sprechend |
| 8 | Microsoft Entra ID als Anmeldeweg ab wann | Ihre IT-Planung | gering, Architektur hält es offen |
