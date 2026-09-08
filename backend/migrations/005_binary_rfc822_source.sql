begin;

do $$
begin
  if exists(select 1 from information_schema.columns where table_schema='fp' and table_name='inbound_emails' and column_name='raw_email' and data_type='text') then
    alter table fp.inbound_emails alter column raw_email type bytea using convert_to(raw_email,'UTF8');
  end if;
end $$;

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
declare alias_row fp.household_inbox_aliases; row_id uuid; raw_bytes integer; attachments integer; decoded_raw bytea;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select * into alias_row from fp.household_inbox_aliases
    where status='active' and lower(local_part||'@'||domain)=lower(trim(recipient_address));
  if alias_row.id is null then return jsonb_build_object('accepted',false,'reason','unknown_or_inactive_alias'); end if;
  begin decoded_raw:=decode(raw_email,'base64'); exception when others then return jsonb_build_object('accepted',false,'reason','invalid_source_encoding'); end;
  raw_bytes:=octet_length(decoded_raw); attachments:=jsonb_array_length(attachment_manifest);
  if raw_bytes<1 or raw_bytes>5242880 or attachments>20 then return jsonb_build_object('accepted',false,'reason','message_limits_exceeded'); end if;
  if lower(encode(extensions.digest(decoded_raw,'sha256'),'hex')) <> lower(raw_sha256) then
    return jsonb_build_object('accepted',false,'reason','source_hash_mismatch');
  end if;
  insert into fp.inbound_emails(
    household_id,inbox_alias_id,source_system,external_message_id,internet_message_id,sender_address,
    recipient_addresses,subject,sent_at,raw_email,raw_sha256,raw_size_bytes,body_text,
    attachment_manifest,attachment_count,attachment_status
  ) values(
    alias_row.household_id,alias_row.id,'mailpit_local',left(mailpit_message_id,160),left(internet_message_id,998),
    lower(left(trim(sender_address),254)),recipient_addresses,left(coalesce(message_subject,''),998),message_sent_at,
    decoded_raw,lower(raw_sha256),raw_bytes,left(coalesce(body_text,''),100000),attachment_manifest,attachments,
    case when attachments=0 then 'none' else 'quarantined_unscanned' end
  ) on conflict(source_system,external_message_id) do nothing returning id into row_id;
  if row_id is null then
    select id into row_id from fp.inbound_emails where source_system='mailpit_local' and external_message_id=mailpit_message_id;
    return jsonb_build_object('accepted',true,'duplicate',true,'email_id',row_id);
  end if;
  return jsonb_build_object('accepted',true,'duplicate',false,'email_id',row_id,'attachment_status',case when attachments=0 then 'none' else 'quarantined_unscanned' end);
end $$;

commit;
