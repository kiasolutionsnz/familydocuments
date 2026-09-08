begin;

-- Standalone reminders keep the existing reminder model; only the document
-- relationship becomes optional. Document-linked uniqueness remains intact.
alter table fp.reminders alter column document_id drop not null;
alter table fp.reminders add column if not exists client_request_id text;
create unique index if not exists reminders_client_request_unique
  on fp.reminders(household_id,created_by,client_request_id)
  where client_request_id is not null;

drop policy if exists reminders_authorised_read on fp.reminders;
create policy reminders_authorised_read on fp.reminders for select using (
  fp.is_active_member(household_id) and (
    (document_id is null and (created_by=fp.current_user_id() or audience='family')) or
    exists(select 1 from fp.documents d where d.id=fp.reminders.document_id and d.household_id=fp.reminders.household_id and (
      d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(
        select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()
      )
    ))
  )
);

create or replace function fp.can_manage_reminder(reminder_row fp.reminders) returns boolean
language sql stable security definer set search_path=pg_catalog,fp as $$
  select fp.is_active_member(reminder_row.household_id) and (
    (reminder_row.document_id is null and reminder_row.created_by=fp.current_user_id()) or
    (reminder_row.document_id is not null and (
      reminder_row.created_by=fp.current_user_id() or fp.is_household_admin(reminder_row.household_id) or exists(
        select 1 from fp.document_permissions p where p.document_id=reminder_row.document_id
          and p.member_user_id=fp.current_user_id() and p.access_level in ('contribute','manage')
      )
    ))
  )
$$;

create or replace function fp.set_reminder_recurrence(reminder uuid,repeat text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare r fp.reminders;
begin
  if repeat not in ('none','monthly','yearly') then raise exception 'invalid recurrence' using errcode='22023';end if;
  select * into r from fp.reminders where id=reminder for update;
  if r.id is null or not fp.can_manage_reminder(r) then raise exception 'not authorised' using errcode='42501';end if;
  if r.status<>'upcoming' then raise exception 'reminder already resolved' using errcode='22023';end if;
  update fp.reminders set recurrence=repeat,root_reminder_id=coalesce(root_reminder_id,id),original_due_at=coalesce(original_due_at,due_at),original_due_time=coalesce(original_due_time,due_time),updated_at=now() where id=r.id;
  return jsonb_build_object('id',r.id,'recurrence',repeat);
end $$;

create or replace function fp.act_on_reminder(reminder uuid,action text,snooze_until date default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();r fp.reminders;next_due date;next_id uuid;local_today date:=(now() at time zone 'Pacific/Auckland')::date;
begin
  if action not in ('complete','paid','dismiss','snooze') then raise exception 'invalid reminder action' using errcode='22023';end if;
  select * into r from fp.reminders where id=reminder for update;
  if r.id is null or not fp.can_manage_reminder(r) then raise exception 'not authorised' using errcode='42501';end if;
  if r.status<>'upcoming' then raise exception 'reminder already resolved' using errcode='22023';end if;
  if action in ('complete','paid') then
    update fp.reminders set status='completed',completed_at=now(),completed_by=uid,completion_kind=case when action='paid' then 'paid' else 'completed' end,updated_at=now() where id=r.id;
    if r.recurrence<>'none' then
      next_due:=case when r.recurrence='monthly' then (r.due_at+interval '1 month')::date else (r.due_at+interval '1 year')::date end;
      insert into fp.reminders(household_id,document_id,title,due_at,due_time,due_time_zone,status,created_by,recurrence,original_due_at,original_due_time,root_reminder_id,sequence_number)
      values(r.household_id,r.document_id,r.title,next_due,r.due_time,r.due_time_zone,'upcoming',r.created_by,r.recurrence,next_due,r.due_time,coalesce(r.root_reminder_id,r.id),r.sequence_number+1)
      on conflict(document_id,due_at) do nothing returning id into next_id;
    end if;
  elsif action='dismiss' then update fp.reminders set status='dismissed',dismissed_at=now(),updated_at=now() where id=r.id;
  else
    if snooze_until is null or snooze_until<=local_today or snooze_until>local_today+365 then raise exception 'invalid snooze date' using errcode='22023';end if;
    update fp.reminders set original_due_at=coalesce(original_due_at,due_at),original_due_time=coalesce(original_due_time,due_time),due_at=snooze_until,snooze_count=snooze_count+1,updated_at=now() where id=r.id;
  end if;
  return jsonb_build_object('id',r.id,'action',action,'status',(select status from fp.reminders where id=r.id),'next_reminder_id',next_id,'next_due_at',next_due,'due_time',r.due_time,'due_time_zone',r.due_time_zone);
end $$;

create or replace function fp.create_reminder(
  reminder_title text,
  due_date date,
  due_time_value time default null,
  due_timezone text default 'Pacific/Auckland',
  related_document uuid default null,
  request_id text default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;row fp.reminders;april_first date;september_last date;autumn_transition date;spring_transition date;
begin
  select household_id,role into hid,member_role from fp.members
    where user_id=uid and status='active' order by joined_at,household_id limit 1 for share;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if reminder_title is null or char_length(trim(reminder_title)) not between 1 and 160 then
    raise exception 'title is required' using errcode='22023';
  end if;
  if due_date is null then raise exception 'due date is required' using errcode='22023';end if;
  if due_timezone is distinct from 'Pacific/Auckland' then
    raise exception 'invalid reminder timezone' using errcode='22023';
  end if;
  if due_time_value is not null and due_time_value>=time '02:00' and due_time_value<time '03:00' then
    april_first:=make_date(extract(year from due_date)::integer,4,1);
    september_last:=make_date(extract(year from due_date)::integer,9,30);
    autumn_transition:=april_first+((7-extract(dow from april_first)::integer)%7);
    spring_transition:=september_last-extract(dow from september_last)::integer;
    if due_date in (autumn_transition,spring_transition) then
      raise exception 'ambiguous or nonexistent Auckland local time' using errcode='22023';
    end if;
  end if;
  if related_document is not null and not exists(
    select 1 from fp.documents d where d.id=related_document and d.household_id=hid and d.lifecycle_status<>'deleted'
      and (d.created_by=uid or fp.is_household_admin(hid) or exists(
        select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid and p.access_level in ('contribute','manage')
      ))
  ) then raise exception 'related document is not available' using errcode='42501';end if;
  if request_id is not null and char_length(request_id) not between 8 and 100 then
    raise exception 'invalid request id' using errcode='22023';
  end if;
  if request_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||request_id,0));
    select * into row from fp.reminders where household_id=hid and created_by=uid and client_request_id=request_id;
    if row.id is not null then
      return jsonb_build_object('id',row.id,'title',row.title,'due_at',row.due_at,'due_time',row.due_time,
        'due_time_zone',row.due_time_zone,'document_id',row.document_id,'status',row.status,'duplicate',true);
    end if;
  end if;
  insert into fp.reminders(household_id,document_id,title,due_at,due_time,due_time_zone,created_by,client_request_id)
  values(hid,related_document,trim(reminder_title),due_date,due_time_value,due_timezone,uid,request_id)
  returning * into row;
  return jsonb_build_object('id',row.id,'title',row.title,'due_at',row.due_at,'due_time',row.due_time,
    'due_time_zone',row.due_time_zone,'document_id',row.document_id,'status',row.status,'duplicate',false);
end $$;

-- Durable database-backed OCR work. The document and source are stored before
-- the job is made visible to a worker.
create table if not exists fp.document_analysis_jobs(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  document_id uuid not null references fp.documents(id) on delete cascade,
  requested_by uuid not null,
  mode text not null default 'document' check(mode in ('document','invoice')),
  status text not null default 'queued' check(status in ('queued','processing','retry_wait','succeeded','failed','permanent_failed','dismissed')),
  attempts integer not null default 0 check(attempts between 0 and 5),
  next_attempt_at timestamptz not null default now(),
  lease_expires_at timestamptz,
  lease_token uuid,
  started_at timestamptz,
  completed_at timestamptz,
  result jsonb,
  failure_code text,
  idempotency_key text not null check(char_length(idempotency_key) between 8 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,requested_by,idempotency_key)
);
create index if not exists document_analysis_jobs_ready
  on fp.document_analysis_jobs(status,next_attempt_at,lease_expires_at,created_at)
  where status in ('queued','retry_wait','processing');
alter table fp.document_analysis_jobs enable row level security;
alter table fp.document_analysis_jobs force row level security;
drop policy if exists document_analysis_job_authorised_read on fp.document_analysis_jobs;
create policy document_analysis_job_authorised_read on fp.document_analysis_jobs for select using(
  fp.is_active_member(household_id) and (
    requested_by=fp.current_user_id() or fp.is_household_admin(household_id) or exists(
      select 1 from fp.document_permissions p where p.document_id=fp.document_analysis_jobs.document_id and p.member_user_id=fp.current_user_id()
    )
  )
);
revoke all on fp.document_analysis_jobs from public,anon,authenticated;

create or replace function fp.create_document_analysis_job(
  file_name text,source_mime_type text,content_base64 text,analysis_mode text,idempotency text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;bytes bytea;digest text;category_id uuid;d fp.documents;j fp.document_analysis_jobs;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active'
    order by joined_at,household_id limit 1 for share;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if analysis_mode not in ('document','invoice') or idempotency is null or char_length(idempotency) not between 8 and 100 then raise exception 'invalid request' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||idempotency,0));
  select * into j from fp.document_analysis_jobs where household_id=hid and requested_by=uid and idempotency_key=idempotency;
  if j.id is not null then return jsonb_build_object('job_id',j.id,'document_id',j.document_id,'status',j.status,'created_at',j.created_at,'duplicate',true);end if;
  if file_name is null or char_length(trim(file_name)) not between 1 and 255 or file_name ~ '[[:cntrl:]]' then raise exception 'invalid filename' using errcode='22023';end if;
  if content_base64 is null or octet_length(content_base64)>7340032 then raise exception 'invalid file encoding' using errcode='22023';end if;
  begin bytes:=decode(regexp_replace(content_base64,'\s','','g'),'base64');exception when others then raise exception 'invalid file encoding' using errcode='22023';end;
  perform fp.validate_document_bytes(source_mime_type,bytes);
  digest:=encode(extensions.digest(bytes,'sha256'),'hex');
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

create or replace function fp.document_analysis_job(job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();j fp.document_analysis_jobs;
begin
  select x.* into j from fp.document_analysis_jobs x where x.id=job and fp.is_active_member(x.household_id)
    and (x.requested_by=uid or fp.is_household_admin(x.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=x.document_id and p.member_user_id=uid));
  if j.id is null then raise exception 'job not found' using errcode='PT404';end if;
  return jsonb_build_object('job_id',j.id,'document_id',j.document_id,'status',j.status,'attempts',j.attempts,
    'created_at',j.created_at,'started_at',j.started_at,'completed_at',j.completed_at,'result',j.result,
    'failure',case when j.status in ('failed','permanent_failed') then 'This document could not be read.' else null end,
    'retry_allowed',j.status in ('failed','permanent_failed'));
end $$;

create or replace function fp.pending_document_analysis_jobs() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then raise exception 'not authorised' using errcode='42501';end if;
  return coalesce((select jsonb_agg(fp.document_analysis_job(j.id) order by j.created_at)
    from fp.document_analysis_jobs j where j.household_id=hid and j.requested_by=uid and
      (j.status in ('queued','processing','retry_wait','failed','permanent_failed') or (j.status='succeeded' and j.completed_at>now()-interval '24 hours'))),'[]'::jsonb);
end $$;

create or replace function fp.retry_document_analysis_job(job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();j fp.document_analysis_jobs;
begin
  update fp.document_analysis_jobs x set status='queued',attempts=0,next_attempt_at=now(),lease_expires_at=null,lease_token=null,
    failure_code=null,updated_at=now() where x.id=job and x.requested_by=uid and fp.is_active_member(x.household_id)
    and x.status in ('failed','permanent_failed') returning * into j;
  if j.id is null then raise exception 'job not found or not retryable' using errcode='PT404';end if;
  return fp.document_analysis_job(j.id);
end $$;

create or replace function fp.categorize_document_analysis_job(job uuid,category_name text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();j fp.document_analysis_jobs;selected_category uuid;canonical_name text;
begin
  select * into j from fp.document_analysis_jobs where id=job and requested_by=uid and fp.is_active_member(household_id);
  if j.id is null then raise exception 'job not found' using errcode='PT404';end if;
  select id,name into selected_category,canonical_name from fp.categories where household_id=j.household_id and lower(name)=lower(trim(category_name)) limit 1;
  if selected_category is null then raise exception 'category not found' using errcode='22023';end if;
  update fp.documents set category_id=selected_category where id=j.document_id and household_id=j.household_id;
  if j.status in ('failed','permanent_failed') then
    update fp.document_analysis_jobs set status='dismissed',updated_at=now() where id=j.id;
  end if;
  return jsonb_build_object('document_id',j.document_id,'category',canonical_name);
end $$;

create or replace function fp.dismiss_document_analysis_job(job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();j fp.document_analysis_jobs;
begin
  update fp.document_analysis_jobs x set status='dismissed',updated_at=now()
    where x.id=job and x.requested_by=uid and fp.is_active_member(x.household_id)
      and x.status in ('failed','permanent_failed') returning * into j;
  if j.id is null then raise exception 'job not found or not dismissible' using errcode='PT404';end if;
  return jsonb_build_object('job_id',j.id,'document_id',j.document_id,'status',j.status);
end $$;

create or replace function fp.claim_document_analysis_jobs(batch_size integer default 1) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  update fp.document_analysis_jobs j set status='permanent_failed',failure_code='source_unavailable',completed_at=now(),lease_expires_at=null,lease_token=null,updated_at=now()
    where j.status in ('queued','retry_wait','processing') and (
      not exists(select 1 from fp.documents d where d.id=j.document_id and d.household_id=j.household_id and d.lifecycle_status<>'deleted') or
      not exists(select 1 from fp.members m where m.household_id=j.household_id and m.user_id=j.requested_by and m.status='active')
    );
  with leased as(
    select j.id from fp.document_analysis_jobs j where
      ((j.status in ('queued','retry_wait') and j.next_attempt_at<=now()) or (j.status='processing' and j.lease_expires_at<now()))
      and j.attempts<5 order by j.next_attempt_at,j.created_at for update skip locked limit least(greatest(batch_size,1),10)
  ),updated as(
    update fp.document_analysis_jobs j set status='processing',attempts=j.attempts+1,started_at=coalesce(j.started_at,now()),
      lease_expires_at=now()+interval '5 minutes',lease_token=gen_random_uuid(),updated_at=now() from leased where j.id=leased.id returning j.*
  ) select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'document_id',j.document_id,'mode',j.mode,'attempt',j.attempts,
      'lease_token',j.lease_token,
      'file_name',s.file_name,'mime_type',s.mime_type,'sha256',s.sha256,'content_base64',encode(s.content,'base64'),
      'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name),'[]'::jsonb) from fp.categories c where c.household_id=j.household_id))), '[]'::jsonb)
    into result from updated j left join fp.manual_document_sources s on s.document_id=j.document_id and s.household_id=j.household_id;
  return result;
end $$;

create or replace function fp.renew_document_analysis_job_lease(job uuid,worker_lease_token uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare renewed boolean;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  update fp.document_analysis_jobs set lease_expires_at=now()+interval '5 minutes',updated_at=now()
    where id=job and status='processing' and lease_token=worker_lease_token returning true into renewed;
  return coalesce(renewed,false);
end $$;

create or replace function fp.complete_document_analysis_job(job uuid,worker_lease_token uuid,job_result jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.document_analysis_jobs;selected_category_id uuid;title_value text;tags_value jsonb;document_date_value date;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select * into j from fp.document_analysis_jobs where id=job and status='processing' and lease_token=worker_lease_token and lease_expires_at>now() for update;
  if j.id is null then raise exception 'job unavailable' using errcode='PT404';end if;
  select id into selected_category_id from fp.categories where household_id=j.household_id and lower(name)=lower(coalesce(job_result->>'category','')) limit 1;
  if selected_category_id is null then select d.category_id into selected_category_id from fp.documents d where d.id=j.document_id;end if;
  title_value:=left(coalesce(nullif(trim(job_result->>'title'),''),(select title from fp.documents where id=j.document_id)),120);
  tags_value:=case when jsonb_typeof(job_result->'tags')='array' then job_result->'tags' else '[]'::jsonb end;
  begin document_date_value:=(job_result->>'document_date')::date;exception when others then document_date_value:=null;end;
  update fp.documents set category_id=selected_category_id,title=title_value,tags=tags_value,document_date=document_date_value,
    extracted_text=left(coalesce(job_result->>'text',''),100000),document_type=left(coalesce(job_result->>'document_type','Document'),80),
    provider_name=nullif(left(coalesce(job_result->>'provider_name',''),120),''),ocr_confidence=least(greatest(coalesce((job_result->>'mean_confidence')::numeric,0),0),1)
    where id=j.document_id and household_id=j.household_id;
  update fp.document_analysis_jobs set status='succeeded',result=job_result-'text',failure_code=null,lease_expires_at=null,lease_token=null,completed_at=now(),updated_at=now() where id=j.id;
  return jsonb_build_object('job_id',j.id,'document_id',j.document_id,'status','succeeded');
end $$;

create or replace function fp.fail_document_analysis_job(job uuid,worker_lease_token uuid,error_code text,retryable boolean default true) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.document_analysis_jobs;next_status text;
begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  select * into j from fp.document_analysis_jobs where id=job and status='processing' and lease_token=worker_lease_token for update;
  if j.id is null then raise exception 'job unavailable' using errcode='PT404';end if;
  next_status:=case when retryable and j.attempts<5 then 'retry_wait' when retryable then 'failed' else 'permanent_failed' end;
  update fp.document_analysis_jobs set status=next_status,failure_code=left(coalesce(nullif(error_code,''),'processing_failed'),80),
    lease_expires_at=null,lease_token=null,next_attempt_at=case when next_status='retry_wait' then now()+(power(2,j.attempts)::text||' minutes')::interval else next_attempt_at end,
    completed_at=case when next_status in ('failed','permanent_failed') then now() else null end,updated_at=now() where id=j.id;
  return jsonb_build_object('job_id',j.id,'status',next_status,'attempts',j.attempts);
end $$;

create or replace function fp.reminder_dashboard() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;local_today date:=(now() at time zone 'Pacific/Auckland')::date;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then return jsonb_build_object('items','[]'::jsonb,'notifications','[]'::jsonb,'counts',jsonb_build_object('overdue',0,'due_soon',0,'unread',0));end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_time_zone',r.due_time_zone,'status',r.status,'recurrence',r.recurrence,'sequence_number',r.sequence_number,'snooze_count',r.snooze_count,'completion_kind',r.completion_kind,'completed_by',r.completed_by,'audience',r.audience,'email_all_members',r.email_all_members,'my_response',(select x.status from fp.reminder_member_responses x where x.reminder_id=r.id and x.member_user_id=uid),'document_title',d.title,'category_name',c.name,'due_state',case when r.status='upcoming' and r.due_at<local_today then 'overdue' when r.status='upcoming' and r.due_at=local_today then 'today' when r.status='upcoming' then 'upcoming' else r.status end,'days_until',r.due_at-local_today) order by case when r.status='upcoming' then 0 else 1 end,r.due_at desc,r.due_time desc nulls last)
      from fp.reminders r left join fp.documents d on d.id=r.document_id left join fp.categories c on c.id=d.category_id
      where r.household_id=hid and (r.document_id is null or d.lifecycle_status<>'deleted') and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_time_zone',r.due_time_zone,'due_state',case when r.due_at<local_today then 'overdue' when r.due_at=local_today then 'today' else 'due_soon' end,'audience',r.audience,'my_response',x.status) order by r.due_at,r.due_time nulls last)
      from fp.reminders r left join fp.reminder_member_responses x on x.reminder_id=r.id and x.member_user_id=uid left join fp.documents d on d.id=r.document_id
      where r.household_id=hid and r.status='upcoming' and r.due_at<=local_today+7 and (r.document_id is null or d.lifecycle_status='active') and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'[]'::jsonb),
    'counts',jsonb_build_object(
      'overdue',(select count(*) from fp.reminders r left join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<local_today and (r.document_id is null or d.lifecycle_status='active') and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),
      'due_soon',(select count(*) from fp.reminders r left join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at between local_today and local_today+7 and (r.document_id is null or d.lifecycle_status='active') and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),
      'unread',(select count(*) from fp.reminders r left join fp.reminder_member_responses x on x.reminder_id=r.id and x.member_user_id=uid left join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<=local_today+7 and (r.document_id is null or d.lifecycle_status='active') and ((r.audience='personal' and r.created_by=uid) or (r.audience='family' and coalesce(x.status,'pending')='pending')))
    )
  );
end $$;

-- Existing due-day delivery also accepts standalone rows while retaining the
-- active-document check for linked reminders.
create or replace function fp.enqueue_due_notifications() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
  select r.household_id,'reminder',m.email,'Due today — '||r.title,
    r.title||' is due today, '||to_char(r.due_at,'DD Mon YYYY')||'. Sign in to acknowledge it or mark it complete.',
    'reminder_due_day:'||r.id::text||':'||r.due_at::text||':'||m.user_id::text,
    (r.due_at+coalesce(r.due_time,time '08:00')) at time zone r.due_time_zone
  from fp.reminders r
  left join fp.documents d on d.id=r.document_id
  join fp.members m on m.household_id=r.household_id and m.status='active' and
    ((r.audience='personal' and m.user_id=r.created_by) or (r.audience='family' and (r.email_all_members or m.user_id=r.created_by)))
  where r.status='upcoming' and (r.document_id is null or d.lifecycle_status='active')
    and r.due_at between (now() at time zone 'Pacific/Auckland')::date and (now() at time zone 'Pacific/Auckland')::date+7
  on conflict(dedupe_key) do nothing;
  get diagnostics changed=row_count;
  return jsonb_build_object('queued',changed,'default_delivery_time','08:00','time_zone','Pacific/Auckland');
end $$;

revoke execute on function fp.create_reminder(text,date,time,text,uuid,text),fp.create_document_analysis_job(text,text,text,text,text),
  fp.document_analysis_job(uuid),fp.pending_document_analysis_jobs(),fp.retry_document_analysis_job(uuid),
  fp.categorize_document_analysis_job(uuid,text),fp.dismiss_document_analysis_job(uuid),
  fp.claim_document_analysis_jobs(integer),fp.renew_document_analysis_job_lease(uuid,uuid),fp.complete_document_analysis_job(uuid,uuid,jsonb),fp.fail_document_analysis_job(uuid,uuid,text,boolean)
  from public,anon;
grant execute on function fp.create_reminder(text,date,time,text,uuid,text),fp.create_document_analysis_job(text,text,text,text,text),
  fp.document_analysis_job(uuid),fp.pending_document_analysis_jobs(),fp.retry_document_analysis_job(uuid),fp.categorize_document_analysis_job(uuid,text),fp.dismiss_document_analysis_job(uuid) to authenticated;
revoke execute on function fp.claim_document_analysis_jobs(integer),fp.renew_document_analysis_job_lease(uuid,uuid),fp.complete_document_analysis_job(uuid,uuid,jsonb),fp.fail_document_analysis_job(uuid,uuid,text,boolean) from authenticated;
grant execute on function fp.claim_document_analysis_jobs(integer),fp.renew_document_analysis_job_lease(uuid,uuid),fp.complete_document_analysis_job(uuid,uuid,jsonb),fp.fail_document_analysis_job(uuid,uuid,text,boolean) to service_role;
revoke execute on function fp.can_manage_reminder(fp.reminders) from public,anon,authenticated;
revoke execute on function fp.enqueue_due_notifications() from public,anon,authenticated;
grant execute on function fp.enqueue_due_notifications() to service_role;

commit;
