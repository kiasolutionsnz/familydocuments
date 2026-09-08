begin;

create table if not exists fp.manual_document_sources (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  document_id uuid not null unique references fp.documents(id) on delete cascade,
  file_name text not null check(char_length(file_name) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  content bytea not null check(octet_length(content) between 1 and 5242880),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  created_by uuid not null,
  created_at timestamptz not null default now()
);
alter table fp.manual_document_sources enable row level security;
alter table fp.manual_document_sources force row level security;
revoke all on fp.manual_document_sources from public,anon,authenticated;

create or replace function fp.create_manual_document(
  document_title text, category uuid, file_name text, source_mime_type text,
  content_base64 text, document_date date default null, reminder_date date default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;bytes bytea;digest text;d fp.documents;rid uuid;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023';end if;
  if source_mime_type not in ('application/pdf','image/jpeg','image/png') or char_length(trim(document_title)) not between 1 and 160 then raise exception 'invalid document' using errcode='22023';end if;
  begin bytes:=decode(regexp_replace(content_base64,'\s','','g'),'base64');exception when others then raise exception 'invalid file encoding' using errcode='22023';end;
  if octet_length(bytes) not between 1 and 5242880 then raise exception 'file must be smaller than 5 MB' using errcode='22023';end if;
  if source_mime_type='application/pdf' and substring(bytes from 1 for 5)<>decode('255044462d','hex') then raise exception 'invalid PDF' using errcode='22023';end if;
  if source_mime_type='image/jpeg' and substring(bytes from 1 for 3)<>decode('ffd8ff','hex') then raise exception 'invalid JPEG' using errcode='22023';end if;
  if source_mime_type='image/png' and substring(bytes from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'invalid PNG' using errcode='22023';end if;
  digest:=encode(extensions.digest(bytes,'sha256'),'hex');
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,document_date,critical_date,confirmation_status)
  values(hid,category,trim(document_title),uid,left(trim(file_name),255),digest,source_mime_type,document_date,reminder_date,'confirmed') returning * into d;
  insert into fp.manual_document_sources(household_id,document_id,file_name,mime_type,content,sha256,created_by) values(hid,d.id,left(trim(file_name),255),source_mime_type,bytes,digest,uid);
  if reminder_date is not null then insert into fp.reminders(household_id,document_id,title,due_at,created_by) values(hid,d.id,d.title||' — reminder',reminder_date,uid) returning id into rid;end if;
  return jsonb_build_object('document_id',d.id,'title',d.title,'reminder_id',rid,'sha256',digest);
end $$;

create or replace function fp.document_source(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();d fp.documents;s fp.external_sources;a fp.inbound_attachments;e fp.inbound_emails;m fp.manual_document_sources;bytes bytea;mime text;fname text;
begin
  select * into d from fp.documents where id=document and lifecycle_status<>'deleted' and (created_by=uid or fp.is_household_admin(household_id) or exists(select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=uid));if d.id is null then raise exception 'source not found' using errcode='P0002';end if;
  select es.* into s from fp.document_external_sources des join fp.external_sources es on es.id=des.external_source_id where des.document_id=d.id;
  if s.id is not null then return jsonb_build_object('document_id',d.id,'provider','google_drive','external_source_id',s.id,'provider_file_id',s.provider_file_id,'file_name',s.file_name,'mime_type',s.mime_type,'size_bytes',s.size_bytes,'stored_version',s.provider_version,'stored_modified_time',s.modified_time,'stored_checksum',s.provider_checksum,'status',s.status);end if;
  select * into m from fp.manual_document_sources where document_id=d.id and household_id=d.household_id;
  if m.id is not null then bytes:=m.content;mime:=m.mime_type;fname:=m.file_name;
  elsif d.source_attachment_id is not null then select * into a from fp.inbound_attachments where id=d.source_attachment_id and household_id=d.household_id and scan_status='clean';bytes:=a.content;mime:='application/pdf';fname:=a.file_name;
  elsif d.inbound_email_id is not null then select * into e from fp.inbound_emails where id=d.inbound_email_id and household_id=d.household_id;bytes:=e.raw_email;mime:='message/rfc822';fname:=regexp_replace(coalesce(d.source_name,'source-email'),'[^A-Za-z0-9._ -]','_','g')||'.eml';else raise exception 'source unavailable' using errcode='P0002';end if;
  if bytes is null or octet_length(bytes)>5242880 then raise exception 'source unavailable' using errcode='P0002';end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('mime_type',mime,'size_bytes',octet_length(bytes)));
  return jsonb_build_object('document_id',d.id,'file_name',fname,'mime_type',mime,'size_bytes',octet_length(bytes),'sha256',encode(extensions.digest(bytes,'sha256'),'hex'),'content_base64',encode(bytes,'base64'));
end $$;

revoke execute on function fp.create_manual_document(text,uuid,text,text,text,date,date) from public,anon;
grant execute on function fp.create_manual_document(text,uuid,text,text,text,date,date) to authenticated;
commit;
