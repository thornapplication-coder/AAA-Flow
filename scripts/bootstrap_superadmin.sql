-- Ersten Superadmin anlegen. Vorher den Auth-Nutzer im Supabase-Dashboard
-- (Authentication → Users → Add user) anlegen und die UUID hier eintragen.
-- Ausführen im SQL-Editor des Supabase-Dashboards (läuft als postgres).
do $$
declare
  v_id    uuid := '00000000-0000-0000-0000-000000000000';  -- UUID aus auth.users
  v_name  text := 'Vorname Nachname';
  v_email text := 'name@aviationacademy.at';
begin
  perform public.enable_internal_write();
  insert into public.users (id, name, email, department, role, language)
  values (v_id, v_name, v_email, 'training_admin', 'superadmin', 'de')
  on conflict (id) do update set role = 'superadmin', active = true;
  perform public.disable_internal_write();
end $$;
