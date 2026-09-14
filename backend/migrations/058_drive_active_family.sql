begin;

-- Drive must use the same explicit Family context as the conversation UI.
-- This changes no existing files, credentials, or storage destinations.
create or replace function fp.authorize_google_drive_admin() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
begin
  perform fp.require_aal2();
  if not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  return jsonb_build_object('household_id',hid,'user_id',uid);
end $$;

create or replace function fp.authorize_google_drive_member() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;connection fp.storage_connections;
begin
  select role into member_role from fp.members where user_id=uid and household_id=hid and status='active';
  if member_role is null or member_role not in ('owner','family_admin','adult_member','contributor') then
    raise exception 'not authorised' using errcode='42501';
  end if;
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if connection.id is null or not exists(select 1 from fp.google_drive_credentials where household_id=hid and status='active') then
    raise exception 'Google Drive must be connected before saving' using errcode='P0002';
  end if;
  return jsonb_build_object('household_id',hid,'user_id',uid,'folder_id',connection.provider_folder_id,'folder_name',connection.folder_name);
end $$;

create or replace function fp.household_google_drive_connection_summary() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid:=fp.active_family_id();connection fp.storage_connections;credential fp.google_drive_credentials;connection_status text;
begin
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive';
  select * into credential from fp.google_drive_credentials where household_id=hid;
  connection_status:=case
    when credential.status='active' and connection.status='active' then 'active'
    when credential.status='active' then 'authorised'
    when connection.status='active' then 'reconnect_required'
    when connection.id is null and credential.household_id is null then 'not_connected'
    else 'disconnected'
  end;
  return jsonb_build_object('provider','google_drive','household_id',hid,
    'folder_id',connection.provider_folder_id,'folder_name',connection.folder_name,
    'web_view_link',connection.web_view_link,'status',connection_status,
    'credential_available',coalesce(credential.status='active',false),
    'google_account',credential.google_account,
    'configured_at',coalesce(connection.configured_at,credential.connected_at),
    'can_manage',fp.is_household_admin(hid),'connection_mode','household_gateway');
end $$;

create or replace function fp.select_household_google_drive_folder(folder_id text,folder_name text,web_view_link text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();connection fp.storage_connections;
begin
  perform fp.require_aal2();
  if not fp.is_household_admin(hid) or not exists(select 1 from fp.google_drive_credentials where household_id=hid and status='active') then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if folder_id is null or folder_name is null or char_length(trim(folder_id)) not between 10 and 200 or char_length(trim(folder_name)) not between 1 and 255 then
    raise exception 'invalid Drive folder' using errcode='22023';
  end if;
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,web_view_link,status,configured_by)
  values(hid,'google_drive',trim(folder_id),left(trim(folder_name),255),left(web_view_link,1000),'active',uid)
  on conflict(household_id,provider) do update set provider_folder_id=excluded.provider_folder_id,folder_name=excluded.folder_name,
    web_view_link=excluded.web_view_link,status='active',configured_by=uid,updated_at=now()
  returning * into connection;
  return fp.household_google_drive_connection_summary();
end $$;

-- Opening old originals remains supported, but never across the selected
-- Family or after membership/access revocation.
create or replace function fp.authorize_google_drive_document(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();d fp.documents;s fp.external_sources;connection fp.storage_connections;
begin
  select candidate.* into d from fp.documents candidate
  where candidate.id=document and candidate.household_id=hid and candidate.lifecycle_status<>'deleted'
    and (candidate.created_by=uid or fp.is_household_admin(hid)
      or exists(select 1 from fp.document_permissions p where p.document_id=candidate.id and p.member_user_id=uid));
  if d.id is null then raise exception 'source not found' using errcode='P0002';end if;
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id
    where des.document_id=d.id and es.household_id=hid and es.provider='google_drive';
  if s.id is null or s.status='disconnected' then raise exception 'source not found' using errcode='P0002';end if;
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if connection.id is null then raise exception 'Google Drive is not connected' using errcode='P0002';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
    values(hid,uid,d.id,'source_opened',jsonb_build_object('provider','google_drive','source_status',s.status));
  return jsonb_build_object('household_id',hid,'source_id',s.id,'file_id',s.provider_file_id,'file_name',s.file_name,
    'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,
    'stored_checksum',s.provider_checksum,'status',s.status,'folder_id',connection.provider_folder_id);
end $$;

revoke execute on function fp.authorize_google_drive_admin(),fp.authorize_google_drive_member(),
  fp.authorize_google_drive_document(uuid),fp.household_google_drive_connection_summary(),
  fp.select_household_google_drive_folder(text,text,text) from public,anon;
grant execute on function fp.authorize_google_drive_admin(),fp.authorize_google_drive_member(),
  fp.authorize_google_drive_document(uuid),fp.household_google_drive_connection_summary(),
  fp.select_household_google_drive_folder(text,text,text) to authenticated;

commit;
