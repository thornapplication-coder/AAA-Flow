# Project Control Center

Projektsteuerung der Aviation Academy Austria: Projekte, Workstreams, Aufgaben,
Meilensteine, Risiken, Issues und Entscheidungen an einer Stelle — mit
Fortschritt und Gesamtlage, die aus den Daten gerechnet und nicht von Hand
gepflegt werden.

Architektur, Datenmodell und Entscheidungen stehen in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), der Versionsstand in
[`docs/CHANGELOG.md`](docs/CHANGELOG.md).

## Grundsatz

Die Regeln stehen in der Datenbank, nicht in der Oberfläche. Row Level Security
entscheidet, wer was sieht und ändert; Trigger und Funktionen erzwingen den
Rest. Was die Oberfläche nicht anbietet, gibt auch die API nicht heraus.

## Stack

| Schicht | Technologie |
|---|---|
| Backend | Supabase (PostgreSQL, Auth, Row Level Security, Storage), Region EU/Frankfurt |
| Geschäftslogik | PostgreSQL-Funktionen und Trigger (`supabase/migrations`) |
| Frontend | Vite, React 19, TypeScript, PWA (`vite-plugin-pwa`) |
| Sprachen | Deutsch / Englisch je Nutzer (`react-i18next`) |
| Tests | SQL-Testsuite gegen PostgreSQL (`supabase/tests`), CI über GitHub Actions |

## Was in der Datenbank steckt

- **Rollen:** Super Admin, Admin, Project Manager, Contributor, Viewer. Wer
  keine Rolle hat, sieht nichts — auch nicht mit gültigem Token.
- **Selbstregistrierung mit Freigabe:** Die Anmeldung erzeugt ein gesperrtes
  Profil; erst der Super Admin schaltet es frei.
- **Gerechnet statt gepflegt:** Fortschritt, Gesamtlage und Risk Score kommen
  aus der Datenbank. Der Score ist eine generierte Spalte und von Hand nicht
  setzbar.
- **Versionierung mit Augenmaß:** Eine neue Projektversion entsteht nur bei
  fachlich bedeutsamen Ereignissen — die Liste steht als Konfiguration in
  `pcc.version_triggers`, nicht im Code.
- **Dokumente:** Quarantäne bis zur Virenprüfung, 50 MB je Datei, Datei oder
  externer Verweis, und eine neue Fassung löst die alte ab, statt sie zu
  überschreiben.
- **Audit-Trail:** jede Änderung mit Wer, Wann, Vorher, Nachher. Kein Weg in
  der Anwendung ändert oder löscht einen Eintrag.
- **Löschverlangen nach Artikel 17 DSGVO:** `pcc.anonymise_user()`
  pseudonymisiert das Konto; die fachliche Zuordnung bleibt über die ID
  bestehen.

## Sandbox

`sandbox/Control-Center-Sandbox.html` ist ein klickbarer Prototyp mit
Demodaten, ohne Backend — einfach im Browser öffnen. Er dient dazu, Oberfläche
und Bedienung zu entscheiden, bevor sie gegen Supabase gebaut werden.

Enthalten sind Dashboard mit Kennzahlen und Projektverlauf, Projektliste
mit Filtern, Projektakte mit Überblick, Projektverlauf, Aufgaben samt Teilaufgaben,
Risiken mit 5×5-Matrix, Problemen, Entscheidungen, Team und RACI, Dokumente,
Aktivität und Versionsverlauf. Dazu Aufgaben-, Risiko- und Meilensteinlisten
über alle Projekte hinweg sowie ein Berichtsbereich.

Der Einstieg erfolgt über einen Anmeldebildschirm; die Schnellwahl darunter
lässt die Rechte aller Rollen durchspielen. Die Sandbox-Leiste am unteren Rand
verschiebt das simulierte Datum um 1, 8 oder 31 Tage — damit werden Fristen,
Überfälligkeit und die Gesamtlage erlebbar. Zurücksetzen stellt den
Ausgangszustand her.

Exportiert wird über **PDF** (Druckansicht, in jeder Ansicht) und **Excel**
(überall dort, wo die Ansicht eine Liste ist).

Die Ansicht ist für Desktop ausgelegt und nach unten reduziert: auf dem Tablet
wandert die Navigation in eine Leiste unter die Kopfzeile, auf dem Telefon
tritt an die Stelle der Tabelle eine Kartenliste.

Weichen Prototyp und Datenbank voneinander ab, gilt die Datenbank.

## Struktur

```
.github/workflows/ci.yml      Drei Jobs: Frontend, Prototyp, Datenbank
docs/                         Architektur und Changelog
index.html                    Einstiegsseite der Anwendung
public/                       Statisches Beiwerk: Symbole für Browser und Installation
sandbox/                      Klickbarer Prototyp mit Demodaten, ohne Backend
scripts/check-sandbox.mjs     Prototyp in drei Bildschirmbreiten auf Fehler und Überlauf prüfen
scripts/db-check.sh           Migrationen + Seed + Tests gegen eine lokale PostgreSQL-Instanz
scripts/local/auth_shim.sql   Ersatz für auth.users und auth.uid(), nur für db-check
scripts/make-icons.py         Erzeugt die PNG-Symbole aus dem Entwurf in public/icon.svg
src/                          Frontend (Auth, Routing, i18n, Theme, Projektübersicht)
supabase/config.toml          Einstellungen der Supabase-CLI
supabase/migrations/          Schema 1.0.0 in sechs Migrationen (Schema, Helfer, Logik,
                              RLS, Sichten, Storage-Policies)
supabase/seed.sql             Versionsauslöser, Einstellungen, erste Projektvorlage
supabase/tests/               SQL-Tests für Rechte, Versionierung, Gesamtlage, Dokumente,
                              Löschweg, Schwärzung und die Angriffe, die scheitern müssen
tsconfig.json                 TypeScript für die Anwendung (tsconfig.node.json für die Werkzeuge)
vite.config.ts                Build, PWA-Manifest, Fassungsnummer aus package.json
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

Datenbank prüfen, ohne Supabase-Projekt (legt die Datenbank `pcc_check` an und
spielt Migrationen, Seed und Tests ein):

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=... npm run db:check
```

Mit Supabase CLI und Docker geht alternativ `supabase start` und
`supabase db reset` (nutzt `supabase/config.toml`, Migrationen und Seed).

## Supabase-Projekt einrichten

1. Projekt in der Organisation anlegen, Region **EU (Frankfurt)**.
2. `supabase link --project-ref <ref>` und `supabase db push`, anschließend
   `supabase/seed.sql` im SQL-Editor ausführen. Nutzerkonto und Audit-Trail
   liegen in `public`, alles Fachliche in `pcc`; beide Schemas sind in
   `supabase/config.toml` für die API freigegeben.
3. Ersten Nutzer über die Anmeldung registrieren — das Profil entsteht gesperrt
   und ohne Rolle. Dann im SQL-Editor:
   ```sql
   select pcc.bootstrap_super_admin('<ihre-adresse>');
   ```
   Die Funktion verweigert sich, sobald ein aktiver Super Admin existiert; ein
   gewöhnliches `update` auf `public.users` weist der Guard ab. Alle weiteren
   Konten gibt dieser Super Admin über `pcc.approve_user()` frei.
4. Storage: den privaten Bucket `project-docs` samt Policies legt die Migration
   `20260918000600_storage.sql` selbst an. Zugriff ausschließlich über signierte
   URLs; ein Objekt heißt `<projekt-id>/<datei>`, und ladbar ist es erst, wenn
   die Virenprüfung über `pcc.set_scan_state()` `clean` gemeldet hat
   (Abschnitt 7a der Architektur).
5. Tagesjob: `pg_cron` **vor** `supabase db push` im Dashboard aktivieren — dann
   richtet die Migration den Job `pcc_daily` selbst ein. Wurde sie schon
   eingespielt, den Job von Hand nachtragen:
   ```sql
   select cron.schedule('pcc_daily', '0 5 * * *', 'select pcc.run_daily_jobs()');
   ```
   Ohne `pg_cron` muss `pcc.run_daily_jobs()` täglich aus einer Edge Function
   oder einem externen Scheduler kommen.
6. Automatisches Datenbank-Backup aktivieren; Storage wird davon **nicht**
   erfasst und braucht einen eigenen Abgleich (Abschnitt 7a).
7. `.env` mit `VITE_SUPABASE_URL` und `VITE_SUPABASE_ANON_KEY` befüllen.

## Konventionen

- Projekte anlegen, archivieren, endgültig löschen, Konten freigeben,
  Kommentare setzen und Dokumente ablösen laufen über die Funktionen in
  `supabase/migrations/20260918000300_logic.sql`; direkte Schreibzugriffe weisen
  Policies und Guard-Trigger ab.
- Fehlermeldungen aus der Datenbank tragen ein Präfix (`PCC_AUTH`,
  `PCC_STATE`, `PCC_ARCHIVED`, `PCC_IMMUTABLE`), damit die Oberfläche sie
  gezielt übersetzen kann.
- Listen und Dropdowns werden alphabetisch sortiert.
- Farben ausschließlich über die Tokens in `src/styles/theme.css`.
