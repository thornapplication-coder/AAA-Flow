-- =============================================================================
-- Project Control Center — Grunddaten
-- Konfiguration und die beiden Zugänge, keine Demodaten. Beispieldaten stehen
-- in supabase/tests/001_core.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Die zwei Zugänge (entschieden am 19.09.2026)
-- 'team' darf alles, 'viewer' liest und gibt aus. Beide werden gemeinsam
-- benutzt. Die Zeilen entstehen hier; verbunden werden sie mit dem
-- Anmeldekonto, sobald der Betreiber es in Supabase unter derselben Adresse
-- anlegt. Ein dritter Zugang scheitert am Riegel users_one_account_per_role.
-- Die Adressen lassen sich vor dem ersten Einspielen ändern — danach über
-- pcc.prepare_account() im SQL-Editor.
-- -----------------------------------------------------------------------------
select pcc.prepare_account('team@aviationacademy.at',   'team',   'Projektteam');
select pcc.prepare_account('viewer@aviationacademy.at', 'viewer', 'Lesezugang');

-- -----------------------------------------------------------------------------
-- Welche Ereignisse eine neue Projektversion erzeugen (Abschnitt 6).
-- Diese Liste ist Konfiguration: sie lässt sich erweitern, ohne Code zu ändern.
-- -----------------------------------------------------------------------------
insert into pcc.version_triggers (code, label_de, label_en, description) values
  ('project_created',      'Projekt angelegt',        'Project created',        'Version 1.0 bei der Anlage'),
  ('project_status',       'Projektstatus geändert',  'Project status changed', 'Statuswechsel des Projekts'),
  ('project_end_date',     'Zieltermin geändert',     'Target date changed',    'Änderung des geplanten Endes'),
  ('milestone_moved',      'Meilenstein verschoben',  'Milestone moved',        'Terminänderung eines Meilensteins'),
  ('milestone_completed',  'Meilenstein erreicht',    'Milestone reached',      'Abschluss eines Meilensteins'),
  ('risk_critical',        'Kritisches Risiko',       'Critical risk',          'Neues Risiko ab Score 15'),
  ('workstream_completed', 'Workstream abgeschlossen','Workstream completed',   'Abschluss eines Workstreams'),
  ('pm_release',           'Freigabe durch die Projektleitung', 'Release by project manager', 'Ausdrückliche Freigabe eines Stands')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- Einstellungen
-- -----------------------------------------------------------------------------
insert into pcc.settings (key, value, description) values
  ('reminders', jsonb_build_object(
      'due_soon_days', 3,
      'overdue_repeat_days', 7,
      'digest_hour', 7),
   'Vorlauf für Fälligkeitshinweise und Wiederholung bei Überfälligkeit'),
  ('risk', jsonb_build_object(
      'critical_score', 15,
      'matrix_size', 5),
   'Ab welchem Score ein Risiko als kritisch gilt (Abschnitt 17)'),
  ('documents', jsonb_build_object(
      'max_size_mb', 50,
      'bucket', 'project-docs',
      'allowed', jsonb_build_array('application/pdf','image/png','image/jpeg','text/plain','text/csv',
        'application/msword','application/vnd.ms-excel','application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation')),
   'Grenzen und Ablage für Uploads (Abschnitt 7a der Architektur)'),
  ('retention', jsonb_build_object(
      'mode', 'unlimited',
      'decided_on', '2026-09-18',
      'note', 'Unbegrenzte Aufbewahrung. Löschung ausschließlich auf Verlangen nach Artikel 17 DSGVO.'),
   'Aufbewahrung von Projektdaten, Dokumenten und Audit-Trail (Abschnitt 7b)'),
  ('health', jsonb_build_object(
      'red_critical_risks', 2,
      'amber_critical_risks', 1),
   'Schwellen der Gesamtlage. Rot bleibt selten, sonst verliert die Farbe ihre Aussage.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Eine erste Projektvorlage (Abschnitt 30)
-- -----------------------------------------------------------------------------
insert into pcc.templates (name, description, payload) values
  ('Simulator-Einführung',
   'Vorlage für die Einführung eines Full Flight Simulators: Qualifikation, Instruktoren, Unterlagen.',
   jsonb_build_object(
     'workstreams', jsonb_build_array(
       jsonb_build_object('name', 'Qualifikation', 'sort_order', 1, 'description', 'Abnahme und behördliche Qualifikation'),
       jsonb_build_object('name', 'Instruktoren',  'sort_order', 2, 'description', 'Qualifikation und Einweisung der Instruktoren'),
       jsonb_build_object('name', 'Unterlagen',    'sort_order', 3, 'description', 'Kursunterlagen und Dokumentation')),
     'tasks', jsonb_build_array(
       jsonb_build_object('title', 'Factory Acceptance Test durchführen', 'workstream', 'Qualifikation', 'priority', 'critical', 'due_offset_days', 30),
       jsonb_build_object('title', 'Qualification Test Guide einreichen', 'workstream', 'Qualifikation', 'priority', 'high', 'due_offset_days', 60),
       jsonb_build_object('title', 'Instruktorenplan aufstellen',         'workstream', 'Instruktoren',  'priority', 'medium', 'due_offset_days', 45),
       jsonb_build_object('title', 'Kursunterlagen erstellen',            'workstream', 'Unterlagen',    'priority', 'medium', 'due_offset_days', 90)),
     'milestones', jsonb_build_array(
       jsonb_build_object('name', 'Abnahme erfolgt',        'workstream', 'Qualifikation', 'due_offset_days', 35),
       jsonb_build_object('name', 'Qualifikation erteilt',  'workstream', 'Qualifikation', 'due_offset_days', 120),
       jsonb_build_object('name', 'Erster Kurs freigegeben','workstream', 'Unterlagen',    'due_offset_days', 150))))
on conflict (name) do nothing;

-- -----------------------------------------------------------------------------
-- Versionsstand für den Bereich des Super Admins
-- -----------------------------------------------------------------------------
insert into pcc.changelog (version, released_on, notes_de, notes_en) values
  ('1.0.0', date '2026-09-18',
   'Project Control Center: Datenmodell, Rechte, Versionierung, Dokumente und Tageslauf in der Datenbank.',
   'Project Control Center: data model, permissions, versioning, documents and daily jobs in the database.'),
  ('1.1.0', date '2026-09-19',
   'Zwei Zugänge statt fünf Rollen, Dateien an Aufgaben, sofortiges Speichern, Exporte mit Stand.',
   'Two accounts instead of five roles, files on tasks, instant saving, exports stamped with their state.'),
  ('1.2.0', date '2026-09-19',
   'Gantt je Projekt: Teilprojekte, Aufgaben, Teilaufgaben und Meilensteine auf einer Zeitachse.',
   'Gantt per project: workstreams, tasks, subtasks and milestones on one timeline.'),
  ('1.3.0', date '2026-09-19',
   'Abhängigkeiten und kritischer Pfad, Wochenbericht, globale Suche, Termine als Kalenderdatei.',
   'Dependencies and critical path, weekly report, global search, dates as a calendar file.')
on conflict (version) do nothing;
