-- =============================================================================
-- Project Control Center — SQL-Tests
-- Registrierung und Freigabe, Rechte, Projekte, Referenzen, Versionierung,
-- Gesamtlage, Fortschritt, Dokumente, Kommentare, Löschweg, Tageslauf.
-- Läuft in einer Transaktion und rollt am Ende zurück.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
begin;

create schema test;
grant usage on schema test to authenticated;
-- auth_id ist der Zugang (nur die beiden Zugangszeilen haben einen),
-- id ist die Person im Verzeichnis. Die Tests sprechen über test.uid() immer
-- von der Person — Zuständigkeiten hängen an ihr, nicht am Zugang.
create table test_users (key text primary key, id uuid, auth_id uuid);
create table test_ids (key text primary key, id uuid not null);
grant select on test_users, test_ids to authenticated;
grant insert on test_ids to authenticated;

create function test.login(p_key text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select auth_id into v_id from test_users where key = p_key;
  if v_id is null then
    raise exception 'TEST FEHLER: % hat keinen Zugang — es gibt nur team und viewer', p_key;
  end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  execute 'set role authenticated';
end $$;
create function test.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function test.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'TEST FAILED: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end $$;
create function test.fails(p_sql text, p_needle text, p_msg text) returns void language plpgsql as $$
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
create function test.uid(p_key text) returns uuid language sql stable as $$
  select id from test_users where key = p_key;
$$;
create function test.pid(p_key text) returns uuid language sql stable as $$
  select id from test_ids where key = p_key;
$$;
grant execute on all functions in schema test to authenticated;

-- -----------------------------------------------------------------------------
-- 1. Grunddaten
-- -----------------------------------------------------------------------------
select test.ok((select count(*) from pcc.version_triggers where active) = 8, 'Acht Versionsauslöser konfiguriert');
select test.ok((select count(*) from pcc.settings) >= 5, 'Einstellungen vorhanden');
select test.ok((select count(*) from pcc.changelog) = 11, 'Der Changelog führt alle Fassungen');
select test.ok((select value ->> 'mode' from pcc.settings where key = 'retention') = 'unlimited',
               'Aufbewahrung steht auf unbegrenzt (Entscheidung vom 18.09.2026)');
select test.ok((select count(*) from pcc.templates where active) = 1, 'Eine Projektvorlage im Seed');
-- Keine Tabelle des Schemas darf ohne Row Level Security dastehen. Eine feste
-- Liste hatte genau hier schon einmal eine Lücke gelassen.
select test.ok((select count(*) from pg_tables t
                 join pg_class c on c.relname = t.tablename
                 join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'pcc'
                where t.schemaname = 'pcc'
                  and not (c.relrowsecurity and c.relforcerowsecurity)) = 0,
               'Jede Tabelle in pcc steht unter Row Level Security');

-- -----------------------------------------------------------------------------
-- 2. Zwei Zugänge, viele Personen (Abschnitt 4, Fassung vom 19.09.2026)
-- -----------------------------------------------------------------------------
-- Der Seed hat die beiden Zugangszeilen angelegt. Die Tests hängen je ein
-- Anmeldekonto daran und tragen daneben Personen ohne eigene Anmeldung ein.
select test.ok((select count(*) from public.users where role is not null) = 2,
               'Der Seed richtet genau zwei Zugänge ein');

insert into test_users (key, id)
select k, u.id from (values ('team'), ('viewer')) v(k)
join public.users u on u.role::text = case v.k when 'team' then 'team' else 'viewer' end;
update test_users set auth_id = gen_random_uuid() where key in ('team', 'viewer');
insert into auth.users (id, email)
select t.auth_id, u.email from test_users t join public.users u on u.id = t.id
 where t.auth_id is not null;

select test.ok((select count(*) from public.users where auth_user_id is not null) = 2,
               'Das Anmeldekonto findet den vorbereiteten Zugang über die Adresse');

-- Personen ohne eigene Anmeldung: sie tragen Aufgaben, Risiken und
-- Verantwortung, melden sich aber nie selbst an.
select public.enable_internal_write();
insert into public.users (name, email, job_title)
values ('Marion Kern',    'ppm@test.invalid',   'Training Admin'),
       ('Christian Wies', 'ppm2@test.invalid',  'Head of Training'),
       ('Lena Ostheim',   'pcon@test.invalid',  'Training Admin'),
       ('Robert Zach',    'pext@test.invalid',  'Course Supervisor');
select public.disable_internal_write();
insert into test_users (key, id)
select k, (select id from public.users where email = k || '@test.invalid')
from (values ('ppm'), ('ppm2'), ('pcon'), ('pext')) v(k);

select test.ok((select role is null and auth_user_id is null and active
                from public.users where id = test.uid('ppm')),
               'Eine Person im Verzeichnis hat weder Rolle noch Anmeldung');

-- Ein drittes Konto gibt es nicht: der Riegel liegt im Schema.
select test.fails('select pcc.prepare_account(''dritter@test.invalid'', ''team'', ''Zuviel'')',
                  'users_one_account_per_role', 'Ein dritter Zugang entsteht nicht');

-- Eine Anmeldung ohne vorbereiteten Zugang läuft ins Leere.
insert into auth.users (id, email) values (gen_random_uuid(), 'fremd@test.invalid');
select test.ok((select count(*) from public.users where email = 'fremd@test.invalid') = 0,
               'Eine fremde Anmeldung legt keine Person an');

select test.login('viewer');
select test.ok(pcc.is_user() = true, 'Der Lesezugang ist angemeldet');
select test.ok(pcc.is_team() = false, 'Der Lesezugang ist nicht der Teamzugang');
select test.logout();
select test.login('team');
select test.ok(pcc.is_team() = true, 'Der Teamzugang darf alles');
select test.logout();

-- -----------------------------------------------------------------------------
-- 3. Projekte anlegen
-- -----------------------------------------------------------------------------
select test.login('viewer');
select test.fails('select pcc.create_project(''VIE-26'', ''Unerlaubt'')',
                  'PCC_AUTH', 'Ein Viewer legt kein Projekt an');
select test.logout();

select test.login('team');
insert into test_ids (key, id)
select 'p1', (pcc.create_project('SIM-26', 'CL650 Full Flight Simulator Introduction',
  test.uid('ppm'), 'Einführung des CL650 FFS am Standort Wien.',
  'FSTD-Qualifikation Level D bis Jahresende.', 'In Scope: Abnahme und Qualifikation.',
  current_date - 120, current_date + 75)).id;
select test.ok((select pm_user_id from pcc.projects where id = test.pid('p1')) = test.uid('ppm'),
               'Die Projektleitung kommt aus dem Personenverzeichnis');
-- Eine Leitung, die es nicht gibt, wird abgewiesen: sonst stünde ein Projekt
-- unter der Verantwortung einer Kennung, hinter der niemand steht.
select test.fails('select pcc.create_project(''VIE-26'', ''Unbekannte Leitung'',
                   ''00000000-0000-0000-0000-000000000009'')',
                  'PCC_STATE', 'Die Projektleitung muss im Verzeichnis stehen');
select test.ok((select count(*) from pcc.project_members where project_id = test.pid('p1')) = 1,
               'Die Projektleitung ist automatisch Mitglied');
select test.ok((select version from pcc.project_versions where project_id = test.pid('p1')) = '1.0',
               'Die Anlage erzeugt Version 1.0');
select test.fails('select pcc.create_project(''sim26'', ''Falscher Schlüssel'')',
                  'projects_key_check', 'Der Projektschlüssel folgt dem Muster SIM-26');
select test.fails(format('insert into pcc.projects (key, name, pm_user_id) values (''XXX-26'', ''Direkt'', %L)', test.uid('ppm')),
                  'permission denied', 'Projekte entstehen nur über create_project()');
select test.logout();

-- -----------------------------------------------------------------------------
-- 4. Referenznummern, generierte Spalten, Statusfelder
-- -----------------------------------------------------------------------------
select test.login('team');
insert into pcc.workstreams (project_id, name, owner_user_id, sort_order)
values (test.pid('p1'), 'Qualifikation', test.uid('ppm'), 1);
insert into test_ids (key, id)
select 'ws1', id from pcc.workstreams where project_id = test.pid('p1');

with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, assignee_user_id, priority, due_date)
  values (test.pid('p1'), test.pid('ws1'), 'Factory Acceptance Test durchführen',
          test.uid('pcon'), 'critical', current_date + 10)
  returning id)
insert into test_ids (key, id) select 't1', id from ins;
select test.ok((select ref from pcc.tasks where id = test.pid('t1')) = 'T-1',
               'Die erste Aufgabe erhält die Referenz T-1');
select test.fails(format('update pcc.tasks set ref = ''T-99'' where id = %L', test.pid('t1')),
                  'PCC_IMMUTABLE', 'Die Referenznummer bleibt bestehen');

with ins as (
  insert into pcc.risks (project_id, title, probability, impact, owner_user_id, status)
  values (test.pid('p1'), 'Verzug bei der behördlichen Qualifikation', 3, 4, test.uid('ppm'), 'open')
  returning id)
insert into test_ids (key, id) select 'r1', id from ins;
select test.ok((select ref = 'R-1' and score = 12 from pcc.risks where id = test.pid('r1')),
               'Risiko R-1, Score wird von der Datenbank gerechnet');
select test.fails(format('update pcc.risks set score = 25 where id = %L', test.pid('r1')),
                  'can only be updated to DEFAULT', 'Der Risk Score lässt sich nicht von Hand setzen');
select test.fails(format('update pcc.risks set probability = 9 where id = %L', test.pid('r1')),
                  'risks_probability_check', 'Eintrittswahrscheinlichkeit bleibt zwischen 1 und 5');

update pcc.tasks set status = 'completed' where id = test.pid('t1');
select test.ok((select completed_at is not null and progress = 100 from pcc.tasks where id = test.pid('t1')),
               'Eine erledigte Aufgabe bekommt Datum und 100 Prozent von selbst');
update pcc.tasks set status = 'in_progress', progress = 40 where id = test.pid('t1');
select test.ok((select completed_at is null from pcc.tasks where id = test.pid('t1')),
               'Wird die Aufgabe wieder geöffnet, verschwindet das Abschlussdatum');
select test.logout();

-- -----------------------------------------------------------------------------
-- 5. Was die beiden Zugänge dürfen (Abschnitt 5, Fassung vom 19.09.2026)
-- -----------------------------------------------------------------------------
select test.login('team');
select pcc.add_member(test.pid('p1'), test.uid('pcon'), 'Course Supervisor', 'Kursunterlagen');
select pcc.add_member(test.pid('p1'), test.uid('pext'), 'Sponsor', 'Freigaben');
select test.ok((select count(*) from pcc.project_members where project_id = test.pid('p1')) = 3,
               'Personen ohne eigene Anmeldung gehören ins Projektteam');
select test.logout();

-- Der Lesezugang: sieht alles, ändert nichts. Ein fehlendes Recht heißt unter
-- Row Level Security nicht „Fehler", sondern „keine Zeile getroffen" — deshalb
-- wird gezählt, nicht auf eine Meldung gewartet.
select test.login('viewer');
select test.ok((select count(*) from pcc.projects where id = test.pid('p1')) = 1,
               'Der Lesezugang liest jedes Projekt');
select test.ok(pcc.can_edit(test.pid('p1')) = false, 'Der Lesezugang hat kein Schreibrecht');
with u as (update pcc.tasks set title = 'Heimlich geändert' where id = test.pid('t1') returning 1)
select test.ok((select count(*) from u) = 0, 'Der Lesezugang ändert keine Aufgabe');
with u as (update pcc.projects set status = 'completed' where id = test.pid('p1') returning 1)
select test.ok((select count(*) from u) = 0, 'Der Lesezugang schließt kein Projekt ab');
select test.fails(format('insert into pcc.tasks (project_id, title) values (%L, ''Vom Lesezugang'')', test.pid('p1')),
                  'row-level security', 'Der Lesezugang legt nichts an');
select test.fails(format('insert into pcc.documents (project_id, title, kind, external_url)
                          values (%L, ''Vom Lesezugang'', ''link'', ''https://x'')', test.pid('p1')),
                  'row-level security', 'Der Lesezugang hängt keine Datei an');
select test.fails(format('select pcc.post_comment(%L, ''task'', %L, ''Kein Recht'')',
                         test.pid('p1'), test.pid('t1')),
                  'PCC_AUTH', 'Der Lesezugang kommentiert nicht');
select test.ok((select count(*) from pcc.v_people) >= 6, 'Der Lesezugang sieht das Personenverzeichnis');
select test.logout();

-- Der Teamzugang: alles, in jedem Projekt.
select test.login('team');
select test.ok(pcc.can_edit(test.pid('p1')) = true, 'Der Teamzugang ändert jedes Projekt');
update pcc.tasks set progress = 60 where id = test.pid('t1');
select test.ok((select progress from pcc.tasks where id = test.pid('t1')) = 60,
               'Der Teamzugang pflegt jede Aufgabe');
insert into pcc.tasks (project_id, title) values (test.pid('p1'), 'Vom Teamzugang angelegt');
select test.ok((select count(*) from pcc.tasks where title = 'Vom Teamzugang angelegt') = 1,
               'Der Teamzugang legt Aufgaben an');
insert into pcc.issues (project_id, title, owner_user_id)
values (test.pid('p1'), 'Lieferung der Instruktorenstation verzögert', test.uid('pcon'));
select test.ok((select count(*) from pcc.issues where project_id = test.pid('p1')) = 1,
               'Ein Problem lässt sich einer Person ohne Anmeldung zuordnen');
select test.logout();

-- -----------------------------------------------------------------------------
-- 6. Versionierung (Abschnitt 6)
-- -----------------------------------------------------------------------------
select test.login('team');
update pcc.projects set status = 'on_track' where id = test.pid('p1');
select test.ok((select count(*) from pcc.project_versions where project_id = test.pid('p1')) = 2,
               'Ein Statuswechsel erzeugt eine Version');
select test.ok((select version from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'project_status') = '1.1',
               'Die Version zählt in Zehnteln hoch');
select test.ok((select count(*) from pcc.version_changes vc
                join pcc.project_versions v on v.id = vc.version_id
                where v.project_id = test.pid('p1') and vc.field = 'status') = 1,
               'Die Einzeländerung steht in version_changes');

update pcc.projects set description = 'Nur eine Beschreibung' where id = test.pid('p1');
select test.ok((select count(*) from pcc.project_versions where project_id = test.pid('p1')) = 2,
               'Eine beliebige Feldänderung erzeugt keine Version');

with ins as (
  insert into pcc.milestones (project_id, name, due_date, owner_user_id)
  values (test.pid('p1'), 'Qualifikation erteilt', current_date + 40, test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'm1', id from ins;
update pcc.milestones set due_date = current_date + 60 where id = test.pid('m1');
select test.ok((select count(*) from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'milestone_moved') = 1,
               'Ein verschobener Meilenstein erzeugt eine Version');
select test.ok((select slipped_days from pcc.v_milestones where id = test.pid('m1')) = 20,
               'Die Verschiebung gegen den Ursprungstermin ist ablesbar');

update pcc.risks set probability = 5, impact = 4 where id = test.pid('r1');
select test.ok((select count(*) from pcc.project_versions
                where project_id = test.pid('p1') and trigger_code = 'risk_critical') = 1,
               'Ein Risiko ab Score 15 erzeugt eine Version');
select test.fails(format('update pcc.project_versions set summary = ''x'' where project_id = %L', test.pid('p1')),
                  'permission denied', 'Versionen sind gegen Änderung gesperrt');
select test.logout();

-- Benachrichtigung über das kritische Risiko geht an die Projektleitung
select test.login('team');
insert into test_ids (key, id)
select 'p2', (pcc.create_project('OMB-26', 'Operations Manual Part B Revision', test.uid('ppm2'))).id;
insert into pcc.risks (project_id, title, probability, impact, status)
values (test.pid('p2'), 'Behördliche Rückfragen', 5, 5, 'open');
select test.logout();
select test.login('team');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('ppm2') and kind = 'risk_critical'
                  and project_id = test.pid('p2')) = 1,
               'Ein kritisches Risiko meldet sich bei der Projektleitung');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('ppm') and project_id = test.pid('p2')) = 0,
               'Die Meldung geht an die zuständige Projektleitung, nicht an alle');
select test.logout();

-- -----------------------------------------------------------------------------
-- 7. Fortschritt und Gesamtlage
-- -----------------------------------------------------------------------------
select test.login('team');
insert into pcc.tasks (project_id, parent_task_id, title, status)
values (test.pid('p1'), test.pid('t1'), 'Prüfprotokoll vorbereiten', 'completed'),
       (test.pid('p1'), test.pid('t1'), 'Testflüge abnehmen', 'not_started');
update pcc.tasks set progress_mode = 'derived' where id = test.pid('t1');
select test.ok(pcc.task_progress(test.pid('t1')) = 50,
               'Der Fortschritt einer Aufgabe kann aus den Teilaufgaben kommen');
update pcc.tasks set progress_mode = 'manual', progress = 60 where id = test.pid('t1');
select test.ok(pcc.task_progress(test.pid('t1')) = 60,
               'Oder von Hand gesetzt bleiben — je Aufgabe entscheidbar');

select test.ok(pcc.health(test.pid('p1')) = 'amber',
               'Ein kritisches Risiko färbt die Gesamtlage gelb');
insert into pcc.risks (project_id, title, probability, impact, status)
values (test.pid('p1'), 'Ausfall des Herstellersupports', 5, 5, 'open');
select test.ok(pcc.health(test.pid('p1')) = 'red',
               'Zwei kritische Risiken färben sie rot');
update pcc.milestones set due_date = current_date - 5, status = 'planned' where id = test.pid('m1');
select test.ok(pcc.health(test.pid('p1')) = 'red', 'Ein überfälliger Meilenstein ebenfalls');
select test.ok((select health from pcc.v_projects where id = test.pid('p2')) = 'amber',
               'Ein einzelnes kritisches Risiko bleibt gelb');
select test.logout();

-- -----------------------------------------------------------------------------
-- 8. RACI, Dokumente, Kommentare
-- -----------------------------------------------------------------------------
select test.login('team');
insert into pcc.raci (project_id, subject_type, subject_id, user_id, letter)
values (test.pid('p1'), 'task', test.pid('t1'), test.uid('pcon'), 'A'),
       (test.pid('p1'), 'task', test.pid('t1'), test.uid('pext'), 'C');
select test.fails(format('insert into pcc.raci (project_id, subject_type, subject_id, user_id, letter)
                          values (%L, ''task'', %L, %L, ''A'')',
                         test.pid('p1'), test.pid('t1'), test.uid('ppm')),
                  'raci_one_accountable', 'Eine Aufgabe hat genau ein A');

select test.fails(format('insert into pcc.documents (project_id, title, kind, storage_path, external_url)
                          values (%L, ''Doppelt'', ''file'', %L, ''https://x'')',
                         test.pid('p1'), test.pid('p1') || '/b.pdf'),
                  'documents_check', 'Ein Dokument ist entweder Datei oder Verweis, nie beides');
select test.fails(format('insert into pcc.documents (project_id, title, kind, storage_path, size_bytes)
                          values (%L, ''Zu groß'', ''file'', %L, 60000000)',
                         test.pid('p1'), test.pid('p1') || '/b.pdf'),
                  'size_bytes', 'Über 50 MB nimmt die Anwendung keine Datei an');
select test.fails(format('insert into pcc.documents (project_id, title, kind, storage_path, size_bytes)
                          values (%L, ''Fremder Pfad'', ''file'', ''anderes-projekt/b.pdf'', 1000)',
                         test.pid('p1')),
                  'documents_check', 'Der Ablagepfad muss mit der Projektkennung beginnen');

with ins as (
  insert into pcc.documents (project_id, title, kind, storage_path, mime_type, size_bytes, owner_user_id)
  values (test.pid('p1'), 'Qualification Test Guide', 'file', test.pid('p1') || '/qtg-v1.pdf',
          'application/pdf', 240000, test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'd1', id from ins;
select test.ok((select scan_state from pcc.documents where id = test.pid('d1')) = 'pending',
               'Ein Upload ist bis zur Prüfung in Quarantäne');
insert into test_ids (key, id)
select 'd2', (pcc.supersede_document(test.pid('d1'), 'Qualification Test Guide', 'file',
                                     test.pid('p1') || '/qtg-v2.pdf', null, 'application/pdf', 260000)).id;
select test.ok((select version = 2 and supersedes_id = test.pid('d1')
                from pcc.documents where id = test.pid('d2')),
               'Eine neue Fassung löst die alte ab, statt sie zu überschreiben');
select test.ok((select count(*) from pcc.documents where project_id = test.pid('p1')) = 2,
               'Die abgelöste Fassung bleibt erhalten');

-- Dateien hängen an der Aufgabe, nicht bloß am Projekt (Auftrag vom 19.09.2026)
with ins as (
  insert into pcc.documents (project_id, entity_type, entity_id, title, kind,
                             storage_path, mime_type, size_bytes, owner_user_id)
  values (test.pid('p1'), 'task', test.pid('t1'), 'FAT-Protokoll', 'file',
          test.pid('p1') || '/' || test.pid('t1') || '/fat-protokoll.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          180000, test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'd3', id from ins;
select test.ok((select entity_type = 'task' and entity_id = test.pid('t1')
                from pcc.documents where id = test.pid('d3')),
               'Eine Datei lässt sich an eine Aufgabe hängen');
select test.fails(format('insert into pcc.documents (project_id, entity_type, entity_id, title, kind,
                            storage_path, size_bytes)
                          values (%L, ''task'', %L, ''Fremde Aufgabe'', ''file'', %L, 1000)',
                         test.pid('p1'), test.pid('p2'), test.pid('p1') || '/x.pdf'),
                  'PCC_STATE', 'Eine Datei hängt nicht an einer Aufgabe aus einem anderen Projekt');
select test.fails(format('insert into pcc.documents (project_id, entity_type, entity_id, title, kind,
                            storage_path, size_bytes)
                          values (%L, ''task'', null, ''Ohne Bezug'', ''file'', %L, 1000)',
                         test.pid('p1'), test.pid('p1') || '/y.pdf'),
                  'PCC_STATE', 'Zu einer Ablage an der Aufgabe gehört die Aufgabe');
select test.logout();

select test.login('team');
insert into test_ids (key, id)
select 'c1', (pcc.post_comment(test.pid('p1'), 'task', test.pid('t1'),
                               'Der Termin ist knapp, ich brauche eine Entscheidung.',
                               array[test.uid('ppm')])).id;
select test.logout();
select test.login('team');
select test.ok((select count(*) from pcc.notifications
                where user_id = test.uid('ppm') and kind = 'mention') = 1,
               'Eine Erwähnung erreicht die genannte Person');
select test.logout();

select test.login('viewer');
select test.fails(format('select pcc.post_comment(%L, ''task'', %L, ''Kein Recht'')',
                         test.pid('p1'), test.pid('t1')),
                  'PCC_AUTH', 'Ein Viewer kommentiert nicht');
select test.logout();

-- Löschen ist kein gewöhnliches Ändern (Abschnitt 7b)
select test.login('team');
select test.fails(format('update pcc.documents set deleted_at = now() where id = %L', test.pid('d2')),
                  'PCC_AUTH', 'Auch der Teamzugang löscht ein Dokument nicht im Vorbeigehen');
select test.logout();
select test.login('team');
select test.fails(format('select pcc.delete_document(%L, '''')', test.pid('d2')),
                  'PCC_STATE', 'Ohne Grundlage keine Dokumentlöschung');
select pcc.delete_document(test.pid('d2'), 'Antrag nach Artikel 17 DSGVO vom 02.09.2026');
select test.ok((select deleted_at is not null and deleted_reason is not null
                from pcc.documents where id = test.pid('d2')),
               'Der Teamzugang löscht auf Antrag, mit Grundlage');
select test.ok((select count(*) from pcc.documents where id = test.pid('d2')) = 1,
               'Für den Teamzugang bleibt das gelöschte Dokument sichtbar');
select test.logout();
select test.login('viewer');
select test.ok((select count(*) from pcc.documents where id = test.pid('d2')) = 0,
               'Für den Lesezugang ist es verschwunden');
with u as (update pcc.comments set body = 'nachtraeglich geaendert' where id = test.pid('c1') returning 1)
select test.ok((select count(*) from u) = 0, 'Der Lesezugang ändert keinen Kommentar');
select test.logout();
select test.login('team');
update pcc.comments set body = 'Der Termin ist knapp — bitte um Entscheidung bis Freitag.' where id = test.pid('c1');
select test.ok((select edited_at is not null from pcc.comments where id = test.pid('c1')),
               'Ein bearbeiteter Kommentar sagt, dass er bearbeitet wurde');
select test.logout();

-- -----------------------------------------------------------------------------
-- 9. Archiv und endgültiges Löschen (Abschnitt 41)
-- -----------------------------------------------------------------------------
select test.login('team');
select test.fails(format('select pcc.archive_project(%L, '''')', test.pid('p2')),
                  'PCC_STATE', 'Archivieren verlangt einen Grund');
select pcc.archive_project(test.pid('p2'), 'Revision in die Linienorganisation überführt');
select test.fails(format('insert into pcc.tasks (project_id, title) values (%L, ''Nachtrag'')', test.pid('p2')),
                  'PCC_ARCHIVED', 'Ein archiviertes Projekt ist schreibgeschützt');
select test.logout();

-- Endgültiges Löschen bleibt dem Teamzugang vorbehalten.
select test.login('viewer');
select test.fails(format('select pcc.delete_project(%L, ''Versehen'')', test.pid('p2')),
                  'PCC_AUTH', 'Der Lesezugang löscht kein Projekt');
select test.logout();

select test.login('team');
select test.fails(format('select pcc.delete_project(%L, ''  '')', test.pid('p2')),
                  'PCC_STATE', 'Auch der Teamzugang nennt einen Grund');
select pcc.delete_project(test.pid('p2'), 'Doppelt angelegt, Inhalt in SIM-26 überführt');
select test.ok((select count(*) from pcc.projects where id = test.pid('p2')) = 0, 'Das Projekt ist gelöscht');
select test.ok((select count(*) from public.audit_log
                where action = 'purge' and project_id = test.pid('p2')) = 1,
               'Die Löschung steht im Audit-Trail, mit Grund');
select test.logout();

-- -----------------------------------------------------------------------------
-- 10. Löschverlangen nach Artikel 17 DSGVO (Abschnitt 7b)
-- -----------------------------------------------------------------------------
select test.login('viewer');
select test.fails(format('select pcc.anonymise_user(%L, ''Antrag vom 01.09.2026'')', test.uid('pcon')),
                  'PCC_AUTH', 'Ein Löschverlangen führt nur der Teamzugang aus');
select test.logout();
select test.login('team');
select test.fails(format('select pcc.anonymise_user(%L, '''')', test.uid('pcon')),
                  'PCC_STATE', 'Ohne Grundlage keine Pseudonymisierung');
select pcc.anonymise_user(test.uid('pcon'), 'Antrag nach Artikel 17 DSGVO vom 01.09.2026');
select test.ok((select name like 'Ehemaliger Mitarbeiter%' and not active
                from public.users where id = test.uid('pcon')),
               'Die Person ist pseudonymisiert und stillgelegt');
select test.ok((select count(*) from pcc.tasks where assignee_user_id = test.uid('pcon')) >= 1,
               'Die fachliche Zuordnung bleibt über die ID bestehen');
select test.ok((select count(*) from public.audit_log
                where action = 'anonymise'
                  and entity_id = test.uid('pcon')::text) = 1,
               'Der Vorgang selbst bleibt nachvollziehbar');
select test.logout();

-- -----------------------------------------------------------------------------
-- 11. Sichten und Tageslauf
-- -----------------------------------------------------------------------------
select test.login('team');
select test.ok((select projects_total from pcc.v_dashboard) = 1, 'Das Dashboard zählt die sichtbaren Projekte');
select test.ok((select critical_risks from pcc.v_projects where id = test.pid('p1')) = 2,
               'Die Projektsicht weist die kritischen Risiken aus');
select test.ok((select count(*) from pcc.v_activity where project_id = test.pid('p1')) > 0,
               'Die Aktivität speist sich aus dem gemeinsamen Audit-Trail');
select test.logout();

select test.login('viewer');
select test.ok((select count(*) from pcc.v_activity where project_id = test.pid('p1')) > 0,
               'Die Aktivität eines Projekts ist für beide Zugänge sichtbar');
-- Mit zwei gemeinsam benutzten Zugängen wäre eine feinere Abstufung des Trails
-- nur Zierde: wer den Lesezugang hat, hat ihn für alles.
select test.ok((select count(*) from pcc.v_activity where entity = 'public.users') > 0,
               'Auch Einträge ohne Projektbezug liegen offen');
select test.logout();

select test.logout();
update pcc.tasks set due_date = current_date - 3, status = 'in_progress',
       assignee_user_id = test.uid('ppm2') where id = test.pid('t1');
select test.ok((select affected from pcc.run_daily_jobs() where job = 'tasks_overdue') >= 1,
               'Der Tageslauf meldet überfällige Aufgaben');
select test.ok((select count(*) from pcc.notifications
                where kind = 'overdue' and entity_id = test.pid('t1')) >= 1,
               'Zuständige und Projektleitung werden benachrichtigt');
select test.ok((select count(*) from pcc.run_daily_jobs()) = 3, 'Der Tageslauf hat drei Teile');

-- -----------------------------------------------------------------------------
-- 12. Vorlage ausrollen (Abschnitt 30)
-- -----------------------------------------------------------------------------
select test.login('team');
insert into test_ids (key, id)
select 'p3', (pcc.create_project('EBT-27', 'Evidence Based Training Einführung',
  test.uid('ppm2'), null, null, null, current_date, current_date + 200,
  (select id from pcc.templates where name = 'Simulator-Einführung'))).id;
select test.ok((select count(*) from pcc.workstreams where project_id = test.pid('p3')) = 3,
               'Die Vorlage legt drei Workstreams an');
select test.ok((select count(*) from pcc.tasks where project_id = test.pid('p3')) = 4,
               'Die Vorlage legt vier Aufgaben an');
select test.ok((select count(*) from pcc.milestones where project_id = test.pid('p3')) = 3,
               'Die Vorlage legt drei Meilensteine an');
select test.ok((select count(*) from pcc.tasks t join pcc.workstreams w on w.id = t.workstream_id
                where t.project_id = test.pid('p3')) = 4,
               'Die Aufgaben der Vorlage hängen an den richtigen Workstreams');
select test.logout();

-- -----------------------------------------------------------------------------
-- 13. Angriffe, die funktionieren müssten, wenn die Riegel fehlten
-- -----------------------------------------------------------------------------
select test.login('viewer');
select test.fails('select public.enable_internal_write()',
                  'permission denied', 'Den internen Schreibmodus legt niemand von außen um');
with u as (update public.users set role = 'team' where role = 'viewer' returning 1)
select test.ok((select count(*) from u) = 0, 'Der Lesezugang befördert sich nicht selbst');
select test.fails(format('select pcc.next_ref(%L, ''HACK'')', test.pid('p1')),
                  'permission denied', 'Referenznummern vergibt der Trigger, nicht der Nutzer');
with u as (update public.users set active = false where role = 'team' returning 1)
select test.ok((select count(*) from u) = 0, 'Der Lesezugang legt den Teamzugang nicht still');
select test.logout();

-- Auch der Teamzugang kommt an Rolle und Anmeldung nicht heran: sonst wäre aus
-- dem Lesezugang in zwei Zügen ein zweiter Vollzugang geworden.
select test.login('team');
select test.fails('update public.users set role = ''team'' where role = ''viewer''',
                  'PCC_AUTH', 'Auch der Teamzugang vergibt keine Rollen');
select test.fails('insert into public.users (name, email, role) values (''Dritter'', ''d@test.invalid'', ''team'')',
                  'PCC_AUTH', 'Über die Anwendung entsteht kein weiterer Zugang');
select test.fails(format('update public.users set auth_user_id = %L where role = ''viewer''',
                         '00000000-0000-0000-0000-000000000009'),
                  'PCC_AUTH', 'Die Anmeldung lässt sich nicht umhängen');
-- Personen darf der Teamzugang anlegen — das ist der Alltag.
insert into public.users (name, email, job_title) values ('Neue Kollegin', 'neu@test.invalid', 'Sales');
select test.ok((select count(*) from public.users where email = 'neu@test.invalid') = 1,
               'Personen pflegt der Teamzugang selbst');

-- Der Prüfstand eines Dokuments kommt von der Virenprüfung
select test.fails(format('update pcc.documents set scan_state = ''clean'' where id = %L', test.pid('d1')),
                  'PCC_GUARD', 'Ein Upload erklärt sich nicht selbst für geprüft');
select test.fails(format('update pcc.documents set project_id = %L where id = %L', test.pid('p3'), test.pid('d1')),
                  'PCC_IMMUTABLE', 'Ein Dokument wechselt nicht das Projekt');
-- Der Versionszähler gehört der Versionierung
select test.fails(format('update pcc.projects set version_minor = 0 where id = %L', test.pid('p1')),
                  'PCC_GUARD', 'Der Versionsstand lässt sich nicht zurücksetzen');
select test.fails(format('update pcc.projects set archived_at = now() where id = %L', test.pid('p1')),
                  'PCC_GUARD', 'Archivieren geht nur mit Grund über die Funktion');
select test.fails(format('update pcc.projects set key = ''XXX-99'' where id = %L', test.pid('p1')),
                  'PCC_IMMUTABLE', 'Der Projektschlüssel bleibt bestehen');
-- Eine Aufgabe ist nicht ihr eigenes Elternteil, und tiefer als eine Ebene geht es nicht
select test.fails(format('update pcc.tasks set parent_task_id = id where id = %L', test.pid('t1')),
                  'tasks_check', 'Eine Aufgabe ist nicht ihre eigene Teilaufgabe');
-- Optimistisches Sperren (Abschnitt 5)
select test.fails(format('update pcc.tasks set title = ''veraltet'', updated_at = %L where id = %L',
                         '2020-01-01 00:00:00+00', test.pid('t1')),
                  'PCC_CONFLICT', 'Ein überholter Stand überschreibt nichts still');
-- Herkunft bei gemeinsam benutztem Zugang: die Oberfläche darf den Menschen
-- benennen, aber nur einen aus dem Verzeichnis. Eine erfundene Kennung
-- verfängt nicht — sie fällt auf den angemeldeten Zugang zurück.
insert into pcc.issues (project_id, title, created_by)
values (test.pid('p1'), 'Von Christian gemeldet', test.uid('ppm2'));
select test.ok((select created_by from pcc.issues where title = 'Von Christian gemeldet') = test.uid('ppm2'),
               'Die benannte Person wird als Herkunft übernommen');
insert into pcc.issues (project_id, title, created_by)
values (test.pid('p1'), 'Erfundene Herkunft', '00000000-0000-0000-0000-000000000009');
select test.ok((select created_by from pcc.issues where title = 'Erfundene Herkunft') = test.uid('team'),
               'Eine erfundene Kennung fällt auf den angemeldeten Zugang zurück');
select test.ok((select actor_id from public.audit_log
                where entity = 'pcc.issues' and action = 'insert'
                order by id desc limit 1) = test.uid('team'),
               'Der Trail hält Zugang und benannte Person getrennt fest');
insert into pcc.issues (project_id, title, ref) values (test.pid('p1'), 'Frei gewählte Referenz', 'T-1');
select test.ok((select ref from pcc.issues where title = 'Frei gewählte Referenz') like 'I-%',
               'Die Referenznummer kommt aus dem Zähler');
select test.logout();

-- Rollenvergabe steht im Audit-Trail
select test.logout();
select test.ok((select count(*) from public.audit_log where entity = 'public.users') > 0,
               'Wer wem welche Rolle gegeben hat, steht im Trail');

-- -----------------------------------------------------------------------------
-- 14. Freigabe eines Stands, Abhängigkeiten, Schwärzung
-- -----------------------------------------------------------------------------
select test.login('viewer');
select test.fails(format('select pcc.release_version(%L, ''Stand zum Lenkungskreis'')', test.pid('p1')),
                  'PCC_AUTH', 'Einen Stand gibt nicht jeder frei');
select test.logout();

select test.login('team');
select test.fails(format('select pcc.release_version(%L, ''   '')', test.pid('p1')),
                  'PCC_STATE', 'Zu einer Freigabe gehört eine Zusammenfassung');
select test.ok(pcc.release_version(test.pid('p1'), 'Stand zum Lenkungskreis 09/2026') is not null,
               'Die Projektleitung gibt einen Stand frei');
select test.ok((select trigger_code from pcc.v_versions
                where project_id = test.pid('p1')
                order by version_major desc, version_minor desc limit 1) = 'pm_release',
               'Der freigegebene Stand ist die jüngste Version');
select test.ok((select count(*) from pcc.v_versions
                where project_id = test.pid('p1') and version_major = 1) >= 4,
               'Die Versionssicht zählt innerhalb der Hauptnummer');

-- Ein Meilenstein wartet nicht auf sich selbst
select test.fails(format('update pcc.milestones set depends_on_milestone_id = id where id = %L', test.pid('m1')),
                  'PCC_STATE', 'Eine Abhängigkeit schließt keinen Kreis');
-- Eine Verantwortung braucht einen Gegenstand im selben Projekt
select test.fails(format('insert into pcc.raci (project_id, subject_type, subject_id, user_id, letter)
                          values (%L, ''task'', %L, %L, ''C'')',
                         test.pid('p1'), test.pid('p3'), test.uid('ppm')),
                  'PCC_STATE', 'RACI verweist nicht ins Leere');
select test.logout();

-- Schwärzen nach Artikel 17: der Wortlaut geht, der Vorgang bleibt
select test.login('viewer');
select test.fails(format('select pcc.redact_audit(''pcc.comments'', %L, ''body'', ''Antrag'')', test.pid('c1')::text),
                  'PCC_AUTH', 'Schwärzen darf nur der Teamzugang');
select test.logout();
select test.login('team');
select test.ok(pcc.redact_audit('pcc.comments', test.pid('c1')::text, 'body',
                                'Antrag nach Artikel 17 DSGVO vom 03.09.2026') > 0,
               'Der Teamzugang schwärzt ein benanntes Feld');
select test.ok((select count(*) from public.audit_log
                where entity = 'pcc.comments' and entity_id = test.pid('c1')::text
                  and (new_value ->> 'body') = 'Der Termin ist knapp — bitte um Entscheidung bis Freitag.') = 0,
               'Der geschwärzte Wortlaut steht nirgends mehr im Trail');
select test.ok((select count(*) from public.audit_log
                where entity = 'pcc.comments' and entity_id = test.pid('c1')::text
                  and action = 'insert') = 1,
               'Der Vorgang selbst bleibt im Trail stehen');
select test.ok((select count(*) from public.audit_log
                where entity = 'pcc.comments' and action = 'redact') >= 1,
               'Die Schwärzung selbst ist protokolliert');
-- Zwei Riegel liegen übereinander: das fehlende Recht und der Trigger.
select test.fails('update public.audit_log set reason = ''nachtraeglich'' where id = (select min(id) from public.audit_log)',
                  'permission denied', 'Am Trail selbst ändert auch der Teamzugang nichts');
select test.fails('delete from public.audit_log where id = (select min(id) from public.audit_log)',
                  'permission denied', 'Und löschen lässt er sich erst recht nicht');
select test.logout();
-- Der Trigger ist der zweite Riegel: er hält selbst dann, wenn ein Zugang an
-- Rechteschutz und Policy vorbeikäme (hier geprüft mit den Rechten des Besitzers).
select test.fails('update public.audit_log set reason = ''nachtraeglich'' where id = (select min(id) from public.audit_log)',
                  'PCC_IMMUTABLE', 'Der Trigger hält den Trail auch ohne Rechteschutz fest');
select test.fails('delete from public.audit_log where id = (select min(id) from public.audit_log)',
                  'PCC_IMMUTABLE', 'Kein Eintrag verschwindet aus dem Trail');

-- -----------------------------------------------------------------------------
-- 15. Gantt je Projekt (Auftrag vom 19.09.2026)
-- -----------------------------------------------------------------------------
select test.login('team');
with ins as (
  insert into pcc.workstreams (project_id, name, owner_user_id, sort_order)
  values (test.pid('p1'), 'Abnahme', test.uid('ppm2'), 5)
  returning id)
insert into test_ids (key, id) select 'ws2', id from ins;

with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, start_date, due_date,
                         progress, status, assignee_user_id)
  values (test.pid('p1'), test.pid('ws2'), 'Abnahmeprotokoll zeichnen',
          current_date - 10, current_date + 20, 40, 'in_progress', test.uid('ppm'))
  returning id)
insert into test_ids (key, id) select 'gt1', id from ins;
insert into pcc.tasks (project_id, workstream_id, parent_task_id, title,
                       start_date, due_date, progress, status)
values (test.pid('p1'), test.pid('ws2'), test.pid('gt1'), 'Maengel nachverfolgen',
        current_date - 10, current_date + 20, 0, 'not_started');
insert into pcc.tasks (project_id, workstream_id, title, start_date, due_date, status)
values (test.pid('p1'), test.pid('ws2'), 'Uebergabe an den Betrieb',
        current_date + 20, current_date + 45, 'not_started');

-- Das Teilprojekt traegt keine eigenen Termine: sie kommen aus seinen Aufgaben.
select test.ok((select start_date from pcc.v_gantt
                where kind = 'workstream' and id = test.pid('ws2')) = current_date - 10,
               'Ein Teilprojekt beginnt mit seiner frühesten Aufgabe');
select test.ok((select due_date from pcc.v_gantt
                where kind = 'workstream' and id = test.pid('ws2')) = current_date + 45,
               'Und endet mit der spätesten');
select test.ok((select open_count from pcc.v_gantt
                where kind = 'workstream' and id = test.pid('ws2')) = 3,
               'Es zählt seine offenen Aufgaben');
-- Der Fortschritt mittelt die obersten Aufgaben, nicht die Teilaufgaben
select test.ok((select progress from pcc.v_gantt
                where kind = 'workstream' and id = test.pid('ws2')) = 20,
               'Der Fortschritt eines Teilprojekts mittelt seine obersten Aufgaben');
select test.ok((select depth from pcc.v_gantt where kind = 'task' and id = test.pid('gt1')) = 1,
               'Eine oberste Aufgabe steht auf Ebene 1');
select test.ok((select count(*) from pcc.v_gantt
                where kind = 'task' and parent_id = test.pid('gt1') and depth = 2) = 1,
               'Eine Teilaufgabe steht darunter auf Ebene 2');
-- Erledigtes zählt als 100 Prozent, unabhängig vom gepflegten Wert. Die
-- Aufgabe wird erst hier angelegt, damit sie den Mittelwert oben nicht stört.
with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, start_date, due_date,
                         progress, status)
  values (test.pid('p1'), test.pid('ws2'), 'Restpunkte abgehakt',
          current_date - 5, current_date, 0, 'completed')
  returning id)
insert into test_ids (key, id) select 'gt2', id from ins;
select test.ok((select progress from pcc.v_gantt
                where kind = 'task' and id = test.pid('gt2')) = 100,
               'Eine erledigte Aufgabe steht auf 100 Prozent, auch ohne gepflegten Wert');
select test.ok((select start_date is null and due_date is not null
                from pcc.v_gantt where kind = 'milestone' and id = test.pid('m1')),
               'Ein Meilenstein hat einen Termin, aber keinen Beginn');
select test.ok((select count(*) from pcc.v_gantt where project_id = test.pid('p1')
                  and kind = 'workstream') = (select count(*) from pcc.workstreams
                                               where project_id = test.pid('p1')),
               'Jedes Teilprojekt bekommt genau eine Zeile');
select test.logout();

select test.login('viewer');
select test.ok((select count(*) from pcc.v_gantt where project_id = test.pid('p1')) > 0,
               'Der Lesezugang sieht das Gantt');
select test.logout();

-- -----------------------------------------------------------------------------
-- 16. Abhaengigkeiten und kritischer Pfad (Auftrag vom 19.09.2026)
-- -----------------------------------------------------------------------------
select test.login('team');
-- Eine Kette: gt1 (heute-10 bis heute+20) -> gt3 -> gt4, alle im selben Teilprojekt
with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, start_date, due_date, status)
  values (test.pid('p1'), test.pid('ws2'), 'Schulung vorbereiten',
          current_date + 21, current_date + 35, 'not_started')
  returning id)
insert into test_ids (key, id) select 'gt3', id from ins;
with ins as (
  insert into pcc.tasks (project_id, workstream_id, title, start_date, due_date, status)
  values (test.pid('p1'), test.pid('ws2'), 'Schulung durchfuehren',
          current_date + 36, current_date + 50, 'not_started')
  returning id)
insert into test_ids (key, id) select 'gt4', id from ins;

insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
values (test.pid('p1'), test.pid('gt1'), test.pid('gt3')),
       (test.pid('p1'), test.pid('gt3'), test.pid('gt4'));
select test.ok((select count(*) from pcc.v_task_links where project_id = test.pid('p1')) = 2,
               'Zwei Abhängigkeiten stehen als Kanten da');

-- Eine Aufgabe wartet nicht auf sich selbst
select test.fails(format('insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
                          values (%L, %L, %L)', test.pid('p1'), test.pid('gt1'), test.pid('gt1')),
                  'PCC_STATE', 'Eine Aufgabe wartet nicht auf sich selbst');
-- Und der Kreis bleibt zu
select test.fails(format('insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
                          values (%L, %L, %L)', test.pid('p1'), test.pid('gt4'), test.pid('gt1')),
                  'PCC_STATE', 'Eine Abhängigkeit schließt keinen Kreis');
-- Auch nicht über zwei Ecken zurueck
select test.fails(format('insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
                          values (%L, %L, %L)', test.pid('p1'), test.pid('gt3'), test.pid('gt1')),
                  'PCC_STATE', 'Auch der kurze Kreis fällt auf');
-- Aufgaben aus fremden Projekten lassen sich nicht verbinden
select test.fails(format('insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
                          values (%L, %L, %L)', test.pid('p1'), test.pid('gt1'), test.pid('t3')),
                  'PCC_STATE', 'Abhängigkeiten bleiben im Projekt');

-- Der Widerspruch faellt auf: der Nachfolger beginnt, bevor der Vorgaenger endet
insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
values (test.pid('p1'), test.pid('gt3'), test.pid('gt2'));
select test.ok((select conflict from pcc.v_task_links
                where successor_id = test.pid('gt2')) = true,
               'Ein Nachfolger, der zu früh beginnt, wird als Widerspruch ausgewiesen');
select test.ok((select conflict_days from pcc.v_task_links
                where successor_id = test.pid('gt2')) > 0,
               'Und die Sicht sagt, um wie viele Tage');
select test.ok((select count(*) from pcc.v_task_links
                where project_id = test.pid('p1') and conflict) = 1,
               'Die übrigen Verbindungen sind widerspruchsfrei');

-- Der kritische Pfad: die Kette bis zum Projektende hat keinen Puffer
select test.ok((select count(*) from pcc.critical_path(test.pid('p1'))) > 0,
               'Die Terminrechnung liefert ein Ergebnis');
-- Solange die Kette vor dem Projektende ausläuft, hat sie Puffer — und jedes
-- frühere Glied nie weniger als das spätere.
select test.ok((select slack_days from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('gt4')) > 0,
               'Eine Kette, die vor dem Projektende endet, hat Puffer');
-- Reicht das letzte Glied bis zum Projektende, wird es kritisch.
update pcc.tasks
   set due_date = (select target_end_date from pcc.projects where id = test.pid('p1'))
 where id = test.pid('gt4');
select test.ok((select is_critical from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('gt4')) = true,
               'Was bis zum Projektende läuft, liegt auf dem kritischen Pfad');
select test.ok((select slack_days from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('gt3')) < 5,
               'Das Glied davor liegt dicht dahinter — nur die Lücke dazwischen ist Puffer');
select test.ok((select slack_days from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('gt1')) >= (select slack_days from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('gt3')),
               'Ein früheres Glied hat nie weniger Puffer als ein späteres');
-- Eine Aufgabe ohne Verbindung hängt allein am Projektende.
select test.ok((select slack_days from pcc.critical_path(test.pid('p1'))
                where task_id = test.pid('t1')) > 0,
               'Was mit nichts verbunden ist, hat den Puffer bis zum Projektende');
select test.logout();

select test.login('viewer');
select test.ok((select count(*) from pcc.v_task_links where project_id = test.pid('p1')) = 3,
               'Der Lesezugang sieht die Abhängigkeiten');
select test.fails(format('insert into pcc.task_dependencies (project_id, predecessor_id, successor_id)
                          values (%L, %L, %L)', test.pid('p1'), test.pid('gt1'), test.pid('gt4')),
                  'row-level security', 'Der Lesezugang verknüpft nichts');
select test.logout();

-- -----------------------------------------------------------------------------
-- 17. Wochenbericht, Suche und Kalender (Auftrag vom 19.09.2026)
-- -----------------------------------------------------------------------------
select test.login('team');
-- Was hat sich geaendert? Der Trail weiss es.
select test.ok((select count(*) from pcc.changes_since(now() - interval '1 hour')) > 0,
               'Der Bericht findet die Änderungen der letzten Stunde');
select test.ok((select count(*) from pcc.changes_since(now() + interval '1 hour')) = 0,
               'Und für die Zukunft nichts');
select test.ok((select count(*) from pcc.changes_since(now() - interval '1 hour', test.pid('p1')))
               <= (select count(*) from pcc.changes_since(now() - interval '1 hour')),
               'Auf ein Projekt eingegrenzt wird die Liste nicht länger');
select test.ok((select count(*) from pcc.changes_since(now() - interval '1 hour')
                where entity = 'pcc.tasks' and action = 'insert') > 0,
               'Neue Aufgaben stehen im Bericht');
-- Ein Statuswechsel wird als Weg von A nach B ausgewiesen
select test.ok((select count(*) from pcc.changes_since(now() - interval '1 hour')
                where detail like '%→%') > 0,
               'Ein Wechsel steht mit Vorher und Nachher da');

-- Suche
select test.ok((select count(*) from pcc.search('Qualification')) > 0,
               'Die Suche findet eine Aufgabe über ihren Titel');
select test.ok((select kind from pcc.search('SIM-26') limit 1) = 'project',
               'Ein Projektschlüssel führt zum Projekt');
select test.ok((select count(*) from pcc.search('a')) = 0,
               'Ein einzelner Buchstabe löst keine Suche aus');
select test.ok((select count(*) from pcc.search('Zusammenhangloses Kauderwelsch')) = 0,
               'Was es nicht gibt, wird nicht gefunden');
select test.ok((select count(*) from pcc.search('Abnahmeprotokoll')) > 0,
               'Auch Dokumente und Aufgaben mit gleichem Wortstamm kommen zurück');

-- Kalender
select test.ok(pcc.calendar(test.pid('p1')) like 'BEGIN:VCALENDAR%',
               'Der Kalender beginnt wie ein iCalendar');
select test.ok(pcc.calendar(test.pid('p1')) like '%END:VCALENDAR',
               'Und endet auch so');
select test.ok((select count(*) from regexp_matches(pcc.calendar(test.pid('p1')), 'BEGIN:VEVENT', 'g')) > 0,
               'Er enthält Termine');
-- Erledigtes gehoert nicht in den Kalender
select test.ok(pcc.calendar(test.pid('p1')) not like '%Simulator FAT%',
               'Ein erreichter Meilenstein steht nicht mehr im Kalender');
select test.logout();

select test.login('viewer');
select test.ok((select count(*) from pcc.search('Qualification')) > 0,
               'Der Lesezugang sucht mit');
select test.ok(pcc.calendar() like 'BEGIN:VCALENDAR%',
               'Und bekommt den Kalender über alle Projekte');
select test.logout();

-- Ohne Anmeldung gibt keine der drei Funktionen etwas heraus
select test.ok((select count(*) from pcc.search('Qualification')) = 0,
               'Ohne Anmeldung findet die Suche nichts');
select test.ok((select count(*) from pcc.changes_since(now() - interval '1 hour')) = 0,
               'Ohne Anmeldung gibt es keinen Bericht');
select test.ok(pcc.calendar() is null, 'Ohne Anmeldung keinen Kalender');

select test.ok(true, 'Alle Prüfungen des Control Centers bestanden');
rollback;
