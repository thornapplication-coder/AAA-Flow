# AAA Flow — Spezifikation

**Produkt:** AAA Flow
**Organisation:** Aviation Academy Austria (AAA)
**Status:** Draft v0.2 — zur Umsetzung in Claude Code
**Prototyp:** `AAA-Flow-Sandbox.html`
**Owner:** Patrick Thorn (Director Training)

---

## 1. Zweck

AAA Flow steuert den Weg eines Trainings von der Kundenanfrage bis zum vollständig abgelegten Trainingsnachweis über drei Abteilungen hinweg: **Sales**, **Training Admin**, **ATO**.

Das Tool löst zwei konkrete Probleme:

1. **Aufgaben werden vergessen.** Heute existiert ein Vorgang in Excel, Mail und auf dem Laufwerk parallel. Es gibt keine verbindliche Quelle der Wahrheit, keine Frist und keinen benannten Verantwortlichen je Schritt.
2. **Kontrolle findet nicht statt.** Fehler werden nachträglich gefunden statt vorher verhindert.

Der Lösungsansatz ist **nicht** eine digitale Checkliste, sondern eine **Gate-Steuerung**: Ein Vorgang kann den nächsten Schritt nicht erreichen, solange die Pflichtprüfpunkte der aktuellen Stufe offen sind. Kontrolle wirkt nur, wenn sie blockiert.

---

## 2. Scope

### In Scope

- Vorgang mit Status und Lebenszyklus
- Drei Gates mit konfigurierbaren Prüfpunkten
- Aufgabenzuweisung nach Pull-Prinzip mit Pool
- Fristen, Erinnerungen, Eskalation
- Sperrlogik: offenes Gate blockiert den nächsten Schritt
- Vier-Augen-Prinzip
- Vertretungsregelung
- Ausnahmefreigaben mit Dokumentation
- Dashboard für Director Training und Head of Training
- Admin-Panel

### Bewusst nicht in Scope

| Nicht enthalten | Bleibt wo |
|---|---|
| Scheduling (Slots, Kalender, Ressourcenplanung) | bestehende Lösung / spätere Standardsoftware |
| Kursverwaltung, Lehrpläne, Curricula | ATO-Systeme |
| Trainingsrecords als Archiv | Laufwerk / Dokumentenablage |
| Dokumentenlenkung (OM, TM, Revisionen) | SharePoint / M365 |
| Grading und Kompetenzbewertung | InstructorConnect Grading Tool |
| Rechnungsstellung | Buchhaltung |

Der schmale Zuschnitt ist bewusst. AAA Flow dupliziert keine Kernfunktion einer möglichen späteren ATO-Standardsoftware und bleibt dadurch ablösbar oder ergänzend einsetzbar.

---

## 3. Technische Rahmenbedingungen

- **Typ:** Standalone PWA, eigenständig — keine Codebasis- oder Datenbank-Kopplung an InstructorConnect oder AAA Connect
- **Backend:** Supabase (Region EU/Frankfurt empfohlen, siehe offene Punkte)
- **Plattformen, in dieser Priorität:** 1. Desktop, 2. Tablet/iPad, 3. iPhone. Desktop ist die Leitplattform — Layoutdichte, Tabellenbreite und Filterleiste werden für Desktop optimiert und nach unten reduziert, nicht umgekehrt. Auf iPhone entfällt die Tabellenansicht zugunsten einer Kartenliste; Gates, Kommunikation und Übernahme aus dem Pool müssen dort vollständig bedienbar bleiben
- **Sprachen:** Deutsch / Englisch, individuell je Nutzer umschaltbar. Betrifft ausschließlich Oberfläche und Bedienelemente, nicht eingegebene Inhalte
- **Design:** visuell konsistent zu AAA Connect — dunkelblaue Farbtöne, Kachelstruktur, modernes Layout. Hex-Codes und Logo werden nachgeliefert
- **Sortierung:** sämtliche Listen und Dropdowns alphabetisch
- **Versionierung:** Schema 1.0.0, Changelog im Superadmin-Bereich
- **Backup:** automatisches Datenbank-Backup, Pflicht
- **Login:** keine Selbstregistrierung, Nutzeranlage ausschließlich durch Admins

---

## 4. Rollen und Rechte

Zwei Ebenen, die unabhängig voneinander konfigurierbar sein müssen:

- **Rolle** bestimmt, was jemand grundsätzlich darf.
- **Zuständigkeit pro Vorgang** bestimmt, wer es konkret tut.

| Rolle | Rechte |
|---|---|
| **Superadmin** | Vollzugriff, Admin-Panel, Nutzerverwaltung, Prüfpunkt-Katalog, Changelog |
| **Admin** | wie Superadmin ohne Nutzeranlage und Katalogänderung |
| **Teamleader** | Abteilungssicht, Zuweisung, Eskalationsempfänger, Ausnahmen anfordern |
| **Mitarbeiter** | Pool einsehen, Vorgänge übernehmen, eigene Aufgaben bearbeiten |

Jeder Nutzer ist genau einer Abteilung zugeordnet: Sales, Training Admin oder ATO.

---

## 4a. Mehrwert je Abteilung

AAA Flow scheitert, wenn es als reines Kontrollinstrument wahrgenommen wird. Jede Abteilung muss einen eigenen, spürbaren Nutzen haben — sonst wird es umgangen. Der Nutzen ist bewusst je Abteilung unterschiedlich:

| Abteilung | Nutzen | Ersetzt heute |
|---|---|---|
| **Sales** | Status jedes Kunden jederzeit einsehbar, ohne nachzufragen. Kundenrückfragen ("wann startet der Kurs?", "was fehlt noch?") sind ohne Rückfrage bei Training Admin beantwortbar | Mails und Anrufe bei Training Admin |
| **Training Admin** | Alles zu einem Vorgang an einer Stelle statt in Mail, Excel und Laufwerk. Keine Rückfragen mehr zu unvollständigen Dokumenten — der Pool zeigt, was ankommt | Suche über drei Ablagen |
| **ATO** | Sicherheit, dass am Kurstag alles bereit ist. Gate 2 zeigt vor Kursbeginn, was fehlt, statt am Kurstag zu überraschen | Überraschungen am Kurstag |
| **Leitung** | Belastbare Zahlen zu Bestand, Engpässen und Ausnahmen statt Bauchgefühl | Nachträgliche Fehlersuche |

**Kritische Selbsteinschätzung:** Sales hat den geringsten unmittelbaren Nutzen und die meiste zusätzliche Erfassungsarbeit (Gate 1). Die Statustransparenz und der Kommunikationskanal (Abschnitt 5a) sind der Ausgleich. Bleibt die Sales-Akzeptanz aus, kippt das Modell an Gate 1 — das ist das größte Adoptionsrisiko des Projekts und sollte in den ersten drei Monaten aktiv beobachtet werden.

---

## 5. Datenmodell

### Kernentscheidung

**Ein Vorgang = ein Trainee.** Ein Kurs mit sechs Teilnehmern erzeugt sechs Vorgänge. Es gibt bewusst **keine** übergeordnete Kursklammer.

Konsequenz: Kursweite Angaben (Instruktor, Prüfer, FSTD-Slot, Kursdatum) werden pro Vorgang geführt. Um doppelte Erfassung zu vermeiden, ist eine **Übernahmefunktion** erforderlich: Diese Felder lassen sich per Klick auf alle anderen Vorgänge mit identischem Muster und Kursdatum kopieren. Die Übernahme ist eine reine Eingabehilfe, sie erzeugt keine Verknüpfung im Datenmodell.

### Tabellen

**users** — id, name, email, department, role, active, language

**aircraft_types** — id, name (alphabetisch: ATR, C525, CL350, CL650, M2, Phenom, XLS), active

**type_assignments** — user_id, aircraft_type_id, department
Steuert bei Sales die Sichtbarkeit, bei ATO die automatische Zuständigkeit.

**deputies** — user_id, deputy_user_id, valid_from, valid_to
Vertretung erhält für den Zeitraum vollen Zugriff auf die Vorgänge des Abwesenden.

**cases** — id, case_number, status, trainee_name, trainee_dob, customer, aircraft_type_id, course_type, enquiry_date, course_start, course_end, closed_reason, created_at

**case_assignments** — case_id, department, user_id, assigned_at
Ein Eintrag je Abteilung und Vorgang. NULL bedeutet: liegt im Pool.

**checkpoints** — id, gate_no, department, label_de, label_en, mandatory (bool), evidence, deadline_days, sort_order, aircraft_type_filter
Konfigurierbarer Katalog. Pflichtfeld-Eigenschaft und Frist im Admin-Panel änderbar.

**case_checkpoints** — case_id, checkpoint_id, status, completed_by, completed_at, verified_by, verified_at, note

**gates** — case_id, gate_no, status, released_by, released_at

**exceptions** — case_id, gate_no, checkpoint_id, reason, requested_by, approved_by, approved_at

**notifications** — user_id, case_id, type, due_at, sent_at, escalated

**companies** — id, name, active
Eigene Entität, da Kommunikation und Zahlungsthemen auf Firmenebene stattfinden und mehrere Vorgänge betreffen.

**messages** — id, scope (case | trainee | company), scope_id, user_id, body, created_at, edited_at
Siehe Abschnitt 5a.

**message_edits** — message_id, previous_body, edited_by, edited_at

**audit_log** — user_id, entity, entity_id, action, old_value, new_value, timestamp

**settings** — key, value (Liegenbleiber-Frist, Eskalationsstufen, Standardfristen, Mailadressen)

---

## 5a. Kontextbezogene Kommunikation

Der zweitwichtigste Baustein nach den Gates. Er ersetzt die Mailkommunikation zwischen den Abteilungen und ist der Hauptgrund, warum Sales das Tool freiwillig nutzt.

### Drei Kontextebenen

| Ebene | Wofür | Beispiel |
|---|---|---|
| **Firma** | kommerzielle und übergreifende Themen | „Trainee ABX von Firma GHD hat noch nicht bezahlt" |
| **Trainee** | personenbezogene Themen über mehrere Kurse hinweg | „Medical läuft vier Tage vor Kursende ab" |
| **Vorgang** | alles zum konkreten Training | „Sollen wir das Training planen, es fehlen noch Dokumente" |

Jeder Thread ist abteilungsübergreifend. Sales, Training Admin und ATO schreiben im selben Strang — das ist der Punkt, denn heute laufen genau diese Abstimmungen in getrennten Mailketten.

### Auditsicherheit

**Nachrichten können nicht gelöscht werden.** Sie sind Teil der Vorgangsakte. Bearbeiten ist möglich, erzeugt aber einen Eintrag in `message_edits` und einen Vermerk „bearbeitet" an der Nachricht.

> **Wichtiger Unterschied zu AAA Connect:** Dort ist automatisches Löschen von Nachrichten eine Kernanforderung. In AAA Flow ist es ausgeschlossen. Wer im Kommunikationsstrang über fehlende Dokumente oder offene Zahlungen spricht, dokumentiert damit den Vorgang. Diese Unterscheidung muss den Nutzern in der Oberfläche erklärt werden, da sie beide Tools parallel verwenden.

### Sichtbarkeit von Threads

- **Vorgangs- und Trainee-Threads** folgen der Sichtbarkeit des Vorgangs. Sales sieht sie nur bei zugeordnetem Muster.
- **Firmen-Threads sind für alle sichtbar,** die mindestens einen Vorgang dieser Firma sehen dürfen, sowie für alle Teamleitungen.

Begründung: Kommerzielle Themen wie Zahlungsverzug sind nicht musterspezifisch. Wäre der Firmen-Thread nach Mustern gefiltert, sähe eine Sales-Person nur Bruchstücke der Zahlungsdiskussion — das erzeugt genau die Informationslücke, die das Tool schließen soll.

### Weitere Anforderungen

- Erwähnung von Personen und Abteilungen, mit Benachrichtigung
- Ungelesen-Zähler je Kontextebene
- Verweis von einer Nachricht auf einen konkreten Prüfpunkt
- Volltextsuche über alle Threads, im Rahmen der Sichtbarkeit
- Keine Direktnachrichten. Kommunikation immer an einen Kontext gebunden — analog zur Entscheidung in AAA Connect

---

## 6. Lebenszyklus des Vorgangs

| Status | Ausgelöst durch | Laufen Fristen? |
|---|---|---|
| **Anfrage** | Kundenanfrage bei Sales | Nein |
| **Gebucht** | Kursdatum fixiert | Ja |
| **Freigegeben** | Gate 2 passiert | Ja |
| **In Durchführung** | Kursbeginn erreicht | Ja |
| **Abgeschlossen** | Gate 3 passiert | Nein |
| **Verworfen** | manuell, mit Pflichtangabe Grund | Nein |

### Trigger und Fristenanker — wichtige Unterscheidung

Der **Trigger** ist die Kundenanfrage: sie legt den Vorgang an. Der **Fristenanker** ist der **Kursbeginn**: alle Fristen rechnen rückwärts von dort.

Solange kein Kursdatum feststeht, laufen **keine** Gate-Fristen. Andernfalls erzeugt das System Erinnerungen für Kurse, die nie stattfinden. Ausgenommen sind Sales-eigene Fristen (z. B. Angebot binnen X Arbeitstagen ab Anfrage), die am Anfragedatum hängen.

Der Status **Verworfen** ist verpflichtend zu nutzen. Ohne ihn füllt sich das System binnen eines Jahres mit Karteileichen und das Dashboard verliert seine Aussagekraft.

---

## 7. Die drei Gates

| Gate | Übergabe | Freigabe durch | Blockiert bei Nichtfreigabe |
|---|---|---|---|
| **1 — Booking Accepted** | Sales → Training Admin | Training Admin | Vorgang erreicht nicht Status „Gebucht" |
| **2 — Course Readiness** | Training Admin → ATO | ATO (Course Supervisor) | Kein Trainingsbeginn |
| **3 — Course Closure** | ATO → Training Admin | Training Admin | siehe unten |

Ein Gate gibt frei, wer die Arbeit **empfängt** — nicht wer sie geleistet hat. Das ist der Kern des Modells: Sales meldet nicht „verkauft", sondern liefert einen prüfbaren Dokumentensatz ab, den Training Admin annimmt oder zurückweist.

### Gate 1 — Prüfpunkte (Vorschlag, konfigurierbar)

- Kundenauftrag liegt vor
- Trainee-Stammdaten vollständig
- Lizenzkopie vorhanden und gültig
- Medical vorhanden und gültig **am letzten Kurstag**
- Sprachkenntnisvermerk vorhanden und gültig
- Voraussetzungen für den Kurstyp geprüft (Vorerfahrung, bestehende Berechtigungen)
- Kurstyp und Muster eindeutig festgelegt
- Rechnungsdaten vollständig
- Sonderbedarf erfasst (Visum, Unterkunft) — optional

### Gate 2 — Prüfpunkte (Vorschlag, konfigurierbar)

- Kursdatum bestätigt
- FSTD-Slot bestätigt
- Instruktor zugewiesen, qualifiziert und current für das Muster
- Prüfer zugewiesen, qualifiziert und current (sofern Prüfung Teil des Kurses)
- Trainingsunterlagen auf gültigem Revisionsstand bereitgestellt
- Verwendete Formulare auf gültigem Revisionsstand
- Kursakte angelegt
- Joining Instructions an Trainee versandt
- Theorie/Ground School geplant

### Gate 3 — Prüfpunkte (Vorschlag, konfigurierbar)

- Anwesenheit dokumentiert
- Grading Sheets vollständig und beidseitig unterschrieben
- Deferred Items geschlossen oder dokumentiert
- Additional Training dokumentiert, sofern zutreffend
- Prüfungsergebnis dokumentiert
- Records an die Ablage übergeben
- Zertifikat/Bescheinigung ausgestellt
- Kundenfeedback eingeholt — optional

### Durchsetzung Gate 3

**Umgesetzt wird:** Warnung im Dashboard bei fehlenden Records, plus Eskalation.

**Nicht umgesetzt:** Kopplung an die Rechnungsfreigabe.

> **Hinweis des Autors dieser Spec:** Gate 3 ist ohne harte Sperre der schwächste Punkt des Modells. Nach Kursende ist der Handlungsdruck gering und die Records trudeln erfahrungsgemäß nach — genau daraus entstehen später Beanstandungen zur Vollständigkeit von Trainingsunterlagen. Empfohlene Alternative ohne externe Schnittstelle: **kein Kursabschlussnachweis, solange Pflicht-Records fehlen.** Die Sperre bliebe vollständig innerhalb der ATO. Siehe offene Punkte.

---

## 8. Zuständigkeit und Zuweisung

### Modell: Pull

Vorgänge werden nicht zugeteilt, sondern übernommen. Ein Vorgang ohne Zuständigen liegt im **Pool** der jeweiligen Abteilung.

| Abteilung | Zuständigkeit |
|---|---|
| **Sales** | Pull aus dem Pool, gefiltert nach zugeordneten Mustern |
| **Training Admin** | Pull aus dem Pool, alle Vorgänge sichtbar |
| **ATO** | automatisch über das Muster — Course Supervisor der Flotte |

### Liegenbleiber-Regel (Pflicht)

Pull hat eine bekannte Schwäche: unattraktive oder komplizierte Vorgänge bleiben liegen, weil sich jeder das Einfache greift. Ohne Gegenmechanismus entsteht das ursprüngliche Problem in neuer Form.

**Regel:** Wird ein Vorgang nicht innerhalb von **2 Arbeitstagen** aus dem Pool übernommen, geht er automatisch an den Teamleader der Abteilung zur Zuweisung. Frist im Admin-Panel konfigurierbar.

### Fallback-Regeln

- **ATO:** ist für ein Muster kein Course Supervisor hinterlegt, fällt die Zuständigkeit auf den **Head of Training**. Erforderlich, da nicht alle Musterposten dauerhaft besetzt sind.
- **Sales:** ist einem Muster niemand zugeordnet, fällt die Zuständigkeit auf die **Sales-Leitung**.

### Vertretung

Jede Zuständigkeit braucht eine hinterlegbare Vertretung mit Gültigkeitszeitraum. Die Vertretung erhält temporär vollen Zugriff auf die Vorgänge des Abwesenden, einschließlich der eingeschränkt sichtbaren. Ohne diese Regel blockiert Urlaub einen Vorgang und Erinnerungen laufen ins Leere.

---

## 9. Sichtbarkeit

| Abteilung | Sichtbar |
|---|---|
| **Sales** | nur Vorgänge der eigenen zugeordneten Muster — im Pool wie in der eigenen Liste |
| **Training Admin** | alle Vorgänge |
| **ATO** | alle Vorgänge |

Mehrfachzuordnung von Mustern je Sales-Mitarbeiter muss möglich sein.

**Drei Sichten in der Oberfläche:**

1. **Pool** — unzugewiesene Vorgänge, reduzierte Darstellung (Kunde, Muster, Kursdatum, nächste offene Aufgabe). Ein Klick übernimmt.
2. **Meine Vorgänge** — alles, wofür der Nutzer zuständig ist, mit voller Detailtiefe.
3. **Alle Vorgänge** — vollständige Abteilungssicht, für Teamleader und Admins.

**Sichtbarkeit ist nicht gleich Berechtigung.** Auch wenn in Training Admin und ATO alle alles sehen, darf einen Prüfpunkt ausschließlich der Zuständige abhaken. Sichtbarkeit dient der Transparenz, Zuständigkeit der Verantwortung.

---

## 10. Vier-Augen-Prinzip

Wer einen Prüfpunkt bearbeitet hat, darf die zugehörige Kontrolle **nicht** durchführen. Das System muss dies hart erzwingen, nicht nur empfehlen.

Konkret: Hat ein Mitarbeiter einen Vorgang aus dem Pool gezogen und die Vorbereitung erledigt, kann derselbe Nutzer den zugehörigen Kontrollpunkt nicht abhaken. Das gilt insbesondere innerhalb von Training Admin, wo Vorbereitung und Kontrolle bisher in einer Hand lagen.

Bei Prüfpunkten mit Vier-Augen-Anforderung sind daher zwei Felder zu führen: `completed_by` und `verified_by`. Diese Eigenschaft ist je Prüfpunkt im Katalog konfigurierbar.

---

## 11. Fristen, Erinnerungen, Eskalation

- Jeder Prüfpunkt hat eine Frist in Arbeitstagen **vor Kursbeginn**, im Admin-Panel konfigurierbar.
- Erinnerung an den Zuständigen vor Fristablauf, Intervall konfigurierbar.
- Bei Fristüberschreitung: Eskalation an die **Eskalationsstufe der jeweiligen Abteilung** — eine Stufe je Abteilung, im Admin-Panel frei festlegbar.
- Reagiert auch diese nicht innerhalb der Frist, erscheint der Vorgang im **Dashboard von Director Training und Head of Training**. Das ist faktisch die zweite Stufe, ohne dass sie gepflegt werden muss.
- Benachrichtigung per E-Mail und In-App. Fehlgeschlagener Mailversand muss im Admin-Panel sichtbar sein.

---

## 12. Ausnahmen bei Kurzfristverkäufen

Kurzfristige Buchungen sind im Business-Jet-Geschäft Normalfall, nicht Ausnahme. Ohne definierten Ausnahmeweg wird die Fristenregel im ersten Monat gebrochen und danach nie wieder ernst genommen.

**Ablauf:**

1. Ist eine Frist objektiv nicht einhaltbar, beantragt der Zuständige eine Ausnahme mit **Pflichtangabe des Grundes**.
2. Freigabe ausschließlich durch **Director Training oder Head of Training**.
3. Die Ausnahme wird mit Antragsteller, Grund, Freigeber und Zeitstempel dokumentiert.
4. Ausnahmen werden im Dashboard **gezählt und nach Abteilung, Muster und Prüfpunkt ausgewertet**.

Punkt 4 ist der eigentliche Wert: Er liefert eine belastbare Kennzahl fürs Compliance Monitoring statt eines Bauchgefühls darüber, wie oft abgewichen wird. Häufen sich Ausnahmen an derselben Stelle, ist entweder die Frist falsch gesetzt oder der Prozess untauglich.

---

## 13. Dashboard

Zwei Ebenen: eine operative Arbeitssicht für alle Nutzer und eine Auswertungssicht für die Leitung.

### Statusmodell — durchgängig gleich

Jeder Prüfpunkt, jedes Gate und jeder Vorgang trägt genau einen von vier Zuständen. Dieselbe Farbe bedeutet überall dasselbe:

| Zustand | Bedeutung |
|---|---|
| **Offen** | noch nicht begonnen |
| **In Arbeit** | mindestens ein Punkt erledigt, Pflichtpunkte offen |
| **Erledigt** | alle Pflichtpunkte erledigt, Gate freigegeben |
| **Überfällig** | Frist überschritten — überschreibt jeden anderen Zustand |

„Überfällig" ist bewusst dominant: Ein Vorgang, der zugleich in Arbeit und überfällig ist, wird als überfällig dargestellt.

### Vorgangsbahn

Die Leitansicht ist keine Kachelsammlung, sondern eine horizontale Bahn: **Anfrage → Gate 1 → Gebucht → Gate 2 → In Durchführung → Gate 3 → Abgeschlossen.** Jede Stufe zeigt den Bestand, jedes Gate zeigt, wie viele Vorgänge dort blockieren. Jedes Element ist als Filter klickbar. Damit ist auf einen Blick erkennbar, an welchem Gate sich Arbeit staut.

### Kennzahlen

- Offene Vorgänge, überfällige Aufgaben, Pool-Bestand, Ausnahmen der letzten 30 Tage, Abschlüsse der letzten 30 Tage
- Pool-Bestand mit Liegedauer je Abteilung — die wichtigste operative Kennzahl, weil sie zeigt, was noch niemand angefasst hat
- Gate-Durchlaufzeiten, Median und Ausreißer
- Ausnahmen nach Abteilung, Muster und Prüfpunkt
- Gate-3-Warnungen: abgeschlossene Kurse mit fehlenden Records
- Eskalationen der laufenden Periode

### Filter

Alle Filter kombinierbar, Zustand in der URL abbildbar, damit eine gefilterte Sicht teilbar ist:

Volltextsuche (Trainee, Firma, Vorgangsnummer, Kurstyp) · Muster · Status · Gate · zuständige Abteilung der nächsten offenen Aufgabe · Zuständige Person · Firma · Kurstyp · Zeitraum Kursbeginn · nur überfällig · nur im Pool · nur mit Ausnahme · nur mit ungelesenen Nachrichten

Sortierbar nach jeder Spalte. Export der gefilterten Sicht als PDF und Excel.

### Auditsicherheit

- **Vollständiger Audit-Trail je Vorgang:** wer hat wann welchen Prüfpunkt erledigt, zurückgesetzt oder freigegeben, mit Zeitstempel. Nicht löschbar, nicht editierbar.
- Zurücksetzen eines bereits erledigten Prüfpunkts ist möglich, erzeugt aber immer einen Eintrag mit Begründung.
- Ausnahmen mit Antragsteller, Grund, Freigeber und Zeitstempel.
- Kommunikation nicht löschbar, Bearbeitungen mit Historie.
- Audit-Trail exportierbar je Vorgang, Zeitraum, Person oder Abteilung.

---

## 14. Admin-Panel

Zugriff für Superadmin, eingeschränkt für Admin:

- Nutzer, Rollen, Abteilungszuordnung
- Musterzuordnungen für Sales und ATO
- Vertretungen
- Eskalationsstufen je Abteilung
- **Prüfpunkt-Katalog:** anlegen, ändern, deaktivieren; je Prüfpunkt Pflicht/optional, Frist, Vier-Augen-Anforderung, Nachweis, Musterfilter
- Standardfristen und Liegenbleiber-Frist
- Mailadressen und Vorlagen
- Fehleranzeige bei fehlgeschlagenem Mailversand
- Changelog und Versionsstand
- Backup-Status
- Audit-Log-Einsicht

---

## 15. Offene Punkte

| # | Punkt | Status |
|---|---|---|
| 1 | Gate 3: Sperre des Kursabschlussnachweises statt reiner Dashboard-Warnung | Entscheidung Patrick offen — Empfehlung: Sperre |
| 2 | Supabase-Hosting-Region | Empfehlung EU/Frankfurt, nicht final |
| 3 | Hex-Codes und Logo im AAA-Connect-Stil | wird nachgeliefert |
| 4 | Namen der Eskalationsstufen je Abteilung | von Patrick zu benennen |
| 5 | Sales-Leitung als Fallback-Zuständigkeit | Person zu benennen |
| 6 | Course Supervisor Phenom und M2 | derzeit unbesetzt, Fallback greift |
| 7 | Ablageort der Kursakte (Pfad SharePoint/Laufwerk) | zu definieren |
| 8 | Aufbewahrungsfristen für Vorgangsdaten | zu definieren |
| 9 | Regulatorische Prüfpunkte gegen die geltende Fassung der Easy Access Rules verifizieren | offen — siehe unten |
| 10 | Aufbewahrungsfrist für Kommunikation — ohne Löschung, aber Archivierung nach X Jahren? | zu definieren |
| 11 | Sales-Akzeptanz an Gate 1 nach 3 Monaten überprüfen | Beobachtungspunkt, siehe 4a |

**Zu Punkt 9:** Die Prüfpunkte in Abschnitt 7 sind fachlich formuliert und bewusst **ohne Paragraphenverweise**. Vor Freigabe des Katalogs sind sie gegen die aktuelle Fassung von Part-ORA und Part-FCL zu prüfen und dort, wo sie einer konkreten Anforderung entsprechen, mit der verifizierten Referenz zu versehen. Erfundene oder veraltete Verweise wären in einem Audit schädlicher als gar keine.

---

## 16. Abgrenzung zu bestehenden AAA-Tools

AAA Flow ist bewusst standalone. Daraus folgen zwei manuelle Schnittstellen, die bekannt und akzeptiert sind:

| Prüfpunkt | Quelle | Prüfung |
|---|---|---|
| Instruktor/Prüfer qualifiziert und current (Gate 2) | InstructorConnect | manuell |
| Grading Sheets vollständig und unterschrieben (Gate 3) | InstructorConnect Grading Tool | manuell |

Beide Prüfpunkte bleiben Handprüfungen gegen ein zweites System. Sollte sich die Fehlerquote hier als relevant erweisen, ist eine spätere Lesekopplung an InstructorConnect der nächste sinnvolle Ausbauschritt.
