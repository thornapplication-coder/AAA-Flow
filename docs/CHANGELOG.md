# Changelog

Versionierung nach Schema `MAJOR.MINOR.PATCH`. Der Versionsstand wird zusätzlich
in der Tabelle `changelog` geführt und im Superadmin-Bereich angezeigt.

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
