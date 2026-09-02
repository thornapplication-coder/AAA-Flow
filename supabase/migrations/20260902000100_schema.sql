-- =============================================================================
-- AAA Flow — Schema 1.0.0
-- Migration 1/5: Extensions, Enums, Tabellen, Constraints, Indizes
-- Referenz: docs/SPEC.md Abschnitt 5 (Datenmodell), 5a (Kommunikation)
-- =============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";   -- Volltextsuche (Trainee, Firma, Vorgangsnummer)

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type public.department as enum ('sales', 'training_admin', 'ato');

create type public.user_role as enum ('superadmin', 'admin', 'teamleader', 'staff');

create type public.ui_language as enum ('de', 'en');

-- Lebenszyklus (Spec Abschnitt 6)
create type public.case_status as enum (
  'enquiry',      -- Anfrage
  'booked',       -- Gebucht (Gate 1 passiert, Kursdatum fixiert)
  'released',     -- Freigegeben (Gate 2 passiert)
  'in_progress',  -- In Durchführung (Kursbeginn erreicht)
  'completed',    -- Abgeschlossen (Gate 3 passiert)
  'discarded'     -- Verworfen (manuell, Grund Pflicht)
);

-- Prüfpunkt-Zustand. "Überfällig" ist kein gespeicherter Zustand, sondern wird
-- aus due_at abgeleitet und überschreibt in der Darstellung jeden anderen Zustand.
create type public.checkpoint_state as enum (
  'open',       -- offen
  'completed',  -- erledigt, wartet auf Kontrolle (nur bei Vier-Augen-Prüfpunkten)
  'verified'    -- erledigt und kontrolliert bzw. erledigt ohne Vier-Augen-Anforderung
);

create type public.gate_state as enum ('open', 'in_progress', 'released');

create type public.exception_state as enum ('requested', 'approved', 'rejected');

create type public.message_scope as enum ('case', 'trainee', 'company');

create type public.notification_type as enum (
  'reminder',            -- Erinnerung vor Fristablauf
  'escalation',          -- Fristüberschreitung → Eskalationsstufe der Abteilung
  'escalation_level2',   -- Eskalationsstufe reagiert nicht → Dashboard Director/HoT
  'pool_stale',          -- Liegenbleiber: Vorgang > N Arbeitstage im Pool
  'mention',             -- Erwähnung in einer Nachricht
  'gate_released',       -- Gate freigegeben, nächste Abteilung ist dran
  'exception_requested', -- Ausnahme beantragt
  'exception_decided',   -- Ausnahme freigegeben/abgelehnt
  'assignment'           -- Vorgang zugewiesen
);

create type public.email_state as enum ('pending', 'sent', 'failed', 'skipped');

-- -----------------------------------------------------------------------------
-- Stammdaten
-- -----------------------------------------------------------------------------
create table public.users (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  email       text not null unique,
  department  public.department not null,
  role        public.user_role not null default 'staff',
  active      boolean not null default true,
  language    public.ui_language not null default 'de',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.users is 'Nutzerprofil. Anlage ausschließlich durch Admins (keine Selbstregistrierung). Genau eine Abteilung je Nutzer.';

create table public.aircraft_types (
  id      uuid primary key default gen_random_uuid(),
  code    text not null unique,
  name    text not null unique,
  active  boolean not null default true
);
comment on table public.aircraft_types is 'Muster. Anzeige stets alphabetisch nach name.';

create table public.type_assignments (
  user_id          uuid not null references public.users (id) on delete cascade,
  aircraft_type_id uuid not null references public.aircraft_types (id) on delete cascade,
  department       public.department not null,
  created_at       timestamptz not null default now(),
  primary key (user_id, aircraft_type_id)
);
comment on table public.type_assignments is 'Sales: steuert Sichtbarkeit. ATO: Course Supervisor der Flotte, automatische Zuständigkeit.';

create table public.deputies (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users (id) on delete cascade,
  deputy_user_id  uuid not null references public.users (id) on delete cascade,
  valid_from      date not null,
  valid_to        date not null,
  created_by      uuid references public.users (id),
  created_at      timestamptz not null default now(),
  check (deputy_user_id <> user_id),
  check (valid_to >= valid_from)
);
comment on table public.deputies is 'Vertretung: erhält im Zeitraum vollen Zugriff auf die Vorgänge des Abwesenden.';
create index deputies_deputy_idx on public.deputies (deputy_user_id, valid_from, valid_to);
create index deputies_user_idx on public.deputies (user_id, valid_from, valid_to);

create table public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on table public.companies is 'Kundenfirma. Eigene Entität, da Kommunikation und Zahlungsthemen auf Firmenebene laufen.';

create table public.trainees (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(trim(name)) > 0),
  date_of_birth  date,
  email          text,
  company_id     uuid references public.companies (id),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (name, date_of_birth)
);
comment on table public.trainees is 'Trainee als eigene Entität, damit Trainee-Threads über mehrere Kurse hinweg möglich sind (Spec 5a). Ein Vorgang referenziert genau einen Trainee.';

-- -----------------------------------------------------------------------------
-- Prüfpunkt-Katalog (konfigurierbar im Admin-Panel)
-- -----------------------------------------------------------------------------
create table public.checkpoints (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique,
  gate_no                smallint not null check (gate_no between 1 and 3),
  department             public.department not null,
  label_de               text not null,
  label_en               text not null,
  mandatory              boolean not null default true,
  four_eyes              boolean not null default false,
  evidence               text,
  deadline_days          integer check (deadline_days is null or deadline_days >= 0),
  deadline_anchor        text not null default 'course_start'
                         check (deadline_anchor in ('course_start', 'enquiry_date', 'course_end')),
  requires_gate_complete boolean not null default false,
  aircraft_type_filter   uuid[],
  sort_order             integer not null default 100,
  active                 boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table public.checkpoints is 'Konfigurierbarer Prüfpunkt-Katalog. Änderungen wirken auf neu angelegte Vorgänge.';
comment on column public.checkpoints.department is 'Abteilung, die den Prüfpunkt bearbeitet (nicht die freigebende Abteilung des Gates).';
comment on column public.checkpoints.deadline_days is 'Frist in Arbeitstagen VOR dem Anker (course_start) bzw. NACH dem Anker (enquiry_date, course_end).';
comment on column public.checkpoints.requires_gate_complete is 'Gate-3-Sperre: kann erst erledigt werden, wenn alle anderen Pflichtpunkte desselben Gates erledigt sind (z. B. Zertifikat).';
comment on column public.checkpoints.aircraft_type_filter is 'NULL = gilt für alle Muster. Sonst nur für die gelisteten Muster.';

-- -----------------------------------------------------------------------------
-- Vorgang
-- -----------------------------------------------------------------------------
create sequence public.case_number_seq;

create table public.cases (
  id               uuid primary key default gen_random_uuid(),
  case_number      text not null unique,
  status           public.case_status not null default 'enquiry',
  trainee_id       uuid not null references public.trainees (id),
  company_id       uuid not null references public.companies (id),
  aircraft_type_id uuid not null references public.aircraft_types (id),
  course_type      text not null check (length(trim(course_type)) > 0),
  enquiry_date     date not null default current_date,
  course_start     date,
  course_end       date,
  instructor       text,
  examiner         text,
  fstd_slot        text,
  closed_reason    text,
  created_by       uuid references public.users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (course_end is null or course_start is null or course_end >= course_start),
  check (status <> 'discarded' or (closed_reason is not null and length(trim(closed_reason)) > 0))
);
comment on table public.cases is 'Ein Vorgang = ein Trainee. Keine übergeordnete Kursklammer. Kursweite Felder werden je Vorgang geführt (Übernahmefunktion: copy_course_fields).';
create index cases_status_idx on public.cases (status);
create index cases_type_idx on public.cases (aircraft_type_id);
create index cases_company_idx on public.cases (company_id);
create index cases_trainee_idx on public.cases (trainee_id);
create index cases_course_start_idx on public.cases (course_start);
create index cases_course_type_trgm on public.cases using gin (course_type gin_trgm_ops);

create table public.case_assignments (
  case_id      uuid not null references public.cases (id) on delete cascade,
  department   public.department not null,
  user_id      uuid references public.users (id),
  assigned_at  timestamptz,
  pool_since   timestamptz not null default now(),
  stale_notified_at timestamptz,
  primary key (case_id, department)
);
comment on table public.case_assignments is 'Ein Eintrag je Abteilung und Vorgang. user_id NULL = liegt im Pool der Abteilung.';
create index case_assignments_user_idx on public.case_assignments (user_id);
create index case_assignments_pool_idx on public.case_assignments (department, pool_since) where user_id is null;

create table public.gates (
  case_id      uuid not null references public.cases (id) on delete cascade,
  gate_no      smallint not null check (gate_no between 1 and 3),
  status       public.gate_state not null default 'open',
  released_by  uuid references public.users (id),
  released_at  timestamptz,
  primary key (case_id, gate_no)
);

create table public.case_checkpoints (
  id             uuid primary key default gen_random_uuid(),
  case_id        uuid not null references public.cases (id) on delete cascade,
  checkpoint_id  uuid not null references public.checkpoints (id),
  status         public.checkpoint_state not null default 'open',
  due_at         date,
  completed_by   uuid references public.users (id),
  completed_at   timestamptz,
  verified_by    uuid references public.users (id),
  verified_at    timestamptz,
  note           text,
  unique (case_id, checkpoint_id),
  -- Vier-Augen-Prinzip: hart erzwungen auf Datenebene.
  check (verified_by is null or completed_by is null or verified_by <> completed_by)
);
comment on table public.case_checkpoints is 'Instanz eines Katalog-Prüfpunkts je Vorgang. Snapshot bei Vorgangsanlage.';
create index case_checkpoints_case_idx on public.case_checkpoints (case_id);
create index case_checkpoints_due_idx on public.case_checkpoints (due_at) where status <> 'verified';

create table public.exceptions (
  id             uuid primary key default gen_random_uuid(),
  case_id        uuid not null references public.cases (id) on delete cascade,
  gate_no        smallint not null check (gate_no between 1 and 3),
  checkpoint_id  uuid not null references public.checkpoints (id),
  reason         text not null check (length(trim(reason)) >= 10),
  status         public.exception_state not null default 'requested',
  requested_by   uuid not null references public.users (id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references public.users (id),
  decided_at     timestamptz,
  decision_note  text
);
comment on table public.exceptions is 'Ausnahmefreigabe mit Pflichtgrund. Freigabe nur durch Director Training oder Head of Training. Wird im Dashboard nach Abteilung, Muster und Prüfpunkt ausgewertet.';
create index exceptions_case_idx on public.exceptions (case_id);
create index exceptions_checkpoint_idx on public.exceptions (checkpoint_id, status);

create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users (id) on delete cascade,
  case_id       uuid references public.cases (id) on delete cascade,
  type          public.notification_type not null,
  payload       jsonb not null default '{}'::jsonb,
  due_at        timestamptz not null default now(),
  sent_at       timestamptz,
  read_at       timestamptz,
  escalated     boolean not null default false,
  email_status  public.email_state not null default 'pending',
  email_error   text,
  created_at    timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, read_at);
create index notifications_pending_idx on public.notifications (due_at) where sent_at is null;
create index notifications_email_failed_idx on public.notifications (email_status) where email_status = 'failed';

-- -----------------------------------------------------------------------------
-- Kontextbezogene Kommunikation (Spec 5a) — nicht löschbar
-- -----------------------------------------------------------------------------
create table public.messages (
  id             uuid primary key default gen_random_uuid(),
  scope          public.message_scope not null,
  scope_id       uuid not null,
  user_id        uuid not null references public.users (id),
  body           text not null check (length(trim(body)) > 0),
  checkpoint_id  uuid references public.checkpoints (id),
  created_at     timestamptz not null default now(),
  edited_at      timestamptz
);
comment on table public.messages is 'Thread-Nachricht auf Ebene Vorgang, Trainee oder Firma. Kein Löschen. Bearbeiten erzeugt message_edits.';
create index messages_scope_idx on public.messages (scope, scope_id, created_at);
create index messages_body_trgm on public.messages using gin (body gin_trgm_ops);

create table public.message_edits (
  id             uuid primary key default gen_random_uuid(),
  message_id     uuid not null references public.messages (id) on delete restrict,
  previous_body  text not null,
  edited_by      uuid not null references public.users (id),
  edited_at      timestamptz not null default now()
);

create table public.message_mentions (
  message_id  uuid not null references public.messages (id) on delete restrict,
  user_id     uuid references public.users (id),
  department  public.department,
  check ((user_id is not null)::int + (department is not null)::int = 1)
);
create unique index message_mentions_user_uidx on public.message_mentions (message_id, user_id) where user_id is not null;
create unique index message_mentions_dept_uidx on public.message_mentions (message_id, department) where department is not null;

create table public.thread_reads (
  user_id       uuid not null references public.users (id) on delete cascade,
  scope         public.message_scope not null,
  scope_id      uuid not null,
  last_read_at  timestamptz not null default now(),
  primary key (user_id, scope, scope_id)
);
comment on table public.thread_reads is 'Lesestand je Nutzer und Thread. Grundlage für Ungelesen-Zähler je Kontextebene.';

-- -----------------------------------------------------------------------------
-- Audit und Einstellungen
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  user_id     uuid,
  case_id     uuid,
  entity      text not null,
  entity_id   text not null,
  action      text not null,
  old_value   jsonb,
  new_value   jsonb,
  reason      text,
  created_at  timestamptz not null default now()
);
comment on table public.audit_log is 'Vollständiger Audit-Trail. Nicht löschbar, nicht editierbar (RLS + Trigger).';
create index audit_log_entity_idx on public.audit_log (entity, entity_id, created_at);
create index audit_log_case_idx on public.audit_log (case_id, created_at);
create index audit_log_user_idx on public.audit_log (user_id, created_at);
create index audit_log_created_idx on public.audit_log (created_at);

create table public.settings (
  key          text primary key,
  value        jsonb not null,
  description  text,
  updated_by   uuid references public.users (id),
  updated_at   timestamptz not null default now()
);

create table public.changelog (
  version      text primary key,
  released_on  date not null default current_date,
  notes_de     text not null,
  notes_en     text not null
);
comment on table public.changelog is 'Versionsstand und Änderungshistorie für den Superadmin-Bereich.';

-- -----------------------------------------------------------------------------
-- updated_at-Trigger
-- -----------------------------------------------------------------------------
create or replace function public.tg_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger users_updated_at before update on public.users
  for each row execute function public.tg_set_updated_at();
create trigger checkpoints_updated_at before update on public.checkpoints
  for each row execute function public.tg_set_updated_at();
create trigger cases_updated_at before update on public.cases
  for each row execute function public.tg_set_updated_at();
