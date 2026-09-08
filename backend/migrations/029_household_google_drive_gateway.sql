begin;

create table if not exists fp.google_drive_credentials(
  household_id uuid primary key references fp.households(id) on delete cascade,
  encrypted_refresh_token text not null check(char_length(encrypted_refresh_token) between 40 and 8192),
  token_nonce text not null check(char_length(token_nonce) between 16 and 128),
  key_version integer not null default 1 check(key_version > 0),
  google_account text check(google_account is null or char_length(google_account) <= 320),
  scopes text not null check(char_length(scopes) between 1 and 2000),
  status text not null default 'active' check(status in ('active','revoked','error')),
  connected_by uuid not null,
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table fp.google_drive_credentials enable row level security;
alter table fp.google_drive_credentials force row level security;
revoke all on fp.google_drive_credentials from public,anon,authenticated;

create or replace function fp.authorize_google_drive_admin() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;
begin
  perform fp.require_aal2();
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  return jsonb_build_object('household_id',hid,'user_id',uid);
end $$;

create or replace function fp.authorize_google_drive_member() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;connection fp.storage_connections;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if connection.id is null then raise exception 'Google Drive is not connected' using errcode='P0002';end if;
  return jsonb_build_object('household_id',hid,'user_id',uid,'folder_id',connection.provider_folder_id,'folder_name',connection.folder_name);
end $$;

create or replace function fp.authorize_google_drive_document(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();d fp.documents;s fp.external_sources;connection fp.storage_connections;
begin
  select * into d from fp.documents where id=document and lifecycle_status<>'deleted' and
    (created_by=uid or fp.is_household_admin(household_id) or exists(select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=uid));
  if d.id is null then raise exception 'source not found' using errcode='P0002';end if;
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id where des.document_id=d.id and es.provider='google_drive';
  if s.id is null or s.status='disconnected' then raise exception 'source not found' using errcode='P0002';end if;
  select * into connection from fp.storage_connections where household_id=d.household_id and provider='google_drive' and status='active';
  if connection.id is null then raise exception 'Google Drive is not connected' using errcode='P0002';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
  values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('provider','google_drive','source_status',s.status));
  return jsonb_build_object('household_id',d.household_id,'source_id',s.id,'file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,'stored_checksum',s.provider_checksum,'status',s.status,'folder_id',connection.provider_folder_id);
end $$;

create or replace function fp.store_google_drive_credential(target_household uuid,ciphertext text,nonce text,version integer,account text,granted_scopes text,actor uuid) returns void
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'),'') <> 'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  if not exists(select 1 from fp.members where household_id=target_household and user_id=actor and status='active' and role in ('owner','family_admin')) then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.google_drive_credentials(household_id,encrypted_refresh_token,token_nonce,key_version,google_account,scopes,status,connected_by)
  values(target_household,ciphertext,nonce,version,left(account,320),left(granted_scopes,2000),'active',actor)
  on conflict(household_id) do update set encrypted_refresh_token=excluded.encrypted_refresh_token,token_nonce=excluded.token_nonce,key_version=excluded.key_version,google_account=excluded.google_account,scopes=excluded.scopes,status='active',connected_by=excluded.connected_by,updated_at=now();
end $$;

create or replace function fp.google_drive_credential(target_household uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.google_drive_credentials;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'),'') <> 'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select * into row from fp.google_drive_credentials where household_id=target_household and status='active';
  if row.household_id is null then raise exception 'Google Drive credential unavailable' using errcode='P0002';end if;
  return jsonb_build_object('ciphertext',row.encrypted_refresh_token,'nonce',row.token_nonce,'key_version',row.key_version,'scopes',row.scopes);
end $$;

create or replace function fp.revoke_google_drive_credential(target_household uuid,actor uuid) returns void
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'),'') <> 'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  if not exists(select 1 from fp.members where household_id=target_household and user_id=actor and status='active' and role in ('owner','family_admin')) then raise exception 'not authorised' using errcode='42501';end if;
  delete from fp.google_drive_credentials where household_id=target_household;
  update fp.storage_connections set status='disconnected',updated_at=now() where household_id=target_household and provider='google_drive';
  update fp.external_sources set status='disconnected',checked_at=now() where household_id=target_household and provider='google_drive';
end $$;

create or replace function fp.household_google_drive_connection_summary() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.storage_connections;credential fp.google_drive_credentials;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return null;end if;
  select * into row from fp.storage_connections where household_id=hid and provider='google_drive';
  select * into credential from fp.google_drive_credentials where household_id=hid;
  if row.id is null and credential.household_id is null then return null;end if;
  return jsonb_build_object('provider','google_drive','folder_id',row.provider_folder_id,'folder_name',row.folder_name,'web_view_link',row.web_view_link,
    'status',case when credential.status='active' and row.status='active' then 'active' when credential.status='active' then 'authorised' else coalesce(row.status,'disconnected') end,
    'google_account',credential.google_account,'configured_at',coalesce(row.configured_at,credential.connected_at),'can_manage',fp.is_household_admin(hid),'connection_mode','household_gateway');
end $$;

create or replace function fp.select_household_google_drive_folder(folder_id text,folder_name text,web_view_link text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.storage_connections;
begin
  perform fp.require_aal2();
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) or not exists(select 1 from fp.google_drive_credentials where household_id=hid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  if char_length(trim(folder_id)) not between 10 and 200 or char_length(trim(folder_name)) not between 1 and 255 then raise exception 'invalid Drive folder' using errcode='22023';end if;
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,web_view_link,status,configured_by)
  values(hid,'google_drive',trim(folder_id),left(trim(folder_name),255),left(web_view_link,1000),'active',uid)
  on conflict(household_id,provider) do update set provider_folder_id=excluded.provider_folder_id,folder_name=excluded.folder_name,web_view_link=excluded.web_view_link,status='active',configured_by=uid,updated_at=now()
  returning * into row;
  return jsonb_build_object('provider','google_drive','folder_id',row.provider_folder_id,'folder_name',row.folder_name,'web_view_link',row.web_view_link,'status','active','can_manage',true,'connection_mode','household_gateway');
end $$;

revoke execute on function fp.authorize_google_drive_admin(),fp.authorize_google_drive_member(),fp.authorize_google_drive_document(uuid) from public,anon;
grant execute on function fp.authorize_google_drive_admin(),fp.authorize_google_drive_member(),fp.authorize_google_drive_document(uuid) to authenticated;
revoke execute on function fp.household_google_drive_connection_summary(),fp.select_household_google_drive_folder(text,text,text) from public,anon;
grant execute on function fp.household_google_drive_connection_summary(),fp.select_household_google_drive_folder(text,text,text) to authenticated;
revoke execute on function fp.store_google_drive_credential(uuid,text,text,integer,text,text,uuid),fp.google_drive_credential(uuid),fp.revoke_google_drive_credential(uuid,uuid) from public,anon,authenticated;
grant execute on function fp.store_google_drive_credential(uuid,text,text,integer,text,text,uuid),fp.google_drive_credential(uuid),fp.revoke_google_drive_credential(uuid,uuid) to service_role;

commit;
