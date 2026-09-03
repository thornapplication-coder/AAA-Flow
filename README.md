# AAA Flow

Gate-Steuerung für Trainingsvorgänge der Aviation Academy Austria (AAA):
von der Kundenanfrage bis zum vollständig abgelegten Trainingsnachweis über
Sales, Training Admin und ATO hinweg. Ein Vorgang erreicht den nächsten
Schritt erst, wenn die Pflichtprüfpunkte der aktuellen Stufe erledigt sind.

Die vollständige Spezifikation liegt in [`docs/SPEC.md`](docs/SPEC.md),
Architekturentscheidungen und Annahmen in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
der Versionsstand in [`docs/CHANGELOG.md`](docs/CHANGELOG.md).

## Stack

| Schicht | Technologie |
|---|---|
| Backend | Supabase (PostgreSQL, Auth, Row Level Security), Region EU/Frankfurt empfohlen |
| Geschäftslogik | PostgreSQL-Funktionen und Trigger (`supabase/migrations`) |
| Frontend | Vite, React 19, TypeScript, PWA (`vite-plugin-pwa`) |
| Sprachen | Deutsch / Englisch je Nutzer (`react-i18next`) |
| Tests | SQL-Testsuite gegen PostgreSQL (`supabase/tests`), CI über GitHub Actions |

## Sandbox

`sandbox/AAA-Flow-Sandbox.html` ist ein klickbarer Prototyp mit Demodaten, ohne
Backend. Er dient dazu, Oberfläche und Bedienung zu entscheiden, bevor sie gegen
Supabase gebaut werden. Einfach im Browser öffnen.

Enthalten sind: Vorgang, Trainee und Firma anlegen; Vorgangsakte mit den drei
Gates, Gate-Sperre, Vier-Augen-Prinzip, Gate-3-Sperre des Abschlussnachweises,
Ausnahmen mit Freigabe; Kommunikation auf den Ebenen Vorgang, Trainee und Firma;
Audit-Trail, Pool mit Liegedauer, Vorgangsbahn und Stammdaten. Dazu ein
Admin-Panel für den Superadmin: Prüfpunkte anlegen und mit Regeln versehen,
Einstellungen und Nutzerverwaltung.
Der Einstieg erfolgt über einen Anmeldebildschirm; die Schnellwahl darunter
lässt die Rechte aller Rollen durchspielen. Die Sandbox-Leiste am unteren Rand
verschiebt das simulierte Datum um 1, 8 oder 31 Tage — damit werden Fristen,
Überfälligkeit, Liegedauer im Pool und der Statuswechsel bei Kursbeginn
erlebbar. Zurücksetzen stellt den Ausgangszustand her.

Exportiert wird über **PDF** (Druckansicht, in jeder Ansicht) und **Excel**
(überall dort, wo die Ansicht eine Liste ist). Die Vorgangsakte lässt sich als
vollständiges PDF mit Gates, Bearbeitern, Ausnahmen, Audit-Trail und
Unterschriftenzeile ausgeben.

Die Ansicht ist für Desktop ausgelegt und nach unten reduziert: auf dem Tablet
wandert die Navigation in eine Leiste unter die Kopfzeile, auf dem Handy tritt an
die Stelle der Tabelle eine Kartenliste. Gates, Kommunikation und die Übernahme
aus dem Pool bleiben dort vollständig bedienbar.

Die Sperrlogik im Prototyp spiegelt `supabase/migrations/20260902000300_logic.sql`.
Weichen beide voneinander ab, gilt die Datenbank. `AAA-Flow-Sandbox-v0.html` ist
der ursprüngliche Prototyp und bleibt als Referenz liegen.

## Struktur

```
docs/                    Spezifikation, Architektur, Changelog
sandbox/                 Klickbarer Prototyp mit Demodaten, ohne Backend
supabase/migrations/     Schema 1.0.0 in fünf Migrationen (Schema, Helfer, Logik, RLS, Views)
supabase/seed.sql        Muster, Prüfpunkt-Katalog Gate 1–3, Einstellungen
supabase/tests/          SQL-Tests für Gate-Sperre, Vier-Augen, Pool, Sichtbarkeit, Kommunikation
scripts/db-check.sh      Migrationen + Seed + Tests gegen eine lokale PostgreSQL-Instanz
scripts/bootstrap_superadmin.sql   Ersten Superadmin anlegen
src/                     Frontend-Gerüst (Auth, Routing, i18n, Theme, Pool-Ansicht)
```

## Lokale Entwicklung

Voraussetzungen: Node 22, npm, PostgreSQL 15 oder 16 (für `db:check`),
optional Supabase CLI mit Docker.

```bash
npm ci
cp .env.example .env            # Supabase-URL und Anon-Key eintragen
npm run dev                     # http://localhost:5173
npm run typecheck
npm run build
```

Datenbank prüfen, ohne Supabase-Projekt (legt die Datenbank `aaa_flow_check`
an, spielt Migrationen, Seed und Tests ein):

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=... npm run db:check
```

Mit Supabase CLI und Docker geht alternativ `supabase start` und
`supabase db reset` (nutzt `supabase/config.toml`, Migrationen und Seed).

## Supabase-Projekt einrichten

1. Projekt in der Organisation anlegen, Region **EU (Frankfurt)**.
2. `supabase link --project-ref <ref>` und `supabase db push`, anschließend
   `supabase/seed.sql` im SQL-Editor ausführen.
3. Ersten Auth-Nutzer im Dashboard anlegen (Authentication → Users), dann
   `scripts/bootstrap_superadmin.sql` mit dessen UUID im SQL-Editor ausführen.
   Selbstregistrierung bleibt deaktiviert; alle weiteren Nutzer legt der
   Superadmin an.
4. Funktionsträger und Eskalationsstufen in `settings` eintragen
   (`function_holders`, `escalation`), Musterzuordnungen in `type_assignments`.
5. Tagesjob: `pg_cron` im Dashboard aktivieren (die Migration richtet den Job
   `aaa_flow_daily` dann selbst ein) oder `public.run_daily_jobs()` täglich aus
   einer Edge Function aufrufen.
6. Automatisches Datenbank-Backup im Projekt aktivieren (Pflicht, Spec Abschnitt 3).
7. `.env` mit `VITE_SUPABASE_URL` und `VITE_SUPABASE_ANON_KEY` befüllen.

## Konventionen

- Alle Statuswechsel, Gate-Freigaben, Zuweisungen und Prüfpunkt-Änderungen
  laufen über die Funktionen in `supabase/migrations/20260902000300_logic.sql`;
  direkte Schreibzugriffe auf diese Tabellen weisen die Guard-Trigger ab.
- Fehlermeldungen aus der Datenbank tragen ein Präfix (`AAA_FLOW_AUTH`,
  `AAA_FLOW_GATE`, `AAA_FLOW_FOUR_EYES`, `AAA_FLOW_STATE`, `AAA_FLOW_GUARD`,
  `AAA_FLOW_IMMUTABLE`), damit das Frontend sie gezielt übersetzen kann.
- Listen und Dropdowns werden alphabetisch sortiert.
- Farben ausschließlich über die Tokens in `src/styles/theme.css`.
