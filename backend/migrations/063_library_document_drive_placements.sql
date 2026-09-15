begin;

-- One confirmed Library destination per original. The placement is metadata
-- only; Google Drive remains the source of truth for the file itself.
create table if not exists fp.library_document_drive_placements(
  document_id uuid primary key references fp.documents(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  node_id uuid not null references fp.library_drive_nodes(id) on delete restrict,
  provider_folder_id text not null check(char_length(provider_folder_id) between 10 and 200),
  placed_by uuid not null,
  placed_at timestamptz not null default now()
);
alter table fp.library_document_drive_placements enable row level security;
alter table fp.library_document_drive_placements force row level security;
revoke all on fp.library_document_drive_placements from public,anon,authenticated;

create or replace function fp.record_library_drive_placement(target_household uuid,actor uuid,document uuid,node_folder text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare d fp.documents;node fp.library_drive_nodes;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' or not exists(select 1 from fp.members where household_id=target_household and user_id=actor and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  select * into d from fp.documents where id=document and household_id=target_household and lifecycle_status<>'deleted';
  select * into node from fp.library_drive_nodes where household_id=target_household and provider_folder_id=node_folder and status='active';
  if d.id is null or node.id is null or not (d.created_by=actor or fp.is_household_admin(target_household) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=actor and p.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.library_document_drive_placements(document_id,household_id,node_id,provider_folder_id,placed_by)
  values(d.id,target_household,node.id,node.provider_folder_id,actor)
  on conflict(document_id) do update set node_id=excluded.node_id,provider_folder_id=excluded.provider_folder_id,placed_by=excluded.placed_by,placed_at=now();
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
  values(target_household,actor,d.id,'library_drive_placed',jsonb_build_object('folder_id',node.provider_folder_id,'node_key',node.node_key));
  return jsonb_build_object('document_id',d.id,'provider_folder_id',node.provider_folder_id);
end$$;

create or replace function fp.authorize_google_drive_document(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();d fp.documents;s fp.external_sources;connection fp.storage_connections;placement fp.library_document_drive_placements;
begin
  select candidate.* into d from fp.documents candidate where candidate.id=document and candidate.household_id=hid and candidate.lifecycle_status<>'deleted'
    and (candidate.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions p where p.document_id=candidate.id and p.member_user_id=uid));
  if d.id is null then raise exception 'source not found' using errcode='P0002';end if;
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id where des.document_id=d.id and es.household_id=hid and es.provider='google_drive';
  if s.id is null or s.status='disconnected' then raise exception 'source not found' using errcode='P0002';end if;
  select * into connection from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if connection.id is null then raise exception 'Google Drive is not connected' using errcode='P0002';end if;
  select * into placement from fp.library_document_drive_placements where document_id=d.id and household_id=hid;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(hid,uid,d.id,'source_opened',jsonb_build_object('provider','google_drive','source_status',s.status));
  return jsonb_build_object('household_id',hid,'source_id',s.id,'file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_checksum',s.provider_checksum,'status',s.status,'folder_id',coalesce(placement.provider_folder_id,connection.provider_folder_id));
end$$;

revoke execute on function fp.record_library_drive_placement(uuid,uuid,uuid,text),fp.authorize_google_drive_document(uuid) from public,anon,authenticated;
grant execute on function fp.record_library_drive_placement(uuid,uuid,uuid,text) to service_role;
grant execute on function fp.authorize_google_drive_document(uuid) to authenticated;

commit;
