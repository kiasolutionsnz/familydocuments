begin;

alter table fp.household_inbox_aliases drop constraint if exists household_inbox_aliases_domain_check;
alter table fp.household_inbox_aliases alter column domain set default 'familydocuments.servicehub.co.nz';
alter table fp.household_inbox_aliases add constraint household_inbox_aliases_domain_check
  check (domain in ('family-passport.local','familydocuments.servicehub.co.nz'));
update fp.household_inbox_aliases set domain='familydocuments.servicehub.co.nz'
where domain='family-passport.local' and status='active';

alter table fp.inbound_emails drop constraint if exists inbound_emails_source_system_check;
alter table fp.inbound_emails add constraint inbound_emails_source_system_check
  check(source_system in ('mailpit_local','cloudflare_email_worker'));

alter table fp.inbound_attachments add column if not exists quarantined_content bytea;
alter table fp.inbound_attachments drop constraint if exists inbound_attachments_check;
alter table fp.inbound_attachments add constraint inbound_attachments_content_state_check check(
  (scan_status='clean' and content is not null and content_sha256 is not null and quarantined_content is null)
  or (scan_status='pending' and content is null)
  or (scan_status in ('rejected','malformed','unsupported','error') and content is null and quarantined_content is null)
);

create table if not exists fp.inbound_webhook_nonces(
  nonce text primary key check(nonce ~ '^[0-9a-f]{32}$'),
  received_at timestamptz not null default now()
);
alter table fp.inbound_webhook_nonces enable row level security;
alter table fp.inbound_webhook_nonces force row level security;
revoke all on fp.inbound_webhook_nonces from public,anon,authenticated;

create or replace function fp.ingest_cloudflare_message(
  recipient_address text, external_message_id text, internet_message_id text,
  sender_address text, recipient_addresses jsonb, message_subject text,
  message_sent_at timestamptz, raw_email text, raw_sha256 text, body_text text,
  attachments jsonb, webhook_nonce text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare alias_row fp.household_inbox_aliases; row_id uuid; decoded_raw bytea; item jsonb;
declare decoded_attachment bytea; attachment_total bigint:=0; attachment_count integer;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  if webhook_nonce !~ '^[0-9a-f]{32}$' then raise exception 'invalid webhook nonce' using errcode='22023'; end if;
  insert into fp.inbound_webhook_nonces(nonce) values(webhook_nonce) on conflict do nothing;
  if not found then return jsonb_build_object('accepted',false,'reason','replayed_webhook'); end if;
  delete from fp.inbound_webhook_nonces where received_at < now()-interval '24 hours';
  select * into alias_row from fp.household_inbox_aliases where status='active' and lower(local_part||'@'||domain)=lower(trim(recipient_address));
  if alias_row.id is null then return jsonb_build_object('accepted',false,'reason','unknown_or_inactive_alias'); end if;
  begin decoded_raw:=decode(raw_email,'base64'); exception when others then return jsonb_build_object('accepted',false,'reason','invalid_source_encoding'); end;
  attachment_count:=jsonb_array_length(attachments);
  if octet_length(decoded_raw) not between 1 and 5242880 or attachment_count>20 then return jsonb_build_object('accepted',false,'reason','message_limits_exceeded'); end if;
  if lower(encode(extensions.digest(decoded_raw,'sha256'),'hex'))<>lower(raw_sha256) then return jsonb_build_object('accepted',false,'reason','source_hash_mismatch'); end if;
  for item in select value from jsonb_array_elements(attachments) loop
    begin decoded_attachment:=decode(item->>'content_base64','base64'); exception when others then return jsonb_build_object('accepted',false,'reason','invalid_attachment_encoding'); end;
    attachment_total:=attachment_total+octet_length(decoded_attachment);
    if octet_length(decoded_attachment) not between 1 and 5242880 or lower(encode(extensions.digest(decoded_attachment,'sha256'),'hex'))<>lower(item->>'sha256') then return jsonb_build_object('accepted',false,'reason','attachment_integrity_mismatch'); end if;
  end loop;
  if attachment_total>5242880 then return jsonb_build_object('accepted',false,'reason','attachment_limits_exceeded'); end if;
  insert into fp.inbound_emails(household_id,inbox_alias_id,source_system,external_message_id,internet_message_id,sender_address,recipient_addresses,subject,sent_at,raw_email,raw_sha256,raw_size_bytes,body_text,attachment_manifest,attachment_count,attachment_status)
  values(alias_row.household_id,alias_row.id,'cloudflare_email_worker',left(external_message_id,160),left(internet_message_id,998),lower(left(trim(sender_address),254)),recipient_addresses,left(coalesce(message_subject,''),998),message_sent_at,decoded_raw,lower(raw_sha256),octet_length(decoded_raw),left(coalesce(body_text,''),100000),
    (select coalesce(jsonb_agg(value-'content_base64'),'[]'::jsonb) from jsonb_array_elements(attachments)),attachment_count,case when attachment_count=0 then 'none' else 'quarantined_unscanned' end)
  on conflict on constraint inbound_emails_source_system_external_message_id_key do nothing returning id into row_id;
  if row_id is null then select id into row_id from fp.inbound_emails where source_system='cloudflare_email_worker' and fp.inbound_emails.external_message_id=left(ingest_cloudflare_message.external_message_id,160); return jsonb_build_object('accepted',true,'duplicate',true,'email_id',row_id); end if;
  insert into fp.inbound_attachments(inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,quarantined_content,scan_status)
  select row_id,alias_row.household_id,left(x.part_id,80),left(x.file_name,255),left(x.content_type,160),x.size_bytes,lower(x.sha256),decode(x.content_base64,'base64'),
    case when lower(x.content_type)='application/pdf' and lower(x.file_name) like '%.pdf' then 'pending' else 'unsupported' end
  from jsonb_to_recordset(attachments) x(part_id text,file_name text,content_type text,size_bytes integer,sha256 text,content_base64 text);
  update fp.inbound_attachments set quarantined_content=null where inbound_email_id=row_id and scan_status='unsupported';
  return jsonb_build_object('accepted',true,'duplicate',false,'email_id',row_id,'attachment_status',case when attachment_count=0 then 'none' else 'quarantined_unscanned' end);
end $$;

create or replace function fp.pending_attachment_scans(batch_size integer default 10) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'source_system',e.source_system,'external_message_id',e.external_message_id,'part_id',a.mailpit_part_id,'file_name',a.file_name,'content_type',a.claimed_content_type,'expected_size_bytes',a.expected_size_bytes,'expected_sha256',a.expected_sha256,'quarantined_content_base64',case when a.quarantined_content is null then null else encode(a.quarantined_content,'base64') end) order by a.created_at)
    from (select * from fp.inbound_attachments where scan_status='pending' order by created_at limit least(greatest(batch_size,1),20)) a join fp.inbound_emails e on e.id=a.inbound_email_id),'[]'::jsonb);
end $$;

create or replace function fp.record_attachment_scan(attachment_id uuid,verdict text,content_base64 text,provided_sha256 text,scanner_engine text,scanner_signature text,result_code text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.inbound_attachments; bytes bytea;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into row from fp.inbound_attachments where id=attachment_id for update;
  if row.id is null then raise exception 'attachment not found' using errcode='P0002'; end if;
  if row.scan_status<>'pending' then return jsonb_build_object('recorded',true,'duplicate',true,'status',row.scan_status); end if;
  if verdict not in ('clean','rejected','malformed','error') then raise exception 'invalid verdict' using errcode='22023'; end if;
  if verdict='clean' then begin bytes:=decode(content_base64,'base64'); exception when others then raise exception 'invalid content encoding' using errcode='22023'; end;
    if octet_length(bytes)<>row.expected_size_bytes or lower(encode(extensions.digest(bytes,'sha256'),'hex'))<>row.expected_sha256 or lower(provided_sha256)<>row.expected_sha256 then raise exception 'attachment integrity mismatch' using errcode='22023'; end if;
  end if;
  update fp.inbound_attachments set scan_status=verdict,content=case when verdict='clean' then bytes else null end,quarantined_content=null,content_sha256=case when verdict='clean' then lower(provided_sha256) else null end,scan_engine=left(scanner_engine,80),signature_version=left(scanner_signature,80),safe_result_code=left(result_code,80),scanned_at=now() where id=attachment_id;
  return jsonb_build_object('recorded',true,'duplicate',false,'status',verdict);
end $$;

revoke execute on function fp.ingest_cloudflare_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function fp.ingest_cloudflare_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb,text) to service_role;

commit;
