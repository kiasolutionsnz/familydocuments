begin;

alter table fp.email_classification_proposals add column if not exists due_time time without time zone;
alter table fp.email_classification_proposals add column if not exists due_time_zone text not null default 'Pacific/Auckland';
alter table fp.reminders add column if not exists due_time time without time zone;
alter table fp.reminders add column if not exists due_time_zone text not null default 'Pacific/Auckland';
alter table fp.reminders add column if not exists original_due_time time without time zone;

alter table fp.email_classification_proposals drop constraint if exists email_classification_proposals_due_time_zone_check;
alter table fp.email_classification_proposals add constraint email_classification_proposals_due_time_zone_check check(due_time_zone='Pacific/Auckland');
alter table fp.reminders drop constraint if exists reminders_due_time_zone_check;
alter table fp.reminders add constraint reminders_due_time_zone_check check(due_time_zone='Pacific/Auckland');

update fp.email_classification_proposals
set due_time='12:00:00'
where status='needs_review' and due_date is not null and due_time is null
  and evidence_excerpt ~* '\m12\s*(pm|p\.m\.)\M';

drop function if exists fp.record_classification_job_success(uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text);
create function fp.record_classification_job_success(
  job_id uuid,model text,proposed_category text,proposed_title text,proposed_document_type text,proposed_provider text,
  proposed_document_date date,proposed_due_date date,proposed_due_time time,proposed_due_time_zone text,
  proposed_amount numeric,proposed_currency text,proposed_tags jsonb,proposed_confidence numeric,
  proposed_evidence text,provided_source_sha256 text
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
  if proposed_due_time_zone<>'Pacific/Auckland' then raise exception 'invalid reminder timezone' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.household_id=j.household_id and lower(c.name)=lower(proposed_category)) then proposed_category:='Other'; end if;
  insert into fp.email_classification_proposals(household_id,inbound_email_id,source_attachment_id,classification_job_id,model_name,category_name,title,document_type,provider_name,document_date,due_date,due_time,due_time_zone,amount,currency,tags,confidence,evidence_excerpt,source_sha256)
  values(j.household_id,j.inbound_email_id,j.source_attachment_id,j.id,left(model,80),left(proposed_category,80),left(trim(proposed_title),160),left(trim(proposed_document_type),80),nullif(left(trim(proposed_provider),120),''),proposed_document_date,proposed_due_date,proposed_due_time,proposed_due_time_zone,proposed_amount,case when proposed_currency~'^[A-Z]{3}$' then proposed_currency else null end,proposed_tags,least(greatest(proposed_confidence,0),1),left(trim(proposed_evidence),1200),lower(provided_source_sha256))
  returning id into row_id;
  update fp.email_classification_jobs set status='proposed',locked_at=null,last_error_code=null,updated_at=now() where id=j.id;
  return jsonb_build_object('recorded',true,'proposal_id',row_id);
end $$;

create or replace function fp.email_classification_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'email_id',p.inbound_email_id,'email_subject',e.subject,'sender_address',e.sender_address,'file_name',a.file_name,'category_name',p.category_name,'title',p.title,'document_type',p.document_type,'provider_name',p.provider_name,'document_date',p.document_date,'due_date',p.due_date,'due_time',p.due_time,'due_time_zone',p.due_time_zone,'amount',p.amount,'currency',p.currency,'tags',p.tags,'confidence',p.confidence,'evidence_excerpt',p.evidence_excerpt,'source_sha256',p.source_sha256,'model_name',p.model_name,'status',p.status,'created_at',p.created_at) order by p.created_at desc) from fp.email_classification_proposals p join fp.inbound_emails e on e.id=p.inbound_email_id left join fp.inbound_attachments a on a.id=p.source_attachment_id where p.household_id=hid),'[]'::jsonb);
end $$;

drop function if exists fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb,uuid);
create function fp.confirm_email_classification(proposal uuid,category uuid,confirmed_title text,confirmed_document_type text,confirmed_provider text,confirmed_document_date date,confirmed_due_date date,confirmed_due_time time,confirmed_tags jsonb,replaces_document uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); p fp.email_classification_proposals; d fp.documents; prior fp.documents; existing fp.documents; reminder_id uuid;
begin
  select * into p from fp.email_classification_proposals where id=proposal for update;
  if p.id is null or not fp.is_household_admin(p.household_id) then raise exception 'not authorised' using errcode='42501'; end if;
  if p.status<>'needs_review' then raise exception 'proposal already reviewed' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.id=category and c.household_id=p.household_id) then raise exception 'invalid category' using errcode='22023'; end if;
  if jsonb_typeof(confirmed_tags)<>'array' or jsonb_array_length(confirmed_tags)>12 then raise exception 'invalid tags' using errcode='22023'; end if;
  if confirmed_due_date is null and confirmed_due_time is not null then raise exception 'reminder time requires a date' using errcode='22023'; end if;
  select * into existing from fp.documents where household_id=p.household_id and source_sha256=p.source_sha256 and lifecycle_status<>'deleted' order by created_at limit 1;
  if existing.id is not null then
    update fp.email_classification_proposals set status='confirmed',reviewed_by=uid,reviewed_at=now(),confirmed_document_id=existing.id where id=p.id;
    return jsonb_build_object('document_id',existing.id,'reminder_id',null,'status','confirmed','duplicate',true);
  end if;
  if replaces_document is not null then
    select * into prior from fp.documents where id=replaces_document and household_id=p.household_id and lifecycle_status='active' for update;
    if prior.id is null then raise exception 'replacement target is not active' using errcode='22023'; end if;
  end if;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,extracted_text,document_type,provider_name,critical_date,ocr_confidence,confirmation_status,tags,document_date,amount,currency,inbound_email_id,source_attachment_id,revision_of)
  select p.household_id,category,left(trim(confirmed_title),160),uid,coalesce(a.file_name,e.subject),p.source_sha256,case when a.id is null then 'message/rfc822' else 'application/pdf' end,p.evidence_excerpt,left(trim(confirmed_document_type),80),nullif(left(trim(confirmed_provider),120),''),confirmed_due_date,p.confidence,'confirmed',confirmed_tags,confirmed_document_date,p.amount,p.currency,p.inbound_email_id,p.source_attachment_id,prior.id
  from fp.inbound_emails e left join fp.inbound_attachments a on a.id=p.source_attachment_id where e.id=p.inbound_email_id returning * into d;
  if prior.id is not null then update fp.documents set lifecycle_status='archived',archived_at=now(),replaced_by=d.id where id=prior.id; end if;
  if confirmed_due_date is not null then insert into fp.reminders(household_id,document_id,title,due_at,due_time,due_time_zone,created_by) values(p.household_id,d.id,concat(d.title,' — payment or renewal due'),confirmed_due_date,confirmed_due_time,'Pacific/Auckland',uid) returning id into reminder_id; end if;
  update fp.email_classification_proposals set status='confirmed',reviewed_by=uid,reviewed_at=now(),confirmed_document_id=d.id,document_date=confirmed_document_date,due_time=confirmed_due_time,tags=confirmed_tags where id=p.id;
  return jsonb_build_object('document_id',d.id,'reminder_id',reminder_id,'status','confirmed','duplicate',false,'revision_of',prior.id);
end $$;

create or replace function fp.configure_reminder(reminder uuid,repeat text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); r fp.reminders; d fp.documents;
begin
  select * into r from fp.reminders where id=reminder for update;
  select * into d from fp.documents where id=r.document_id;
  if r.id is null or not (d.created_by=uid or fp.is_household_admin(r.household_id)) then raise exception 'not authorised' using errcode='42501'; end if;
  if r.status<>'upcoming' or repeat not in ('none','monthly','yearly') then raise exception 'invalid reminder configuration' using errcode='22023'; end if;
  update fp.reminders set recurrence=repeat,root_reminder_id=coalesce(root_reminder_id,id),original_due_at=coalesce(original_due_at,due_at),original_due_time=coalesce(original_due_time,due_time),updated_at=now() where id=r.id;
  return jsonb_build_object('id',r.id,'recurrence',repeat);
end $$;

create or replace function fp.act_on_reminder(reminder uuid,action text,snooze_until date default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); r fp.reminders; d fp.documents; next_due date; next_id uuid;
begin
  select * into r from fp.reminders where id=reminder for update;
  select * into d from fp.documents where id=r.document_id;
  if r.id is null or not (d.created_by=uid or fp.is_household_admin(r.household_id)) then raise exception 'not authorised' using errcode='42501'; end if;
  if r.status<>'upcoming' then raise exception 'reminder is not active' using errcode='22023'; end if;
  if action in ('complete','paid') then
    update fp.reminders set status='completed',completed_at=now(),completed_by=uid,completion_kind=case when action='paid' then 'paid' else 'completed' end,updated_at=now() where id=r.id;
    if r.recurrence<>'none' and d.lifecycle_status='active' then
      next_due:=case when r.recurrence='monthly' then (r.due_at+interval '1 month')::date else (r.due_at+interval '1 year')::date end;
      insert into fp.reminders(household_id,document_id,title,due_at,due_time,due_time_zone,status,created_by,recurrence,original_due_at,original_due_time,root_reminder_id,sequence_number)
      values(r.household_id,r.document_id,r.title,next_due,r.due_time,r.due_time_zone,'upcoming',r.created_by,r.recurrence,next_due,r.due_time,coalesce(r.root_reminder_id,r.id),r.sequence_number+1)
      on conflict(document_id,due_at) do nothing returning id into next_id;
    end if;
  elsif action='dismiss' then
    update fp.reminders set status='dismissed',dismissed_at=now(),updated_at=now() where id=r.id;
  elsif action='snooze' then
    if snooze_until is null or snooze_until<=current_date or snooze_until>current_date+365 then raise exception 'invalid snooze date' using errcode='22023'; end if;
    begin
      update fp.reminders set original_due_at=coalesce(original_due_at,due_at),original_due_time=coalesce(original_due_time,due_time),due_at=snooze_until,snooze_count=snooze_count+1,updated_at=now() where id=r.id;
    exception when unique_violation then raise exception 'a reminder already exists on that date' using errcode='23505'; end;
  else raise exception 'invalid reminder action' using errcode='22023';
  end if;
  return jsonb_build_object('id',r.id,'action',action,'status',(select status from fp.reminders where id=r.id),'next_reminder_id',next_id,'next_due_at',next_due,'due_time',r.due_time,'due_time_zone',r.due_time_zone);
end $$;

create or replace function fp.reminder_dashboard() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return jsonb_build_object('items','[]'::jsonb,'notifications','[]'::jsonb,'counts',jsonb_build_object('overdue',0,'due_soon',0)); end if;
  admin:=fp.is_household_admin(hid);
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_time_zone',r.due_time_zone,'original_due_at',r.original_due_at,'original_due_time',r.original_due_time,'status',r.status,'recurrence',r.recurrence,'sequence_number',r.sequence_number,'snooze_count',r.snooze_count,'completion_kind',r.completion_kind,'document_title',d.title,'category_name',c.name,'due_state',case when r.status='upcoming' and r.due_at<current_date then 'overdue' when r.status='upcoming' and r.due_at=current_date then 'today' when r.status='upcoming' then 'upcoming' else r.status end,'days_until',r.due_at-current_date) order by case when r.status='upcoming' then 0 else 1 end,r.due_at desc,r.due_time desc nulls last) from fp.reminders r join fp.documents d on d.id=r.document_id join fp.categories c on c.id=d.category_id where r.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_time_zone',r.due_time_zone,'due_state',case when r.due_at<current_date then 'overdue' when r.due_at=current_date then 'today' else 'due_soon' end) order by r.due_at,r.due_time nulls last) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<=current_date+7 and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb),
    'counts',jsonb_build_object('overdue',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<current_date and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'due_soon',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at between current_date and current_date+7 and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))))
  );
end $$;

revoke execute on function fp.record_classification_job_success(uuid,text,text,text,text,text,date,date,time,text,numeric,text,jsonb,numeric,text,text) from public,anon,authenticated;
grant execute on function fp.record_classification_job_success(uuid,text,text,text,text,text,date,date,time,text,numeric,text,jsonb,numeric,text,text) to service_role;
revoke execute on function fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,time,jsonb,uuid) from public,anon;
grant execute on function fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,time,jsonb,uuid) to authenticated;

commit;
