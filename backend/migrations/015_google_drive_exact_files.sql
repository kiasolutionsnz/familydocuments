begin;

create table if not exists fp.external_sources(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  provider text not null check(provider='google_drive'),
  provider_file_id text not null check(char_length(provider_file_id) between 10 and 200),
  file_name text not null check(char_length(file_name) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  size_bytes bigint not null check(size_bytes between 1 and 15728640),
  modified_time timestamptz not null,
  provider_version text not null check(char_length(provider_version) between 1 and 80),
  provider_checksum text check(provider_checksum is null or provider_checksum ~ '^[0-9a-f]{32}$'),
  content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
  web_view_link text check(web_view_link is null or char_length(web_view_link)<=1000),
  status text not null default 'active' check(status in ('active','changed','missing','disconnected')),
  added_by uuid not null,
  added_at timestamptz not null default now(),
  checked_at timestamptz not null default now(),
  unique(household_id,provider,provider_file_id)
);
create table if not exists fp.document_external_sources(
  document_id uuid primary key references fp.documents(id) on delete cascade,
  external_source_id uuid not null references fp.external_sources(id) on delete restrict,
  linked_by uuid not null,
  linked_at timestamptz not null default now()
);
alter table fp.external_sources enable row level security; alter table fp.external_sources force row level security;
alter table fp.document_external_sources enable row level security; alter table fp.document_external_sources force row level security;
drop policy if exists external_source_authorised_read on fp.external_sources;
create policy external_source_authorised_read on fp.external_sources for select using(exists(select 1 from fp.document_external_sources des join fp.documents d on d.id=des.document_id where des.external_source_id=external_sources.id and d.lifecycle_status<>'deleted' and (d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));
drop policy if exists document_external_source_authorised_read on fp.document_external_sources;
create policy document_external_source_authorised_read on fp.document_external_sources for select using(exists(select 1 from fp.documents d where d.id=document_id and d.lifecycle_status<>'deleted' and (d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));

create or replace function fp.register_google_drive_source(file_id text,file_name text,mime_type text,size_bytes bigint,modified_time timestamptz,provider_version text,provider_checksum text,content_sha256 text,web_view_link text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; member_role text; row fp.external_sources;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501'; end if;
  if char_length(trim(file_id)) not between 10 and 200 or mime_type not in ('application/pdf','image/jpeg','image/png') or size_bytes not between 1 and 15728640 or content_sha256 !~ '^[0-9a-f]{64}$' or (provider_checksum is not null and lower(provider_checksum) !~ '^[0-9a-f]{32}$') then raise exception 'invalid Drive source' using errcode='22023'; end if;
  insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,provider_checksum,content_sha256,web_view_link,status,added_by)
  values(hid,'google_drive',trim(file_id),left(trim(file_name),255),mime_type,size_bytes,modified_time,left(provider_version,80),lower(provider_checksum),lower(content_sha256),left(web_view_link,1000),'active',uid)
  on conflict(household_id,provider,provider_file_id) do update set file_name=excluded.file_name,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes,modified_time=excluded.modified_time,provider_version=excluded.provider_version,provider_checksum=excluded.provider_checksum,content_sha256=excluded.content_sha256,web_view_link=excluded.web_view_link,status='active',checked_at=now()
  returning * into row;
  return jsonb_build_object('id',row.id,'provider','google_drive','file_id',row.provider_file_id,'file_name',row.file_name,'status',row.status);
end $$;

create or replace function fp.link_google_drive_source(document uuid,external_source uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; s fp.external_sources;
begin
  select * into d from fp.documents where id=document; select * into s from fp.external_sources where id=external_source;
  if d.id is null or s.id is null or d.household_id<>s.household_id or s.status<>'active' or not(d.created_by=uid or fp.is_household_admin(d.household_id)) then raise exception 'not authorised' using errcode='42501'; end if;
  if d.source_sha256<>s.content_sha256 then raise exception 'source hash mismatch' using errcode='22023'; end if;
  insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(d.id,s.id,uid) on conflict(document_id) do update set external_source_id=excluded.external_source_id,linked_by=excluded.linked_by,linked_at=now();
  return jsonb_build_object('document_id',d.id,'external_source_id',s.id,'provider','google_drive');
end $$;

create or replace function fp.update_google_drive_source(source uuid,modified_time timestamptz,provider_version text,provider_checksum text,observed_status text default 'active') returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); row fp.external_sources; next_status text;
begin
  select * into row from fp.external_sources where id=source and exists(select 1 from fp.document_external_sources des join fp.documents d on d.id=des.document_id where des.external_source_id=source and (d.created_by=uid or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid)));
  if row.id is null or observed_status not in ('active','missing') then raise exception 'not authorised' using errcode='42501'; end if;
  next_status:=case when observed_status='missing' then 'missing' when row.provider_version<>provider_version or row.modified_time<>modified_time or coalesce(row.provider_checksum,'')<>coalesce(lower(provider_checksum),'') then 'changed' else 'active' end;
  update fp.external_sources set status=next_status,checked_at=now() where id=row.id;
  return jsonb_build_object('id',row.id,'status',next_status,'stored_version',row.provider_version,'observed_version',provider_version);
end $$;

create or replace function fp.google_drive_source_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then return '[]'::jsonb;end if;admin:=fp.is_household_admin(hid);
  return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'document_id',des.document_id,'provider_file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'modified_time',s.modified_time,'provider_version',s.provider_version,'provider_checksum',s.provider_checksum,'content_sha256',s.content_sha256,'web_view_link',s.web_view_link,'status',s.status,'checked_at',s.checked_at) order by s.added_at desc) from fp.external_sources s join fp.document_external_sources des on des.external_source_id=s.id join fp.documents d on d.id=des.document_id where s.household_id=hid and d.lifecycle_status<>'deleted' and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb);
end $$;

create or replace function fp.disconnect_google_drive() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; changed integer;
begin
  perform fp.require_aal2();select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  update fp.external_sources set status='disconnected',checked_at=now() where household_id=hid and provider='google_drive' and status<>'disconnected';get diagnostics changed=row_count;
  return jsonb_build_object('provider','google_drive','disconnected',true,'sources_affected',changed);
end $$;

create or replace function fp.document_source(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; s fp.external_sources; a fp.inbound_attachments; e fp.inbound_emails; bytes bytea; mime text; fname text;
begin
  select * into d from fp.documents where id=document and lifecycle_status<>'deleted' and (created_by=uid or fp.is_household_admin(household_id) or exists(select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=uid));if d.id is null then raise exception 'source not found' using errcode='P0002';end if;
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id where des.document_id=d.id;
  if s.id is not null then
    insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('provider','google_drive','source_status',s.status));
    return jsonb_build_object('document_id',d.id,'provider','google_drive','external_source_id',s.id,'provider_file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,'stored_checksum',s.provider_checksum,'status',s.status);
  end if;
  if d.source_attachment_id is not null then select * into a from fp.inbound_attachments where id=d.source_attachment_id and household_id=d.household_id and scan_status='clean';bytes:=a.content;mime:='application/pdf';fname:=a.file_name;
  elsif d.inbound_email_id is not null then select * into e from fp.inbound_emails where id=d.inbound_email_id and household_id=d.household_id;bytes:=e.raw_email;mime:='message/rfc822';fname:=regexp_replace(coalesce(d.source_name,'source-email'),'[^A-Za-z0-9._ -]','_','g')||'.eml';else raise exception 'source unavailable' using errcode='P0002';end if;
  if bytes is null or octet_length(bytes)>5242880 then raise exception 'source unavailable' using errcode='P0002';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('mime_type',mime,'size_bytes',octet_length(bytes)));
  return jsonb_build_object('document_id',d.id,'file_name',fname,'mime_type',mime,'size_bytes',octet_length(bytes),'sha256',encode(extensions.digest(bytes,'sha256'),'hex'),'content_base64',encode(bytes,'base64'));
end $$;

revoke all on fp.external_sources,fp.document_external_sources from public,anon,authenticated;
revoke execute on function fp.register_google_drive_source(text,text,text,bigint,timestamptz,text,text,text,text),fp.link_google_drive_source(uuid,uuid),fp.update_google_drive_source(uuid,timestamptz,text,text,text),fp.google_drive_source_summaries(),fp.disconnect_google_drive() from public,anon;
grant execute on function fp.register_google_drive_source(text,text,text,bigint,timestamptz,text,text,text,text),fp.link_google_drive_source(uuid,uuid),fp.update_google_drive_source(uuid,timestamptz,text,text,text),fp.google_drive_source_summaries(),fp.disconnect_google_drive() to authenticated;

commit;
