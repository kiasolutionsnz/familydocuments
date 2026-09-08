begin;

do $$
declare
  owner_id constant uuid:='20000000-0000-4000-8000-000000000001';
  other_id constant uuid:='20000000-0000-4000-8000-000000000002';
  household_id uuid:=gen_random_uuid();other_household uuid:=gen_random_uuid();category_id uuid:=gen_random_uuid();
  linked_document uuid:=gen_random_uuid();foreign_document uuid:=gen_random_uuid();standalone jsonb;duplicate jsonb;linked jsonb;job jsonb;claimed jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(household_id,'Phase 1B family',owner_id),(other_household,'Other family',other_id);
  insert into fp.members(household_id,user_id,email,role) values(household_id,owner_id,'phase1b@example.test','owner'),(other_household,other_id,'other-phase1b@example.test','owner');
  insert into fp.categories(id,household_id,name,is_system,created_by) values(category_id,household_id,'Documents',true,owner_id);
  insert into fp.categories(household_id,name,is_system,created_by) values(other_household,'Documents',true,other_id);
  insert into fp.documents(id,household_id,category_id,title,created_by,confirmation_status) values(linked_document,household_id,category_id,'Linked synthetic document',owner_id,'confirmed');
  insert into fp.documents(id,household_id,category_id,title,created_by,confirmation_status)
    select foreign_document,other_household,c.id,'Foreign synthetic document',other_id,'confirmed' from fp.categories c where c.household_id=other_household limit 1;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','phase1b@example.test','role','authenticated')::text,true);
  standalone:=fp.create_reminder('Doctor appointment',current_date+1,time '14:00','Pacific/Auckland',null,'phase1b-reminder-1');
  if standalone->>'document_id' is not null or standalone->>'due_time'<>'14:00:00' or standalone->>'due_time_zone'<>'Pacific/Auckland' then raise exception 'standalone reminder fields incorrect';end if;
  perform fp.enqueue_due_notifications();
  if not exists(select 1 from fp.notification_outbox where dedupe_key like 'reminder_due_day:'||(standalone->>'id')||':%') then raise exception 'standalone notification was not queued';end if;
  duplicate:=fp.create_reminder('Doctor appointment',current_date+1,time '14:00','Pacific/Auckland',null,'phase1b-reminder-1');
  if duplicate->>'id'<>standalone->>'id' or (duplicate->>'duplicate')::boolean is not true then raise exception 'reminder idempotency failed';end if;
  linked:=fp.create_reminder('Document reminder',current_date+2,null,'Pacific/Auckland',linked_document,'phase1b-reminder-2');
  if linked->>'document_id'<>linked_document::text then raise exception 'document-linked reminder failed';end if;
  if not exists(select 1 from jsonb_array_elements(fp.reminder_dashboard()->'items') item where item->>'id'=standalone->>'id') then raise exception 'standalone reminder missing from dashboard';end if;
  perform fp.set_reminder_recurrence((standalone->>'id')::uuid,'monthly');
  perform fp.act_on_reminder((standalone->>'id')::uuid,'complete');
  if not exists(select 1 from fp.reminders where root_reminder_id=(standalone->>'id')::uuid and document_id is null and status='upcoming') then raise exception 'standalone reminder recurrence failed';end if;
  begin perform fp.create_reminder('Foreign reminder',current_date+2,null,'Pacific/Auckland',foreign_document,'phase1b-reminder-3');raise exception 'cross-family reminder unexpectedly succeeded';exception when insufficient_privilege then null;end;
  begin perform fp.create_reminder('',current_date+2,null,'Pacific/Auckland',null,'phase1b-reminder-4');raise exception 'missing title unexpectedly succeeded';exception when invalid_parameter_value then null;end;

  job:=fp.create_document_analysis_job('test.pdf','application/pdf',encode(convert_to('%PDF-1.4 synthetic','UTF8'),'base64'),'invoice','phase1b-analysis-1');
  if job->>'status'<>'queued' or job->>'document_id' is null then raise exception 'job was not durably queued after upload';end if;
  duplicate:=fp.create_document_analysis_job('test.pdf','application/pdf',encode(convert_to('%PDF-1.4 synthetic','UTF8'),'base64'),'invoice','phase1b-analysis-1');
  if duplicate->>'job_id'<>job->>'job_id' or (duplicate->>'duplicate')::boolean is not true then raise exception 'job idempotency failed';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  claimed:=fp.claim_document_analysis_jobs(2);
  if jsonb_array_length(claimed)<>1 or claimed#>>'{0,job_id}'<>job->>'job_id' then raise exception 'atomic claim failed';end if;
  if jsonb_array_length(fp.claim_document_analysis_jobs(2))<>0 then raise exception 'active lease was claimed twice';end if;
  update fp.document_analysis_jobs set lease_expires_at=now()-interval '1 second' where id=(job->>'job_id')::uuid;
  claimed:=fp.claim_document_analysis_jobs(2);
  if jsonb_array_length(claimed)<>1 then raise exception 'expired lease was not recovered';end if;
  perform fp.complete_document_analysis_job((job->>'job_id')::uuid,jsonb_build_object('title','Test invoice','category','Documents','document_type','Invoice','provider_name','Synthetic','document_date',current_date::text,'tags',jsonb_build_array('invoice'),'text','Synthetic invoice text','mean_confidence',0.9));
  if (select status from fp.document_analysis_jobs where id=(job->>'job_id')::uuid)<>'succeeded' then raise exception 'result was not stored';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_id,'email','other-phase1b@example.test','role','authenticated')::text,true);
  begin perform fp.document_analysis_job((job->>'job_id')::uuid);raise exception 'cross-family status unexpectedly succeeded';exception when sqlstate 'PT404' then null;end;
  begin perform fp.retry_document_analysis_job((job->>'job_id')::uuid);raise exception 'cross-family retry unexpectedly succeeded';exception when sqlstate 'PT404' then null;end;
end $$;

rollback;
