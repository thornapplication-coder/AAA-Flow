# Arbeitsregeln für dieses Repository

Diese Anwendung wird im Team eingesetzt. Jede Fassung, die aus einer Sitzung
hervorgeht, muss vollständig funktionieren — nicht „wahrscheinlich".

## Vor jedem Commit

1. `npm run verify` — Typprüfung, Logiktests, Darstellung bei drei Breiten,
   Funktionsdurchlauf durch die ganze Anwendung (beide Zugänge, alle Dialoge,
   Ausgaben, Speicherung, Rechte). Muss ohne Befund enden.
2. Wenn Migrationen, Seed oder SQL-Tests geändert wurden: zusätzlich
   `npm run db:check` gegen eine lokale PostgreSQL-Instanz.
3. Nie mit rotem Prüflauf committen. Ein Befund wird behoben, nicht umgangen:
   keine Prüfung abschalten, abschwächen oder auskommentieren, um grün zu werden.

## Bei jeder neuen Fassung

- Versionsnummer an allen vier Stellen gleich ziehen: `package.json`,
  `APP_VERSION` im Prototyp, Überschrift in `docs/CHANGELOG.md`, Zeile in
  `supabase/seed.sql` (und den Zähler in `supabase/tests/001_core.sql`).
  `check:logic` bricht ab, wenn sie auseinanderlaufen.
- Neue Knöpfe, Dialoge oder Abläufe bekommen im selben Commit eine Prüfung in
  `scripts/check-app.mjs`; neue Rechenregeln eine in `scripts/check-logic.mjs`;
  neue Tabellen, Funktionen oder Rechte eine in `supabase/tests/`.
- Neue Texte in beiden Sprachen (`de` und `en`) anlegen; fehlende Schlüssel
  lässt `check:logic` durchfallen.

## Grundsätze der Anwendung

- Zwei Zugänge: `team` darf alles, `viewer` liest. Kein Rechtecheck verlässt
  sich auf die Oberfläche; die Datenbank entscheidet (RLS auf jeder Tabelle).
- Jede Änderung wird sofort gespeichert (`commit()`), landet im Verlauf und
  zieht offene Ausgaben nach. Nichts wird hart gelöscht, was einen Bezug hat.
- Eingaben werden nie als HTML ausgeführt: alles, was in die Seite kommt, geht
  durch `esc()`.
- Sprache der Oberfläche, Kommentare und Prüfmeldungen: Deutsch.
