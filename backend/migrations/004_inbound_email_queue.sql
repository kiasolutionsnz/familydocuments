begin;

create table if not exists fp.inbound_emails (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  inbox_alias_id uuid not null references fp.household_inbox_aliases(id),
  source_system text not null check(source_system='mailpit_local'),
  external_message_id text not null check(char_length(external_message_id) between 1 and 160),
  internet_message_id text check(char_length(internet_message_id)<=998),
  sender_address text not null check(char_length(sender_address) between 3 and 254),
  recipient_addresses jsonb not null check(jsonb_typeof(recipient_addresses)='array'),
  subject text not null check(char_length(subject)<=998),
  sent_at timestamptz,
  raw_email text not null,
  raw_sha256 text not null check(raw_sha256 ~ '^[0-9a-f]{64}$'),
  raw_size_bytes integer not null check(raw_size_bytes between 1 and 5242880),
  body_text text not null check(char_length(body_text)<=100000),
  attachment_manifest jsonb not null default '[]'::jsonb check(jsonb_typeof(attachment_manifest)='array'),
  attachment_count integer not null default 0 check(attachment_count between 0 and 20),
  attachment_status text not null check(attachment_status in ('none','quarantined_unscanned')),
  processing_status text not null default 'awaiting_classification' check(processing_status in ('awaiting_classification','classified','needs_review','rejected')),
  ingested_at timestamptz not null default now(),
  unique(source_system,external_message_id)
);
create index if not exists inbound_emails_household_ingested on fp.inbound_emails(household_id,ingested_at desc);

alter table fp.inbound_emails enable row level security;
alter table fp.inbound_emails force row level security;
drop policy if exists inbound_email_admin_read on fp.inbound_emails;
create policy inbound_email_admin_read on fp.inbound_emails for select using(fp.is_household_admin(household_id));

create or replace function fp.ingest_mailpit_message(
  recipient_address text,
  mailpit_message_id text,
  internet_message_id text,
  sender_address text,
  recipient_addresses jsonb,
  message_subject text,
  message_sent_at timestamptz,
  raw_email text,
  raw_sha256 text,
  body_text text,
  attachment_manifest jsonb
) returns jsonb
language plpgsql security definer
set search_path=pg_catalog,fp
as $$
declare alias_row fp.household_inbox_aliases; row_id uuid; raw_bytes integer; attachments integer;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select * into alias_row from fp.household_inbox_aliases
    where status='active' and lower(local_part||'@'||domain)=lower(trim(recipient_address));
  if alias_row.id is null then return jsonb_build_object('accepted',false,'reason','unknown_or_inactive_alias'); end if;
  raw_bytes:=octet_length(raw_email); attachments:=jsonb_array_length(attachment_manifest);
  if raw_bytes<1 or raw_bytes>5242880 or attachments>20 then return jsonb_build_object('accepted',false,'reason','message_limits_exceeded'); end if;
  if lower(encode(extensions.digest(convert_to(raw_email,'UTF8'),'sha256'),'hex')) <> lower(raw_sha256) then
    return jsonb_build_object('accepted',false,'reason','source_hash_mismatch');
  end if;
  insert into fp.inbound_emails(
    household_id,inbox_alias_id,source_system,external_message_id,internet_message_id,sender_address,
    recipient_addresses,subject,sent_at,raw_email,raw_sha256,raw_size_bytes,body_text,
    attachment_manifest,attachment_count,attachment_status
  ) values(
    alias_row.household_id,alias_row.id,'mailpit_local',left(mailpit_message_id,160),left(internet_message_id,998),
    lower(left(trim(sender_address),254)),recipient_addresses,left(coalesce(message_subject,''),998),message_sent_at,
    raw_email,lower(raw_sha256),raw_bytes,left(coalesce(body_text,''),100000),attachment_manifest,attachments,
    case when attachments=0 then 'none' else 'quarantined_unscanned' end
  ) on conflict(source_system,external_message_id) do nothing returning id into row_id;
  if row_id is null then
    select id into row_id from fp.inbound_emails where source_system='mailpit_local' and external_message_id=mailpit_message_id;
    return jsonb_build_object('accepted',true,'duplicate',true,'email_id',row_id);
  end if;
  return jsonb_build_object('accepted',true,'duplicate',false,'email_id',row_id,'attachment_status',case when attachments=0 then 'none' else 'quarantined_unscanned' end);
end $$;

create or replace function fp.inbound_email_summaries() returns jsonb
language plpgsql security definer
set search_path=pg_catalog,fp
as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',e.id,'sender_address',e.sender_address,'subject',e.subject,'sent_at',e.sent_at,
    'attachment_count',e.attachment_count,'attachment_status',e.attachment_status,
    'processing_status',e.processing_status,'ingested_at',e.ingested_at,'raw_sha256',e.raw_sha256
  ) order by e.ingested_at desc) from fp.inbound_emails e where e.household_id=hid),'[]'::jsonb);
end $$;

revoke all on fp.inbound_emails from public,anon,authenticated;
grant usage on schema fp to service_role;
revoke execute on function fp.ingest_mailpit_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function fp.ingest_mailpit_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb) to service_role;
grant execute on function fp.inbound_email_summaries() to authenticated;

commit;
