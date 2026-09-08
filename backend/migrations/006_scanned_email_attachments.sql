begin;

create table if not exists fp.inbound_attachments (
  id uuid primary key default gen_random_uuid(),
  inbound_email_id uuid not null references fp.inbound_emails(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  mailpit_part_id text not null check(char_length(mailpit_part_id) between 1 and 80),
  file_name text not null check(char_length(file_name) between 1 and 255),
  claimed_content_type text not null check(char_length(claimed_content_type) between 1 and 160),
  expected_size_bytes integer not null check(expected_size_bytes between 1 and 5242880),
  expected_sha256 text not null check(expected_sha256 ~ '^[0-9a-f]{64}$'),
  content bytea,
  content_sha256 text check(content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$'),
  scan_status text not null check(scan_status in ('pending','clean','rejected','malformed','unsupported','error')),
  scan_engine text,
  signature_version text,
  safe_result_code text,
  scanned_at timestamptz,
  created_at timestamptz not null default now(),
  unique(inbound_email_id,mailpit_part_id),
  check((scan_status='clean' and content is not null and content_sha256 is not null) or (scan_status<>'clean' and content is null))
);
create index if not exists inbound_attachments_pending on fp.inbound_attachments(scan_status,created_at) where scan_status='pending';
alter table fp.inbound_attachments enable row level security;
alter table fp.inbound_attachments force row level security;
drop policy if exists inbound_attachment_admin_read on fp.inbound_attachments;
create policy inbound_attachment_admin_read on fp.inbound_attachments for select using(fp.is_household_admin(household_id));

insert into fp.inbound_attachments(inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,scan_status)
select e.id,e.household_id,a.part_id,a.file_name,a.content_type,a.size_bytes,a.sha256,
  case when a.content_type='application/pdf' and lower(a.file_name) like '%.pdf' then 'pending' else 'unsupported' end
from fp.inbound_emails e
cross join lateral jsonb_to_recordset(e.attachment_manifest) as a(part_id text,file_name text,content_type text,size_bytes integer,sha256 text)
where a.part_id is not null and a.sha256 ~ '^[0-9a-f]{64}$' and a.size_bytes between 1 and 5242880
on conflict do nothing;

create or replace function fp.ingest_mailpit_message(
  recipient_address text,mailpit_message_id text,internet_message_id text,sender_address text,
  recipient_addresses jsonb,message_subject text,message_sent_at timestamptz,raw_email text,
  raw_sha256 text,body_text text,attachment_manifest jsonb
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare alias_row fp.household_inbox_aliases; row_id uuid; raw_bytes integer; attachments integer; decoded_raw bytea;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into alias_row from fp.household_inbox_aliases where status='active' and lower(local_part||'@'||domain)=lower(trim(recipient_address));
  if alias_row.id is null then return jsonb_build_object('accepted',false,'reason','unknown_or_inactive_alias'); end if;
  begin decoded_raw:=decode(raw_email,'base64'); exception when others then return jsonb_build_object('accepted',false,'reason','invalid_source_encoding'); end;
  raw_bytes:=octet_length(decoded_raw); attachments:=jsonb_array_length(attachment_manifest);
  if raw_bytes<1 or raw_bytes>5242880 or attachments>20 then return jsonb_build_object('accepted',false,'reason','message_limits_exceeded'); end if;
  if lower(encode(extensions.digest(decoded_raw,'sha256'),'hex')) <> lower(raw_sha256) then return jsonb_build_object('accepted',false,'reason','source_hash_mismatch'); end if;
  insert into fp.inbound_emails(household_id,inbox_alias_id,source_system,external_message_id,internet_message_id,sender_address,recipient_addresses,subject,sent_at,raw_email,raw_sha256,raw_size_bytes,body_text,attachment_manifest,attachment_count,attachment_status)
  values(alias_row.household_id,alias_row.id,'mailpit_local',left(mailpit_message_id,160),left(internet_message_id,998),lower(left(trim(sender_address),254)),recipient_addresses,left(coalesce(message_subject,''),998),message_sent_at,decoded_raw,lower(raw_sha256),raw_bytes,left(coalesce(body_text,''),100000),attachment_manifest,attachments,case when attachments=0 then 'none' else 'quarantined_unscanned' end)
  on conflict(source_system,external_message_id) do nothing returning id into row_id;
  if row_id is null then select id into row_id from fp.inbound_emails where source_system='mailpit_local' and external_message_id=mailpit_message_id; return jsonb_build_object('accepted',true,'duplicate',true,'email_id',row_id); end if;
  insert into fp.inbound_attachments(inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,scan_status)
  select row_id,alias_row.household_id,a.part_id,left(a.file_name,255),left(a.content_type,160),a.size_bytes,lower(a.sha256),
    case when a.content_type='application/pdf' and lower(a.file_name) like '%.pdf' then 'pending' else 'unsupported' end
  from jsonb_to_recordset(attachment_manifest) as a(part_id text,file_name text,content_type text,size_bytes integer,sha256 text)
  where a.part_id is not null and a.file_name is not null and a.content_type is not null and a.sha256 ~ '^[0-9a-f]{64}$' and a.size_bytes between 1 and 5242880;
  return jsonb_build_object('accepted',true,'duplicate',false,'email_id',row_id,'attachment_status',case when attachments=0 then 'none' else 'quarantined_unscanned' end);
end $$;

create or replace function fp.pending_attachment_scans(batch_size integer default 10) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'mailpit_message_id',e.external_message_id,'part_id',a.mailpit_part_id,'file_name',a.file_name,'content_type',a.claimed_content_type,'expected_size_bytes',a.expected_size_bytes,'expected_sha256',a.expected_sha256) order by a.created_at)
    from (select * from fp.inbound_attachments where scan_status='pending' order by created_at limit least(greatest(batch_size,1),20)) a join fp.inbound_emails e on e.id=a.inbound_email_id),'[]'::jsonb);
end $$;

drop function if exists fp.record_attachment_scan(uuid,text,text,text,text,text,text);
create function fp.record_attachment_scan(attachment_id uuid,verdict text,content_base64 text,provided_sha256 text,scanner_engine text,scanner_signature text,result_code text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.inbound_attachments; bytes bytea;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into row from fp.inbound_attachments where id=attachment_id for update;
  if row.id is null then raise exception 'attachment not found' using errcode='P0002'; end if;
  if row.scan_status<>'pending' then return jsonb_build_object('recorded',true,'duplicate',true,'status',row.scan_status); end if;
  if verdict not in ('clean','rejected','malformed','error') then raise exception 'invalid verdict' using errcode='22023'; end if;
  if verdict='clean' then
    begin bytes:=decode(content_base64,'base64'); exception when others then raise exception 'invalid content encoding' using errcode='22023'; end;
    if octet_length(bytes)<>row.expected_size_bytes or lower(encode(extensions.digest(bytes,'sha256'),'hex'))<>row.expected_sha256 or lower(provided_sha256)<>row.expected_sha256 then raise exception 'attachment integrity mismatch' using errcode='22023'; end if;
  end if;
  update fp.inbound_attachments set scan_status=verdict,content=case when verdict='clean' then bytes else null end,content_sha256=case when verdict='clean' then lower(provided_sha256) else null end,scan_engine=left(scanner_engine,80),signature_version=left(scanner_signature,80),safe_result_code=left(result_code,80),scanned_at=now() where id=attachment_id;
  return jsonb_build_object('recorded',true,'duplicate',false,'status',verdict);
end $$;

create or replace function fp.inbound_email_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'sender_address',e.sender_address,'subject',e.subject,'sent_at',e.sent_at,'attachment_count',e.attachment_count,
    'attachment_status',case when e.attachment_count=0 then 'none' when exists(select 1 from fp.inbound_attachments a where a.inbound_email_id=e.id and a.scan_status in ('rejected','malformed','error')) then 'rejected' when not exists(select 1 from fp.inbound_attachments a where a.inbound_email_id=e.id and a.scan_status in ('pending','unsupported')) then 'clean' else 'quarantined_unscanned' end,
    'processing_status',e.processing_status,'ingested_at',e.ingested_at,'raw_sha256',e.raw_sha256) order by e.ingested_at desc) from fp.inbound_emails e where e.household_id=hid),'[]'::jsonb);
end $$;

create or replace function fp.inbound_attachment_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'email_id',a.inbound_email_id,'email_subject',e.subject,'file_name',a.file_name,'content_type',a.claimed_content_type,'size_bytes',a.expected_size_bytes,'sha256',a.expected_sha256,'scan_status',a.scan_status,'safe_result_code',a.safe_result_code,'scanned_at',a.scanned_at) order by a.created_at desc) from fp.inbound_attachments a join fp.inbound_emails e on e.id=a.inbound_email_id where a.household_id=hid),'[]'::jsonb);
end $$;

revoke all on fp.inbound_attachments from public,anon,authenticated;
revoke execute on function fp.pending_attachment_scans(integer),fp.record_attachment_scan(uuid,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function fp.pending_attachment_scans(integer),fp.record_attachment_scan(uuid,text,text,text,text,text,text) to service_role;
grant execute on function fp.inbound_attachment_summaries() to authenticated;

commit;
