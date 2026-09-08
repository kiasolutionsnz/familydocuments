begin;

create table if not exists fp.storage_connections(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  provider text not null check(provider='google_drive'),
  provider_folder_id text not null check(char_length(provider_folder_id) between 10 and 200),
  folder_name text not null check(char_length(folder_name) between 1 and 255),
  web_view_link text check(web_view_link is null or char_length(web_view_link)<=1000),
  status text not null default 'active' check(status in ('active','disconnected')),
  configured_by uuid not null,
  configured_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,provider)
);
alter table fp.storage_connections enable row level security;
alter table fp.storage_connections force row level security;
revoke all on fp.storage_connections from public,anon,authenticated;

create or replace function fp.google_drive_connection_summary() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.storage_connections;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return null;end if;
  select * into row from fp.storage_connections where household_id=hid and provider='google_drive';
  if row.id is null then return null;end if;
  return jsonb_build_object('provider','google_drive','folder_id',row.provider_folder_id,'folder_name',row.folder_name,'web_view_link',row.web_view_link,'status',row.status,'configured_at',row.configured_at,'can_manage',fp.is_household_admin(hid));
end $$;

create or replace function fp.set_google_drive_folder(folder_id text,folder_name text,web_view_link text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.storage_connections;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  if char_length(trim(folder_id)) not between 10 and 200 or char_length(trim(folder_name)) not between 1 and 255 then raise exception 'invalid Drive folder' using errcode='22023';end if;
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,web_view_link,status,configured_by)
  values(hid,'google_drive',trim(folder_id),left(trim(folder_name),255),left(web_view_link,1000),'active',uid)
  on conflict(household_id,provider) do update set provider_folder_id=excluded.provider_folder_id,folder_name=excluded.folder_name,web_view_link=excluded.web_view_link,status='active',configured_by=uid,updated_at=now()
  returning * into row;
  return jsonb_build_object('provider','google_drive','folder_id',row.provider_folder_id,'folder_name',row.folder_name,'web_view_link',row.web_view_link,'status',row.status,'can_manage',true);
end $$;

create or replace function fp.disconnect_google_drive_storage() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  update fp.storage_connections set status='disconnected',updated_at=now() where household_id=hid and provider='google_drive';
  return jsonb_build_object('provider','google_drive','status','disconnected');
end $$;

create or replace function fp.create_google_drive_document(
  document_title text,category uuid,folder_id text,file_id text,file_name text,source_mime_type text,
  size_bytes bigint,modified_time timestamptz,provider_version text,provider_checksum text,content_sha256 text,
  web_view_link text default null,document_date date default null,reminder_date date default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;connection fp.storage_connections;source fp.external_sources;d fp.documents;rid uuid;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if connection.id is null or connection.provider_folder_id<>trim(folder_id) then raise exception 'Drive folder is not connected' using errcode='42501';end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023';end if;
  if char_length(trim(document_title)) not between 1 and 160 or char_length(trim(file_id)) not between 10 and 200 or source_mime_type not in ('application/pdf','image/jpeg','image/png') or size_bytes not between 1 and 5242880 or content_sha256 !~ '^[0-9a-f]{64}$' or (provider_checksum is not null and lower(provider_checksum) !~ '^[0-9a-f]{32}$') then raise exception 'invalid Drive document' using errcode='22023';end if;
  insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,provider_checksum,content_sha256,web_view_link,status,added_by)
  values(hid,'google_drive',trim(file_id),left(trim(file_name),255),source_mime_type,size_bytes,modified_time,left(provider_version,80),lower(provider_checksum),lower(content_sha256),left(web_view_link,1000),'active',uid)
  returning * into source;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,document_date,critical_date,confirmation_status)
  values(hid,category,trim(document_title),uid,left(trim(file_name),255),lower(content_sha256),source_mime_type,document_date,reminder_date,'confirmed') returning * into d;
  insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(d.id,source.id,uid);
  if reminder_date is not null then insert into fp.reminders(household_id,document_id,title,due_at,created_by) values(hid,d.id,d.title||' — reminder',reminder_date,uid) returning id into rid;end if;
  return jsonb_build_object('document_id',d.id,'external_source_id',source.id,'reminder_id',rid,'provider','google_drive');
end $$;

revoke execute on function fp.google_drive_connection_summary(),fp.set_google_drive_folder(text,text,text),fp.disconnect_google_drive_storage(),fp.create_google_drive_document(text,uuid,text,text,text,text,bigint,timestamptz,text,text,text,text,date,date) from public,anon;
grant execute on function fp.google_drive_connection_summary(),fp.set_google_drive_folder(text,text,text),fp.disconnect_google_drive_storage(),fp.create_google_drive_document(text,uuid,text,text,text,text,bigint,timestamptz,text,text,text,text,date,date) to authenticated;

commit;
