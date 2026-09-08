begin;

alter table fp.documents add column if not exists storage_provider text;
alter table fp.documents add column if not exists storage_key text;
alter table fp.documents add column if not exists original_filename text;
alter table fp.documents add column if not exists file_size bigint;
alter table fp.documents add column if not exists source_status text not null default 'unavailable'
  check(source_status in ('available','unavailable','changed','moved','missing','inaccessible','disconnected'));

create table if not exists fp.ocr_intake_drafts(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  owner_user_id uuid not null,
  category_id uuid not null references fp.categories(id),
  original_filename text not null check(char_length(original_filename) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  file_size bigint not null check(file_size between 1 and 5242880),
  checksum text not null check(checksum ~ '^[0-9a-f]{64}$'),
  content bytea not null,
  status text not null default 'processing'
    check(status in ('processing','review_required','confirmed','rejected','failed')),
  extracted_text text,
  ocr_confidence numeric(5,4),
  confirmed_document_id uuid unique references fp.documents(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now()+interval '24 hours'),
  check(octet_length(content)=file_size or (status in ('confirmed','rejected','failed') and octet_length(content)=0))
);
alter table fp.ocr_intake_drafts enable row level security;
alter table fp.ocr_intake_drafts force row level security;
revoke all on fp.ocr_intake_drafts from public,anon,authenticated;

alter table fp.security_audit_events drop constraint if exists security_audit_events_event_type_check;
alter table fp.security_audit_events add constraint security_audit_events_event_type_check check(event_type in (
  'source_opened','document_purged','member_role_changed','member_suspended','member_activated','member_removed',
  'ownership_transferred','invitation_revoked','ocr_intake_confirmed','ocr_intake_rejected'
));

-- Resolve tenancy from the session, never from a caller-supplied household/user ID.
-- Hold the membership stable until the mutation commits, including role changes.
create or replace function fp.require_ocr_intake_writer() returns uuid
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid;member_role text;
begin
  select household_id,role into hid,member_role from fp.members
  where user_id=fp.current_user_id() and status='active' order by joined_at,household_id limit 1 for share;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then
    raise exception 'not authorised' using errcode='42501';
  end if;
  return hid;
end $$;

create or replace function fp.validate_document_bytes(source_mime_type text,bytes bytea) returns void
language plpgsql immutable set search_path=pg_catalog as $$
begin
  if source_mime_type is null or bytes is null or source_mime_type not in ('application/pdf','image/jpeg','image/png') or octet_length(bytes) not between 1 and 5242880 then
    raise exception 'invalid document' using errcode='22023';
  end if;
  if source_mime_type='application/pdf' and substring(bytes from 1 for 5)<>decode('255044462d','hex') then raise exception 'invalid PDF' using errcode='22023';end if;
  if source_mime_type='image/jpeg' and substring(bytes from 1 for 3)<>decode('ffd8ff','hex') then raise exception 'invalid JPEG' using errcode='22023';end if;
  if source_mime_type='image/png' and substring(bytes from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'invalid PNG' using errcode='22023';end if;
end $$;

create or replace function fp.create_ocr_intake_draft(file_name text,source_mime_type text,content_base64 text,category uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;bytes bytea;digest text;draft fp.ocr_intake_drafts;
begin
  hid:=fp.require_ocr_intake_writer();
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023';end if;
  if file_name is null or char_length(trim(file_name)) not between 1 and 255 or file_name ~ '[[:cntrl:]]' then raise exception 'invalid filename' using errcode='22023';end if;
  if content_base64 is null or octet_length(content_base64)>7340032 then raise exception 'invalid file encoding' using errcode='22023';end if;
  begin bytes:=decode(regexp_replace(content_base64,'\s','','g'),'base64');exception when others then raise exception 'invalid file encoding' using errcode='22023';end;
  perform fp.validate_document_bytes(source_mime_type,bytes);
  digest:=encode(extensions.digest(bytes,'sha256'),'hex');
  insert into fp.ocr_intake_drafts(household_id,owner_user_id,category_id,original_filename,mime_type,file_size,checksum,content)
  values(hid,uid,category,left(trim(file_name),255),source_mime_type,octet_length(bytes),digest,bytes) returning * into draft;
  return jsonb_build_object('draft_id',draft.id,'status',draft.status,'storage_provider','home_server','storage_key','ocr-draft/'||draft.id::text,
    'original_filename',draft.original_filename,'mime_type',draft.mime_type,'file_size',draft.file_size,'checksum',draft.checksum);
end $$;

create or replace function fp.record_ocr_intake_result(draft uuid,confirmed_text text,mean_confidence numeric) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.ocr_intake_drafts;
begin
  hid:=fp.require_ocr_intake_writer();
  select * into row from fp.ocr_intake_drafts where id=draft and household_id=hid and owner_user_id=uid for update;
  if row.id is null then raise exception 'not authorised' using errcode='42501';end if;
  if row.status not in ('processing','review_required') or row.expires_at<=now() then raise exception 'draft unavailable' using errcode='PT404';end if;
  if confirmed_text is null or char_length(confirmed_text) not between 3 and 100000 or mean_confidence is null or mean_confidence<0 or mean_confidence>1 then raise exception 'invalid extraction' using errcode='22023';end if;
  if row.status='review_required' then
    if confirmed_text is distinct from row.extracted_text or round(mean_confidence,4) is distinct from row.ocr_confidence then raise exception 'extraction already recorded' using errcode='22023';end if;
  else
    update fp.ocr_intake_drafts set extracted_text=confirmed_text,ocr_confidence=round(mean_confidence,4),status='review_required',updated_at=now() where id=row.id;
  end if;
  return jsonb_build_object('draft_id',row.id,'status','review_required','mean_confidence',round(mean_confidence,4));
end $$;

create or replace function fp.confirm_ocr_intake(
  draft uuid,document_title text,category uuid,confirmed_text text,confirmed_document_type text,confirmed_provider text,
  confirmed_critical_date date default null,mean_confidence numeric default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.ocr_intake_drafts;d fp.documents;rid uuid;
begin
  hid:=fp.require_ocr_intake_writer();
  select * into row from fp.ocr_intake_drafts where id=draft and household_id=hid and owner_user_id=uid for update;
  if row.id is null then raise exception 'not authorised' using errcode='42501';end if;
  if row.status='confirmed' and row.confirmed_document_id is not null then
    select * into d from fp.documents where id=row.confirmed_document_id and household_id=hid and created_by=uid and lifecycle_status<>'deleted';
    if d.id is null then raise exception 'draft unavailable' using errcode='PT404';end if;
    select id into rid from fp.reminders where document_id=d.id order by created_at limit 1;
    return jsonb_build_object('document_id',d.id,'reminder_id',rid,'status','confirmed','duplicate',true);
  end if;
  if row.status<>'review_required' or row.expires_at<=now() then raise exception 'draft unavailable' using errcode='PT404';end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023';end if;
  if document_title is null or char_length(trim(document_title)) not between 1 and 120
    or confirmed_text is distinct from row.extracted_text or mean_confidence is null or mean_confidence<0 or mean_confidence>1
    or round(mean_confidence,4) is distinct from row.ocr_confidence then raise exception 'invalid confirmation' using errcode='22023';end if;
  perform fp.validate_document_bytes(row.mime_type,row.content);
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,extracted_text,document_type,provider_name,critical_date,ocr_confidence,confirmation_status,
    storage_provider,storage_key,original_filename,file_size,source_status)
  values(hid,category,trim(document_title),uid,row.original_filename,row.checksum,row.mime_type,row.extracted_text,left(trim(confirmed_document_type),80),nullif(left(trim(confirmed_provider),120),''),confirmed_critical_date,row.ocr_confidence,'confirmed',
    'home_server','manual/'||row.id::text,row.original_filename,row.file_size,'available') returning * into d;
  insert into fp.manual_document_sources(household_id,document_id,file_name,mime_type,content,sha256,created_by)
  values(hid,d.id,row.original_filename,row.mime_type,row.content,row.checksum,uid);
  if confirmed_critical_date is not null then
    insert into fp.reminders(household_id,document_id,title,due_at,created_by) values(hid,d.id,d.title||' — check or renew',confirmed_critical_date,uid) returning id into rid;
  end if;
  update fp.ocr_intake_drafts set status='confirmed',confirmed_document_id=d.id,content=''::bytea,updated_at=now() where id=row.id;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
  values(hid,uid,d.id,'ocr_intake_confirmed',jsonb_build_object('draft_id',row.id,'reminder_id',rid));
  return jsonb_build_object('document_id',d.id,'reminder_id',rid,'status','confirmed','duplicate',false);
end $$;

create or replace function fp.reject_ocr_intake(draft uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.ocr_intake_drafts;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  select * into row from fp.ocr_intake_drafts where id=draft and household_id=hid and owner_user_id=uid for update;
  if row.id is null then raise exception 'not authorised' using errcode='42501';end if;
  if row.status='confirmed' then raise exception 'draft unavailable' using errcode='PT404';end if;
  if row.status<>'rejected' then
    update fp.ocr_intake_drafts set status='rejected',content=''::bytea,extracted_text=null,ocr_confidence=null,updated_at=now() where id=row.id;
    insert into fp.security_audit_events(household_id,actor_user_id,event_type,details)
    values(hid,uid,'ocr_intake_rejected',jsonb_build_object('draft_id',row.id));
  end if;
  return jsonb_build_object('draft_id',draft,'status','rejected');
end $$;

-- A source is never authorised merely because its creator or a stale permission
-- row matches the caller. Active membership in that document's family is needed.
create or replace function fp.authorized_source_document(document uuid) returns fp.documents
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();row fp.documents;
begin
  select d.* into row from fp.documents d
  where d.id=document and d.lifecycle_status<>'deleted' and fp.is_active_member(d.household_id)
    and (d.created_by=uid or fp.is_household_admin(d.household_id)
      or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid));
  if row.id is null then raise exception 'source not found' using errcode='PT404';end if;
  return row;
end $$;

create or replace function fp.document_source(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();d fp.documents;s fp.external_sources;a fp.inbound_attachments;e fp.inbound_emails;m fp.manual_document_sources;bytes bytea;mime text;fname text;
begin
  d:=fp.authorized_source_document(document);
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id
  where des.document_id=d.id and es.household_id=d.household_id;
  if s.id is not null then
    if s.status in ('disconnected','missing') then raise exception 'source unavailable' using errcode='PT404';end if;
    return jsonb_build_object('document_id',d.id,'provider','google_drive','external_source_id',s.id,'provider_file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,'stored_checksum',s.provider_checksum,'status',s.status);
  end if;
  select * into m from fp.manual_document_sources where document_id=d.id and household_id=d.household_id;
  if m.id is not null then bytes:=m.content;mime:=m.mime_type;fname:=m.file_name;
  elsif d.source_attachment_id is not null then
    select * into a from fp.inbound_attachments where id=d.source_attachment_id and household_id=d.household_id and scan_status='clean';bytes:=a.content;mime:='application/pdf';fname:=a.file_name;
  elsif d.inbound_email_id is not null then
    select * into e from fp.inbound_emails where id=d.inbound_email_id and household_id=d.household_id;bytes:=e.raw_email;mime:='message/rfc822';fname:=regexp_replace(coalesce(d.source_name,'source-email'),'[^A-Za-z0-9._ -]','_','g')||'.eml';
  else raise exception 'source unavailable' using errcode='PT404';end if;
  if bytes is null or octet_length(bytes) not between 1 and 5242880 then raise exception 'source unavailable' using errcode='PT404';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
  values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('mime_type',mime,'size_bytes',octet_length(bytes)));
  return jsonb_build_object('document_id',d.id,'file_name',fname,'mime_type',mime,'size_bytes',octet_length(bytes),'sha256',encode(extensions.digest(bytes,'sha256'),'hex'),'content_base64',encode(bytes,'base64'));
end $$;

create or replace function fp.authorize_google_drive_document(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();d fp.documents;s fp.external_sources;connection fp.storage_connections;
begin
  d:=fp.authorized_source_document(document);
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id
  where des.document_id=d.id and es.provider='google_drive' and es.household_id=d.household_id;
  if s.id is null or s.status in ('disconnected','missing') then raise exception 'source unavailable' using errcode='PT404';end if;
  select * into connection from fp.storage_connections where household_id=d.household_id and provider='google_drive' and status='active';
  if connection.id is null then raise exception 'Google Drive is not connected' using errcode='PT404';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details)
  values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('provider','google_drive','source_status',s.status));
  return jsonb_build_object('household_id',d.household_id,'source_id',s.id,'file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,'stored_checksum',s.provider_checksum,'status',s.status,'folder_id',connection.provider_folder_id);
end $$;

-- Maintenance entry point: call from the service-role retention worker. It is
-- deliberately not granted to browser roles and never touches confirmed sources.
create or replace function fp.expire_ocr_intake_drafts() returns integer
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then
    raise exception 'not authorised' using errcode='42501';
  end if;
  update fp.ocr_intake_drafts set status='failed',content=''::bytea,extracted_text=null,ocr_confidence=null,updated_at=now()
  where status in ('processing','review_required') and expires_at<=now();
  get diagnostics changed=row_count;
  return changed;
end $$;

create or replace function fp.sync_manual_source_metadata() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if tg_op='DELETE' then
    update fp.documents set source_status='unavailable'
    where id=old.document_id and storage_provider='home_server' and storage_key='manual/'||old.id::text;
    return old;
  end if;
  if not exists(select 1 from fp.documents where id=new.document_id and household_id=new.household_id) then
    raise exception 'source household mismatch' using errcode='42501';
  end if;
  update fp.documents set storage_provider='home_server',storage_key='manual/'||new.id::text,original_filename=new.file_name,file_size=octet_length(new.content),source_status='available' where id=new.document_id;
  return new;
end $$;
drop trigger if exists manual_source_metadata on fp.manual_document_sources;
create trigger manual_source_metadata after insert or update of file_name,content,household_id,document_id on fp.manual_document_sources for each row execute function fp.sync_manual_source_metadata();
drop trigger if exists manual_source_removed_metadata on fp.manual_document_sources;
create trigger manual_source_removed_metadata after delete on fp.manual_document_sources for each row execute function fp.sync_manual_source_metadata();

create or replace function fp.sync_external_source_metadata() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare source fp.external_sources;
begin
  select * into source from fp.external_sources where id=new.external_source_id;
  if not exists(select 1 from fp.documents where id=new.document_id and household_id=source.household_id) then
    raise exception 'source household mismatch' using errcode='42501';
  end if;
  update fp.documents set storage_provider=source.provider,storage_key=source.provider_file_id,original_filename=source.file_name,file_size=source.size_bytes,
    source_status=case when source.status='active' then 'available' else source.status end where id=new.document_id;
  return new;
end $$;
drop trigger if exists external_source_metadata on fp.document_external_sources;
create trigger external_source_metadata after insert or update of external_source_id,document_id on fp.document_external_sources for each row execute function fp.sync_external_source_metadata();

create or replace function fp.refresh_external_source_metadata() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  update fp.documents d set original_filename=new.file_name,file_size=new.size_bytes,
    source_status=case when new.status='active' then 'available' else new.status end
  from fp.document_external_sources link where link.document_id=d.id and link.external_source_id=new.id;
  return new;
end $$;
drop trigger if exists external_source_refresh_metadata on fp.external_sources;
create trigger external_source_refresh_metadata after update of file_name,size_bytes,status on fp.external_sources for each row execute function fp.refresh_external_source_metadata();

update fp.documents d set storage_provider='home_server',storage_key='manual/'||m.id::text,original_filename=m.file_name,file_size=octet_length(m.content),source_status='available'
from fp.manual_document_sources m where m.document_id=d.id;
update fp.documents d set storage_provider='google_drive',storage_key=e.provider_file_id,original_filename=e.file_name,file_size=e.size_bytes,source_status=case when e.status='active' then 'available' else e.status end
from fp.document_external_sources x join fp.external_sources e on e.id=x.external_source_id where x.document_id=d.id;
update fp.documents d set storage_provider='home_server',storage_key='attachment/'||a.id::text,original_filename=a.file_name,file_size=octet_length(a.content),source_status=case when a.content is not null and a.scan_status='clean' then 'available' else 'unavailable' end
from fp.inbound_attachments a where a.id=d.source_attachment_id;
update fp.documents d set storage_provider='home_server',storage_key='email/'||e.id::text,original_filename=coalesce(d.source_name,'source-email.eml'),file_size=octet_length(e.raw_email),source_status=case when e.raw_email is not null then 'available' else 'unavailable' end
from fp.inbound_emails e where e.id=d.inbound_email_id and d.source_attachment_id is null;

revoke execute on function fp.validate_document_bytes(text,bytea),fp.sync_manual_source_metadata(),fp.sync_external_source_metadata(),fp.refresh_external_source_metadata(),fp.create_ocr_intake_draft(text,text,text,uuid),fp.record_ocr_intake_result(uuid,text,numeric),fp.confirm_ocr_intake(uuid,text,uuid,text,text,text,date,numeric),fp.reject_ocr_intake(uuid) from public,anon;
revoke execute on function fp.require_ocr_intake_writer(),fp.authorized_source_document(uuid),fp.expire_ocr_intake_drafts() from public,anon,authenticated;
grant execute on function fp.expire_ocr_intake_drafts() to service_role;
grant execute on function fp.create_ocr_intake_draft(text,text,text,uuid),fp.record_ocr_intake_result(uuid,text,numeric),fp.confirm_ocr_intake(uuid,text,uuid,text,text,text,date,numeric),fp.reject_ocr_intake(uuid) to authenticated;

commit;
