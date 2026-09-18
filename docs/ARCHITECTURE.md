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
| **Admin** | alle, anlegen, archivieren | alle | einsehen, keine Rollenvergabe | Exporte |
| **Project Manager** | eigene Projekte vollständig | in eigenen Projekten alles | Projektteam der eigenen Projekte | — |
| **Contributor** | alle nicht archivierten lesen | in Projekten mit Mitgliedschaft: zugewiesene bearbeiten, Risiken und Issues melden, kommentieren, Dokumente ablegen | — | — |
| **Viewer** | alle nicht archivierten lesen | lesen, exportieren | — | — |

Umsetzung je Tabelle über drei Hilfsfunktionen:

```sql
pcc.can_read(project_id)         -- jeder freigegebene Nutzer, Archiv nur für Mitglieder
pcc.can_contribute(project_id)   -- Contributor mit Mitgliedschaft, oder can_edit
pcc.can_edit(project_id)         -- PM des Projekts, Admin oder Super Admin
```

**Registrierung und Freigabe (Abschnitt 4):** Selbstregistrierung ist erlaubt,
erzeugt aber `active = false, pending = true`. Ohne Freigabe durch den Super
Admin greift keine einzige RLS-Policy — der Nutzer sieht nichts. Die Freigabe
läuft über `pcc.approve_user()`; das allererste Konto bekommt seine Rolle über
`pcc.bootstrap_super_admin()`, die sich verweigert, sobald es einen Super Admin
gibt.

> **Entschieden am 18.09.2026:** Selbstregistrierung ist erlaubt. Ein Trigger
> auf `auth.users` legt das Profil gesperrt und ohne Rolle an; erst die Freigabe
> durch den Super Admin über `pcc.approve_user()` schaltet es frei. Ein eigener
> Guard verhindert, dass jemand Rolle, Freigabe oder Aktivstatus an sich selbst
> ändert — sonst wäre die Registrierung ein Weg zum Super Admin.

### Sichtbarkeit von Projekten

**Entschieden am 18.09.2026:** Jeder freigegebene Nutzer liest alle nicht
archivierten Projekte. Abschnitt 5 gibt dem Viewer ausdrücklich Leserecht auf
Projekte, und ein Management-Dashboard mit Löchern wäre wertlos. Geändert wird
weiterhin nur nach Rolle.

Technisch heißt das: die SELECT-Policy ruft `pcc.can_read()` — freigegebenes
Konto mit Rolle, Archiv nur für Mitglieder und die Admin-Ebene. Die schreibenden
Policies prüfen `pcc.can_edit()` beziehungsweise `pcc.can_contribute()`. Eine
spätere Einschränkung je Projekt bliebe eine reine Erweiterung von `can_read()`
um ein Feld `projects.restricted`.

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

Umgesetzter Weg, ausschließlich für den Super Admin
(`pcc.anonymise_user()`, `pcc.delete_comment()`, `pcc.delete_document()` —
jede dieser Funktionen verlangt eine Grundlage im Klartext):

| Objekt | Behandlung |
|---|---|
| `users` | Konto deaktiviert, Name ersetzt durch „Ehemaliger Mitarbeiter (Nr.)", E-Mail geleert. Die ID bleibt, damit Zuordnungen nicht brechen |
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
| Anmeldung | Rollenwahl | **Datenbankseite umgesetzt**: Registrierungs-Trigger, Freigabe durch Super Admin; Supabase Auth folgt mit dem Projekt |
| Persistenz | im Speicher, bis Neuladen | **Schema umgesetzt** (`20260918000100`), noch keine Cloud-Instanz |
| Echtzeit, Autosave | nicht vorhanden | offen — braucht die Supabase-Instanz |
| Audit und Versionen | nachgebildet | **umgesetzt**: gemeinsamer Trail mit Modulspalte, unveränderliche Versionstabellen |
| Export | PDF echt, Excel als Text | offen — Edge Function |

---

## 10. Reihenfolge und Stand

| Schritt | Inhalt | Stand |
|---|---|---|
| 1 | Datenmodell `pcc`, Nutzerkonto und Audit-Trail in `public` | **fertig** — `supabase/migrations/20260918000100`, lokal geprüft |
| 2 | Registrierung, Freigabe durch Super Admin, Rollen, RLS | **fertig** — `…000200` bis `…000400` |
| 3 | Kern: Projekte, Workstreams, Aufgaben, Teilaufgaben, Meilensteine | **Datenbank fertig**, Oberfläche offen |
| 4 | Risiken, Issues, Decisions, RACI | **Datenbank fertig**, Oberfläche offen |
| 5 | Dashboard, Timeline, Suche, Filter | Sichten fertig (`…000500`), Oberfläche offen |
| 6 | Kommentare, Benachrichtigungen, Dokumente mit Upload, Activity, Audit | **Datenbank fertig**; Storage-Bucket und Virenprüfung brauchen die Instanz |
| 7 | Versionierung, Autosave, Echtzeit, Konfliktbehandlung | Versionierung fertig; Echtzeit braucht die Instanz |
| 8 | Export Excel und PDF, Dashboard-Bericht | offen, 2 Tage |
| 9 | PWA, Offline, Auto-Update | Gerüst steht, Ausbau offen, 1–2 Tage |
| 10 | Oberfläche auf die Datenbank heben, Prototyp ablösen | offen, 8–10 Tage |
| 11 | Tests nach Abschnitt 59, Sicherheitsdurchsicht, Bereitstellung | SQL-Tests laufen, Oberflächentests offen |

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
| 1 | Selbstregistrierung | erlaubt, Zugang erst nach Freigabe durch den Super Admin |
| 2 | Sichtbarkeit von Projekten | jeder freigegebene Nutzer liest alle nicht archivierten Projekte |
| 3 | Auslöser für eine neue Version | nur fachlich bedeutsame Ereignisse, Liste in Abschnitt 6 |
| 4 | Dokumente | Upload in die Anwendung, Folgen in Abschnitt 7a |
| 5 | Aufbewahrung von Dokumenten, Projektdaten und Audit | unbegrenzt, Löschweg nach DSGVO in Abschnitt 7b |

### Noch offen

| # | Punkt | Braucht | Dringlichkeit |
|---|---|---|---|
| 6 | Projektschlüssel: fortlaufend oder sprechend (`SIM-26`) | Ihre Vorgabe | gering, im Prototyp sprechend |
| 7 | Microsoft Entra ID als Anmeldeweg ab wann | Ihre IT-Planung | gering, Architektur hält es offen |
| 8 | Supabase-Projekt anlegen (EU/Frankfurt, Pro-Tarif) | Ihre Freigabe und ein Konto — rund 25 USD im Monat | **hoch**: Migrationen, Rechte und Tests liegen fertig vor und warten nur auf die Instanz |
