begin;

-- Inbox originals are quarantined only until review and malware scanning. Once
-- accepted, the verified original is committed to the selected Family Drive;
-- PostgreSQL retains metadata, audit links and the email review record only.
create table fp.inbox_drive_uploads(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  inbound_email_id uuid not null references fp.inbound_emails(id) on delete cascade,
  attachment_id uuid not null references fp.inbound_attachments(id) on delete cascade,
  actor_user_id uuid not null,
  category_id uuid not null references fp.categories(id),
  request_id text not null check(char_length(request_id) between 8 and 100),
  tags jsonb not null default '[]'::jsonb check(jsonb_typeof(tags)='array'),
  request_ocr boolean not null default false,
  file_id text not null check(char_length(file_id) between 10 and 200),
  folder_id text not null check(char_length(folder_id) between 10 and 200),
  file_name text not null check(char_length(file_name) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  size_bytes bigint not null check(size_bytes between 1 and 5242880),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'reserved' check(status in ('reserved','uploaded')),
  modified_time timestamptz, provider_version text, provider_checksum text,
  result jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(attachment_id), unique(household_id,file_id), unique(household_id,actor_user_id,request_id)
);
alter table fp.inbox_drive_uploads enable row level security;
alter table fp.inbox_drive_uploads force row level security;
revoke all on fp.inbox_drive_uploads from public,anon,authenticated;

-- A scanned attachment may be blanked only after its Drive metadata has been
-- durably recorded. The check remains strict for every other scan outcome.
alter table fp.inbound_attachments drop constraint if exists inbound_attachments_content_state_check;
alter table fp.inbound_attachments add constraint inbound_attachments_content_state_check check(
  (scan_status='clean' and content_sha256 is not null and quarantined_content is null)
  or (scan_status='pending' and content is null)
  or (scan_status in ('rejected','malformed','unsupported','error') and content is null and quarantined_content is null)
);

create or replace function fp.assert_inbox_drive_actor(actor uuid,family uuid) returns text
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare selected uuid; family_count integer; member_role text; folder text;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select role into member_role from fp.members where household_id=family and user_id=actor and status='active';
  if member_role is null or not fp.inbox_can_edit(member_role) then raise exception 'not authorised' using errcode='42501';end if;
  select count(*) into family_count from fp.members where user_id=actor and status='active';
  select household_id into selected from fp.active_family_contexts where user_id=actor;
  if (selected is not null and selected<>family) or (selected is null and family_count<>1) then raise exception 'active Family changed' using errcode='PT409';end if;
  select c.provider_folder_id into folder from fp.storage_connections c join fp.google_drive_credentials g on g.household_id=c.household_id and g.status='active' where c.household_id=family and c.provider='google_drive' and c.status='active';
  if folder is null then raise exception 'Google Drive must be connected' using errcode='P0002';end if;
  return folder;
end$$;

create or replace function fp.reserve_inbox_drive_upload(message uuid,attachment uuid,category uuid,selected_tags jsonb,request_id text,request_ocr boolean,actor uuid,family uuid,generated_file_id text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare root text;e fp.inbound_emails;a fp.inbound_attachments;row fp.inbox_drive_uploads;tags jsonb;
begin
  root:=fp.assert_inbox_drive_actor(actor,family);
  if generated_file_id is null or char_length(generated_file_id) not between 10 and 200 or request_id is null or char_length(request_id) not between 8 and 100 or jsonb_typeof(coalesce(selected_tags,'[]'::jsonb))<>'array' then raise exception 'invalid upload' using errcode='22023';end if;
  select * into e from fp.inbound_emails where id=message and household_id=family and deleted_at is null;
  select * into a from fp.inbound_attachments where id=attachment and inbound_email_id=e.id and household_id=family and scan_status='clean' for update;
  if e.id is null or a.id is null or a.content is null then raise exception 'attachment not available' using errcode='PT404';end if;
  if not exists(select 1 from fp.categories where id=category and household_id=family) then raise exception 'invalid category' using errcode='42501';end if;
  perform fp.validate_document_bytes(a.claimed_content_type,a.content);
  select coalesce(jsonb_agg(value order by value),'[]'::jsonb) into tags from (select distinct lower(trim(value)) value from jsonb_array_elements_text(coalesce(selected_tags,'[]'::jsonb)) where char_length(trim(value)) between 1 and 40 limit 12)t;
  insert into fp.inbox_drive_uploads(household_id,inbound_email_id,attachment_id,actor_user_id,category_id,request_id,tags,request_ocr,file_id,folder_id,file_name,mime_type,size_bytes,sha256)
  values(family,e.id,a.id,actor,category,request_id,tags,request_ocr,generated_file_id,root,a.file_name,a.claimed_content_type,octet_length(a.content),a.content_sha256)
  on conflict(attachment_id) do nothing;
  select * into row from fp.inbox_drive_uploads where attachment_id=a.id for update;
  if row.household_id<>family or row.actor_user_id<>actor or row.category_id<>category or row.request_id<>request_id or row.sha256<>a.content_sha256 or row.folder_id<>root then raise exception 'upload changed' using errcode='PT409';end if;
  return jsonb_build_object('id',row.id,'file_id',row.file_id,'folder_id',row.folder_id,'status',row.status,'file_name',row.file_name,'mime_type',row.mime_type,'size_bytes',row.size_bytes,'sha256',row.sha256,'content_base64',encode(a.content,'base64'));
end$$;

create or replace function fp.finish_inbox_drive_upload(reservation uuid,actor uuid,family uuid,google_file_id text,google_modified_time timestamptz,google_version text,google_checksum text,request_ocr boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare root text;row fp.inbox_drive_uploads;d fp.documents;s uuid;j fp.document_analysis_jobs;outcome jsonb;
begin
  root:=fp.assert_inbox_drive_actor(actor,family);
  select * into row from fp.inbox_drive_uploads where id=reservation and household_id=family and actor_user_id=actor for update;
  if row.id is null or row.folder_id<>root or row.file_id<>google_file_id or google_modified_time is null or google_version is null or char_length(google_version) not between 1 and 80 or (google_checksum is not null and lower(google_checksum)!~'^[0-9a-f]{32}$') then raise exception 'invalid upload result' using errcode='22023';end if;
  if row.status='uploaded' then return row.result||jsonb_build_object('duplicate',true);end if;
  update fp.inbox_drive_uploads set status='uploaded',modified_time=google_modified_time,provider_version=google_version,provider_checksum=lower(google_checksum),request_ocr=finish_inbox_drive_upload.request_ocr,updated_at=now() where id=row.id;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,confirmation_status,storage_provider,original_filename,file_size,source_status,inbound_email_id,source_attachment_id,tags)
  values(family,row.category_id,left(regexp_replace(row.file_name,'\.[^.]+$',''),160),actor,row.file_name,row.sha256,row.mime_type,'confirmed','google_drive',row.file_name,row.size_bytes,'available',row.inbound_email_id,row.attachment_id,row.tags) returning * into d;
  insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,provider_checksum,content_sha256,status,added_by)
  values(family,'google_drive',row.file_id,row.file_name,row.mime_type,row.size_bytes,google_modified_time,google_version,lower(google_checksum),row.sha256,'active',actor) returning id into s;
  insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(d.id,s,actor);
  if request_ocr then insert into fp.document_analysis_jobs(household_id,document_id,requested_by,mode,idempotency_key) values(family,d.id,actor,case when lower(row.file_name) like '%invoice%' or lower(row.file_name) like '%bill%' then 'invoice' else 'document' end,row.request_id) returning * into j;end if;
  outcome:=jsonb_build_object('document_id',d.id,'title',d.title,'category_id',row.category_id,'tags',row.tags,'job_id',j.id,'job_status',j.status,'duplicate',false);
  insert into fp.inbox_actions(household_id,inbound_email_id,attachment_id,actor_user_id,action_type,request_id,result) values(family,row.inbound_email_id,row.attachment_id,actor,case when request_ocr then 'ocr_requested' else 'document_saved' end,row.request_id,outcome);
  update fp.inbox_drive_uploads set result=outcome where id=row.id;
  update fp.inbound_attachments set content=null where id=row.attachment_id and content_sha256=row.sha256;
  return outcome;
end$$;

-- Prevent a browser from bypassing the verified gateway path.
create or replace function fp.inbox_save_attachment(message uuid,attachment uuid,category uuid,selected_tags jsonb,request_id text,request_ocr boolean default false) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$ begin raise exception 'save through the Drive gateway' using errcode='P0002'; end$$;

revoke execute on function fp.assert_inbox_drive_actor(uuid,uuid),fp.reserve_inbox_drive_upload(uuid,uuid,uuid,jsonb,text,boolean,uuid,uuid,text),fp.finish_inbox_drive_upload(uuid,uuid,uuid,text,timestamptz,text,text,boolean) from public,anon,authenticated;
grant execute on function fp.reserve_inbox_drive_upload(uuid,uuid,uuid,jsonb,text,boolean,uuid,uuid,text),fp.finish_inbox_drive_upload(uuid,uuid,uuid,text,timestamptz,text,text,boolean) to service_role;
commit;
