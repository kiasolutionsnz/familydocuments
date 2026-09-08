begin;

alter table fp.email_classification_proposals drop constraint if exists email_classification_proposals_inbound_email_id_key;

create table if not exists fp.email_classification_jobs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  inbound_email_id uuid not null references fp.inbound_emails(id) on delete cascade,
  source_attachment_id uuid references fp.inbound_attachments(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','processing','retry_wait','proposed','dead_letter')),
  attempts integer not null default 0 check(attempts between 0 and 5),
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error_code text check(last_error_code is null or last_error_code ~ '^[a-z0-9_]{1,80}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists classification_job_attachment_unique on fp.email_classification_jobs(inbound_email_id,source_attachment_id) where source_attachment_id is not null;
create unique index if not exists classification_job_body_unique on fp.email_classification_jobs(inbound_email_id) where source_attachment_id is null;
create index if not exists classification_jobs_ready on fp.email_classification_jobs(status,next_attempt_at,created_at) where status in ('pending','retry_wait','processing');
alter table fp.email_classification_jobs enable row level security;
alter table fp.email_classification_jobs force row level security;
drop policy if exists classification_job_admin_read on fp.email_classification_jobs;
create policy classification_job_admin_read on fp.email_classification_jobs for select using(fp.is_household_admin(household_id));

alter table fp.email_classification_proposals add column if not exists classification_job_id uuid references fp.email_classification_jobs(id) on delete set null;
create unique index if not exists classification_proposal_job_unique on fp.email_classification_proposals(classification_job_id) where classification_job_id is not null;
create unique index if not exists classification_proposal_attachment_unique on fp.email_classification_proposals(inbound_email_id,source_attachment_id) where source_attachment_id is not null;
create unique index if not exists classification_proposal_body_unique on fp.email_classification_proposals(inbound_email_id) where source_attachment_id is null;

insert into fp.email_classification_jobs(household_id,inbound_email_id,source_attachment_id,status,attempts)
select p.household_id,p.inbound_email_id,p.source_attachment_id,'proposed',1 from fp.email_classification_proposals p
on conflict do nothing;
update fp.email_classification_proposals p set classification_job_id=j.id
from fp.email_classification_jobs j where p.classification_job_id is null and j.inbound_email_id=p.inbound_email_id and j.source_attachment_id is not distinct from p.source_attachment_id;

drop function if exists fp.pending_email_classifications(integer);
create function fp.pending_email_classifications(batch_size integer default 5) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  insert into fp.email_classification_jobs(household_id,inbound_email_id,source_attachment_id)
  select a.household_id,a.inbound_email_id,a.id from fp.inbound_attachments a where a.scan_status='clean' on conflict do nothing;
  insert into fp.email_classification_jobs(household_id,inbound_email_id,source_attachment_id)
  select e.household_id,e.id,null from fp.inbound_emails e where e.attachment_count=0 on conflict do nothing;
  with leased as (
    select j.id from fp.email_classification_jobs j
    where ((j.status in ('pending','retry_wait') and j.next_attempt_at<=now()) or (j.status='processing' and j.locked_at<now()-interval '5 minutes')) and j.attempts<5
    order by j.next_attempt_at,j.created_at for update skip locked limit least(greatest(batch_size,1),10)
  ), updated as (
    update fp.email_classification_jobs j set status='processing',attempts=j.attempts+1,locked_at=now(),updated_at=now()
    from leased where j.id=leased.id returning j.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'job_id',j.id,'email_id',e.id,'subject',e.subject,'sender_address',e.sender_address,'body_text',left(coalesce(e.body_text,''),20000),
    'source_sha256',coalesce(a.content_sha256,e.raw_sha256),'attachment_id',a.id,'file_name',a.file_name,
    'content_base64',case when a.id is null then null else encode(a.content,'base64') end,'attempt',j.attempts,
    'categories',(select coalesce(jsonb_agg(c.name order by c.name),'[]'::jsonb) from fp.categories c where c.household_id=e.household_id)
  ) order by j.created_at),'[]'::jsonb) into result
  from updated j join fp.inbound_emails e on e.id=j.inbound_email_id left join fp.inbound_attachments a on a.id=j.source_attachment_id;
  return result;
end $$;

create or replace function fp.record_classification_job_success(
  job_id uuid,model text,proposed_category text,proposed_title text,proposed_document_type text,proposed_provider text,
  proposed_document_date date,proposed_due_date date,proposed_amount numeric,proposed_currency text,proposed_tags jsonb,
  proposed_confidence numeric,proposed_evidence text,provided_source_sha256 text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.email_classification_jobs; e fp.inbound_emails; a fp.inbound_attachments; row_id uuid;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into j from fp.email_classification_jobs where id=job_id for update;
  if j.id is null or j.status<>'processing' then raise exception 'job not processing' using errcode='22023'; end if;
  select * into e from fp.inbound_emails where id=j.inbound_email_id;
  if j.source_attachment_id is not null then select * into a from fp.inbound_attachments where id=j.source_attachment_id and scan_status='clean'; end if;
  if j.source_attachment_id is not null and a.id is null then raise exception 'clean attachment required' using errcode='22023'; end if;
  if lower(provided_source_sha256)<>coalesce(a.content_sha256,e.raw_sha256) then raise exception 'source integrity mismatch' using errcode='22023'; end if;
  if jsonb_typeof(proposed_tags)<>'array' or jsonb_array_length(proposed_tags)>12 then raise exception 'invalid tags' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.household_id=j.household_id and lower(c.name)=lower(proposed_category)) then proposed_category:='Other'; end if;
  insert into fp.email_classification_proposals(household_id,inbound_email_id,source_attachment_id,classification_job_id,model_name,category_name,title,document_type,provider_name,document_date,due_date,amount,currency,tags,confidence,evidence_excerpt,source_sha256)
  values(j.household_id,j.inbound_email_id,j.source_attachment_id,j.id,left(model,80),left(proposed_category,80),left(trim(proposed_title),160),left(trim(proposed_document_type),80),nullif(left(trim(proposed_provider),120),''),proposed_document_date,proposed_due_date,proposed_amount,case when proposed_currency~'^[A-Z]{3}$' then proposed_currency else null end,proposed_tags,least(greatest(proposed_confidence,0),1),left(trim(proposed_evidence),1200),lower(provided_source_sha256))
  returning id into row_id;
  update fp.email_classification_jobs set status='proposed',locked_at=null,last_error_code=null,updated_at=now() where id=j.id;
  return jsonb_build_object('recorded',true,'proposal_id',row_id);
end $$;

create or replace function fp.record_classification_job_failure(job_id uuid,error_code text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.email_classification_jobs; next_status text;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into j from fp.email_classification_jobs where id=job_id for update;
  if j.id is null or j.status<>'processing' then raise exception 'job not processing' using errcode='22023'; end if;
  if error_code !~ '^[a-z0-9_]{1,80}$' then error_code:='classification_failed'; end if;
  next_status:=case when j.attempts>=5 then 'dead_letter' else 'retry_wait' end;
  update fp.email_classification_jobs set status=next_status,last_error_code=error_code,locked_at=null,
    next_attempt_at=case when next_status='retry_wait' then now()+(power(2,j.attempts)::text||' minutes')::interval else next_attempt_at end,updated_at=now() where id=j.id;
  return jsonb_build_object('status',next_status,'attempts',j.attempts);
end $$;

create or replace function fp.retry_classification_job(job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); changed integer;
begin
  update fp.email_classification_jobs j set status='pending',attempts=0,next_attempt_at=now(),last_error_code=null,locked_at=null,updated_at=now()
  where j.id=job and j.status in ('retry_wait','dead_letter') and fp.is_household_admin(j.household_id);
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'not authorised or job not retryable' using errcode='42501'; end if;
  return jsonb_build_object('status','pending');
end $$;

create or replace function fp.classification_job_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'email_id',j.inbound_email_id,'email_subject',e.subject,'file_name',a.file_name,'status',j.status,'attempts',j.attempts,'last_error_code',j.last_error_code,'next_attempt_at',j.next_attempt_at,'updated_at',j.updated_at) order by j.updated_at desc) from fp.email_classification_jobs j join fp.inbound_emails e on e.id=j.inbound_email_id left join fp.inbound_attachments a on a.id=j.source_attachment_id where j.household_id=hid),'[]'::jsonb);
end $$;

revoke all on fp.email_classification_jobs from public,anon,authenticated;
revoke execute on function fp.record_email_classification(uuid,uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text) from public,anon,authenticated,service_role;
revoke execute on function fp.record_classification_job_success(uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text),fp.record_classification_job_failure(uuid,text) from public,anon,authenticated;
grant execute on function fp.record_classification_job_success(uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text),fp.record_classification_job_failure(uuid,text),fp.pending_email_classifications(integer) to service_role;
grant execute on function fp.retry_classification_job(uuid),fp.classification_job_summaries() to authenticated;

commit;
