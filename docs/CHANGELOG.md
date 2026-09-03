# Changelog

Versionierung nach Schema `MAJOR.MINOR.PATCH`. Der Versionsstand wird zusätzlich
in der Tabelle `changelog` geführt und im Superadmin-Bereich angezeigt.

## 1.5.0 — 2026-09-03

- **Export.** PDF über eine eigene Druckansicht in jeder Ansicht, Excel überall
  dort, wo die Ansicht eine Liste ist: Vorgangsliste (gefilterte Sicht),
  Ausnahmen, Prüfpunkt-Katalog, Nutzer, Firmen, Trainees, Prüfpunkte und
  Audit-Trail eines Vorgangs. Dazu die vollständige **Vorgangsakte als PDF**
  mit Stammdaten, allen drei Gates samt Bearbeiter und Kontrolleur, Ausnahmen,
  Audit-Trail und Unterschriftenzeile.
- **Logins und Rollen.** Die E-Mail-Adresse ist der Login und wird vom
  Superadmin vergeben; Anlegen versendet eine Einladung, der Status zeigt
  Eingeladen, Aktiv oder Deaktiviert. Rollen vergibt ausschließlich der
  Superadmin, und er kann sich die eigene Rolle nicht entziehen. Auf dem
  Anmeldebildschirm führt die vergebene Adresse tatsächlich zur Anmeldung;
  unbekannte Adressen werden mit dem Hinweis auf die fehlende
  Selbstregistrierung abgewiesen.
- Sales ohne Musterzuordnung sieht eine erklärende leere Ansicht statt einer
  wortlosen Liste.

## 1.4.0 — 2026-09-03

Angeregt durch die Sandbox von InstructorConnect:

- **Zeitreise.** Eine Sandbox-Leiste am unteren Rand verschiebt das simulierte
  Datum um 1, 8 oder 31 Tage. Fristen, Überfälligkeit, Liegedauer im Pool,
  Gate-3-Warnungen und der Statuswechsel bei Kursbeginn werden dabei neu
  berechnet — die Fristenlogik lässt sich damit erleben statt nur ansehen.
  Zurücksetzen stellt den Ausgangszustand her.
- **Anmeldebildschirm** statt Auswahlfeld in der Kopfzeile: E-Mail-Feld mit
  Hinweis auf den Einmalcode, ausdrücklicher Vermerk zur fehlenden
  Selbstregistrierung und eine Schnellwahl der Rollen für die Sandbox,
  sortiert nach Superadmin, Leitung, Mitarbeiter.
- **Sichtbare Sandbox-Kennzeichnung** mit simuliertem Datum, damit die
  Demodaten nicht mit einem Echtsystem verwechselt werden.

## 1.3.0 — 2026-09-03

- Sandbox: Admin-Panel für den Superadmin mit drei Bereichen.
  - **Prüfpunkte:** anlegen, bearbeiten, duplizieren, deaktivieren, löschen
    (nur wenn in keinem Vorgang verwendet), Reihenfolge je Gate ändern.
    Regeln je Punkt: Pflicht/optional, Vier-Augen, sperrt nachfolgende Punkte,
    Vorbedingung, erst nach allen übrigen Pflichtpunkten, Frist mit Anker,
    Nachweis und Nachweispflicht, Musterfilter, Kurstypfilter, nur Teamleitung,
    aktiv. Neue Punkte wahlweise auch auf laufende Vorgänge anwenden.
  - **Einstellungen:** Liegenbleiber-Frist (wirkt sofort), Erinnerungstage,
    Frist bis Eskalationsstufe 2, Funktionsträger (Director Training, Head of
    Training, Sales-Leitung), Eskalationsstufe je Abteilung.
  - **Nutzer und Muster:** Nutzer anlegen und bearbeiten, Rolle, Abteilung,
    Aktivstatus und Musterzuordnung — wirkt unmittelbar auf Sichtbarkeit bei
    Sales und automatische Zuständigkeit bei ATO.
- Sandbox: Prüfpunkt-Katalog wird je Vorgang als Snapshot geführt, damit
  Katalogänderungen laufende Vorgänge nicht rückwirkend verändern.
- Sandbox: Nachweis wird beim Erledigen erfasst, wenn der Punkt es verlangt.
- ARCHITECTURE: neue Regelfelder gegenüber Schema 1.0.0 dokumentiert.

## 1.2.0 — 2026-09-03

- Sandbox: Vorgang, Trainee und Firma lassen sich anlegen. Beim Anlegen eines
  Vorgangs können Firma und Trainee direkt im Dialog neu erfasst werden; die
  ATO-Zuständigkeit wird automatisch über das Muster gesetzt (Fallback Head of
  Training), Sales kann nur Vorgänge zugeordneter Muster anlegen.
- Sandbox: neue Ansicht Stammdaten mit Firmen und Trainees.
- Sandbox: Kommunikation korrigiert — Trainee- und Firmen-Threads hängen jetzt
  an Person und Firma statt am einzelnen Vorgang und sind damit über alle
  Vorgänge derselben Person bzw. Firma sichtbar, mit Ungelesen-Zähler je Ebene.
- Sandbox: Tablet- und Handy-Ansichten. Navigation als feste Leiste unter der
  Kopfzeile, Kartenliste statt Tabelle auf dem Handy, Vorgangsakte über die
  volle Breite, einklappbare Filterleiste.

## 1.1.0 — 2026-09-03

- Sandbox `sandbox/AAA-Flow-Sandbox.html`: klickbarer Prototyp der Vorgangsakte
  mit Demodaten. Gate-Sperre, Vier-Augen-Prinzip als zweistufiger Ablauf,
  Gate-3-Sperre des Abschlussnachweises, Ausnahmen mit Antrag und Freigabe,
  Kommunikation auf drei Kontextebenen mit Bearbeitungsvermerk, Audit-Trail,
  Pool mit Liegedauer, Vorgangsbahn, Prüfpunkt-Katalog, Rollenwechsel, DE/EN.
- Design-Tokens in `src/styles/theme.css` auf die Farbwerte und die Typografie
  des Prototyps umgestellt (IBM Plex Sans / Mono, Navy-Palette, semantische
  Statusfarben getrennt vom Akzent).
- `sandbox/AAA-Flow-Sandbox-v0.html` als Referenz abgelegt.

## 1.0.0 — 2026-09-02

Fundament.

- Datenmodell nach Spec Abschnitt 5 als Supabase-Migrationen, ergänzt um `trainees`
  als eigene Entität (Trainee-Threads über mehrere Kurse), `message_mentions`,
  `thread_reads` und `changelog`.
- Geschäftslogik in Postgres: Vorgangsanlage mit Snapshot des Prüfpunkt-Katalogs,
  Pool-Übernahme, Zuweisung, Liegenbleiber-Regel, Prüfpunkte erledigen /
  kontrollieren / zurücksetzen, Vier-Augen-Prinzip (hart), Gate-Freigabe mit
  Sperrlogik, Gate-3-Sperre für den Abschlussnachweis, Ausnahmen mit Freigabe
  durch Director Training / Head of Training, Verwerfen mit Pflichtgrund,
  Übernahmefunktion für kursweite Felder, Erinnerungen und zweistufige
  Eskalation, Statuswechsel „In Durchführung" bei Kursbeginn.
- Kommunikation: Threads auf Ebene Vorgang, Trainee, Firma; kein Löschen;
  Bearbeitungshistorie; Erwähnungen mit Benachrichtigung; Ungelesen-Zähler.
- Audit-Trail als unveränderliche Tabelle mit generischem Trigger.
- Row Level Security für alle Tabellen inkl. Sales-Sichtbarkeit nach Muster,
  Vertretungsregelung und Firmen-Thread-Sichtbarkeit.
- Views für Vorgangsliste, Pool, Vorgangsbahn, Ausnahmen-Auswertung,
  Gate-Durchlaufzeiten und Ungelesen-Zähler.
- Seed: Muster, Prüfpunkt-Katalog für Gate 1–3, Einstellungen.
- SQL-Testsuite (`supabase/tests`) und lokale Prüf-Harness (`scripts/db-check.sh`).
- Frontend-Gerüst: Vite, React, TypeScript, PWA, Supabase-Client, DE/EN,
  Design-Tokens, Auth, Routing-Skelett, Pool-Ansicht als erster Durchstich.
