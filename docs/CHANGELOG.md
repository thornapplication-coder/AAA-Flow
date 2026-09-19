# Changelog

Versionierung nach Schema `MAJOR.MINOR.PATCH`. Der Versionsstand wird zusätzlich
in der Tabelle `pcc.changelog` geführt und im Bereich des Super Admins angezeigt.

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
- **Dreizehn Sichten**: Projekte mit gerechneten Kennzahlen (`v_projects`, die
  Grundlage der Oberfläche), Dashboard, Aufgaben, Meilensteine, Risiken, Risk
  Matrix, Issues, überfällige Aufgaben, anstehende Meilensteine, Aktivität,
  Versionsverlauf, Benachrichtigungen und offene Freigaben — alle mit
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
