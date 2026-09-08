begin;

alter table fp.household_inbox_aliases drop constraint if exists household_inbox_aliases_domain_check;
alter table fp.household_inbox_aliases alter column domain set default 'familydocuments.app';
alter table fp.household_inbox_aliases add constraint household_inbox_aliases_domain_check
  check (domain in ('family-passport.local','familydocuments.servicehub.co.nz','familydocuments.app'));

update fp.household_inbox_aliases
set domain='familydocuments.app'
where domain='familydocuments.servicehub.co.nz' and status='active';

create or replace function fp.set_household_inbox_alias(preferred_local_part text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id(); hid uuid; candidate text:=lower(trim(preferred_local_part));
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  if candidate !~ '^[a-z0-9][a-z0-9-]{2,39}$' or candidate ~ '--' then
    raise exception 'inbox name must be 3 to 40 lowercase letters, numbers or single hyphens' using errcode='22023';
  end if;
  if candidate = any(array['admin','administrator','abuse','billing','contact','help','info','mailer-daemon','no-reply','noreply','postmaster','privacy','security','support','webmaster']) then
    raise exception 'reserved inbox name' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text,0));
  if exists(select 1 from fp.household_inbox_aliases where local_part=candidate and household_id<>hid) then
    raise exception 'inbox name unavailable' using errcode='23505';
  end if;
  update fp.household_inbox_aliases set status='rotated',ended_at=now() where household_id=hid and status='active';
  insert into fp.household_inbox_aliases(household_id,local_part,domain,created_by)
    values(hid,candidate,'familydocuments.app',uid);
  return fp.household_snapshot();
exception when unique_violation then
  raise exception 'inbox name unavailable' using errcode='23505';
end $$;

revoke execute on function fp.set_household_inbox_alias(text) from public,anon;
grant execute on function fp.set_household_inbox_alias(text) to authenticated;

-- The legacy ServiceHub address remains deliverable during the transition by
-- resolving its local part to the active familydocuments.app alias.
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
  select * into alias_row from fp.household_inbox_aliases
  where status='active' and (
    lower(local_part||'@'||domain)=lower(trim(recipient_address))
    or (
      lower(split_part(trim(recipient_address),'@',2))='familydocuments.servicehub.co.nz'
      and domain='familydocuments.app'
      and lower(local_part)=lower(split_part(trim(recipient_address),'@',1))
    )
  ) limit 1;
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

revoke execute on function fp.ingest_cloudflare_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function fp.ingest_cloudflare_message(text,text,text,text,jsonb,text,timestamptz,text,text,text,jsonb,text) to service_role;

commit;
