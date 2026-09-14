begin;

-- The upload reservation is the durable hand-off between Google Drive and an
-- authorised conversation. It contains metadata only; original bytes are not
-- retained in PostgreSQL. Service-role access is restricted to the gateway.
create table fp.conversation_drive_uploads(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  file_id text not null check(char_length(file_id) between 10 and 200),
  folder_id text not null check(char_length(folder_id) between 10 and 200),
  file_name text not null check(char_length(file_name) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  size_bytes bigint not null check(size_bytes between 1 and 5242880),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'reserved' check(status in ('reserved','uploaded')),
  modified_time timestamptz,
  provider_version text,
  provider_checksum text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(conversation_id,user_id,sha256),
  unique(household_id,file_id)
);
alter table fp.conversation_drive_uploads enable row level security;
alter table fp.conversation_drive_uploads force row level security;
revoke all on fp.conversation_drive_uploads from public,anon,authenticated;

alter table fp.conversation_attachments add column drive_upload_id uuid unique references fp.conversation_drive_uploads(id);
alter table fp.conversation_attachments alter column content drop not null;
alter table fp.conversation_attachments add constraint conversation_attachment_has_original
  check((content is not null and drive_upload_id is null) or (content is null and drive_upload_id is not null));

create or replace function fp.assert_conversation_drive_actor(actor uuid,family uuid,conversation uuid) returns text
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare member_role text;folder text;selected uuid;family_count integer;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select m.role into member_role from fp.conversations c join fp.members m on m.user_id=c.user_id and m.household_id=c.household_id
    where c.id=conversation and c.user_id=actor and c.household_id=family and m.status='active' for share of m;
  if member_role is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  select count(*) into family_count from fp.members where user_id=actor and status='active';
  select household_id into selected from fp.active_family_contexts where user_id=actor;
  if (selected is not null and selected<>family) or (selected is null and family_count<>1) then raise exception 'active Family changed' using errcode='PT409';end if;
  select c.provider_folder_id into folder from fp.storage_connections c join fp.google_drive_credentials cred on cred.household_id=c.household_id and cred.status='active'
    where c.household_id=family and c.provider='google_drive' and c.status='active';
  if folder is null then raise exception 'Google Drive must be connected' using errcode='P0002';end if;
  return folder;
end $$;

create or replace function fp.reserve_conversation_drive_upload(conversation uuid,actor uuid,family uuid,
  generated_file_id text,file_name text,source_mime_type text,size_bytes bigint,content_sha256 text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare folder text;stored fp.conversation_drive_uploads;
begin
  folder:=fp.assert_conversation_drive_actor(actor,family,conversation);
  if generated_file_id is null or char_length(generated_file_id) not between 10 and 200 or
    file_name is null or char_length(trim(file_name)) not between 1 and 255 or
    source_mime_type not in ('application/pdf','image/jpeg','image/png') or size_bytes not between 1 and 5242880 or
    content_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'invalid upload' using errcode='22023';end if;
  insert into fp.conversation_drive_uploads(conversation_id,household_id,user_id,file_id,folder_id,file_name,mime_type,size_bytes,sha256)
    values(conversation,family,actor,generated_file_id,folder,left(trim(file_name),255),source_mime_type,size_bytes,content_sha256)
    on conflict(conversation_id,user_id,sha256) do nothing;
  select * into stored from fp.conversation_drive_uploads where conversation_id=conversation and user_id=actor and sha256=content_sha256 for update;
  if stored.household_id<>family or stored.folder_id<>folder or stored.file_name<>left(trim(file_name),255) or
    stored.mime_type<>source_mime_type or stored.size_bytes<>size_bytes then raise exception 'upload changed' using errcode='PT409';end if;
  return jsonb_build_object('id',stored.id,'file_id',stored.file_id,'folder_id',stored.folder_id,'status',stored.status);
end $$;

create or replace function fp.finish_conversation_drive_upload(reservation uuid,actor uuid,family uuid,conversation uuid,
  google_file_id text,google_modified_time timestamptz,google_version text,google_checksum text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare folder text;stored fp.conversation_drive_uploads;attachment fp.conversation_attachments;
begin
  folder:=fp.assert_conversation_drive_actor(actor,family,conversation);
  select * into stored from fp.conversation_drive_uploads where id=reservation and conversation_id=conversation and user_id=actor and household_id=family for update;
  if stored.id is null or stored.folder_id<>folder or stored.file_id<>google_file_id or google_modified_time is null or
    google_version is null or char_length(google_version) not between 1 and 80 or
    (google_checksum is not null and lower(google_checksum) !~ '^[0-9a-f]{32}$') then raise exception 'invalid upload result' using errcode='22023';end if;
  if stored.status='uploaded' and (stored.modified_time<>google_modified_time or stored.provider_version<>google_version or stored.provider_checksum is distinct from lower(google_checksum)) then raise exception 'uploaded file changed' using errcode='PT409';end if;
  update fp.conversation_drive_uploads set status='uploaded',modified_time=google_modified_time,
    provider_version=google_version,provider_checksum=lower(google_checksum),updated_at=now() where id=stored.id;
  insert into fp.conversation_attachments(conversation_id,household_id,user_id,file_name,mime_type,content,sha256,drive_upload_id)
    values(conversation,family,actor,stored.file_name,stored.mime_type,null,stored.sha256,stored.id)
    on conflict(conversation_id,user_id,sha256) do update set drive_upload_id=excluded.drive_upload_id,
      content=null,expires_at=now()+interval '24 hours' returning * into attachment;
  return jsonb_build_object('id',attachment.id,'file_name',attachment.file_name,'mime_type',attachment.mime_type,'sha256',attachment.sha256,'expires_at',attachment.expires_at);
end $$;

-- Existing service callers can still open historical originals. New
-- conversation attachments must have a verified Drive upload reservation.
alter function fp.run_conversation_execution(uuid) rename to run_conversation_execution_before_059;
create function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.conversation_executions;uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();role text;
  p jsonb;a fp.conversation_attachments;upload fp.conversation_drive_uploads;doc fp.documents;
  category_id uuid;category_name text;source_id uuid;job fp.document_analysis_jobs;
begin
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.user_id<>uid or e.household_id<>hid then raise exception 'not authorised' using errcode='42501';end if;
  p:=e.action_parameters;
  if e.action_type not in ('save_document','request_document_ocr') then return fp.run_conversation_execution_before_059(execution);end if;
  select m.role into role from fp.members m where m.household_id=hid and m.user_id=uid and m.status='active' for share;
  if role is null or role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if e.action_type='request_document_ocr' and p?'document_id' then
    select d.* into doc from fp.documents d where d.id=(p->>'document_id')::uuid and d.household_id=hid and d.lifecycle_status<>'deleted' and
      (d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid and x.access_level in ('contribute','manage')));
    if doc.id is null then raise exception 'not authorised' using errcode='42501';end if;
    if not exists(select 1 from fp.document_external_sources x join fp.external_sources s on s.id=x.external_source_id where x.document_id=doc.id and s.household_id=hid and s.provider='google_drive' and s.status='active') then
      return fp.run_conversation_execution_before_059(execution);
    end if;
  else
    select * into a from fp.conversation_attachments where id=(p->>'attachment_id')::uuid and conversation_id=e.conversation_id and household_id=hid and user_id=uid and expires_at>now() for update;
    if a.id is null or a.drive_upload_id is null then raise exception 'Connect Google Drive and attach the file again' using errcode='P0002';end if;
    select * into upload from fp.conversation_drive_uploads where id=a.drive_upload_id and conversation_id=e.conversation_id and household_id=hid and user_id=uid and status='uploaded' for share;
    if upload.id is null then raise exception 'uploaded file unavailable' using errcode='P0002';end if;
    select d.* into doc from fp.document_external_sources x join fp.external_sources s on s.id=x.external_source_id join fp.documents d on d.id=x.document_id
      where s.household_id=hid and s.provider='google_drive' and s.provider_file_id=upload.file_id and d.lifecycle_status<>'deleted' for update of d;
  end if;
  if not exists(select 1 from fp.storage_connections c join fp.google_drive_credentials cred on cred.household_id=c.household_id and cred.status='active'
    where c.household_id=hid and c.provider='google_drive' and c.status='active' and (upload.id is null or c.provider_folder_id=upload.folder_id)) then
    raise exception 'Google Drive is unavailable' using errcode='P0002';end if;
  if e.action_type='save_document' then
    select id,name into category_id,category_name from fp.categories where household_id=hid and lower(name)=lower(trim(p->>'category_name'));
    if category_id is null and coalesce((p->>'create_category')::boolean,false) then
      if role not in ('owner','family_admin') then raise exception 'not authorised' using errcode='42501';end if;
      insert into fp.categories(household_id,name,created_by) values(hid,trim(p->>'category_name'),uid) returning id,name into category_id,category_name;
    end if;
    if category_id is null then raise exception 'category not found' using errcode='22023';end if;
  else
    select id,name into category_id,category_name from fp.categories where household_id=hid order by (lower(name)='documents') desc,is_system desc,name limit 1;
  end if;
  if doc.id is null then
    insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,confirmation_status,storage_provider,original_filename,file_size,source_status,tags)
      values(hid,category_id,left(regexp_replace(upload.file_name,'\.[^.]+$',''),160),uid,upload.file_name,upload.sha256,upload.mime_type,'confirmed','google_drive',upload.file_name,upload.size_bytes,'available',
        case when e.action_type='save_document' then coalesce(p->'tags','[]'::jsonb) else '[]'::jsonb end) returning * into doc;
    insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,provider_checksum,content_sha256,status,added_by)
      values(hid,'google_drive',upload.file_id,upload.file_name,upload.mime_type,upload.size_bytes,upload.modified_time,upload.provider_version,upload.provider_checksum,upload.sha256,'active',uid)
      returning id into source_id;
    insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(doc.id,source_id,uid);
  end if;
  if e.action_type='save_document' then
    if a.id is not null then delete from fp.conversation_attachments where id=a.id;end if;
    return jsonb_build_object('message','Saved '||doc.title||' in '||category_name||'.','document_id',doc.id,'title',doc.title,'category',category_name,'tags',doc.tags);
  end if;
  select * into job from fp.document_analysis_jobs where household_id=hid and requested_by=uid and idempotency_key=e.request_key;
  if job.id is null then
    insert into fp.document_analysis_jobs(household_id,document_id,requested_by,mode,idempotency_key)
      values(hid,doc.id,uid,p->>'mode',e.request_key) returning * into job;
  end if;
  if a.id is not null then delete from fp.conversation_attachments where id=a.id;end if;
  return jsonb_build_object('message','Your document is queued for reading.','job_id',job.id,'document_id',job.document_id,'status',job.status);
end $$;

-- Claim once via the existing lease/fencing source. The worker receives only
-- an authorised Drive reference; the original bytes are streamed from Drive
-- after the claim and discarded after OCR.
create or replace function fp.claim_document_analysis_jobs(batch_size integer default 1) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  update fp.document_analysis_jobs j set status='permanent_failed',failure_code='source_unavailable',completed_at=now(),lease_expires_at=null,lease_token=null,updated_at=now()
    where j.status in ('queued','retry_wait','processing') and (
      not exists(select 1 from fp.documents d where d.id=j.document_id and d.household_id=j.household_id and d.lifecycle_status<>'deleted') or
      not exists(select 1 from fp.members m where m.household_id=j.household_id and m.user_id=j.requested_by and m.status='active'));
  with leased as(
    select j.id from fp.document_analysis_jobs j where
      ((j.status in ('queued','retry_wait') and j.next_attempt_at<=now()) or (j.status='processing' and j.lease_expires_at<now()))
      and j.attempts<5 order by j.next_attempt_at,j.created_at for update skip locked limit least(greatest(batch_size,1),10)
  ),updated as(
    update fp.document_analysis_jobs j set status='processing',attempts=j.attempts+1,started_at=coalesce(j.started_at,now()),
      lease_expires_at=now()+interval '5 minutes',lease_token=gen_random_uuid(),updated_at=now() from leased where j.id=leased.id returning j.*
  ) select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'document_id',j.document_id,'mode',j.mode,'attempt',j.attempts,
      'lease_token',j.lease_token,'file_name',coalesce(s.file_name,es.file_name),'mime_type',coalesce(s.mime_type,es.mime_type),
      'sha256',coalesce(s.sha256,es.content_sha256),'content_base64',case when es.id is null then encode(s.content,'base64') else null end,
      'source_kind',case when es.id is null then 'legacy' else 'google_drive' end,
      'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name),'[]'::jsonb) from fp.categories c where c.household_id=j.household_id))), '[]'::jsonb)
    into result from updated j left join fp.manual_document_sources s on s.document_id=j.document_id and s.household_id=j.household_id
      left join fp.document_external_sources des on des.document_id=j.document_id
      left join fp.external_sources es on es.id=des.external_source_id and es.household_id=j.household_id and es.provider='google_drive';
  return result;
end $$;

create or replace function fp.authorize_drive_analysis_source(job uuid,worker_lease_token uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.document_analysis_jobs;source fp.external_sources;folder text;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select * into j from fp.document_analysis_jobs where id=job and status='processing' and lease_token=worker_lease_token and lease_expires_at>now();
  if j.id is null or not exists(select 1 from fp.members m where m.household_id=j.household_id and m.user_id=j.requested_by and m.status='active'
    and m.role in ('owner','family_admin','adult_member','contributor')) then raise exception 'job unavailable' using errcode='42501';end if;
  if not exists(select 1 from fp.documents d where d.id=j.document_id and d.household_id=j.household_id and d.lifecycle_status<>'deleted' and
    (d.created_by=j.requested_by or exists(select 1 from fp.members m where m.household_id=j.household_id and m.user_id=j.requested_by and m.status='active' and m.role in ('owner','family_admin')) or
     exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=j.requested_by and p.access_level in ('contribute','manage')))) then
    raise exception 'document access revoked' using errcode='42501';end if;
  select s.* into source from fp.document_external_sources x join fp.external_sources s on s.id=x.external_source_id
    where x.document_id=j.document_id and s.household_id=j.household_id and s.provider='google_drive' and s.status='active';
  select c.provider_folder_id into folder from fp.storage_connections c join fp.google_drive_credentials cred on cred.household_id=c.household_id and cred.status='active'
    where c.household_id=j.household_id and c.provider='google_drive' and c.status='active';
  if source.id is null or folder is null then raise exception 'Drive source unavailable' using errcode='P0002';end if;
  return jsonb_build_object('household_id',j.household_id,'file_id',source.provider_file_id,'folder_id',folder,
    'mime_type',source.mime_type,'file_name',source.file_name,'size_bytes',source.size_bytes,'sha256',source.content_sha256);
end $$;

revoke all on function fp.assert_conversation_drive_actor(uuid,uuid,uuid),
  fp.reserve_conversation_drive_upload(uuid,uuid,uuid,text,text,text,bigint,text),
  fp.finish_conversation_drive_upload(uuid,uuid,uuid,uuid,text,timestamptz,text,text),
  fp.run_conversation_execution_before_059(uuid),fp.run_conversation_execution(uuid),
  fp.authorize_drive_analysis_source(uuid,uuid) from public,anon,authenticated;
grant execute on function fp.assert_conversation_drive_actor(uuid,uuid,uuid),
  fp.reserve_conversation_drive_upload(uuid,uuid,uuid,text,text,text,bigint,text),
  fp.finish_conversation_drive_upload(uuid,uuid,uuid,uuid,text,timestamptz,text,text),
  fp.authorize_drive_analysis_source(uuid,uuid) to service_role;

commit;
