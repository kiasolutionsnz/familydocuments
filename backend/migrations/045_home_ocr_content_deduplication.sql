begin;

create or replace function fp.create_document_analysis_job(
  file_name text,source_mime_type text,content_base64 text,analysis_mode text,idempotency text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id();hid uuid;member_role text;bytes bytea;digest text;category_id uuid;
  d fp.documents;j fp.document_analysis_jobs;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active'
    order by joined_at,household_id limit 1 for share;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if analysis_mode not in ('document','invoice') or idempotency is null or char_length(idempotency) not between 8 and 100 then raise exception 'invalid request' using errcode='22023';end if;
  if file_name is null or char_length(trim(file_name)) not between 1 and 255 or file_name ~ '[[:cntrl:]]' then raise exception 'invalid filename' using errcode='22023';end if;
  if content_base64 is null or octet_length(content_base64)>7340032 then raise exception 'invalid file encoding' using errcode='22023';end if;
  begin bytes:=decode(regexp_replace(content_base64,'\s','','g'),'base64');exception when others then raise exception 'invalid file encoding' using errcode='22023';end;
  perform fp.validate_document_bytes(source_mime_type,bytes);
  digest:=encode(extensions.digest(bytes,'sha256'),'hex');

  -- Serialize equivalent submissions even when an older client supplies a new
  -- request ID after a timeout, refresh or file re-selection.
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||analysis_mode||':'||digest,0));
  select * into j from fp.document_analysis_jobs where household_id=hid and requested_by=uid and idempotency_key=idempotency;
  if j.id is null then
    select jobs.* into j from fp.document_analysis_jobs jobs
      join fp.documents documents on documents.id=jobs.document_id and documents.household_id=jobs.household_id
      where jobs.household_id=hid and jobs.requested_by=uid and jobs.mode=analysis_mode
        and jobs.status<>'dismissed' and documents.lifecycle_status<>'deleted' and documents.source_sha256=digest
      order by jobs.created_at desc limit 1;
  end if;
  if j.id is not null then return fp.document_analysis_job(j.id)||jsonb_build_object('duplicate',true);end if;

  select id into category_id from fp.categories where household_id=hid and lower(name) in ('other','documents') order by case when lower(name)='documents' then 0 else 1 end limit 1;
  if category_id is null then select id into category_id from fp.categories where household_id=hid order by is_system desc,name limit 1;end if;
  if category_id is null then raise exception 'no category is available' using errcode='22023';end if;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,confirmation_status,
    storage_provider,original_filename,file_size,source_status)
  values(hid,category_id,left(regexp_replace(trim(file_name),'\.[^.]+$',''),120),uid,left(trim(file_name),255),digest,source_mime_type,'confirmed',
    'home_server',left(trim(file_name),255),octet_length(bytes),'available') returning * into d;
  insert into fp.manual_document_sources(household_id,document_id,file_name,mime_type,content,sha256,created_by)
    values(hid,d.id,left(trim(file_name),255),source_mime_type,bytes,digest,uid);
  insert into fp.document_analysis_jobs(household_id,document_id,requested_by,mode,idempotency_key)
    values(hid,d.id,uid,analysis_mode,idempotency) returning * into j;
  return jsonb_build_object('job_id',j.id,'document_id',j.document_id,'status',j.status,'created_at',j.created_at,'duplicate',false);
end $$;

revoke execute on function fp.create_document_analysis_job(text,text,text,text,text) from public,anon;
grant execute on function fp.create_document_analysis_job(text,text,text,text,text) to authenticated;

commit;
