begin;
create or replace function fp.pending_attachment_search_backfill(batch_size integer default 10) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(jsonb_build_object('attachment_id',a.id,'source_sha256',a.content_sha256,'content_base64',encode(a.content,'base64')) order by a.created_at) from(select a.* from fp.inbound_attachments a join fp.inbound_emails e on e.id=a.inbound_email_id where a.scan_status='clean' and a.search_text is null and e.sender_disposition='allowed' and e.deleted_at is null and exists(select 1 from fp.documents d where d.source_attachment_id=a.id and d.lifecycle_status<>'deleted' and d.confirmation_status='confirmed') order by a.created_at limit least(greatest(batch_size,1),20))a),'[]'::jsonb);
end$$;
create or replace function fp.store_attachment_search_backfill(attachment_id uuid,provided_sha256 text,extracted_text text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  update fp.inbound_attachments set search_text=left(extracted_text,100000) where id=attachment_id and scan_status='clean' and content_sha256=lower(provided_sha256) and search_text is null;get diagnostics changed=row_count;
  if changed<>1 then raise exception 'attachment unavailable or integrity mismatch' using errcode='22023';end if;return jsonb_build_object('stored',true);
end$$;
revoke execute on function fp.pending_attachment_search_backfill(integer),fp.store_attachment_search_backfill(uuid,text,text) from public,anon,authenticated;
grant execute on function fp.pending_attachment_search_backfill(integer),fp.store_attachment_search_backfill(uuid,text,text) to service_role;
commit;
