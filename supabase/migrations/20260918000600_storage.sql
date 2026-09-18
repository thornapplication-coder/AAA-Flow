-- =============================================================================
-- Project Control Center — Schema 1.0.0
-- Migration 6/6: Storage-Policies für den Bucket project-docs
-- Referenz: docs/ARCHITECTURE.md Abschnitt 7a
--
-- Der Bucket gehört zu Supabase Storage. Lokal (reines Postgres) gibt es das
-- Schema storage nicht; dann tut diese Migration nichts und meldet das. Auf
-- Supabase legt sie den privaten Bucket an und hängt die Policies daran.
--
-- Namenskonvention: ein Objekt heißt <projekt-id>/<datei>. Die erste Ebene ist
-- damit die Projektzugehörigkeit, und pcc.documents.storage_path trägt genau
-- diesen Namen (Check-Constraint in Migration 1).
-- =============================================================================

do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'Schema storage nicht vorhanden: Storage-Policies übersprungen (lokale Prüfung)';
    return;
  end if;

  -- Privat: kein öffentlicher Lesezugriff, Dateien nur über signierte URLs.
  insert into storage.buckets (id, name, public, file_size_limit)
  values ('project-docs', 'project-docs', false, 52428800)
  on conflict (id) do update set public = false, file_size_limit = 52428800;

  execute $p$drop policy if exists project_docs_read on storage.objects$p$;
  execute $p$drop policy if exists project_docs_insert on storage.objects$p$;
  execute $p$drop policy if exists project_docs_update on storage.objects$p$;

  -- Lesen darf, wer das Projekt lesen darf — und erst, wenn die Virenprüfung
  -- das Dokument freigegeben hat. Ein Upload in Prüfung liegt zwar im Bucket,
  -- ist aber für niemanden ladbar (Abschnitt 7a). Gelöschte Dokumente
  -- verschwinden mit dem Löschvermerk auch aus dem Bucket-Zugriff.
  execute $p$
    create policy project_docs_read on storage.objects for select to authenticated
    using (
      bucket_id = 'project-docs'
      and exists (
        select 1 from pcc.documents d
         where d.storage_path = storage.objects.name
           and d.deleted_at is null
           and d.scan_state = 'clean'
           and pcc.can_read(d.project_id))
    )$p$;

  -- Hochladen darf, wer im Projekt beitragen darf, und nur unter dessen
  -- Kennung. Ein Objektname ohne gültige Projekt-UUID wird abgewiesen, bevor
  -- die Umwandlung ihn zu Fall bringen könnte.
  execute $p$
    create policy project_docs_insert on storage.objects for insert to authenticated
    with check (
      bucket_id = 'project-docs'
      and name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+'
      and pcc.can_contribute(split_part(name, '/', 1)::uuid)
    )$p$;

  -- Überschreiben gibt es nicht: eine neue Fassung ist ein neues Objekt
  -- (pcc.supersede_document). Löschen bleibt dem Dienstkonto vorbehalten —
  -- ohne Policy greift für authenticated nichts.
  raise notice 'Storage-Policies für project-docs eingerichtet';
end $$;
