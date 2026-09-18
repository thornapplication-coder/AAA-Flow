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

Enthalten sind Dashboard mit Kennzahlen und Management-Timeline, Projektliste
mit Filtern, Projektakte mit Überblick, Timeline, Aufgaben samt Teilaufgaben,
Risiken mit 5×5-Matrix, Issues, Entscheidungen, Team und RACI, Dokumente,
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
docs/                    Architektur und Changelog
sandbox/                 Klickbarer Prototyp mit Demodaten, ohne Backend
supabase/migrations/     Schema 1.0.0 in fünf Migrationen (Schema, Helfer, Logik, RLS, Sichten)
supabase/seed.sql        Versionsauslöser, Einstellungen, erste Projektvorlage
supabase/tests/          SQL-Tests für Rechte, Versionierung, Gesamtlage, Dokumente, Löschweg
scripts/db-check.sh      Migrationen + Seed + Tests gegen eine lokale PostgreSQL-Instanz
src/                     Frontend-Gerüst (Auth, Routing, i18n, Theme, Projektübersicht)
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
3. Ersten Nutzer über die Anmeldung registrieren, dann im SQL-Editor zum Super
   Admin machen:
   ```sql
   update public.users
      set role = 'super_admin', active = true, pending = false, approved_at = now()
    where email = '<ihre-adresse>';
   ```
   Alle weiteren Konten gibt dieser Super Admin über `pcc.approve_user()` frei.
4. Storage-Bucket `project-docs` **privat** anlegen (Abschnitt 7a der
   Architektur): Zugriff ausschließlich über signierte URLs, Upload zunächst
   nach `quarantine/`.
5. Tagesjob: `pg_cron` im Dashboard aktivieren (die Migration richtet den Job
   `pcc_daily` dann selbst ein) oder `pcc.run_daily_jobs()` täglich aus einer
   Edge Function aufrufen.
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
