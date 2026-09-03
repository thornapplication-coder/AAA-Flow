# Architektur und Entscheidungen

Stand: Schema 1.0.0. Ergänzt die Spezifikation (`docs/SPEC.md`) um die
Entscheidungen, die bei der Umsetzung des Fundaments getroffen wurden.

## Leitprinzip: Logik in der Datenbank

Gate-Sperre, Vier-Augen-Prinzip, Zuständigkeit und Audit werden in
PostgreSQL erzwungen, nicht im Frontend. Das Frontend ruft Funktionen auf
(`claim_case`, `complete_checkpoint`, `release_gate`, …) und liest Views.
Gründe:

- Kontrolle wirkt nur, wenn sie blockiert (Spec 1). Eine Regel, die nur in
  der Oberfläche lebt, ist über die API umgehbar.
- Ein späterer zweiter Client (Edge Function, Export, Standardsoftware) erbt
  dieselben Regeln.
- Die Regeln sind mit einer SQL-Testsuite ohne Browser prüfbar.

Guard-Trigger weisen direkte Schreibzugriffe auf `cases.status`, `gates`,
`case_assignments`, `case_checkpoints` und `exceptions` ab. Die Funktionen
schalten den Schreibmodus per Transaktions-Setting `app.internal_write`
frei und wieder aus.

## Abweichungen und Ergänzungen zum Datenmodell der Spec

| Punkt | Entscheidung | Begründung |
|---|---|---|
| `trainees` als eigene Tabelle | `cases.trainee_id` statt `trainee_name`/`trainee_dob` | Trainee-Threads müssen über mehrere Kurse hinweg funktionieren (Spec 5a); dafür braucht der Trainee eine stabile Identität. |
| `cases.company_id` | statt Freitext `customer` | Firmen-Threads und Zahlungsthemen hängen an der Firma (Spec 5). |
| `checkpoints.code` | stabiler Schlüssel je Prüfpunkt | Referenzierbar in Tests, Vorlagen und späteren Auswertungen, unabhängig vom Label. |
| `checkpoints.four_eyes` | je Prüfpunkt konfigurierbar | Spec 10 und 14. |
| `checkpoints.requires_gate_complete` | Gate-3-Sperre | Prüfpunkt kann erst erledigt werden, wenn alle anderen Pflichtpunkte des Gates erledigt sind. Im Seed gesetzt für „Zertifikat/Bescheinigung ausgestellt". Umsetzung von offenem Punkt 1 (Entscheidung: Sperre). |
| `checkpoints.deadline_anchor` | `course_start` (rückwärts), `enquiry_date` oder `course_end` (vorwärts) | Sales-eigene Fristen hängen am Anfragedatum, Gate-3-Fristen am Kursende (Spec 6). |
| `case_assignments.pool_since`, `stale_notified_at` | Liegedauer und Liegenbleiber-Meldung | Spec 8 und 13 (Pool-Bestand mit Liegedauer). |
| `exceptions.status` | `requested` / `approved` / `rejected` | Antrag und Entscheidung sind getrennte Schritte (Spec 12). |
| `message_mentions`, `thread_reads` | Erwähnungen und Lesestand | Spec 5a: Erwähnung mit Benachrichtigung, Ungelesen-Zähler je Kontextebene. |
| `audit_log.case_id` | zusätzliche Spalte | Audit-Trail je Vorgang ohne Join, Sichtbarkeit folgt dem Vorgang. |
| `changelog` | Tabelle | Versionsstand im Superadmin-Bereich (Spec 3). |
| Funktionsträger in `settings.function_holders` | Director Training, Head of Training, Sales-Leitung als `user_id` | Das sind Funktionen, keine Rollen. So bleiben sie ohne Schemaänderung umbesetzbar. |

## Regeln, die die Spec offen lässt (Annahmen)

1. **Gate-Reihenfolge ist strikt.** Prüfpunkte von Gate n lassen sich erst
   erledigen, wenn Gate n-1 freigegeben ist. Vorarbeiten am nächsten Gate
   sind damit ausgeschlossen. Wird das im Betrieb als zu hart empfunden, ist
   die Prüfung in `complete_checkpoint` an einer Stelle lockerbar.
2. **Zurücksetzen nur vor Gate-Freigabe.** Nach Freigabe bleibt der Prüfpunkt
   erledigt; ein „Gate wieder öffnen" gibt es nicht. Begründung: Sonst wäre
   der Status „Gebucht" nicht belastbar. Bei echten Fehlern nach Freigabe:
   Vorgang verwerfen und neu anlegen, oder Ausnahme dokumentieren.
3. **Kontrolle (Vier-Augen) durch die Abteilung des Prüfpunkts.** Jeder aktive
   Nutzer der Abteilung außer dem Bearbeiter darf kontrollieren; Admins
   ebenfalls. Das Vier-Augen-Prinzip gilt auch für Vertretungen und Admins.
4. **Admins dürfen Prüfpunkte erledigen**, Teamleader nur, wenn sie zuständig
   sind. Alles wird im Audit-Trail protokolliert.
5. **Gate 1 setzt ein Kursdatum voraus**, weil „Gebucht" den Fristenlauf
   startet (Spec 6). Gate 3 ist erst nach Kursende freigebbar.
6. **Sales legt nur Vorgänge für zugeordnete Muster an**; Sales-Teamleitung
   und Sales-Leitung für alle. Training Admin kann Vorgänge ebenfalls anlegen.
7. **Arbeitstage sind Montag bis Freitag** ohne Feiertagskalender. Ein
   Feiertagskalender ist in `add_business_days` nachrüstbar.
8. **Nachrichten bearbeitet nur der Autor** (Superadmin ausgenommen); jede
   Bearbeitung landet in `message_edits`. Löschen ist auch für den Superuser
   per Trigger gesperrt.
9. **Erinnerungen** gehen an den Zuständigen, bei Pool-Vorgängen an die
   Teamleader der Abteilung. Ist keine Eskalationsstufe hinterlegt, ersetzt der
   Teamleader sie. Stufe 2 geht an Director Training und Head of Training.
10. **E-Mail-Versand** ist entkoppelt: Die Datenbank schreibt `notifications`
    mit `email_status = 'pending'`; eine Edge Function versendet und setzt
    `sent`/`failed` mit Fehlertext (Admin-Panel, Spec 11 und 14).

## Rechte in Kurzform

| Aktion | Wer |
|---|---|
| Vorgang anlegen | Sales (eigene Muster), Training Admin, Teamleader, Admin |
| Aus dem Pool übernehmen | jeder aktive Nutzer der Abteilung, sofern sichtbar |
| Zuweisen / in den Pool zurücklegen | Teamleader der Abteilung, Admin (zurücklegen auch der Zuständige) |
| Prüfpunkt erledigen | Zuständiger der Prüfpunkt-Abteilung (inkl. Vertretung), Admin |
| Prüfpunkt kontrollieren | zweite Person der Abteilung, Admin — nie der Bearbeiter |
| Prüfpunkt zurücksetzen | Zuständiger, Teamleader der Abteilung, Admin — mit Begründung, nur vor Gate-Freigabe |
| Gate freigeben | Zuständiger oder Teamleader der empfangenden Abteilung, Admin |
| Ausnahme beantragen | Zuständiger, Teamleader der Abteilung, Admin |
| Ausnahme entscheiden | Director Training, Head of Training, Superadmin |
| Verwerfen | Zuständiger, Teamleader, Admin — mit Begründung |
| Nutzer anlegen | Superadmin |
| Prüfpunkt-Katalog ändern | Superadmin |
| Einstellungen, Muster, Zuordnungen | Admin, Superadmin |

## Sichtbarkeit

- Sales: Vorgänge der zugeordneten Muster (auch im Pool), eigene Zuständigkeiten,
  alles bei Teamleader-Rolle oder als Sales-Leitung. Vertretung erbt die Sicht
  des Vertretenen.
- Training Admin, ATO, Admins: alle Vorgänge.
- Firmen-Threads: alle, die mindestens einen Vorgang der Firma sehen, plus
  alle Teamleitungen. Vorgangs- und Trainee-Threads folgen dem Vorgang.
- Audit-Trail: Admins alles, sonst nur Einträge zu sichtbaren Vorgängen.

## Views und Statusmodell

`v_case_checkpoints`, `v_gates` und `v_cases` liefern je Ebene genau einen
Anzeigezustand `display_state` aus `open`, `in_progress`, `done`, `overdue`
(dominant) sowie `discarded` beim Vorgang. `v_pool` zeigt den Pool mit
Liegedauer in Arbeitstagen, `v_pipeline` die Vorgangsbahn mit Bestand und
Blockierern je Gate, `v_exception_stats` die Ausnahmen nach Abteilung, Muster
und Prüfpunkt, `v_gate_lead_times` die Gate-Durchlaufzeiten.

## Offene Punkte der Spec — Stand im Fundament

| # | Punkt | Stand |
|---|---|---|
| 1 | Gate-3-Sperre | umgesetzt (`requires_gate_complete`, Test 7) |
| 2 | Supabase-Region | Projekt noch nicht angelegt; Empfehlung EU/Frankfurt bleibt |
| 3 | Hex-Codes und Logo | Farbwerte und Typografie aus dem Prototyp übernommen (`src/styles/theme.css`); Logo steht weiterhin aus |
| 4 | Eskalationsstufen | `settings.escalation.contacts` je Abteilung, im Admin-Panel zu pflegen |
| 5 | Sales-Leitung | `settings.function_holders.sales_lead` |
| 6 | Course Supervisor Phenom, M2 | Fallback auf Head of Training aktiv (Test) |
| 7 | Ablageort Kursakte | `settings.course_file.base_path`, noch leer |
| 8, 10 | Aufbewahrungsfristen | `settings.retention`, noch leer; keine Löschlogik |
| 9 | Regulatorische Referenzen | Katalog ohne Paragraphenverweise, Feld `evidence` vorbereitet |
| 11 | Sales-Akzeptanz | Kennzahlen dafür: `v_pool` (Liegedauer Sales), `v_exception_stats` |

## Regelwerk je Prüfpunkt — Erweiterung gegenüber Schema 1.0.0

Das Admin-Panel der Sandbox vergibt je Prüfpunkt Regeln, die über die heutigen
Spalten von `checkpoints` hinausgehen. Bewährt sich das im Prototyp, sind
folgende Spalten zu ergänzen (Migration `20260904_checkpoint_rules.sql`):

| Regel | Spalte | Wirkung | Schon im Schema |
|---|---|---|---|
| Pflicht / optional | `mandatory` | ohne den Punkt keine Gate-Freigabe | ja |
| Vier-Augen-Pflicht | `four_eyes` | Erledigen und Kontrollieren durch zwei Personen | ja |
| Frist und Anker | `deadline_days`, `deadline_anchor` | Arbeitstage vor Kursbeginn bzw. nach Anfrage oder Kursende | ja |
| Erst nach allen übrigen Pflichtpunkten | `requires_gate_complete` | Sperre des Abschlussnachweises | ja |
| Musterfilter | `aircraft_type_filter` | Punkt gilt nur für bestimmte Muster | ja |
| Aktiv / deaktiviert | `active` | wirkt nur auf neu angelegte Vorgänge | ja |
| **Sperrt nachfolgende Punkte** | `blocks_following bool` | solange offen, ist kein späterer Punkt desselben Gates erledigbar | **nein** |
| **Vorbedingung** | `depends_on uuid` | erst möglich, wenn ein bestimmter anderer Punkt erledigt ist | **nein** |
| **Kurstypfilter** | `course_type_filter text[]` | Punkt gilt nur für bestimmte Kurstypen, z. B. Prüfer nur beim Type Rating | **nein** |
| **Nur Teamleitung** | `role_required user_role` | nur die Teamleitung der Abteilung darf abhaken | **nein** |
| **Nachweis verpflichtend** | `evidence_required bool` | beim Erledigen ist der Nachweis zu erfassen (landet in `case_checkpoints.note`) | **nein** |

`blocks_following` und `depends_on` sind bewusst beide vorgesehen: Ersteres ist
ein Schalter für den häufigen Fall „dieser Punkt kommt zuerst", Letzteres die
genaue Angabe einer einzelnen Abhängigkeit. Beide werden in
`complete_checkpoint()` geprüft und melden den blockierenden Punkt im Klartext.

**Katalogänderungen und laufende Vorgänge.** Der Katalog wird je Vorgang bei der
Anlage festgehalten; spätere Änderungen wirken nur auf neue Vorgänge. Weil das
im Betrieb zu eng sein kann, bietet das Anlegen eines Prüfpunkts die Option
„auf laufende Vorgänge anwenden" — abgeschlossene und verworfene Vorgänge
bleiben ausgenommen. In der Datenbank entspricht das einem gezielten
`instantiate_case_checkpoints()` für die betroffenen Vorgänge, mit Eintrag im
Audit-Trail.

## Offene Entscheidung: Vier-Augen-Prinzip an Gate 3

Bei Gate 1 und Gate 2 empfängt eine andere Abteilung, als geliefert hat — die
Gate-Freigabe ist dort automatisch ein zweites Augenpaar. Bei **Gate 3 nicht:**
Training Admin empfängt von ATO, hat in Gate 3 aber selbst zwei Pflichtpunkte
(Records übergeben, Zertifikat ausstellen). Dieselbe Person kann beide erledigen
und anschließend das Gate freigeben.

Der ursprüngliche Prototyp löste das mit einem eigenen Abnahme-Prüfpunkt der
empfangenden Abteilung mit Vier-Augen-Pflicht. Drei Wege:

1. **Freigabe darf nicht von der Person kommen, die einen Pflichtpunkt des Gates
   erledigt hat.** Kleinste Änderung, eine zusätzliche Prüfung in `release_gate`.
   Empfohlen.
2. Abnahme-Prüfpunkt je Gate wie im Prototyp — dokumentiert die Abnahme
   ausdrücklich, erfasst sie aber neben `gates.released_by` ein zweites Mal.
3. Belassen und über den Audit-Trail nachhalten. Nicht empfohlen: die Prüfung
   wäre dann nachträglich statt sperrend, was dem Grundgedanken widerspricht.

## Export

Die Spec verlangt Export der gefilterten Sicht als PDF und Excel sowie einen
je Vorgang, Zeitraum, Person oder Abteilung exportierbaren Audit-Trail
(Abschnitt 13).

- **PDF** entsteht in der Sandbox über eine eigene Druckansicht: die
  Bildschirmoberfläche wird per `@media print` ausgeblendet und ein eigens
  aufgebautes Dokument gedruckt. Das hat gegenüber einer PDF-Bibliothek den
  Vorteil, dass Kopf, Fußzeile, Seitenumbrüche und wiederholte Tabellenköpfe
  vom Browser übernommen werden. Für die Zielversion bleibt das der einfachste
  Weg; erst wenn serverseitig erzeugte PDFs gebraucht werden (etwa als Anhang
  einer Mail), lohnt eine Edge Function mit einer Rendering-Bibliothek.
- **Excel** liefert die Sandbox als tabulatorgetrennten Text zum Einfügen,
  weil die Artifact-Vorschau Dateidownloads unterbindet. In der Zielversion
  wird daraus ein echter `.xlsx`-Download.
- Exportierbar sind: Vorgangsliste in der jeweils gefilterten Sicht,
  Ausnahmen, Prüfpunkt-Katalog, Nutzer, Firmen, Trainees, Prüfpunkte und
  Audit-Trail eines Vorgangs sowie die vollständige Vorgangsakte als PDF.
- Der Audit-Export je Zeitraum, Person und Abteilung ist umgesetzt. In der
  Zielversion liest die Ansicht `audit_log` mit den Filtern auf `created_at`,
  `user_id` und der Abteilung des handelnden Nutzers; die RLS-Policy
  `audit_log_select` beschränkt die Zeilen bereits heute auf Vorgänge im Rahmen
  der eigenen Sichtbarkeit, Admins sehen alles. Für große Zeiträume ist eine
  Seitenaufteilung nachzurüsten, der Index `audit_log_created_idx` liegt vor.

## Logins und Rollen

Die E-Mail-Adresse in `users.email` ist der Login. Angelegt wird ausschließlich
durch den Superadmin: In der Zielversion legt eine Edge Function mit der
Supabase Admin API den Auth-Nutzer an und verschickt die Einladung, das Profil
in `public.users` entsteht im selben Schritt. Der Guard-Trigger
`tg_users_role_guard` erzwingt bereits heute, dass nur ein Superadmin Nutzer
anlegt und die Superadmin-Rolle vergibt; ergänzt werden sollte, dass ein
Superadmin sich die eigene Rolle nicht entziehen kann, damit kein Projekt ohne
Superadmin zurückbleibt.

## Nächste Ausbauschritte

1. Vorgangsakte im Frontend: Gates, Prüfpunkte, Erledigen/Kontrollieren,
   Ausnahmen, Kommunikation mit Erwähnungen.
2. Meine Vorgänge / Alle Vorgänge mit Filterleiste (URL-Zustand), Sortierung,
   Export PDF/Excel.
3. Dashboard mit Vorgangsbahn und Kennzahlen aus `v_pipeline`,
   `v_exception_stats`, `v_gate_lead_times`.
4. Admin-Panel: Nutzer (über Supabase Admin API in einer Edge Function),
   Katalog, Zuordnungen, Vertretungen, Einstellungen, Mailfehler, Audit-Log.
5. Edge Functions: E-Mail-Versand, Tagesjob-Aufruf, Nutzeranlage.
6. Feiertagskalender für Arbeitstage.
