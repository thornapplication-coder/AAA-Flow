-- =============================================================================
-- Project Control Center — SQL-Tests: Berichtslinie zur Geschäftsführung
-- Entscheidungsbedarf, Ampel-Trend, Verschiebungshistorie, Superadmin.
-- Läuft in einer eigenen Transaktion und rollt am Ende zurück.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
begin;

create schema test2;
grant usage on schema test2 to authenticated;
create table t2_users (key text primary key, id uuid, auth_id uuid);
create table t2_ids (key text primary key, id uuid not null);
grant select on t2_users, t2_ids to authenticated;
grant insert on t2_ids to authenticated;

create function test2.login(p_key text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select auth_id into v_id from t2_users where key = p_key;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  execute 'set role authenticated';
end $$;
create function test2.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function test2.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'TEST FAILED: %', p_msg; end if;
  raise notice 'ok - %', p_msg;
end $$;
create function test2.fails(p_sql text, p_needle text, p_msg text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_needle in sqlerrm) = 0 then
      raise exception 'TEST FAILED: % — erwartet "%", erhalten "%"', p_msg, p_needle, sqlerrm;
    end if;
    raise notice 'ok - % [%]', p_msg, p_needle;
    return;
  end;
  raise exception 'TEST FAILED: % — kein Fehler ausgelöst', p_msg;
end $$;
create function test2.pid(p_key text) returns uuid language sql stable as $$
  select id from t2_ids where key = p_key;
$$;
grant execute on all functions in schema test2 to authenticated;

-- Zugänge: der Seed legt die beiden Zeilen an, das Anmeldekonto hängt der
-- Test daran — wie in 001_core.
insert into t2_users (key, id)
select k, u.id from (values ('team'), ('viewer')) v(k)
join public.users u on u.role::text = v.k;
update t2_users set auth_id = gen_random_uuid() where key in ('team', 'viewer');
insert into auth.users (id, email)
select t.auth_id, u.email from t2_users t join public.users u on u.id = t.id
 where t.auth_id is not null;

-- Eine Person ohne eigene Anmeldung, die das Projekt leitet.
select public.enable_internal_write();
insert into public.users (name, email, job_title)
values ('Regina Berg', 'pm.report@test.invalid', 'Head of Training');
select public.disable_internal_write();
insert into t2_users (key, id)
select 'pm', id from public.users where email = 'pm.report@test.invalid';

-- -----------------------------------------------------------------------------
-- 1. Struktur: die vier neuen Bausteine sind da und stehen unter RLS
-- -----------------------------------------------------------------------------
select test2.ok((select count(*) from pg_tables where schemaname = 'pcc'
                  and tablename in ('decision_requests','health_snapshots','milestone_shifts')) = 3,
                'Die drei neuen Tabellen gibt es');
select test2.ok((select count(*) from pg_tables t
                  join pg_class c on c.relname = t.tablename
                  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'pcc'
                 where t.schemaname = 'pcc' and t.tablename in
                       ('decision_requests','health_snapshots','milestone_shifts')
                   and c.relrowsecurity and c.relforcerowsecurity) = 3,
                'Alle drei stehen unter Row Level Security');
select test2.ok((select count(*) from information_schema.columns
                  where table_schema = 'public' and table_name = 'users' and column_name = 'is_super') = 1,
                'Das Superadmin-Kennzeichen steht am Personenverzeichnis');

-- -----------------------------------------------------------------------------
-- 2. Kalenderwoche nach ISO 8601
-- -----------------------------------------------------------------------------
select test2.ok(pcc.iso_week(date '2026-01-01') = '2026-01', 'Der 1. Januar 2026 liegt in Woche 1');
select test2.ok(pcc.iso_week(date '2026-01-05') = '2026-02', 'Der 5. Januar 2026 liegt in Woche 2');
select test2.ok(pcc.iso_week(date '2026-09-19') = '2026-38', 'Der 19. September 2026 liegt in Woche 38');
-- Der 1. Januar 2027 ist ein Freitag und gehört noch zur letzten Woche 2026.
select test2.ok(pcc.iso_week(date '2027-01-01') = '2026-53', 'Der Jahreswechsel trifft das richtige Bezugsjahr');

-- -----------------------------------------------------------------------------
-- 3. Entscheidungsbedarf
-- -----------------------------------------------------------------------------
select test2.login('team');
insert into t2_ids (key, id)
select 'p1', (pcc.create_project('REP-26', 'Berichtsprüfung',
  (select id from t2_users where key = 'pm'))).id;

insert into pcc.decision_requests (project_id, topic, question, recommendation, due_date, decide_by)
values (test2.pid('p1'), 'Zweiter Slot', 'Soll der Slot fest gebucht werden?',
        'Buchen — der Ersatztermin kostet mehr.', current_date + 10, 'Geschäftsführung');
select test2.ok((select ref from pcc.decision_requests where project_id = test2.pid('p1')) = 'A-1',
                'Die Referenznummer wird vergeben, nicht eingegeben');
select test2.ok((select count(*) from pcc.decision_requests where status = 'open') = 1,
                'Der Punkt steht offen');
select test2.ok((select overdue from pcc.v_decision_requests where ref = 'A-1') = false,
                'Eine Frist in der Zukunft ist nicht überfällig');
select test2.ok((select raised_by from pcc.v_decision_requests where ref = 'A-1') is not null,
                'Die Sicht nennt, wer die Frage gestellt hat');

-- Ohne Frist geht es nicht: eine Anfrage ohne Termin bleibt liegen.
select test2.fails(
  'insert into pcc.decision_requests (project_id, topic, question, due_date)
     values (''' || test2.pid('p1') || ''', ''Ohne Frist'', ''Frage?'', null)',
  'null value', 'Ohne Frist lässt sich nichts anfordern');

-- Entschieden heißt: mit Datum.
select test2.fails(
  'update pcc.decision_requests set status = ''decided'' where ref = ''A-1''',
  'decided_needs_date', 'Entschieden ohne Datum wird abgewiesen');

update pcc.decision_requests set status = 'decided', decided_on = current_date where ref = 'A-1';
select test2.ok((select decided_on from pcc.decision_requests where ref = 'A-1') = current_date,
                'Mit Datum lässt sich der Punkt schließen');

-- Die Referenz bleibt, woran man sie im Gespräch erkennt.
select test2.fails(
  'update pcc.decision_requests set ref = ''A-9'' where ref = ''A-1''',
  'PCC_IMMUTABLE', 'Die Referenznummer bleibt bestehen');

-- Der Lesezugang darf nichts anfordern.
select test2.login('viewer');
select test2.ok((select count(*) from pcc.decision_requests) = 1, 'Der Lesezugang sieht den Bedarf');
select test2.fails(
  'insert into pcc.decision_requests (project_id, topic, question, due_date)
     values (''' || test2.pid('p1') || ''', ''Unerlaubt'', ''Frage?'', current_date + 5)',
  'row-level security', 'Der Lesezugang fordert nichts an');

-- -----------------------------------------------------------------------------
-- 4. Ampel-Trend
-- -----------------------------------------------------------------------------
select test2.logout();
select test2.ok(pcc.take_health_snapshot() >= 1, 'Der Tageslauf hält die Lage fest');
select test2.ok((select count(*) from pcc.health_snapshots
                  where project_id = test2.pid('p1') and iso_week = pcc.iso_week()) = 1,
                'Eine Zeile je Projekt und Woche');
select test2.ok(pcc.take_health_snapshot() >= 1, 'Ein zweiter Lauf in derselben Woche läuft durch');
select test2.ok((select count(*) from pcc.health_snapshots
                  where project_id = test2.pid('p1')) = 1,
                'Und überschreibt, statt eine zweite Zeile anzulegen');

-- Richtung: erst eine frühere Woche macht einen Vergleich möglich.
select test2.ok((select count(*) from pcc.health_trend(test2.pid('p1'))) = 0,
                'Ohne frühere Woche gibt es keine Richtung');
insert into pcc.health_snapshots (project_id, iso_week, health)
values (test2.pid('p1'), '2026-01', 'red');
select test2.ok((select direction from pcc.health_trend(test2.pid('p1'))) = 1,
                'Von rot auf grün ist besser');
select test2.ok((select from_health from pcc.health_trend(test2.pid('p1'))) = 'red',
                'Die Richtung nennt, womit verglichen wurde');
insert into pcc.health_snapshots (project_id, iso_week, health)
values (test2.pid('p1'), '2026-02', 'green');
select test2.ok((select from_week from pcc.health_trend(test2.pid('p1'))) = '2026-02',
                'Verglichen wird mit der jüngsten früheren Woche');

-- Momentaufnahmen schreibt die Anwendung nicht.
select test2.login('team');
select test2.fails(
  'insert into pcc.health_snapshots (project_id, iso_week, health)
     values (''' || test2.pid('p1') || ''', ''2025-01'', ''green'')',
  'permission denied', 'Die Oberfläche schreibt keine Momentaufnahmen');

-- -----------------------------------------------------------------------------
-- 5. Verschiebungshistorie der Meilensteine
-- -----------------------------------------------------------------------------
with neu as (
  insert into pcc.milestones (project_id, name, due_date, baseline_date)
  values (test2.pid('p1'), 'Freigabe', current_date + 30, current_date + 30)
  returning id)
insert into t2_ids (key, id) select 'm1', id from neu;
select test2.ok((select count(*) from pcc.milestone_shifts where milestone_id = test2.pid('m1')) = 1,
                'Schon das Anlegen erzeugt den ersten Eintrag der Linie');
update pcc.milestones set due_date = current_date + 45 where id = test2.pid('m1');
select test2.ok((select count(*) from pcc.milestone_shifts where milestone_id = test2.pid('m1')) = 2,
                'Jede Verschiebung kommt dazu');
select test2.ok((select from_date from pcc.milestone_shifts
                  where milestone_id = test2.pid('m1') and from_date is not null) = current_date + 30,
                'Die Spur hält fest, von wo verschoben wurde');
-- Eine Änderung am Namen ist keine Verschiebung.
update pcc.milestones set name = 'Freigabe FSTD' where id = test2.pid('m1');
select test2.ok((select count(*) from pcc.milestone_shifts where milestone_id = test2.pid('m1')) = 2,
                'Andere Änderungen erzeugen keinen Eintrag');
select test2.ok((select max_slip_days from pcc.v_schedule_drift where project_id = test2.pid('p1')) = 15,
                'Die Termintreue nennt den größten Verzug in Tagen');

-- -----------------------------------------------------------------------------
-- 6. Superadmin
-- -----------------------------------------------------------------------------
select test2.logout();
update public.users set is_super = true where email = 'pm.report@test.invalid';
select test2.ok((select count(*) from public.users where is_super and active) >= 1,
                'Es gibt mindestens einen Superadmin');
-- Der letzte bleibt — sonst kommt niemand mehr in die Verwaltung.
update public.users set is_super = false
 where is_super and email <> 'pm.report@test.invalid';
select test2.fails(
  'update public.users set is_super = false where email = ''pm.report@test.invalid''',
  'PCC_STATE', 'Dem letzten Superadmin lässt sich das Recht nicht entziehen');
select test2.fails(
  'update public.users set active = false where email = ''pm.report@test.invalid''',
  'PCC_STATE', 'Und stilllegen lässt er sich auch nicht');
-- Mit einer zweiten Person geht beides wieder.
select public.enable_internal_write();
insert into public.users (name, email, is_super) values ('Zweiter Super', 'super2@test.invalid', true);
select public.disable_internal_write();
update public.users set is_super = false where email = 'pm.report@test.invalid';
select test2.ok((select is_super from public.users where email = 'pm.report@test.invalid') = false,
                'Mit einem zweiten Superadmin lässt sich das Recht abgeben');

rollback;
