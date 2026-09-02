-- =============================================================================
-- AAA Flow — Seed: Muster, Prüfpunkt-Katalog (Spec 7), Einstellungen, Changelog
-- Idempotent (on conflict). Keine Nutzer: Anlage ausschließlich durch Admins.
-- =============================================================================
select public.enable_internal_write();

insert into public.aircraft_types (code, name) values
  ('ATR',    'ATR'),
  ('C525',   'C525'),
  ('CL350',  'CL350'),
  ('CL650',  'CL650'),
  ('M2',     'M2'),
  ('PHENOM', 'Phenom'),
  ('XLS',    'XLS')
on conflict (code) do nothing;

-- Gate 1 — Booking Accepted (Sales → Training Admin), Fristen in Arbeitstagen vor Kursbeginn
insert into public.checkpoints (code, gate_no, department, label_de, label_en, mandatory, four_eyes, evidence, deadline_days, deadline_anchor, sort_order) values
  ('g1_customer_order',   1, 'sales', 'Kundenauftrag liegt vor',                                           'Customer order on file',                                         true,  false, 'Auftrag/Bestätigung', 15, 'course_start', 10),
  ('g1_trainee_data',     1, 'sales', 'Trainee-Stammdaten vollständig',                                    'Trainee master data complete',                                   true,  false, 'Stammdatenblatt', 15, 'course_start', 20),
  ('g1_licence',          1, 'sales', 'Lizenzkopie vorhanden und gültig',                                  'Licence copy on file and valid',                                 true,  true,  'Lizenzkopie', 15, 'course_start', 30),
  ('g1_medical',          1, 'sales', 'Medical vorhanden und gültig am letzten Kurstag',                   'Medical on file and valid on last course day',                   true,  true,  'Medical-Kopie', 15, 'course_start', 40),
  ('g1_language',         1, 'sales', 'Sprachkenntnisvermerk vorhanden und gültig',                        'Language proficiency endorsement on file and valid',             true,  false, 'Vermerk/Lizenz', 15, 'course_start', 50),
  ('g1_prerequisites',    1, 'sales', 'Voraussetzungen für den Kurstyp geprüft (Vorerfahrung, Berechtigungen)', 'Course prerequisites checked (experience, ratings)',        true,  true,  'Logbuch/Lizenz', 15, 'course_start', 60),
  ('g1_course_defined',   1, 'sales', 'Kurstyp und Muster eindeutig festgelegt',                            'Course type and aircraft type defined',                          true,  false, null, 15, 'course_start', 70),
  ('g1_billing',          1, 'sales', 'Rechnungsdaten vollständig',                                         'Billing data complete',                                          true,  false, 'Rechnungsadresse', 15, 'course_start', 80),
  ('g1_special_needs',    1, 'sales', 'Sonderbedarf erfasst (Visum, Unterkunft)',                           'Special requirements recorded (visa, accommodation)',            false, false, null, 15, 'course_start', 90),
  ('g1_offer_sent',       1, 'sales', 'Angebot an Kunden versandt',                                         'Offer sent to customer',                                         false, false, 'Angebot', 3, 'enquiry_date', 5)
on conflict (code) do nothing;

-- Gate 2 — Course Readiness (Training Admin → ATO)
insert into public.checkpoints (code, gate_no, department, label_de, label_en, mandatory, four_eyes, evidence, deadline_days, deadline_anchor, sort_order) values
  ('g2_course_date',      2, 'training_admin', 'Kursdatum bestätigt',                                                  'Course date confirmed',                                          true,  false, null, 10, 'course_start', 10),
  ('g2_fstd_slot',        2, 'training_admin', 'FSTD-Slot bestätigt',                                                  'FSTD slot confirmed',                                            true,  false, 'Slot-Bestätigung', 10, 'course_start', 20),
  ('g2_instructor',       2, 'ato',            'Instruktor zugewiesen, qualifiziert und current für das Muster',       'Instructor assigned, qualified and current on type',             true,  true,  'InstructorConnect (manuelle Prüfung)', 7, 'course_start', 30),
  ('g2_examiner',         2, 'ato',            'Prüfer zugewiesen, qualifiziert und current (sofern Prüfung Teil des Kurses)', 'Examiner assigned, qualified and current (if a check is part of the course)', false, true, 'InstructorConnect (manuelle Prüfung)', 7, 'course_start', 40),
  ('g2_training_docs',    2, 'training_admin', 'Trainingsunterlagen auf gültigem Revisionsstand bereitgestellt',       'Training documents provided at valid revision',                  true,  true,  'Revisionsstand TM', 5, 'course_start', 50),
  ('g2_forms',            2, 'training_admin', 'Verwendete Formulare auf gültigem Revisionsstand',                     'Forms in use at valid revision',                                 true,  false, 'Formularliste', 5, 'course_start', 60),
  ('g2_course_file',      2, 'training_admin', 'Kursakte angelegt',                                                    'Course file created',                                            true,  false, 'Pfad Kursakte', 5, 'course_start', 70),
  ('g2_joining_instr',    2, 'training_admin', 'Joining Instructions an Trainee versandt',                             'Joining instructions sent to trainee',                           true,  false, 'Versandnachweis', 5, 'course_start', 80),
  ('g2_ground_school',    2, 'ato',            'Theorie/Ground School geplant',                                        'Theory / ground school scheduled',                               true,  false, null, 5, 'course_start', 90)
on conflict (code) do nothing;

-- Gate 3 — Course Closure (ATO → Training Admin), Fristen in Arbeitstagen nach Kursende
insert into public.checkpoints (code, gate_no, department, label_de, label_en, mandatory, four_eyes, evidence, deadline_days, deadline_anchor, requires_gate_complete, sort_order) values
  ('g3_attendance',       3, 'ato',            'Anwesenheit dokumentiert',                                             'Attendance documented',                                          true,  false, 'Anwesenheitsliste', 3, 'course_end', false, 10),
  ('g3_grading_sheets',   3, 'ato',            'Grading Sheets vollständig und beidseitig unterschrieben',             'Grading sheets complete and signed by both parties',             true,  true,  'InstructorConnect Grading Tool (manuelle Prüfung)', 3, 'course_end', false, 20),
  ('g3_deferred_items',   3, 'ato',            'Deferred Items geschlossen oder dokumentiert',                         'Deferred items closed or documented',                            true,  false, null, 3, 'course_end', false, 30),
  ('g3_additional_trg',   3, 'ato',            'Additional Training dokumentiert, sofern zutreffend',                  'Additional training documented, if applicable',                  false, false, null, 3, 'course_end', false, 40),
  ('g3_exam_result',      3, 'ato',            'Prüfungsergebnis dokumentiert',                                        'Examination result documented',                                  true,  true,  'Prüfungsprotokoll', 3, 'course_end', false, 50),
  ('g3_records_filed',    3, 'training_admin', 'Records an die Ablage übergeben',                                      'Records handed over to filing',                                  true,  true,  'Ablagepfad', 5, 'course_end', false, 60),
  ('g3_certificate',      3, 'training_admin', 'Zertifikat/Bescheinigung ausgestellt',                                 'Certificate issued',                                             true,  false, 'Zertifikat', 5, 'course_end', true,  70),
  ('g3_feedback',         3, 'training_admin', 'Kundenfeedback eingeholt',                                             'Customer feedback obtained',                                     false, false, null, 10, 'course_end', false, 80)
on conflict (code) do nothing;

insert into public.settings (key, value, description) values
  ('pool_stale',       '{"business_days": 2}',
     'Liegenbleiber-Regel: nach N Arbeitstagen im Pool geht der Vorgang an den Teamleader (Spec 8)'),
  ('reminders',        '{"days_before": [3, 1]}',
     'Erinnerung an den Zuständigen N Arbeitstage vor Fristablauf (Spec 11)'),
  ('escalation',       '{"contacts": {"sales": null, "training_admin": null, "ato": null}, "level2_after_business_days": 2}',
     'Eskalationsstufe je Abteilung (user_id) und Frist bis Stufe 2 (Dashboard Director Training / Head of Training)'),
  ('function_holders', '{"director_training": null, "head_of_training": null, "sales_lead": null}',
     'Funktionsträger (user_id): Ausnahmefreigabe, ATO-Fallback, Sales-Fallback (Spec 8, 12)'),
  ('mail',             '{"from": "aaa-flow@example.invalid", "reply_to": null, "templates": {}}',
     'Absender und Vorlagen für E-Mail-Benachrichtigungen'),
  ('retention',        '{"cases_years": null, "messages_years": null}',
     'Aufbewahrungsfristen — offen (Spec 15, Punkte 8 und 10)'),
  ('course_file',      '{"base_path": null}',
     'Ablageort der Kursakte — offen (Spec 15, Punkt 7)')
on conflict (key) do nothing;

insert into public.changelog (version, released_on, notes_de, notes_en) values
  ('1.0.0', '2026-09-02',
   'Fundament: Datenmodell, Gate-Logik, Vier-Augen-Prinzip, Pool, Fristen, Ausnahmen, Gate-3-Sperre, Kommunikation, Audit-Trail, RLS.',
   'Foundation: data model, gate logic, four-eyes principle, pool, deadlines, exceptions, gate 3 lock, communication, audit trail, RLS.')
on conflict (version) do nothing;
