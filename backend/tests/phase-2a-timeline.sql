begin;

do $$
declare
  owner_id constant uuid:='21000000-0000-4000-8000-000000000001';
  other_id constant uuid:='21000000-0000-4000-8000-000000000002';
  member_id constant uuid:='21000000-0000-4000-8000-000000000003';
  household_id uuid:=gen_random_uuid();other_household uuid:=gen_random_uuid();category_id uuid:=gen_random_uuid();
  doc_id uuid:=gen_random_uuid();foreign_document uuid:=gen_random_uuid();job_id uuid:=gen_random_uuid();
  link_category uuid:=gen_random_uuid();foreign_link_category uuid:=gen_random_uuid();
  local_alias uuid:=gen_random_uuid();foreign_alias uuid:=gen_random_uuid();result jsonb;linked_reminder jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(household_id,'Timeline family',owner_id),(other_household,'Other timeline family',other_id);
  insert into fp.members(household_id,user_id,email,role) values
    (household_id,owner_id,'timeline@example.test','owner'),
    (household_id,member_id,'timeline-member@example.test','viewer'),
    (other_household,other_id,'other-timeline@example.test','owner');
  insert into fp.categories(id,household_id,name,is_system,created_by) values(category_id,household_id,'Documents',true,owner_id);
  insert into fp.categories(household_id,name,is_system,created_by) values(other_household,'Documents',true,other_id);
  insert into fp.saved_link_categories(id,household_id,owner_user_id,name) values(link_category,household_id,owner_id,'Research');
  insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title)
    values(household_id,owner_id,link_category,'https://example.test/local',repeat('2',64),'example.test','Timeline link');
  insert into fp.saved_link_categories(id,household_id,owner_user_id,name) values(foreign_link_category,other_household,other_id,'Foreign links');
  insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title)
    values(other_household,other_id,foreign_link_category,'https://example.test/foreign',repeat('1',64),'example.test','Foreign timeline link');
  insert into fp.reminders(household_id,document_id,title,due_at,created_by)
    values(other_household,null,'Foreign timeline reminder',current_date+1,other_id);
  insert into fp.household_inbox_aliases(id,household_id,local_part,created_by)
    values(foreign_alias,other_household,'family-111111111111111111111111',other_id);
  insert into fp.household_inbox_aliases(id,household_id,local_part,created_by)
    values(local_alias,household_id,'family-222222222222222222222222',owner_id);
  insert into fp.inbound_emails(household_id,inbox_alias_id,source_system,external_message_id,sender_address,recipient_addresses,subject,
    raw_email,raw_sha256,raw_size_bytes,body_text,attachment_manifest,attachment_count,attachment_status)
    values(other_household,foreign_alias,'mailpit_local','foreign-timeline-message','sender@example.test',jsonb_build_array('foreign@example.test'),
      'Foreign timeline message',convert_to('synthetic','UTF8'),repeat('0',64),9,'synthetic','[]'::jsonb,0,'none');
  insert into fp.inbound_emails(household_id,inbox_alias_id,source_system,external_message_id,sender_address,recipient_addresses,subject,
    raw_email,raw_sha256,raw_size_bytes,body_text,attachment_manifest,attachment_count,attachment_status)
    values(household_id,local_alias,'mailpit_local','local-timeline-message','sender@example.test',jsonb_build_array('local@example.test'),
      'Timeline message',convert_to('synthetic','UTF8'),repeat('3',64),9,'synthetic','[]'::jsonb,0,'none');
  insert into fp.documents(id,household_id,category_id,title,created_by,confirmation_status,tags) values
    (doc_id,household_id,category_id,'Timeline document',owner_id,'confirmed',jsonb_build_array('test'));
  insert into fp.documents(id,household_id,category_id,title,created_by,confirmation_status)
    select foreign_document,other_household,c.id,'Foreign timeline document',other_id,'confirmed' from fp.categories c where c.household_id=other_household limit 1;
  insert into fp.document_analysis_jobs(id,household_id,document_id,requested_by,status,idempotency_key)
    values(job_id,household_id,doc_id,owner_id,'queued','timeline-analysis-1');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','timeline@example.test','role','authenticated')::text,true);
  perform fp.create_reminder('Timeline reminder',current_date+1,null,'Pacific/Auckland',null,'timeline-reminder-1');
  linked_reminder:=fp.create_reminder('Document reminder',current_date+2,null,'Pacific/Auckland',doc_id,'timeline-reminder-2');
  perform fp.set_reminder_audience((linked_reminder->>'id')::uuid,'family',false);
  result:=fp.family_timeline(null,null,null,40);
  if not exists(select 1 from jsonb_array_elements(result->'items') x where x->>'job_id'=job_id::text and x->>'status'='queued') then raise exception 'active OCR missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'items') x where x->>'kind'='reminder') then raise exception 'reminder missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'items') x where x->>'kind'='link') then raise exception 'saved link missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'items') x where x->>'kind'='message') then raise exception 'message missing';end if;
  if exists(select 1 from jsonb_array_elements(result->'items') x where x->>'title' like '%Foreign%') then raise exception 'cross-family document exposed';end if;
  if exists(select 1 from jsonb_array_elements(result->'items') x where x->>'event_key'='document:'||doc_id::text) then raise exception 'analysis document duplicated';end if;

  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by) values(doc_id,member_id,'view',owner_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',member_id,'email','timeline-member@example.test','role','authenticated')::text,true);
  if not exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'job_id'=job_id::text) then raise exception 'permitted document missing';end if;
  if not exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'event_key'='reminder-created:'||(linked_reminder->>'id')) then raise exception 'permitted document reminder missing';end if;
  delete from fp.document_permissions where document_id=doc_id and member_user_id=member_id;
  if exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'job_id'=job_id::text) then raise exception 'revoked document remained visible';end if;
  if exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'event_key'='reminder-created:'||(linked_reminder->>'id')) then raise exception 'revoked document reminder remained visible';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_id,'email','other-timeline@example.test','role','authenticated')::text,true);
  if exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'job_id'=job_id::text) then raise exception 'cross-family OCR job exposed';end if;
  if exists(select 1 from jsonb_array_elements(fp.family_timeline(null,null,null,40)->'items') x where x->>'title' in ('Timeline link saved','Timeline message','Timeline reminder reminder created')) then raise exception 'cross-family Timeline activity exposed';end if;
end $$;

rollback;
