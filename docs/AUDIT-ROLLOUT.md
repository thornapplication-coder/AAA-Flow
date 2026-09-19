# Freigabeprüfung für den Teameinsatz

Stand: 19.09.2026, Fassung 1.5.0. Geprüft wurde, ob das Team die Anwendung
im Alltag benutzen kann: jeder Knopf, jeder Dialog, jeder Ablauf, die
Speicherung, die Rechte, die Ausgaben und die Datenbankseite.

## Kurzfassung

| | Bereich | Stand |
|---|---|---|
| 🟢 | Prototyp: Bedienung, Dialoge, Ausgaben, Rechte, Speicherung auf dem Gerät | einsatzfähig, 217 automatische Prüfungen |
| 🟢 | Datenbank: Schema, Rechte (RLS auf jeder Tabelle), Logik, Sichten, Auswertungen | einsatzfähig, 181 SQL-Prüfungen |
| 🟢 | Prüfläufe: laufen vor jedem Commit und bei jedem Push in der CI | eingerichtet |
| 🟡 | Gemeinsamer Datenstand im Team | **nur über Datensicherung** — jedes Gerät hält seinen eigenen Stand, bis die Supabase-Instanz steht |
| 🟡 | Anmeldung mit Passwort | im Prototyp Auswahl ohne Passwort; die Datenbank ist für zwei Konten vorbereitet |
| 🔴 | Zielanwendung (React auf Supabase) | Gerüst mit Anmeldung, Typen und Rahmen; Fachoberfläche noch nicht auf die Datenbank gehoben |

**Empfehlung:** Der Prototyp kann ab sofort im Team verwendet werden — als
Arbeitsmittel auf einem gemeinsam genutzten Gerät oder mit der Datensicherung
als Übergabe. Für echtes gemeinsames Arbeiten (mehrere Personen, gleichzeitig,
ein Stand) ist die Supabase-Instanz die nächste Stufe; die Datenbankseite ist
dafür fertig und geprüft.

## Was die Prüfung ergeben hat

### Behoben in 1.5.0

| Befund | Schwere | Behebung |
|---|---|---|
| Aufgaben, Risiken, Probleme ließen sich anlegen, aber nicht bearbeiten oder abschließen (außer „Erledigt" bei Aufgaben) | hoch — im Alltag unbenutzbar | Bearbeitungsdialoge in allen Bereichen, mit Pflichtfeldern und Prüfungen |
| Meilensteine, Teilprojekte, Entscheidungen, Teammitglieder, Personen konnten nicht angelegt werden | hoch | Anlegedialoge, auch aus der Anmeldung |
| Nichts ließ sich verwerfen; Fehleingaben blieben stehen | mittel | Verwerfen mit Rückfrage und Verlaufseintrag; hängende Teile werden mitgenommen |
| Archivieren war nur im Datenmodell vorgesehen | mittel | Archivieren mit Grund, wieder öffnen, Schalter in der Projektliste |
| Zurücksetzen löschte ohne Rückfrage alles | hoch — Datenverlust mit einem Klick | Rückfrage mit Hinweis auf die Datensicherung |
| Kein Weg, den Stand zu sichern oder auf ein anderes Gerät zu bringen | hoch | Datensicherung als Datei, Einspielen mit Prüfung |
| Die verschobene Sandbox-Uhr wurde mitgespeichert; Fristen stimmten am nächsten Tag nicht | mittel | Uhr wird nicht mehr gespeichert |
| Zwei Fenster überschrieben sich gegenseitig | mittel | Abgleich über das Speicherereignis, nie mitten in einer Eingabe |
| Excel-Ausgabe: Zellen mit `=`, `+`, `-`, `@` am Anfang wurden als Formel gelesen | mittel — Sicherheitsrisiko | entschärft |
| Kalenderdatei: Zeilenumbruch im Titel zerriss den Eintrag; Semikolon blieb unmaskiert (`"\;"` ist in JavaScript nur `;`) — der Logiktest hatte denselben Fehler in der Erwartung und war deshalb grün | niedrig | beides korrigiert, Erwartung im Test ebenfalls |
| Sicherungsdatei mit richtigem Kopf, aber kaputtem Projektinhalt hätte beim Einspielen die Anzeige zerlegt | mittel | Projektstruktur wird vor dem Übernehmen geprüft |
| Namen in Ausgaben und Tooltips teils unmaskiert | niedrig | konsequent über `esc()` |
| Referenznummern zählten über die Listenlänge; nach Verwerfen doppelt | mittel | Zählung über die höchste vergebene Nummer |
| Toast-Rückgängig nicht klickbar (`pointer-events`) | niedrig | behoben |
| `task_dependencies` ohne RLS — der Lesezugang konnte Verbindungen schreiben | **hoch — Rechtelücke** | RLS auf jeder Tabelle des Schemas per Schleife, Test dazu |

### Geprüft und in Ordnung

- Beide Zugänge: der Lesezugang sieht alles, kann nichts ändern — in der
  Oberfläche und in der Datenbank (Policies, Guard-Trigger, Funktionen).
- Jede Änderung wird im selben Augenblick gespeichert, zählt den Änderungsstand
  hoch und zieht offene Ausgaben nach; Exporte tragen Stand, Zeit und Person.
- Anhänge an Aufgaben: Typ- und Größenprüfung, Ablage in IndexedDB, in der
  Datensicherung enthalten (bis 25 MB).
- Gantt mit Abhängigkeiten, kritischem Pfad, Verzugsanzeige; Kreise werden
  beim Verknüpfen abgewiesen.
- Wochenbericht, Suche, Kalenderdatei, Risikomatrix mit Erklärung.
- Eingaben werden nie als HTML ausgeführt (geprüft mit einem präparierten Titel
  in Liste, Suche und Dialog).
- Drei Bildschirmbreiten ohne Überlauf, englische Fassung ohne deutsche Reste.
- Audit-Trail in der Datenbank unveränderlich; Versionen nur über Funktionen.

### Nachgezogen in 1.7.0

| Befund | Schwere | Behebung |
|---|---|---|
| Teilaufgaben ließen sich nicht anlegen — eine Aufgabe war nicht in Schritte für mehrere Personen zerlegbar | mittel | „+ Teilaufgabe" an jeder Hauptaufgabe; Teilprojekt, Priorität und Zeitraum vom Elternteil |
| Der Fortschritt einer zerlegten Aufgabe war frei setzbar und widersprach ihren Teilen; im Projektfortschritt zählten zerlegte Aufgaben doppelt | mittel | Fortschritt wird aus den Teilaufgaben gemittelt, das Feld ist gesperrt; gemittelt wird über Hauptaufgaben |
| **Kennungen wurden nach einem Neuladen doppelt vergeben** — Verwerfen hätte zwei Einträge getroffen, Anhänge hätten an der falschen Aufgabe gehangen | **hoch — stille Datenverfälschung** | Zähler wird nach Laden und Einspielen über alles Vergebene gehoben; Prüfung nach dem Neuladen, gegengeprüft |

### Nachgezogen in 1.6.1

| Befund | Schwere | Behebung |
|---|---|---|
| Überschrift „Kritische Risiken" lag quer über dem Erklärungstext daneben; das Feld war auf null Breite zusammengefallen (`min-width: 0`). Ab 1280 px aufwärts, nicht nur auf dem Telefon | mittel — unleserlich | Titel und Erklärung behalten ihre Mindestbreite, der Kartenkopf bricht um |
| In der Kopfzeile schob der Personenchip Name und Knöpfe über den Sprachumschalter, ab 834 px | mittel | nur der Name schrumpft, mit Auslassungspunkten; ab 1100 px Initialen statt Beschriftung |
| Die waagerecht scrollende Reiterleiste sah am Telefon abgeschnitten aus | niedrig | Verlauf am rechten Rand als Hinweis, verschwindet am Ende der Leiste |
| Keine Prüfung erkannte überlagerte Schrift — der Überlaufstest sah nur die Seitenbreite | **hoch — die Prüfkette hatte eine Lücke** | `check:layout`: 1.584 Geometrieprüfungen auf elf Geräteklassen in beiden Sprachen, in `verify` und CI; gegengeprüft gegen beide Fehler |

### Nachgezogen in 1.6.0

- Excel-Ausgabe war eine Textdatei zum Einfügen; jetzt eine echte `.xlsx` mit einem Blatt je Abschnitt (Prüfung im Logik- und im Funktionstest).
- Einführungsseite für das Team mit den vier Betriebsregeln; Betriebsmodus entschieden: **ein Gerät führt**.

## Was das Team beim Einsatz wissen muss

1. **Der Stand liegt auf dem Gerät.** Ein anderer Browser, ein anderes Gerät,
   ein gelöschter Browserspeicher — anderer Stand. Deshalb: regelmäßig
   *Berichte → Datensicherung herunterladen*. Die Datei ist die Übergabe.
2. **Der Teamzugang ist ein gemeinsamer Zugang.** Wer ihn nutzt, wählt beim
   Anmelden seine Person; der Verlauf trägt diesen Namen. Das ist eine
   Zuschreibung, kein Beweis — so wurde es am 19.09.2026 entschieden.
3. **Verwerfen ist endgültig** (mit Rückfrage). Archivieren ist es nicht.
4. **Zurücksetzen löscht alles auf dem Gerät.** Vorher sichern.

## Nächste Stufe: gemeinsamer Stand

| Schritt | Aufwand | Voraussetzung |
|---|---|---|
| Supabase-Projekt anlegen, Migrationen und Seed einspielen, zwei Konten über `pcc.prepare_account` verbinden | ½ Tag | Supabase-Konto |
| Fachoberfläche der Zielanwendung auf die Datenbank heben (der Prototyp ist die Vorlage, Dialoge und Regeln sind dort ausgearbeitet) | 8–10 Tage | — |
| Anhänge in den Storage-Bucket, Virenprüfung | 1 Tag | Instanz |
| Echtzeit-Abgleich zwischen Personen | 1 Tag | Instanz |

## Wie die Prüfung fortgeschrieben wird

Jede neue Fassung läuft durch `npm run verify` (Typen, Logik, Darstellung,
Funktionsdurchlauf) und `npm run db:check` (Datenbank). Die CI führt beides bei
jedem Push aus. Neue Knöpfe, Dialoge und Regeln bekommen ihre Prüfung im selben
Commit — so steht es in `CLAUDE.md`, und so gilt es für jede Sitzung.
