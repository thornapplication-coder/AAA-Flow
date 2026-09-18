-- =============================================================================
-- Project Control Center — Schema 1.0.0
-- Migration 1/5: Erweiterungen, gemeinsame Tabellen, Enums, Tabellen, Indizes
-- Referenz: docs/ARCHITECTURE.md Abschnitte 3, 4, 6, 7a
--
-- Aufteilung: Nutzerkonto und Audit-Trail liegen in public, weil sie an der
-- Anmeldung hängen und nicht am Fachmodul. Alles Fachliche liegt in pcc.
-- =============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";   -- Volltextsuche über Projekte, Aufgaben, Risiken

create schema if not exists pcc;

-- -----------------------------------------------------------------------------
-- Enums. Die Werte sind identisch mit den Statuslisten des Prototyps, damit
-- Oberfläche und Datenbank dieselbe Sprache sprechen.
-- -----------------------------------------------------------------------------
create type pcc.user_role as enum ('super_admin', 'admin', 'pm', 'contributor', 'viewer');

create type pcc.project_status as enum (
  'not_started', 'started', 'on_track', 'at_risk', 'delayed', 'cancelled', 'completed'
);

-- Gesamtlage. Wird von pcc.health() gerechnet, nicht von Hand gesetzt.
create type pcc.health as enum ('green', 'amber', 'red');

create type pcc.task_status as enum ('not_started', 'in_progress', 'blocked', 'completed', 'cancelled');
create type pcc.priority as enum ('low', 'medium', 'high', 'critical');
create type pcc.milestone_status as enum ('planned', 'in_progress', 'completed', 'delayed');
create type pcc.risk_status as enum ('open', 'monitoring', 'mitigated', 'closed', 'accepted');
create type pcc.issue_status as enum ('open', 'in_progress', 'blocked', 'resolved', 'closed');
create type pcc.progress_mode as enum ('manual', 'derived');
create type pcc.document_kind as enum ('file', 'link');
-- Abschnitt 7a: Upload landet in Quarantäne und ist bis zur Prüfung nicht ladbar.
create type pcc.scan_state as enum ('pending', 'clean', 'infected');
create type pcc.raci_letter as enum ('R', 'A', 'C', 'I');
create type pcc.entity_type as enum (
  'project', 'workstream', 'task', 'milestone', 'risk', 'issue', 'decision', 'document'
);
-- Zustellung der Benachrichtigung per E-Mail (Abschnitt 29)
create type pcc.email_state as enum ('pending', 'sent', 'failed', 'skipped');

create type pcc.notification_kind as enum (
  'assigned', 'mention', 'comment', 'due_soon', 'overdue', 'status_change',
  'milestone', 'risk_critical', 'approval'
);

-- -----------------------------------------------------------------------------
-- Nutzerkonten
-- Abschnitt 4: Selbstregistrierung ist erlaubt, erzeugt aber ein gesperrtes
-- Konto ohne Rolle. Eine NULL-Rolle sperrt die Anwendung vollständig, weil
-- keine einzige Policy greift.
-- -----------------------------------------------------------------------------
create type public.ui_language as enum ('de', 'en');

create table public.users (
  id            uuid primary key references auth.users (id) on delete cascade,
  name          text not null check (length(trim(name)) > 0),
  email         text not null unique,
  role          pcc.user_role,
  active        boolean not null default false,
  pending       boolean not null default true,
  language      public.ui_language not null default 'de',
  approved_at   timestamptz,
  approved_by   uuid references public.users (id),
  registered_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.users is 'Nutzerprofil. Entsteht bei der Anmeldung gesperrt und ohne Rolle; freigegeben wird durch den Super Admin.';
comment on column public.users.role is 'Rolle im Project Control Center. NULL: kein Zugang.';
comment on column public.users.pending is 'Selbstregistrierung, noch nicht freigegeben (Abschnitt 4).';
create index users_pending_idx on public.users (pending) where pending;

-- -----------------------------------------------------------------------------
-- Audit-Trail. Unveränderlich, nicht löschbar (RLS und Trigger).
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  user_id     uuid,
  project_id  uuid,
  entity      text not null,
  entity_id   text not null,
  action      text not null,
  old_value   jsonb,
  new_value   jsonb,
  reason      text,
  created_at  timestamptz not null default now()
);
comment on table public.audit_log is 'Vollständiger Audit-Trail. Jede Änderung mit Wer, Wann, Was, Vorher, Nachher.';
create index audit_log_entity_idx on public.audit_log (entity, entity_id, created_at);
create index audit_log_project_idx on public.audit_log (project_id, created_at);
create index audit_log_user_idx on public.audit_log (user_id, created_at);
create index audit_log_created_idx on public.audit_log (created_at);

-- -----------------------------------------------------------------------------
-- Interner Schreibmodus
-- Guard-Trigger sollen Nutzer bremsen, nicht die eigenen Funktionen. Eine
-- transaktionslokale Einstellung schaltet sie für den Aufruf einer geprüften
-- Funktion frei. Das Ausführungsrecht wird in Migration 4 entzogen: wer den
-- Schalter selbst umlegen könnte, hätte alle Guards auf einmal ausgehebelt.
-- -----------------------------------------------------------------------------
create or replace function public.internal_write_enabled()
returns boolean
language sql stable as $$
  select coalesce(current_setting('app.internal_write', true), '') = 'on';
$$;

create or replace function public.enable_internal_write()
returns void
language sql volatile as $$
  select set_config('app.internal_write', 'on', true);
$$;

create or replace function public.disable_internal_write()
returns void
language sql volatile as $$
  select set_config('app.internal_write', '', true);
$$;

create or replace function public.tg_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger users_updated_at before update on public.users
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- Projekte
-- -----------------------------------------------------------------------------
create table pcc.templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  description text,
  payload     jsonb not null default '{}'::jsonb,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.users (id),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.users (id)
);
comment on table pcc.templates is 'Projektvorlagen (Abschnitt 30): Workstreams, Aufgaben, Meilensteine als jsonb.';

create table pcc.projects (
  id              uuid primary key default gen_random_uuid(),
  key             text not null unique check (key ~ '^[A-Z][A-Z0-9]{1,9}-[0-9]{2}$'),
  name            text not null check (length(trim(name)) >= 3),
  description     text,
  objectives      text,
  scope           text,
  status          pcc.project_status not null default 'not_started',
  pm_user_id      uuid not null references public.users (id),
  sponsor_user_id uuid references public.users (id),
  start_date      date,
  target_end_date date,
  actual_end_date date,
  progress_mode   pcc.progress_mode not null default 'derived',
  progress_manual smallint not null default 0 check (progress_manual between 0 and 100),
  template_id     uuid references pcc.templates (id),
  version_major   smallint not null default 1,
  version_minor   smallint not null default 0,
  archived_at     timestamptz,
  archived_by     uuid references public.users (id),
  created_at      timestamptz not null default now(),
  created_by      uuid references public.users (id),
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.users (id),
  check (target_end_date is null or start_date is null or target_end_date >= start_date),
  check (actual_end_date is null or start_date is null or actual_end_date >= start_date)
);
comment on table pcc.projects is 'Projekt. Gesamtlage (health) und Fortschritt werden gerechnet, nicht gespeichert.';
comment on column pcc.projects.key is 'Sprechender Schlüssel, etwa SIM-26 (offener Punkt 8 der Architektur).';
create index projects_status_idx on pcc.projects (status) where archived_at is null;
create index projects_pm_idx on pcc.projects (pm_user_id);

create table pcc.project_members (
  project_id       uuid not null references pcc.projects (id) on delete cascade,
  user_id          uuid not null references public.users (id) on delete cascade,
  project_role     text not null check (length(trim(project_role)) > 0),
  responsibilities text,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.users (id),
  primary key (project_id, user_id)
);
comment on table pcc.project_members is 'Projektteam. project_role ist eine fachliche Bezeichnung (Sponsor, Head of Training), nicht das Rechtemodell.';

create table pcc.workstreams (
  project_id    uuid not null references pcc.projects (id) on delete cascade,
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(trim(name)) > 0),
  description   text,
  owner_user_id uuid references public.users (id),
  sort_order    smallint not null default 0,
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.users (id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.users (id),
  unique (project_id, name)
);
create index workstreams_project_idx on pcc.workstreams (project_id, sort_order);
create index members_user_idx on pcc.project_members (user_id);

-- -----------------------------------------------------------------------------
-- Aufgaben, Meilensteine, Risiken, Issues, Entscheidungen
-- -----------------------------------------------------------------------------
create table pcc.tasks (
  id               uuid primary key default gen_random_uuid(),
  project_id       uuid not null references pcc.projects (id) on delete cascade,
  workstream_id    uuid references pcc.workstreams (id) on delete set null,
  parent_task_id   uuid references pcc.tasks (id) on delete cascade,
  ref              text not null,
  title            text not null check (length(trim(title)) > 0),
  description      text,
  assignee_user_id uuid references public.users (id),
  priority         pcc.priority not null default 'medium',
  status           pcc.task_status not null default 'not_started',
  start_date       date,
  due_date         date,
  completed_at     timestamptz,
  progress         smallint not null default 0 check (progress between 0 and 100),
  progress_mode    pcc.progress_mode not null default 'manual',
  sort_order       smallint not null default 0,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.users (id),
  updated_at       timestamptz not null default now(),
  updated_by       uuid references public.users (id),
  unique (project_id, ref),
  check (due_date is null or start_date is null or due_date >= start_date),
  check (parent_task_id is distinct from id)
);
comment on table pcc.tasks is 'Aufgabe. Eine Teilaufgabe ist eine Aufgabe mit parent_task_id (eine Ebene, Abschnitt 21).';
create index tasks_project_idx on pcc.tasks (project_id, status);
create index tasks_assignee_idx on pcc.tasks (assignee_user_id, status);
create index tasks_due_idx on pcc.tasks (due_date) where status not in ('completed', 'cancelled');
create index tasks_parent_idx on pcc.tasks (parent_task_id);
create index tasks_workstream_idx on pcc.tasks (workstream_id);

create table pcc.milestones (
  id                      uuid primary key default gen_random_uuid(),
  project_id              uuid not null references pcc.projects (id) on delete cascade,
  workstream_id           uuid references pcc.workstreams (id) on delete set null,
  ref                     text not null,
  name                    text not null check (length(trim(name)) > 0),
  description             text,
  due_date                date not null,
  baseline_date           date,
  owner_user_id           uuid references public.users (id),
  status                  pcc.milestone_status not null default 'planned',
  depends_on_milestone_id uuid references pcc.milestones (id) on delete set null,
  completed_at            timestamptz,
  notes                   text,
  created_at              timestamptz not null default now(),
  created_by              uuid references public.users (id),
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.users (id),
  unique (project_id, ref),
  check (depends_on_milestone_id is null or depends_on_milestone_id <> id)
);
comment on column pcc.milestones.baseline_date is 'Ursprünglich geplantes Datum. Jede Verschiebung erzeugt eine Version (Abschnitt 6).';
create index milestones_project_idx on pcc.milestones (project_id, due_date);
create index milestones_due_idx on pcc.milestones (due_date) where status <> 'completed';
create index milestones_workstream_idx on pcc.milestones (workstream_id);

create table pcc.risks (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references pcc.projects (id) on delete cascade,
  ref           text not null,
  title         text not null check (length(trim(title)) > 0),
  description   text,
  category      text,
  probability   smallint not null check (probability between 1 and 5),
  impact        smallint not null check (impact between 1 and 5),
  score         smallint generated always as (probability * impact) stored,
  owner_user_id uuid references public.users (id),
  mitigation    text,
  contingency   text,
  due_date      date,
  status        pcc.risk_status not null default 'open',
  closed_at     timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.users (id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.users (id),
  unique (project_id, ref)
);
comment on column pcc.risks.score is 'Generierte Spalte. Nie im Anwendungscode gerechnet, damit Filter und Sortierung serverseitig stimmen (Abschnitt 24).';
create index risks_project_idx on pcc.risks (project_id, score desc);
create index risks_open_idx on pcc.risks (project_id) where status in ('open', 'monitoring');
create index risks_owner_idx on pcc.risks (owner_user_id);

create table pcc.issues (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references pcc.projects (id) on delete cascade,
  ref           text not null,
  title         text not null check (length(trim(title)) > 0),
  description   text,
  owner_user_id uuid references public.users (id),
  priority      pcc.priority not null default 'medium',
  status        pcc.issue_status not null default 'open',
  due_date      date,
  resolution    text,
  resolved_at   timestamptz,
  risk_id       uuid references pcc.risks (id) on delete set null,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.users (id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.users (id),
  unique (project_id, ref)
);
comment on column pcc.issues.risk_id is 'Ein eingetretenes Risiko wird zum Issue und behält die Herkunft.';
create index issues_project_idx on pcc.issues (project_id, status);
create index issues_owner_idx on pcc.issues (owner_user_id, created_by);

create table pcc.decisions (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references pcc.projects (id) on delete cascade,
  ref            text not null,
  decided_on     date not null default current_date,
  topic          text not null check (length(trim(topic)) > 0),
  decision       text not null check (length(trim(decision)) > 0),
  maker_user_id  uuid references public.users (id),
  participants   uuid[] not null default '{}',
  rationale      text,
  impact         text,
  task_id        uuid references pcc.tasks (id) on delete set null,
  created_at     timestamptz not null default now(),
  created_by     uuid references public.users (id),
  updated_at     timestamptz not null default now(),
  updated_by     uuid references public.users (id),
  unique (project_id, ref)
);
create index decisions_project_idx on pcc.decisions (project_id, decided_on desc);

-- -----------------------------------------------------------------------------
-- RACI, Dokumente, Kommentare
-- -----------------------------------------------------------------------------
create table pcc.raci (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null references pcc.projects (id) on delete cascade,
  subject_type pcc.entity_type not null,
  subject_id   uuid not null,
  user_id      uuid not null references public.users (id) on delete cascade,
  letter       pcc.raci_letter not null,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.users (id),
  check (subject_type in ('workstream', 'task', 'milestone')),
  unique (subject_type, subject_id, user_id, letter)
);
comment on table pcc.raci is 'Eigene Tabelle statt Feld an der Aufgabe: genau ein A, beliebig viele C und I (Abschnitt 19).';
-- Genau ein Accountable je Gegenstand.
create unique index raci_one_accountable on pcc.raci (subject_type, subject_id) where letter = 'A';
create index raci_subject_idx on pcc.raci (subject_type, subject_id);
create index raci_user_idx on pcc.raci (user_id);
create index raci_project_idx on pcc.raci (project_id);

create table pcc.documents (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references pcc.projects (id) on delete cascade,
  entity_type   pcc.entity_type not null default 'project',
  entity_id     uuid,
  title         text not null check (length(trim(title)) > 0),
  description   text,
  kind          pcc.document_kind not null,
  storage_path  text,
  external_url  text,
  mime_type     text,
  size_bytes    bigint check (size_bytes is null or size_bytes <= 52428800),
  scan_state    pcc.scan_state not null default 'pending',
  version       smallint not null default 1 check (version >= 1),
  supersedes_id uuid references pcc.documents (id) on delete set null,
  owner_user_id uuid references public.users (id),
  deleted_at    timestamptz,
  deleted_by    uuid references public.users (id),
  deleted_reason text,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.users (id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.users (id),
  -- Abschnitt 7a: entweder Datei im Bucket oder externer Verweis, nie beides.
  check ((kind = 'file' and storage_path is not null and external_url is null)
      or (kind = 'link' and external_url is not null and storage_path is null)),
  -- Ohne Größe keine Datei: sonst ließe sich die 50-MB-Grenze umgehen, indem
  -- die Angabe schlicht weggelassen wird.
  check (kind <> 'file' or size_bytes is not null)
);
comment on table pcc.documents is 'Dokument. Eine neue Fassung löst die alte über supersedes_id ab, statt sie zu überschreiben (Abschnitt 7a).';
comment on column pcc.documents.size_bytes is 'Harte Grenze 50 MB je Datei. Größeres bleibt extern.';
create index documents_project_idx on pcc.documents (project_id) where deleted_at is null;
create index documents_entity_idx on pcc.documents (entity_type, entity_id);
create index documents_owner_idx on pcc.documents (owner_user_id);
create unique index documents_supersedes_once on pcc.documents (supersedes_id) where supersedes_id is not null;

create table pcc.comments (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references pcc.projects (id) on delete cascade,
  entity_type pcc.entity_type not null,
  entity_id   uuid not null,
  user_id     uuid not null references public.users (id),
  body        text not null check (length(trim(body)) > 0),
  edited_at   timestamptz,
  deleted_at  timestamptz,
  deleted_by  uuid references public.users (id),
  deleted_reason text,
  created_at  timestamptz not null default now()
);
create index comments_entity_idx on pcc.comments (entity_type, entity_id, created_at);
create index comments_project_idx on pcc.comments (project_id, created_at desc);
create index comments_user_idx on pcc.comments (user_id);

create table pcc.mentions (
  comment_id uuid not null references pcc.comments (id) on delete cascade,
  user_id    uuid not null references public.users (id) on delete cascade,
  primary key (comment_id, user_id)
);
create index mentions_user_idx on pcc.mentions (user_id);

create table pcc.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  project_id  uuid references pcc.projects (id) on delete cascade,
  kind        pcc.notification_kind not null,
  entity_type pcc.entity_type,
  entity_id   uuid,
  title       text not null,
  body        text,
  read_at     timestamptz,
  email_state pcc.email_state not null default 'pending',
  created_at  timestamptz not null default now()
);
create index notifications_user_idx on pcc.notifications (user_id, read_at, created_at desc);
-- Der Tageslauf fragt je Eintrag, ob heute schon gemeldet wurde.
create index notifications_entity_idx on pcc.notifications (entity_id, kind, created_at);
create index notifications_project_idx on pcc.notifications (project_id);

-- -----------------------------------------------------------------------------
-- Versionierung (Abschnitt 6)
-- -----------------------------------------------------------------------------
create table pcc.version_triggers (
  code        text primary key,
  label_de    text not null,
  label_en    text not null,
  active      boolean not null default true,
  description text
);
comment on table pcc.version_triggers is 'Konfiguration: welche Ereignisse eine neue Projektversion erzeugen. Erweiterbar ohne Codeänderung.';

create table pcc.project_versions (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null references pcc.projects (id) on delete cascade,
  version      text not null,
  trigger_code text references pcc.version_triggers (code),
  summary      text not null,
  created_by   uuid references public.users (id),
  created_at   timestamptz not null default now(),
  unique (project_id, version)
);
create index project_versions_idx on pcc.project_versions (project_id, created_at desc);

create table pcc.version_changes (
  id          bigint generated always as identity primary key,
  version_id  uuid not null references pcc.project_versions (id) on delete cascade,
  entity_type pcc.entity_type not null,
  entity_id   uuid,
  entity_label text,
  field       text not null,
  old_value   text,
  new_value   text
);
create index version_changes_idx on pcc.version_changes (version_id);

-- -----------------------------------------------------------------------------
-- Referenznummern je Projekt (T-1, R-4, I-2, D-3)
-- -----------------------------------------------------------------------------
create table pcc.ref_counters (
  project_id uuid not null references pcc.projects (id) on delete cascade,
  prefix     text not null,
  last_value integer not null default 0,
  primary key (project_id, prefix)
);

create table pcc.changelog (
  version      text primary key,
  released_on  date not null default current_date,
  notes_de     text not null,
  notes_en     text not null
);
comment on table pcc.changelog is 'Versionsstand und Änderungshistorie, sichtbar im Bereich des Super Admins.';

create table pcc.settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_by  uuid references public.users (id),
  updated_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- updated_at
-- -----------------------------------------------------------------------------
-- Optimistisches Sperren (Abschnitt 5). Schickt die Oberfläche den Stand mit,
-- auf dem sie den Satz geladen hat, und ist dieser inzwischen überholt, wird
-- der Schreibvorgang abgewiesen statt still zu überschreiben. Wer kein
-- updated_at mitschickt, bekommt das alte Verhalten.
create or replace function pcc.tg_touch()
returns trigger language plpgsql as $$
begin
  if not public.internal_write_enabled()
     and new.updated_at is distinct from old.updated_at
     and new.updated_at < old.updated_at then
    raise exception 'PCC_CONFLICT: Der Satz wurde inzwischen von jemand anderem geändert'
      using errcode = 'P0001',
            detail = 'Geladen: ' || new.updated_at || ', aktuell: ' || old.updated_at;
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['templates','projects','workstreams','tasks','milestones',
                           'risks','issues','decisions','documents']
  loop
    execute format('create trigger %I_touch before update on pcc.%I for each row execute function pcc.tg_touch()', t, t);
  end loop;
end $$;
