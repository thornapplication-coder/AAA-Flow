# Changelog

Versionierung nach Schema `MAJOR.MINOR.PATCH`. Der Versionsstand wird zusätzlich
in der Tabelle `pcc.changelog` geführt und im Bereich des Super Admins angezeigt.

## 1.6.0 — 2026-09-19

### Excel ist jetzt Excel

Bisher lieferte der Excel-Knopf einen tabulatorgetrennten Text zum Einfügen.
Jetzt lädt er eine echte `.xlsx`-Datei — ohne Bibliothek, aus dem Prototyp
heraus: das Zip-Archiv und die Tabellenblätter entstehen in etwa 80 Zeilen.

- **Ein Blatt je Abschnitt.** Der Projektbericht hat zehn Blätter, das
  Dashboard fünf, der Wochenbericht fünf; Blattnamen ohne verbotene Zeichen und
  eindeutig.
- **Titel, Stand und Spaltenköpfe fett**, Spaltenbreiten nach Inhalt, Zahlen
  als Zahlen.
- **Text bleibt Text.** Zellen sind Inline-Zeichenketten; ein Titel wie
  `=SUMME(A1)` kann nie als Formel laufen. Der Apostroph-Schutz bleibt nur für
  die Zwischenablage nötig.
- **Kopieren bleibt** als zweiter Knopf im Dialog — für Umgebungen, in denen
  Downloads gesperrt sind. Der Dialog kann jetzt allgemein einen Nebenweg
  neben Abbrechen und OK tragen.
- **Geprüft:** der Logiktest liest das Archiv selbst, rechnet jede Prüfsumme
  unabhängig nach und kontrolliert Blätter, Zahlen, Maskierung und Fettdruck;
  der Funktionstest lädt die Datei wirklich herunter und prüft den Zip-Kopf.
  Alle zwölf Ausgaben wurden zusätzlich mit Pythons `zipfile` gegengeprüft.

### Einführungsseite für das Team

Eine Seite: die vier Regeln („Ein Gerät führt", eigene Person wählen, freitags
sichern, Zurücksetzen nur nach Sicherung), Anmelden, Projekt pflegen, Ausgeben,
Sichern und Übergeben, die Sandbox-Leiste, was der Prototyp nicht kann.

## 1.5.0 — 2026-09-19

### Freigabeprüfung für den Teameinsatz

Vor dem Einsatz im Team wurde die Anwendung Knopf für Knopf, Ablauf für Ablauf
durchgesehen. Ergebnis: sie konnte anlegen, aber nicht pflegen. Was einmal
eingetragen war, ließ sich weder bearbeiten noch abschließen noch verwerfen.
Das ist jetzt geschlossen. Der vollständige Befund mit Ampel steht in
[`AUDIT-ROLLOUT.md`](AUDIT-ROLLOUT.md).

- **Bearbeiten in jedem Bereich.** Aufgaben (Stand, Fortschritt, Termine,
  Zuständigkeit, Vorgänger mit Kreisprüfung), Risiken (schließen, akzeptieren,
  Maßnahme nachtragen), Probleme (lösen — ohne Lösungstext kein Abschluss),
  Meilensteine, Teilprojekte, Entscheidungen, Teammitglieder und Rollen.
- **Anlegen, was fehlte:** Meilensteine, Teilprojekte, Entscheidungen,
  Teammitglieder und neue Personen im Verzeichnis — auch direkt aus der Anmeldung.
- **Verwerfen mit Rückfrage.** Eine Aufgabe nimmt Teilaufgaben, Verbindungen
  und Anhänge mit; nichts bleibt verwaist. Jeder Vorgang steht im Verlauf.
- **Archivieren und wieder öffnen.** Mit Grund, schreibgeschützt, in den
  Berichten weiterhin sichtbar, in der Projektliste über einen Schalter.
- **Datensicherung.** Der gesamte Stand samt Anhängen als eine Datei — zum
  Sichern, zum Gerätewechsel, zur Weitergabe. Einspielen ersetzt den Stand auf
  dem Gerät und weist fremde Dateien ab.
- **Zurücksetzen fragt nach** und weist auf die Datensicherung hin.
- **Zwei offene Fenster** derselben Anwendung gleichen sich ab, sobald eines
  speichert — nicht mitten in einer Eingabe.
- **Zeitreise wird nicht mehr mitgespeichert.** Wer die Sandbox-Uhr verschoben
  hat, startet am nächsten Tag wieder in der Gegenwart.
- **Ausgaben gehärtet:** Zellen, die Excel als Formel läse, werden
  entschärft; Zeilenumbrüche zerreißen keine Kalenderdatei mehr; Namen in
  Ausgaben und Tooltips sind konsequent maskiert.

### Prüfläufe vor jeder Fassung

`npm run verify` läuft vor jedem Commit und in der CI bei jedem Push:

| Prüflauf | Was er abdeckt | Umfang |
|---|---|---|
| `typecheck` | React-Gerüst und Typen gegen das Schema | — |
| `check:logic` | Rechenregeln (Risikostufen, Terminnetz, Ampel, Fortschritt), Ausgabeschutz, Kalenderdatei, Speicherstand, Wortschatz in beiden Sprachen, Versionsnummer an allen Stellen | 58 Prüfungen |
| `check:sandbox` | Laufzeitfehler und Überlauf bei 1440, 1024 und 390 px, beide Zugänge, englische Fassung | 3 Breiten |
| `check:app` | Jeder Knopf, jeder Dialog samt Pflichtfeldern, jede Ausgabe, Suche, Kalender, Zeitreise, Speicherung über einen Neustart, Rechte des Lesezugangs, Bearbeiten/Verwerfen/Archiv/Sicherung, HTML in Eingaben | 217 Prüfungen |
| `db:check` | Migrationen, Seed und SQL-Tests in einer frischen Datenbank; bricht ab, wenn stillschweigend weniger als 175 Prüfungen laufen | 181 Prüfungen |

Die Regeln dazu stehen in `CLAUDE.md` und gelten für jede Sitzung: nie mit
rotem Prüflauf committen, jeder neue Knopf bekommt seine Prüfung im selben Commit.

## 1.4.0 — 2026-09-19

### Die Risikomatrix erklärt sich jetzt selbst

Eine Skala ohne Worte ist Auslegungssache: Jede und jeder versteht unter einer
„4" etwas anderes, und damit ist eine Risikomatrix Dekoration statt Werkzeug.

- **Beide Skalen sind ausgeschrieben** — fünf Stufen für Eintritt und fünf für
  Auswirkung, in der Sprache einer Trainingsorganisation: von „etwas
  Mehraufwand, kein Termin in Gefahr" bis „Qualifikation, Zulassung oder
  Betrieb sind betroffen".
- **Was aus einem Wert folgt**, steht daneben: 1–4 hinnehmen, 5–9 Maßnahme
  festlegen, 10–14 umsetzen und nachhalten, 15–25 sofort in die Leitungsrunde.
- **Die Felder sind anklickbar.** Ein Klick zeigt genau die Risiken darin und
  nennt Wert, Stufe und die nächste Handlung. Die Matrix bleibt dabei
  vollständig stehen — sonst verschwände die Übersicht, in der man gerade ist.
- **Die Erklärung lässt sich zuklappen** und bleibt zu, wer sie kennt.
- **Im Risikodialog tragen die Stufen ihre Bedeutung mit**, und der Risikowert
  samt Einstufung und Handlungsempfehlung steht sofort daneben — an der Stelle,
  an der jemand ein Risiko einträgt, nicht auf einer anderen Seite.

### Funktionsdurchlauf durch die ganze Anwendung

Neu: `npm run check:app` — 171 Prüfungen, die die Anwendung durchklicken wie
ein Mensch, der alles anfasst. Anmeldung und beide Zugänge, alle Bereiche, alle
zehn Reiter, jeder Dialog samt Abbrechen und Pflichtfeldern, Datei anhängen und
öffnen, Erledigt und Zurücknehmen, jede Ausgabe, Suche, Wochenbericht,
Kalenderdatei, Zeitreise, Speicherung über einen Neustart hinweg, die Rechte
des Lesezugangs, die englische Fassung und drei Bildschirmbreiten. Läuft in der
CI mit.

**Dabei gefunden und behoben:**

| Befund | Ursache |
|---|---|
| Der Knopf „Rückgängig" im Toast war wirkungslos | Der Toast behielt `pointer-events: none`, auch wenn er sichtbar war. Er sah aus wie ein Knopf, war aber keiner |
| Im Teamzugang lief die Kopfzeile auf dem Telefon 13 px über den Rand | Mit dem Personenwechsel kam ein zweiter Knopf dazu. Jetzt sind alle Elemente der Kopfzeile schrumpfbar, und der Personenwechsel zeigt auf schmalen Schirmen die Initialen |

Die bisherige Prüfung `check:sandbox` hatte beides nicht gefunden: Sie fuhr auf
dem Telefon den Lesezugang, in dem der zweite Knopf fehlt, und klickte keine
Toasts an.

### Ein Hinweis, der eine teure Fehlannahme verhindert

Das Dashboard sagt beim ersten Start, was dieser Prototyp ist und was nicht:
Er speichert **auf dem Gerät**, nicht in einer gemeinsamen Datenbank. Jede
Person sieht ihren eigenen Stand. Für das gemeinsame Arbeiten im Team ist die
Supabase-Instanz nötig — die Datenbank dafür ist fertig und geprüft. Der
Hinweis lässt sich wegklicken und bleibt weg.

## 1.3.0 — 2026-09-19

Vier Bausteine, vom Auftraggeber aus einer Auswahl bestimmt.

### Abhängigkeiten und kritischer Pfad

- **Was auf was wartet:** neue Tabelle `pcc.task_dependencies` mit zwei Arten —
  „erst wenn das fertig ist" und „beides zugleich beginnen" — samt Vorlaufzeit.
  Die übrigen Lehrbuchformen kommen im Trainingsbetrieb nicht vor und wären nur
  eine Quelle für Fehleingaben.
- **Ein Trigger schließt Kreise aus** und lässt nur Aufgaben desselben Projekts
  verbinden. Ein Kreis wäre kein Plan, sondern eine Behauptung, die sich nicht
  auflösen lässt — und jede Terminrechnung liefe endlos.
- **`pcc.critical_path()`** rechnet rückwärts vom Zieltermin: wie viel Puffer
  hat eine Aufgabe, bevor sie ihre Nachfolger und damit das Projektende
  verschiebt? Ohne Puffer liegt sie auf dem kritischen Pfad.
- **`pcc.v_task_links`** weist aus, wo der Plan einer Verbindung widerspricht —
  der Nachfolger beginnt, bevor der Vorgänger fertig sein kann — und um wie
  viele Tage.
- **Im Gantt:** Pfeile zwischen den Balken, der kritische Pfad mit kräftigem
  Rahmen (nicht mit einer weiteren Farbe — Rot heißt schon Verzug), Widersprüche
  rot gestrichelt und als Hinweis über dem Diagramm. Im Aufgabendialog lassen
  sich Vorgänger auswählen.

### Wochenbericht auf Knopfdruck

- **`pcc.changes_since()`** beantwortet die Frage jeder Leitungsrunde aus dem
  Audit-Trail: was hat sich seit einem Stichtag geändert, wann und durch wen.
  Statuswechsel und Terminverschiebungen stehen mit Vorher und Nachher da.
- **Der Bericht schaut in beide Richtungen:** im Zeitraum erledigt, anstehend in
  vierzehn Tagen, überfällig, kritische Risiken, dann die Änderungen. Ein
  Bericht, der nur zurückblickt, beantwortet die Frage nur halb. Rückblick
  wählbar über sieben, vierzehn oder dreißig Tage; PDF und Excel.

### Globale Suche

- **`pcc.search()`** über Projekte, Teilprojekte, Aufgaben, Meilensteine,
  Risiken, Probleme, Entscheidungen und Dokumente. Was der Fragende nicht lesen
  darf, kommt nicht zurück. `pg_trgm` sortiert nach Ähnlichkeit, sodass auch ein
  Tippfehler noch trifft.
- **Im Prototyp** ein Suchfeld in der Kopfzeile: gruppierte Treffer, Eingabetaste
  springt zum ersten, Klick öffnet den Fundort im richtigen Reiter.

### Termine im Kalender

- **`pcc.calendar()`** gibt offene Meilensteine und Aufgabenfristen als
  iCalendar-Text aus — ganztägige Einträge, deren Ende auf den Folgetag fällt,
  weil Outlook sonst den letzten Tag verschluckt. Wahlweise je Projekt oder über
  alle.

### Nebenbei behoben

- **Eine Lücke im Rechteschutz:** Die Liste der Tabellen, für die Row Level
  Security eingeschaltet wird, war von Hand gepflegt — und die neue Tabelle
  fehlte darin. Sie stand damit offen. Jetzt läuft die Migration über *jede*
  Tabelle des Schemas, und ein Test wacht darüber. Aufgefallen ist es, weil eine
  Zusicherung für den Lesezugang nicht scheiterte, wo sie es sollte.

## 1.2.0 — 2026-09-19

### Gantt je Projekt

- **Neuer Reiter-Inhalt „Projektverlauf" im Projekt:** ein Gantt über die
  Teilprojekte, ihre Aufgaben, deren Teilaufgaben und die Meilensteine. Ein
  einzelnes Projekt als ein Balken war nichtssagend — die Frage lautet, was
  *innerhalb* des Projekts wann läuft.
- **Teilprojekte sind eine Klammer, kein Balken:** sie tragen keine eigenen
  Termine, sondern spannen sich über die früheste und späteste Aufgabe darin.
  Die Zeile nennt Anzahl, offene Aufgaben und die verantwortliche Person.
- **Farbe sagt den Zustand** (erledigt, in Arbeit, überfällig oder blockiert,
  nicht begonnen) und steht nie allein: jede Zeile trägt Titel, Referenz und
  Zuständigkeit, der Balken seinen Fortschritt, der Tooltip den Zeitraum. Die
  Prozentzahl erscheint nur, wenn der gefüllte Teil sie auch fasst.
- **Meilensteine als Raute** mit Termin und Status im Text; die Heute-Linie ist
  beschriftet; eine Zeichenerklärung steht unter dem Diagramm.
- **Ohne Termin keine erfundene Dauer:** eine Aufgabe ohne Datum wird als
  solche ausgewiesen, statt einen Balken zu erfinden. Teilaufgaben übernehmen
  Beginn und Frist ihres Elternteils — so steht es im Datenmodell.
- **In die Ausgaben aufgenommen:** das Gantt steht im Projektbericht und hat
  eine eigene Ausgabe (PDF mit Bild und Tabelle, Excel mit den Zeilen).

### Datenbank

- Neue Sicht **`pcc.v_gantt`**: eine Zeile je Balken — Teilprojekte mit
  abgeleiteten Terminen, abgeleitetem Fortschritt und der Zahl offener
  Aufgaben, dazu Aufgaben, Teilaufgaben und Meilensteine, jeweils mit ihrer
  Ebene. Damit rechnet die Datenbank die Ableitungen, nicht jede Oberfläche
  für sich.

## 1.1.0 — 2026-09-19

Vier Festlegungen des Auftraggebers, die das Rechtemodell vereinfachen und die
Arbeit mit Dateien und Ausgaben verbindlich machen.

### Zwei Zugänge statt fünf Rollen

- **`pcc.user_role` kennt nur noch `team` und `viewer`.** Der Teamzugang darf
  alles, der Lesezugang sieht alles und ändert nichts. Beide werden gemeinsam
  benutzt. Ein partieller Unique-Index lässt keinen dritten Zugang zu.
- **Personen und Zugänge sind getrennt.** `public.users` ist das
  Personenverzeichnis — Zuständigkeit, Verantwortung und RACI zeigen darauf;
  nur zwei Zeilen tragen eine Anmeldung (`auth_user_id`). Das Verzeichnis
  pflegt der Teamzugang, Rolle und Anmeldung hält ein Guard fest.
- **Kein Freigabeverfahren mehr.** `approve_user()`, `set_role()` und
  `bootstrap_super_admin()` sind entfallen; an ihre Stelle tritt
  `pcc.prepare_account()`, das die beiden Zugänge einrichtet. Sie verbinden
  sich selbst, sobald in Supabase ein Anmeldekonto mit derselben Adresse
  entsteht. Selbstregistrierung ist abgeschaltet.
- **Der Trail hält zweierlei auseinander:** `audit_log.user_id` den Zugang
  (beweiskräftig), `audit_log.actor_id` die Person, zu der sich die Oberfläche
  bekannt hat (Angabe, kein Nachweis). Eine erfundene Kennung fällt auf den
  Zugang zurück. Was ein gemeinsamer Zugang an Beweiskraft kostet, steht offen
  in Abschnitt 4 der Architektur.
- Policies, Sichten und Funktionen folgen: `can_read()` heißt jetzt
  „angemeldet", `can_edit()` „Teamzugang und nicht archiviert". Neu sind
  `pcc.v_people`; `v_pending_users` ist entfallen, `v_my_notifications` wurde
  zu `v_notifications`.

### Dateien an Aufgaben

- Ein Dokument hängt am Projekt oder an einem Gegenstand darin — in aller Regel
  an einer Aufgabe. Der Trigger `pcc.tg_documents_subject()` weist einen
  Verweis ins Leere oder in ein fremdes Projekt ab.
- Der Ablagepfad lautet `<projekt-id>/<aufgaben-id>/<datei>`; die Storage-Policy
  stützt sich weiterhin auf die erste Ebene.
- Im Prototyp lassen sich Dateien wirklich anhängen: PDF, Word, Excel,
  PowerPoint, CSV, Text und Bilder bis 50 MB, je Aufgabe sichtbar und wieder zu
  öffnen. Der Inhalt liegt in IndexedDB und übersteht das Neuladen.

### Sofort speichern

- Es gibt kein „Speichern" mehr. Jede Änderung geht durch `commit()`: sie wird
  im selben Augenblick abgelegt, gezählt und in jeder offenen Ausgabe
  nachgezogen. Die Sandbox-Leiste zeigt den Zeitpunkt; kann das Fenster nicht
  speichern (privates Fenster, gesperrte Vorschau), sagt sie das.
- In der Anwendung gilt derselbe Ansatz: jeder Vorgang schreibt sofort, und das
  optimistische Sperren über `updated_at` verhindert, dass ein überholter Stand
  einen neueren still überschreibt.

### Exporte immer auf dem letzten Stand

- Jede Ausgabe entsteht im Augenblick des Klicks aus dem Live-Zustand und trägt
  ihren Stand im Kopf: Datum, Uhrzeit und die laufende Nummer der letzten
  Änderung. Ein ausgedrucktes Blatt lässt sich damit einem Datenstand zuordnen.
- Eine offene Druck- oder Excel-Ansicht wird nach jeder Änderung neu aufgebaut,
  statt einen überholten Stand stehen zu lassen.
- Aufgabenlisten und der Projektbericht führen die Anhänge mit, der
  Dokumentenabschnitt nennt zu jeder Datei den Gegenstand.

## 1.0.0 — 2026-09-18

Erste Fassung des Project Control Centers: Datenmodell, Rechte und
Geschäftslogik in PostgreSQL, dazu ein klickbarer Prototyp der Oberfläche.

### Datenbank

- **Schema `pcc`** mit 20 Tabellen: Projekte, Projektteam, Workstreams,
  Aufgaben mit Teilaufgaben, Meilensteine, Risiken, Issues, Entscheidungen,
  RACI, Dokumente, Kommentare, Erwähnungen, Benachrichtigungen, Versionen,
  Versionsänderungen, Vorlagen, Versionsauslöser, Referenzzähler, Einstellungen
  und Changelog. Nutzerkonto und Audit-Trail liegen in `public`, weil beides an
  der Anmeldung hängt und nicht am Fachmodell.
- **Rollen und Sichtbarkeit** über Row Level Security auf jeder Tabelle. Der
  Contributor bearbeitet, was ihm zugewiesen ist; der Viewer liest und
  exportiert; die Projektleitung führt ihr Projekt; archivierte Projekte sind
  schreibgeschützt. Eine NULL-Rolle sperrt die Anwendung vollständig.
- **Selbstregistrierung mit Freigabe:** Ein Trigger auf `auth.users` legt ein
  gesperrtes Profil ohne Rolle an. Ein eigener Guard verhindert, dass jemand
  Rolle, Freigabe oder Aktivstatus an sich selbst ändert.
- **Risk Score** als generierte Spalte — von Hand nicht setzbar, damit Filter
  und Sortierung serverseitig stimmen.
- **Fortschritt** je Aufgabe wahlweise gerechnet oder gesetzt (`progress_mode`),
  **Gesamtlage** immer gerechnet. Rot bleibt selten: verzögert, überfälliger
  Meilenstein oder zwei kritische Risiken.
- **Versionierung** nur bei fachlich bedeutsamen Ereignissen — Statuswechsel,
  verschobener oder erreichter Meilenstein, geänderter Zieltermin, Risiko ab
  Score 15, abgeschlossener Workstream. Die Liste steht als Konfiguration in
  `pcc.version_triggers`. Versionen sind unveränderlich.
- **Dokumente:** Quarantäne bis zur Virenprüfung, 50 MB je Datei, Datei oder
  externer Verweis — nie beides. Eine neue Fassung löst die alte über
  `supersedes_id` ab, statt sie zu überschreiben. Die Storage-Policies des
  privaten Buckets `project-docs` legt eine eigene Migration an; ladbar ist eine
  Datei erst, wenn die Prüfung `clean` gemeldet hat.
- **Audit-Trail** aus Triggern, gegen Änderung und Löschung gesperrt. Die
  einzige Ausnahme ist die Schwärzung nach Artikel 17 — sie berührt nur das
  benannte Feld und wird selbst protokolliert.
- **Löschweg nach Artikel 17 DSGVO:** `pcc.anonymise_user()` pseudonymisiert
  das Konto; die fachliche Zuordnung bleibt über die ID bestehen.
- **Vierzehn Sichten**: Projekte mit gerechneten Kennzahlen (`v_projects`, die
  Grundlage der Oberfläche), Dashboard, Aufgaben, Meilensteine, Risiken, Risk
  Matrix, Issues, überfällige Aufgaben, anstehende Meilensteine, Aktivität,
  Versionsverlauf, Gantt, Benachrichtigungen und Personenverzeichnis — alle mit
  `security_invoker`.
- **Tageslauf** `pcc.run_daily_jobs()`: verzögerte Meilensteine,
  Vorlaufhinweise und Überfälligkeitsmeldungen; als `pg_cron`-Job eingeplant,
  wo die Erweiterung verfügbar ist.
- **SQL-Testsuite** in `supabase/tests/001_core.sql`, ausgeführt über
  `scripts/db-check.sh` und in der CI.

### Oberfläche

- **Prototyp** `sandbox/Control-Center-Sandbox.html`: Dashboard mit Kennzahlen
  und Projektverlauf, Projektliste mit Filtern, Projektakte mit zehn
  Reitern, Aufgaben-, Risiko- und Meilensteinlisten über alle Projekte,
  Berichte, Anmeldebildschirm mit Rollenschnellwahl, Sandbox-Leiste mit
  simuliertem Datum, PDF- und Excel-Export.
- **Frontend-Gerüst** mit Vite, React 19, TypeScript, PWA, Deutsch/Englisch,
  Supabase-Anmeldung und Projektübersicht aus `pcc.v_projects`.

### Geprüft

Vier Durchsichten mit eigenen Prüfern — Oberfläche, Bedienung, Datenbank­sicherheit
und Konsistenz des Repositories. Was daraus behoben wurde:

- **Rechteausweitung geschlossen:** `public.enable_internal_write()` war für
  angemeldete Nutzer aufrufbar und hätte in einer Transaktion sämtliche Guards
  stillgelegt — ein Viewer konnte sich damit zum Super Admin machen. Vier
  Angriffe belegen jetzt in der Testsuite, dass der Weg zu ist.
- **Inbetriebnahme war blockiert:** Die Anleitung im README stufte den ersten
  Nutzer per `update` hoch, was der Rollen-Guard abweist. Dafür gibt es jetzt
  `pcc.bootstrap_super_admin()`, und die Selbstregistrierung ist in
  `supabase/config.toml` eingeschaltet — sie ist die Grundlage des Rechtemodells.
- **Kennzahlen zeigten die falsche Zahl:** Das Dashboard zählte den von Hand
  gesetzten Projektstatus, während die Zeitstrahlen darunter die gerechnete
  Gesamtlage zeigten. Beide Zahlen kommen jetzt aus derselben Quelle, und jede
  Ampel trägt ihre Begründung neben sich.
- **Berichte verschwiegen ihren Filter:** Ein Filter aus der Projektliste wirkte
  bis in den PDF-Bericht für die Geschäftsleitung, ohne dass es dort sichtbar
  war. Jetzt steht er in der Ansicht und im Kopf jedes Berichts.
- **Weiteres:** Aufgabenliste mit Filter auf Zuständigkeit, Status und Zeitraum;
  einheitliche Leerzustände; beschriftete Ampeln und Abzeichen; Achsen der
  Risikomatrix benannt; „Erledigt" nennt die Aufgabe und lässt sich zurücknehmen;
  deutsche Prioritäten statt Low/Medium/High; vier Kontraste auf WCAG AA
  gehoben; Fingerbreite Trefferflächen auf dem Telefon.

### Behoben aus den Prüfberichten

Was die vier Durchsichten zusätzlich aufgeworfen haben und was daraus geworden ist:

| Befund | Behebung |
|---|---|
| Der Trail ließ kein Schwärzen zu, obwohl Artikel 17 es verlangt | `pcc.redact_audit()` schwärzt genau ein benanntes Feld; ein eigener Trigger auf `public.audit_log` erlaubt nur diesen einen Fall und weist jedes Löschen und jede andere Änderung weiter ab |
| Meilensteine konnten voneinander im Kreis abhängen | Trigger `pcc.tg_milestone_cycle()` |
| RACI konnte auf einen Gegenstand aus einem fremden Projekt zeigen | Trigger `pcc.tg_raci_subject()` |
| Versionsnummern zählten über die Hauptnummer hinweg und wurden als Text sortiert | Zählung innerhalb der Hauptnummer, Sicht `pcc.v_versions` sortiert numerisch |
| Delete-Rechte auf Dokumenten und Kommentaren, die keine Policy je zuließ | entzogen; gelöscht wird über `pcc.delete_document()` und `pcc.delete_comment()` |
| `public.users` hing mit `on delete cascade` an `auth.users` | `on delete restrict`: ein entferntes Anmeldekonto nimmt das Profil nicht mit |
| Der Ablagepfad eines Dokuments war frei wählbar | Check-Constraint `<projekt-id>/<datei>`, auf den sich die Storage-Policy stützt |
| Der Reiter „Projektverlauf" wiederholte die Übersicht | eigener Inhalt: Zeitstrahl mit Zeichenerklärung und beschrifteter Heute-Linie, darunter die Termine des Projekts |
| Verlauf und Versionen blieben nach dem Sprachwechsel deutsch | Ereignisse liegen als Schlüssel im Speicher und werden erst beim Anzeigen zu Text; die Prüfung `check:sandbox` fährt die englische Fassung eigens an |
| Der Anlegedialog nannte immer nur den ersten Fehler | Pflichtfelder sind gekennzeichnet, alle Beanstandungen erscheinen zusammen, das erste betroffene Feld bekommt den Fokus |
| Entscheidungen waren der einzige Reiter ohne Ausgabe | PDF und Excel wie überall sonst |
| Wortschatz aus der Vorgeschichte | Issues → Probleme, Workstream → Teilprojekt, Scope → Abgrenzung, Management Timeline → Projektverlauf, Datensätze → Einträge; die Unterschriftszeilen des Berichts lauten Projektleitung und Sponsor |
| Kein PWA-Symbol in den geforderten Größen | 192, 512 und ein maskierbares 512, erzeugt von `scripts/make-icons.py` |
| Die Oberfläche nannte ihre Fassung nicht | Die Nummer kommt zur Bauzeit aus `package.json` und steht in der Kopfzeile |

### Hinweis zur Vorgeschichte

Dieses Repository enthielt bis zur Version 1.0.0 zusätzlich das Modul
**AAA Flow** (Gate-Steuerung für Trainingsvorgänge). Es wurde auf Wunsch
vollständig entfernt; die Anwendung ist seitdem einteilig. Die Geschichte
bleibt in der Versionsverwaltung erhalten.
