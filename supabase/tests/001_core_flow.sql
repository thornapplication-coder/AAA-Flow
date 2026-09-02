-- =============================================================================
-- AAA Flow — SQL-Tests: Kernfluss, Sperrlogik, Rechte, Kommunikation
-- Läuft in einer Transaktion und rollt am Ende zurück. Ausführung über
-- scripts/db-check.sh als Superuser; Nutzerkontexte werden per JWT-Claim und
-- SET ROLE authenticated simuliert, RLS greift also wie im Betrieb.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
begin;

create schema test;
grant usage on schema test to authenticated;
create table test_users (key text primary key, id uuid not null default gen_random_uuid());
create table test_cases (key text primary key, id uuid not null);
grant select on test_users, test_cases to authenticated;
grant insert on test_cases to authenticated;

create function test.login(p_key text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from test_users where key = p_key;
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
create function test.cid(p_key text) returns uuid language sql stable as $$
  select id from test_cases where key = p_key;
$$;
create function test.cc(p_case text, p_code text) returns uuid language sql stable security definer as $$
  select cc.id from public.case_checkpoints cc join public.checkpoints cp on cp.id = cc.checkpoint_id
  where cc.case_id = test.cid(p_case) and cp.code = p_code;
$$;
create function test.cp(p_code text) returns uuid language sql stable security definer as $$
  select id from public.checkpoints where code = p_code;
$$;

-- -----------------------------------------------------------------------------
-- Setup (Superuser, interner Schreibmodus)
-- -----------------------------------------------------------------------------
grant execute on all functions in schema test to authenticated;

insert into test_users (key) values ('sa'), ('dt'), ('sales1'), ('sales2'), ('sales_tl'), ('ta1'), ('ta2'), ('ta_tl'), ('ato1'), ('hot');

select public.enable_internal_write();
insert into auth.users (id, email) select id, key || '@test.invalid' from test_users;
insert into public.users (id, name, email, department, role)
select id, key, key || '@test.invalid',
  case when key like 'sales%' then 'sales' when key in ('ta1','ta2','ta_tl','dt','sa') then 'training_admin' else 'ato' end::public.department,
  case key when 'sa' then 'superadmin' when 'dt' then 'admin'
           when 'sales_tl' then 'teamleader' when 'ta_tl' then 'teamleader' when 'hot' then 'teamleader'
           else 'staff' end::public.user_role
from test_users;

insert into public.type_assignments (user_id, aircraft_type_id, department)
select test.uid('sales1'), id, 'sales' from public.aircraft_types where code = 'C525';
insert into public.type_assignments (user_id, aircraft_type_id, department)
select test.uid('sales2'), id, 'sales' from public.aircraft_types where code = 'XLS';
insert into public.type_assignments (user_id, aircraft_type_id, department)
select test.uid('ato1'), id, 'ato' from public.aircraft_types where code = 'C525';

update public.settings set value = jsonb_build_object(
  'director_training', test.uid('dt'), 'head_of_training', test.uid('hot'), 'sales_lead', null)
 where key = 'function_holders';
select public.disable_internal_write();

select test.ok((select count(*) from public.aircraft_types) = 7, 'Seed: 7 Muster');
select test.ok((select count(*) from public.checkpoints where active) = 27, 'Seed: 27 Prüfpunkte im Katalog');
select test.ok(public.add_business_days('2026-09-04', 1) = '2026-09-07', 'Arbeitstage: Freitag + 1 = Montag');
select test.ok(public.add_business_days('2026-09-07', -1) = '2026-09-04', 'Arbeitstage: Montag - 1 = Freitag');
select test.ok(public.business_days_between('2026-09-04', '2026-09-08') = 2, 'Arbeitstage zwischen Fr und Di = 2');

-- -----------------------------------------------------------------------------
-- 1. Sales legt Vorgang an → Gates, Prüfpunkte, Zuständigkeiten
-- -----------------------------------------------------------------------------
select test.login('sales1');
insert into public.companies (name) values ('GHD Aviation');
insert into public.trainees (name, date_of_birth, company_id)
  values ('Max Mustermann', '1985-04-12', (select id from public.companies where name = 'GHD Aviation')),
         ('Erika Musterfrau', '1990-01-30', (select id from public.companies where name = 'GHD Aviation')),
         ('Hans Huber', '1978-11-02', (select id from public.companies where name = 'GHD Aviation'));

insert into test_cases select 'c1', public.create_case(
  (select id from public.trainees where name = 'Max Mustermann'),
  (select id from public.companies where name = 'GHD Aviation'),
  (select id from public.aircraft_types where code = 'C525'),
  'Type Rating', current_date, public.add_business_days(current_date, 40), public.add_business_days(current_date, 50));

select test.ok((select case_number from public.cases where id = test.cid('c1')) ~ '^AF-\d{4}-\d{4}$', 'Vorgangsnummer AF-JJJJ-NNNN');
select test.ok((select count(*) from public.gates where case_id = test.cid('c1')) = 3, 'Drei Gates angelegt');
select test.ok((select count(*) from public.case_checkpoints where case_id = test.cid('c1')) = 27, 'Alle aktiven Prüfpunkte instanziiert');
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c1') and department = 'sales') = test.uid('sales1'), 'Sales: Anleger ist zuständig');
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c1') and department = 'training_admin') is null, 'Training Admin: liegt im Pool');
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c1') and department = 'ato') = test.uid('ato1'), 'ATO: Course Supervisor automatisch zuständig');
select test.ok((select due_at from public.case_checkpoints cc join public.checkpoints cp on cp.id = cc.checkpoint_id
                 where cc.case_id = test.cid('c1') and cp.code = 'g1_licence') = public.add_business_days(public.add_business_days(current_date, 40), -15),
               'Frist: 15 Arbeitstage vor Kursbeginn');
select test.ok((select due_at from public.case_checkpoints cc join public.checkpoints cp on cp.id = cc.checkpoint_id
                 where cc.case_id = test.cid('c1') and cp.code = 'g1_offer_sent') = public.add_business_days(current_date, 3),
               'Sales-eigene Frist hängt am Anfragedatum');

-- Zweiter und dritter Vorgang, gleiches Muster und Kursdatum (Übernahmefunktion)
insert into test_cases select 'c2', public.create_case(
  (select id from public.trainees where name = 'Erika Musterfrau'),
  (select id from public.companies where name = 'GHD Aviation'),
  (select id from public.aircraft_types where code = 'C525'),
  'Type Rating', current_date, public.add_business_days(current_date, 40), public.add_business_days(current_date, 50));
insert into test_cases select 'c3', public.create_case(
  (select id from public.trainees where name = 'Hans Huber'),
  (select id from public.companies where name = 'GHD Aviation'),
  (select id from public.aircraft_types where code = 'C525'),
  'Type Rating', current_date, public.add_business_days(current_date, 40), public.add_business_days(current_date, 50));

-- Sales legt nur Vorgänge zugeordneter Muster an
select test.fails(format('select public.create_case(%L, %L, %L, ''Recurrent'')',
  (select id from public.trainees where name = 'Hans Huber'), (select id from public.companies where name = 'GHD Aviation'),
  (select id from public.aircraft_types where code = 'PHENOM')), 'AAA_FLOW_AUTH', 'Sales legt keinen Vorgang für fremdes Muster an');
-- Muster ohne Course Supervisor → Head of Training (Fallback); Anlage durch Sales-Teamleitung
select test.login('sales_tl');
insert into test_cases select 'c4', public.create_case(
  (select id from public.trainees where name = 'Hans Huber'),
  (select id from public.companies where name = 'GHD Aviation'),
  (select id from public.aircraft_types where code = 'PHENOM'), 'Recurrent');
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c4') and department = 'ato') = test.uid('hot'), 'ATO-Fallback: Head of Training');
select test.ok((select count(*) from public.case_checkpoints where case_id = test.cid('c4') and due_at is not null) = 1, 'Ohne Kursdatum laufen keine Gate-Fristen (nur Sales-Frist)');
select test.login('sales1');

-- -----------------------------------------------------------------------------
-- 2. Sichtbarkeit (Spec 9)
-- -----------------------------------------------------------------------------
select test.ok((select count(*) from public.v_cases where id = test.cid('c1')) = 1, 'sales1 sieht eigenes Muster');
select test.ok((select count(*) from public.v_cases where id = test.cid('c4')) = 0, 'sales1 sieht fremdes Muster nicht');
select test.login('sales2');
select test.ok((select count(*) from public.v_cases where id = test.cid('c1')) = 0, 'sales2 (XLS) sieht C525-Vorgang nicht');
select test.ok((select count(*) from public.v_pool) = 0, 'sales2 sieht C525-Vorgang auch nicht im Pool');
select test.login('sales_tl');
select test.ok((select count(*) from public.v_cases) = 4, 'Sales-Teamleitung sieht alle Vorgänge');
select test.login('ta1');
select test.ok((select count(*) from public.v_cases) = 4, 'Training Admin sieht alle Vorgänge');
select test.ok((select count(*) from public.v_pool where department = 'training_admin') = 4, 'Training-Admin-Pool zeigt 4 Vorgänge');
select test.login('ato1');
select test.ok((select count(*) from public.v_cases) = 4, 'ATO sieht alle Vorgänge');

-- -----------------------------------------------------------------------------
-- 3. Guards: Status und Gate-Tabellen nur über Funktionen
-- -----------------------------------------------------------------------------
select test.login('sales1');
select test.fails(format('update public.cases set status = ''booked'' where id = %L', test.cid('c1')), 'AAA_FLOW_GUARD', 'Direkter Statuswechsel abgelehnt');
update public.gates set status = 'released' where case_id = test.cid('c1') and gate_no = 1;
select test.ok((select status from public.gates where case_id = test.cid('c1') and gate_no = 1) = 'open', 'Direkte Gate-Änderung wirkungslos (keine Schreib-Policy)');
update public.case_checkpoints set status = 'verified' where case_id = test.cid('c1');
select test.ok((select count(*) from public.case_checkpoints where case_id = test.cid('c1') and status = 'verified') = 0, 'Direkte Prüfpunkt-Änderung wirkungslos (keine Schreib-Policy)');
select test.logout();
select test.fails(format('update public.gates set status = ''released'' where case_id = %L and gate_no = 1', test.cid('c1')), 'AAA_FLOW_GUARD', 'Direkte Gate-Änderung auch für Superuser abgelehnt');
select test.fails(format('update public.case_checkpoints set status = ''verified'' where case_id = %L', test.cid('c1')), 'AAA_FLOW_GUARD', 'Direkte Prüfpunkt-Änderung auch für Superuser abgelehnt');
select test.login('sales1');
select test.fails(format('update public.users set role = ''admin'' where id = %L', test.uid('sales1')), 'AAA_FLOW_GUARD', 'Eigene Rolle nicht änderbar');
update public.users set language = 'en' where id = test.uid('sales1');
select test.ok((select language from public.users where id = test.uid('sales1')) = 'en', 'Eigene Sprache änderbar');
select test.fails('insert into public.users (id, name, email, department) values (gen_random_uuid(), ''x'', ''x@x'', ''sales'')', 'Superadmin', 'Nutzeranlage nur durch Superadmin');

-- -----------------------------------------------------------------------------
-- 4. Prüfpunkte: Zuständigkeit, Vier-Augen-Prinzip (Spec 9, 10)
-- -----------------------------------------------------------------------------
select test.login('ta1');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g1_customer_order')), 'AAA_FLOW_AUTH', 'Sichtbarkeit ist nicht Berechtigung: TA darf Sales-Prüfpunkt nicht abhaken');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g2_course_date')), 'AAA_FLOW_AUTH', 'TA ohne Übernahme nicht zuständig');

select test.login('sales1');
select public.complete_checkpoint(test.cc('c1', 'g1_customer_order'), 'Auftrag 4711');
select test.ok((select status from public.case_checkpoints where id = test.cc('c1', 'g1_customer_order')) = 'verified', 'Prüfpunkt ohne Vier-Augen sofort erledigt');
select test.ok((select status from public.gates where case_id = test.cid('c1') and gate_no = 1) = 'in_progress', 'Gate 1 in Arbeit');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g1_customer_order')), 'bereits erledigt', 'Doppeltes Erledigen abgelehnt');

select public.complete_checkpoint(test.cc('c1', 'g1_licence'));
select test.ok((select status from public.case_checkpoints where id = test.cc('c1', 'g1_licence')) = 'completed', 'Vier-Augen-Prüfpunkt wartet auf Kontrolle');
select test.fails(format('select public.verify_checkpoint(%L)', test.cc('c1', 'g1_licence')), 'AAA_FLOW_FOUR_EYES', 'Vier-Augen: Bearbeiter darf nicht kontrollieren');
select test.login('ta1');
select test.fails(format('select public.verify_checkpoint(%L)', test.cc('c1', 'g1_licence')), 'AAA_FLOW_AUTH', 'Kontrolle nur durch die Abteilung des Prüfpunkts');
select test.login('sales_tl');
select public.verify_checkpoint(test.cc('c1', 'g1_licence'));
select test.ok((select status from public.case_checkpoints where id = test.cc('c1', 'g1_licence')) = 'verified', 'Kontrolle durch zweite Person erledigt');
select test.ok((select verified_by from public.case_checkpoints where id = test.cc('c1', 'g1_licence')) = test.uid('sales_tl'), 'verified_by gesetzt');

-- -----------------------------------------------------------------------------
-- 5. Pool-Übernahme und Gate-Sperre (Spec 7, 8)
-- -----------------------------------------------------------------------------
select test.login('ta1');
select public.claim_case(test.cid('c1'));
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c1') and department = 'training_admin') = test.uid('ta1'), 'Pull aus dem Pool');
select test.login('ta2');
select test.fails(format('select public.claim_case(%L)', test.cid('c1')), 'bereits übernommen', 'Doppelte Übernahme abgelehnt');
select test.login('ta1');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g2_course_date')), 'AAA_FLOW_GATE', 'Gate-2-Prüfpunkt gesperrt, solange Gate 1 offen');
select test.fails(format('select public.release_gate(%L, 1)', test.cid('c1')), 'Pflichtpunkt', 'Gate 1 nicht freigebbar mit offenen Pflichtpunkten');

select test.login('sales1');
select public.complete_checkpoint(test.cc('c1', 'g1_trainee_data'));
select public.complete_checkpoint(test.cc('c1', 'g1_medical'));
select public.complete_checkpoint(test.cc('c1', 'g1_language'));
select public.complete_checkpoint(test.cc('c1', 'g1_prerequisites'));
select public.complete_checkpoint(test.cc('c1', 'g1_course_defined'));
select public.complete_checkpoint(test.cc('c1', 'g1_billing'));
select test.login('sales_tl');
select public.verify_checkpoint(test.cc('c1', 'g1_medical'));
select public.verify_checkpoint(test.cc('c1', 'g1_prerequisites'));
select test.ok((select count(*) from public.open_mandatory_checkpoints(test.cid('c1'), 1)) = 0, 'Alle Pflichtpunkte Gate 1 erledigt');

select test.login('sales1');
select test.fails(format('select public.release_gate(%L, 1)', test.cid('c1')), 'AAA_FLOW_AUTH', 'Gate 1 gibt nur Training Admin frei (Empfänger)');
select test.login('ta1');
select public.release_gate(test.cid('c1'), 1);
select test.ok((select status from public.cases where id = test.cid('c1')) = 'booked', 'Gate 1 → Status Gebucht');
select test.ok((select status from public.gates where case_id = test.cid('c1') and gate_no = 1) = 'released', 'Gate 1 freigegeben');
select test.logout();
select test.ok((select count(*) from public.notifications where case_id = test.cid('c1') and type = 'gate_released') = 2, 'Zuständige (Sales, ATO) benachrichtigt');
select test.login('ta1');
select test.fails(format('select public.release_gate(%L, 1)', test.cid('c1')), 'bereits freigegeben', 'Gate nicht doppelt freigebbar');
select test.fails(format('select public.release_gate(%L, 3)', test.cid('c1')), 'AAA_FLOW_GATE', 'Gate 3 nicht vor Gate 2');

-- Zurücksetzen: nur mit Begründung, nicht nach Gate-Freigabe (Spec 13)
select test.login('sales1');
select test.fails(format('select public.reset_checkpoint(%L, ''Lizenz abgelaufen'')', test.cc('c1', 'g1_licence')), 'bereits freigegeben', 'Kein Zurücksetzen nach Gate-Freigabe');
select test.login('ta1');
select public.complete_checkpoint(test.cc('c1', 'g2_course_date'));
select test.fails(format('select public.reset_checkpoint(%L, '''')', test.cc('c1', 'g2_course_date')), 'Begründung', 'Zurücksetzen ohne Begründung abgelehnt');
select public.reset_checkpoint(test.cc('c1', 'g2_course_date'), 'Kunde hat Termin verschoben');
select test.ok((select status from public.case_checkpoints where id = test.cc('c1', 'g2_course_date')) = 'open', 'Prüfpunkt zurückgesetzt');
select test.ok(exists (select 1 from public.audit_log where entity = 'case_checkpoints' and entity_id = test.cc('c1', 'g2_course_date')::text and reason = 'Kunde hat Termin verschoben'), 'Audit-Eintrag mit Begründung');
select public.complete_checkpoint(test.cc('c1', 'g2_course_date'));

-- -----------------------------------------------------------------------------
-- 6. Ausnahmen (Spec 12)
-- -----------------------------------------------------------------------------
select test.fails(format('select public.request_exception(%L, %L, ''kurz'')', test.cid('c1'), test.cp('g2_fstd_slot')), 'check constraint', 'Ausnahme braucht aussagekräftigen Grund');
select public.request_exception(test.cid('c1'), test.cp('g2_fstd_slot'), 'Kurzfristbuchung, Slot wird erst am Vortag bestätigt');
select test.fails(format('select public.request_exception(%L, %L, ''Kurzfristbuchung, zweiter Antrag'')', test.cid('c1'), test.cp('g2_fstd_slot')), 'bereits ein offener Antrag', 'Nur ein offener Antrag je Prüfpunkt');
select test.fails(format('select public.decide_exception(id, true) from public.exceptions where case_id = %L', test.cid('c1')), 'AAA_FLOW_AUTH', 'Ausnahme gibt nicht der Antragsteller frei');
select test.login('ta_tl');
select test.fails(format('select public.decide_exception(id, true) from public.exceptions where case_id = %L', test.cid('c1')), 'AAA_FLOW_AUTH', 'Auch Teamleader gibt keine Ausnahme frei');
select test.logout();
select test.ok((select count(*) from public.notifications where user_id in (test.uid('dt'), test.uid('hot')) and type = 'exception_requested') = 2, 'Director Training und Head of Training informiert');
select test.login('ta1');
select test.ok((select count(*) from public.notifications where type = 'exception_requested') = 0, 'Fremde Benachrichtigungen unsichtbar');
select test.login('hot');
select public.decide_exception(id, true, 'Genehmigt, Slot am Vortag prüfen') from public.exceptions where case_id = test.cid('c1');
select test.ok((select status from public.exceptions where case_id = test.cid('c1')) = 'approved', 'Ausnahme freigegeben');
select test.ok(public.checkpoint_is_done(test.cid('c1'), test.cp('g2_fstd_slot')), 'Freigestellter Prüfpunkt gilt als erledigt');
select test.ok((select approved from public.v_exception_stats where checkpoint_code = 'g2_fstd_slot') = 1, 'Ausnahme in Auswertung nach Prüfpunkt');

-- Gate 2 fertigstellen
select test.login('ato1');
select public.complete_checkpoint(test.cc('c1', 'g2_instructor'));
select public.complete_checkpoint(test.cc('c1', 'g2_ground_school'));
select test.login('hot');
select public.verify_checkpoint(test.cc('c1', 'g2_instructor'));
select test.login('ta1');
select public.complete_checkpoint(test.cc('c1', 'g2_training_docs'));
select public.complete_checkpoint(test.cc('c1', 'g2_forms'));
select public.complete_checkpoint(test.cc('c1', 'g2_course_file'));
select public.complete_checkpoint(test.cc('c1', 'g2_joining_instr'));
select test.login('ta2');
select public.verify_checkpoint(test.cc('c1', 'g2_training_docs'));
select test.login('ta1');
select test.fails(format('select public.release_gate(%L, 2)', test.cid('c1')), 'AAA_FLOW_AUTH', 'Gate 2 gibt nur ATO frei');
select test.login('ato1');
select public.release_gate(test.cid('c1'), 2);
select test.ok((select status from public.cases where id = test.cid('c1')) = 'released', 'Gate 2 → Status Freigegeben');

-- -----------------------------------------------------------------------------
-- 7. Gate 3 und Gate-3-Sperre (Spec 7, offener Punkt 1)
-- -----------------------------------------------------------------------------
select test.login('ta1');
select test.fails(format('select public.release_gate(%L, 3)', test.cid('c1')), 'nach Kursende', 'Gate 3 nicht vor Kursende');
-- Kurs in die Vergangenheit legen (Teamleader darf Stammfelder ändern)
select test.login('ta_tl');
update public.cases set course_start = current_date - 10, course_end = current_date - 3 where id = test.cid('c1');
select test.ok((select due_at from public.case_checkpoints where id = test.cc('c1', 'g3_attendance')) = public.add_business_days(current_date - 3, 3), 'Gate-3-Fristen hängen am Kursende');
select test.login('ta1');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g3_certificate')), 'gesperrt', 'Gate-3-Sperre: kein Zertifikat, solange Pflicht-Records fehlen');
select test.login('ato1');
select public.complete_checkpoint(test.cc('c1', 'g3_attendance'));
select public.complete_checkpoint(test.cc('c1', 'g3_grading_sheets'));
select public.complete_checkpoint(test.cc('c1', 'g3_deferred_items'));
select public.complete_checkpoint(test.cc('c1', 'g3_exam_result'));
select test.login('hot');
select public.verify_checkpoint(test.cc('c1', 'g3_grading_sheets'));
select public.verify_checkpoint(test.cc('c1', 'g3_exam_result'));
select test.login('ta1');
select test.fails(format('select public.complete_checkpoint(%L)', test.cc('c1', 'g3_certificate')), 'gesperrt', 'Gate-3-Sperre greift auch bei nur einem offenen Record');
select public.complete_checkpoint(test.cc('c1', 'g3_records_filed'));
select test.login('ta2');
select public.verify_checkpoint(test.cc('c1', 'g3_records_filed'));
select test.login('ta1');
select public.complete_checkpoint(test.cc('c1', 'g3_certificate'));
select test.ok((select status from public.case_checkpoints where id = test.cc('c1', 'g3_certificate')) = 'verified', 'Zertifikat nach vollständigen Records ausstellbar');
select public.release_gate(test.cid('c1'), 3);
select test.ok((select status from public.cases where id = test.cid('c1')) = 'completed', 'Gate 3 → Status Abgeschlossen');
select test.fails(format('update public.cases set instructor = ''x'' where id = %L', test.cid('c1')), 'schreibgeschützt', 'Abgeschlossener Vorgang schreibgeschützt');
select test.ok((select days_to_gate1 from public.v_gate_lead_times where case_id = test.cid('c1')) = 0, 'Gate-Durchlaufzeit berechnet');

-- -----------------------------------------------------------------------------
-- 8. Übernahmefunktion und Verwerfen (Spec 5, 6)
-- -----------------------------------------------------------------------------
select test.login('ta_tl');
update public.cases set instructor = 'Capt. Beispiel', fstd_slot = 'FFS-2 08:00' where id = test.cid('c2');
select test.ok(public.copy_course_fields(test.cid('c2')) = 1, 'Übernahme auf Vorgänge mit gleichem Muster und Kursdatum (c3, nicht c1)');
select test.ok((select instructor from public.cases where id = test.cid('c3')) = 'Capt. Beispiel', 'Instruktor auf c3 übernommen');
select test.login('sales1');
select test.fails(format('select public.discard_case(%L, '''')', test.cid('c3')), 'Begründung', 'Verwerfen ohne Grund abgelehnt');
select public.discard_case(test.cid('c3'), 'Kunde hat storniert');
select test.ok((select status from public.cases where id = test.cid('c3')) = 'discarded', 'Vorgang verworfen');
select test.ok((select closed_reason from public.cases where id = test.cid('c3')) = 'Kunde hat storniert', 'Grund dokumentiert');
select test.fails(format('select public.claim_case(%L)', test.cid('c4')), 'nicht sichtbar', 'Sales kann fremdes Muster nicht übernehmen');

-- -----------------------------------------------------------------------------
-- 9. Kommunikation (Spec 5a)
-- -----------------------------------------------------------------------------
select test.login('sales1');
insert into public.messages (scope, scope_id, user_id, body) values ('case', test.cid('c2'), test.uid('sales1'), 'Sollen wir das Training planen, es fehlen noch Dokumente');
insert into public.messages (scope, scope_id, user_id, body, checkpoint_id) values ('case', test.cid('c2'), test.uid('sales1'), 'Medical läuft vor Kursende ab', test.cp('g1_medical'));
insert into public.messages (scope, scope_id, user_id, body) values ('company', (select company_id from public.cases where id = test.cid('c2')), test.uid('sales1'), 'Trainee ABX von Firma GHD hat noch nicht bezahlt');
select test.login('ta1');
select test.ok((select count(*) from public.messages where scope = 'case' and scope_id = test.cid('c2')) = 2, 'TA sieht Vorgangs-Thread');
select test.ok((select unread from public.v_unread_threads where scope = 'case' and scope_id = test.cid('c2')) = 2, 'Ungelesen-Zähler = 2');
select public.mark_thread_read('case', test.cid('c2'));
select test.ok((select count(*) from public.v_unread_threads where scope = 'case' and scope_id = test.cid('c2')) = 0, 'Nach Lesen keine ungelesenen Nachrichten');
insert into public.messages (scope, scope_id, user_id, body) values ('case', test.cid('c2'), test.uid('ta1'), 'Bitte Lizenzkopie nachreichen');
delete from public.messages where scope_id = test.cid('c2');
select test.ok((select count(*) from public.messages where scope = 'case' and scope_id = test.cid('c2')) = 3, 'Löschen über RLS wirkungslos');
update public.messages set body = 'geändert' where user_id = test.uid('sales1');
select test.ok((select count(*) from public.message_edits) = 0, 'Fremde Nachricht nicht bearbeitbar');
select test.login('sales2');
select test.ok((select count(*) from public.messages) = 0, 'sales2 sieht weder Vorgangs- noch Firmen-Thread ohne sichtbaren Vorgang');
select test.fails(format('insert into public.messages (scope, scope_id, user_id, body) values (''case'', %L, %L, ''x'')', test.cid('c2'), test.uid('sales2')), 'AAA_FLOW_AUTH', 'Schreiben in unsichtbaren Thread abgelehnt');
select test.login('sales_tl');
select test.ok((select count(*) from public.messages where scope = 'company') = 1, 'Teamleitung sieht Firmen-Thread');
select test.login('sales1');
update public.messages set body = 'Sollen wir das Training planen? Es fehlen noch Dokumente.' where body = 'Sollen wir das Training planen, es fehlen noch Dokumente';
select test.ok((select count(*) from public.message_edits) = 1, 'Bearbeitung erzeugt Historie');
select test.ok((select edited_at is not null from public.messages where body like 'Sollen wir das Training planen?%'), 'Vermerk „bearbeitet"');
select public.post_message('case', test.cid('c2'), '@ta1 bitte übernehmen', null, array[test.uid('ta1')]);
select test.logout();
select test.ok((select count(*) from public.notifications where user_id = test.uid('ta1') and type = 'mention') = 1, 'Erwähnung benachrichtigt');
select test.login('sales1');
select public.post_message('case', test.cid('c2'), '@ato bitte Instruktor prüfen', test.cp('g2_instructor'), '{}', array['ato']::public.department[]);
select test.ok((select count(*) from public.message_mentions) = 2, 'Erwähnungen gespeichert');
select test.logout();
select test.ok((select count(*) from public.notifications where type = 'mention' and user_id in (select id from public.users where department = 'ato')) = 2, 'Abteilungs-Erwähnung benachrichtigt alle ATO-Nutzer');
select test.fails('delete from public.messages', 'AAA_FLOW_IMMUTABLE', 'Nachrichten auch für Superuser unlöschbar');
select test.fails('update public.audit_log set action = ''x''', 'AAA_FLOW_IMMUTABLE', 'Audit-Trail unveränderlich');
select test.fails('delete from public.audit_log', 'AAA_FLOW_IMMUTABLE', 'Audit-Trail unlöschbar');

-- -----------------------------------------------------------------------------
-- 10. Audit-Sichtbarkeit und Vertretung (Spec 8, 13)
-- -----------------------------------------------------------------------------
select test.login('sales2');
select test.ok((select count(*) from public.audit_log where case_id = test.cid('c1')) = 0, 'Audit nur für sichtbare Vorgänge');
select test.login('sales1');
select test.ok((select count(*) from public.audit_log where case_id = test.cid('c1')) > 10, 'Audit-Trail je Vorgang einsehbar');
select test.logout();
insert into public.deputies (user_id, deputy_user_id, valid_from, valid_to) values (test.uid('sales1'), test.uid('sales2'), current_date, current_date + 7);
select test.login('sales2');
select test.ok((select count(*) from public.v_cases where id = test.cid('c2')) = 1, 'Vertretung sieht Vorgänge des Vertretenen');
select public.complete_checkpoint(test.cc('c2', 'g1_special_needs'));
select test.ok((select completed_by from public.case_checkpoints where id = test.cc('c2', 'g1_special_needs')) = test.uid('sales2'), 'Vertretung darf Prüfpunkte des Vertretenen erledigen');

-- -----------------------------------------------------------------------------
-- 11. Liegenbleiber-Regel, Erinnerungen, Eskalation (Spec 8, 11)
-- -----------------------------------------------------------------------------
select test.logout();
select public.enable_internal_write();
update public.case_assignments set pool_since = now() - interval '7 days' where case_id = test.cid('c2') and department = 'training_admin';
select public.disable_internal_write();
select test.ok(public.escalate_stale_pool() = 1, 'Liegenbleiber erkannt');
select test.ok((select count(*) from public.notifications where user_id = test.uid('ta_tl') and type = 'pool_stale') = 1, 'Teamleader zur Zuweisung informiert');
select test.ok(public.escalate_stale_pool() = 0, 'Keine doppelte Liegenbleiber-Meldung');
select test.login('ta_tl');
select test.ok((select is_stale from public.v_pool where case_id = test.cid('c2') and department = 'training_admin'), 'Pool zeigt Liegenbleiber');
select public.assign_case(test.cid('c2'), 'training_admin', test.uid('ta2'));
select test.ok((select user_id from public.case_assignments where case_id = test.cid('c2') and department = 'training_admin') = test.uid('ta2'), 'Teamleader weist zu');
select test.fails(format('select public.assign_case(%L, ''training_admin'', %L)', test.cid('c2'), test.uid('ato1')), 'nicht in Abteilung', 'Zuweisung nur innerhalb der Abteilung');

select test.logout();
-- c2 als "gebucht" simulieren: Gate-2-Fristen (10 AT) fallen auf heute + 3 AT, Gate-1-Fristen (15 AT) sind überschritten
select public.enable_internal_write();
update public.cases set status = 'booked', course_start = public.add_business_days(current_date, 13) where id = test.cid('c2');
select public.disable_internal_write();
select test.ok(public.generate_reminders() > 0, 'Erinnerungen und Eskalationen erzeugt');
select test.ok((select count(*) from public.notifications where type = 'reminder' and case_id = test.cid('c2') and user_id = test.uid('ta2')) = 2, 'Erinnerung 3 AT vorher an den Zuständigen (2 Prüfpunkte)');
select test.ok((select count(*) from public.notifications where type = 'escalation' and case_id = test.cid('c2') and user_id = test.uid('sales_tl')) = 8, 'Überfällige Gate-1-Pflichtpunkte (8) eskaliert an Sales-Teamleitung');
select test.ok(public.generate_reminders() = 0, 'Keine doppelten Erinnerungen am selben Tag');
select public.enable_internal_write();
update public.notifications set created_at = created_at - interval '5 days' where type = 'escalation';
select public.disable_internal_write();
select test.ok(public.generate_reminders() = 8, 'Stufe 2 nach Frist ohne Reaktion');
select test.ok((select count(*) from public.notifications where type = 'escalation_level2' and user_id = test.uid('dt')) = 8, 'Director Training im Dashboard informiert');
select test.ok((select count(*) from public.notifications where type = 'escalation_level2' and user_id = test.uid('hot')) = 8, 'Head of Training im Dashboard informiert');
select test.login('ta2');
select test.fails('update public.notifications set email_status = ''sent''', 'AAA_FLOW_GUARD', 'Benachrichtigung: nur read_at änderbar');
select test.ok(public.mark_notifications_read(array(select id from public.notifications where user_id = test.uid('ta2'))) = 3, 'Eigene Benachrichtigungen als gelesen markiert (2 Erinnerungen, 1 Zuweisung)');
select test.ok((select display_state from public.v_cases where id = test.cid('c2')) = 'overdue', 'Überfällig dominiert Vorgangsstatus');
select test.ok((select gate1_state from public.v_cases where id = test.cid('c2')) = 'overdue', 'Gate 1 überfällig');
select test.ok((select overdue_cases from public.v_pipeline) = 1, 'Dashboard zählt überfällige Vorgänge');
select test.ok((select completed from public.v_pipeline) = 1, 'Dashboard zählt Abschlüsse');
select test.ok((select gate3_warnings from public.v_pipeline) = 0, 'Keine Gate-3-Warnung bei vollständigen Records');

select test.logout();
select test.ok(public.run_daily_jobs() is not null, 'Tagesjob läuft');
rollback;
