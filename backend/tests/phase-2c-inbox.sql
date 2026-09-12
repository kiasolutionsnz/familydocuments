begin;

do $$
declare
  owner_id constant uuid:='23000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='23000000-0000-4000-8000-000000000002';
  outsider_id constant uuid:='23000000-0000-4000-8000-000000000003';
  family_id uuid:=gen_random_uuid();other_family uuid:=gen_random_uuid();alias_id uuid:=gen_random_uuid();other_alias uuid:=gen_random_uuid();
  category_id uuid:=gen_random_uuid();other_category uuid:=gen_random_uuid();link_category uuid:=gen_random_uuid();
  message_one uuid:=gen_random_uuid();message_two uuid:=gen_random_uuid();foreign_message uuid:=gen_random_uuid();attachment_id uuid:=gen_random_uuid();attachment_two uuid:=gen_random_uuid();
  pdf bytea:=convert_to('%PDF-1.4'||chr(10)||'1 0 obj<</Type/Catalog>>endobj'||chr(10)||'%%EOF','UTF8');result jsonb;first_document uuid;second_document uuid;home_document uuid;
begin
  insert into fp.households(id,name,owner_user_id) values(family_id,'Inbox family',owner_id),(other_family,'Other inbox family',outsider_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_id,owner_id,'inbox-owner@example.test','owner'),(family_id,viewer_id,'inbox-viewer@example.test','viewer'),(other_family,outsider_id,'inbox-outsider@example.test','owner');
  insert into fp.household_inbox_aliases(id,household_id,local_part,domain,created_by) values
    (alias_id,family_id,'family-111111111111111111111111','familydocuments.app',owner_id),(other_alias,other_family,'family-222222222222222222222222','familydocuments.app',outsider_id);
  insert into fp.categories(id,household_id,name,is_system,created_by) values(category_id,family_id,'Finance',false,owner_id),(other_category,other_family,'Private',false,outsider_id);
  insert into fp.saved_link_categories(id,household_id,owner_user_id,name) values(link_category,family_id,owner_id,'Research');
  insert into fp.inbound_sender_rules(household_id,sender_address,action,created_by) values
    (family_id,'sender@example.test','allow',owner_id),(family_id,'older@example.test','allow',owner_id),(other_family,'private@example.test','allow',outsider_id);
  insert into fp.inbound_emails(id,household_id,inbox_alias_id,source_system,external_message_id,sender_address,recipient_addresses,subject,raw_email,raw_sha256,raw_size_bytes,body_text,attachment_manifest,attachment_count,attachment_status,processing_status,sender_disposition,ingested_at) values
    (message_one,family_id,alias_id,'mailpit_local','inbox-one','sender@example.test','["family@example.test"]','Insurance invoice',pdf,repeat('1',64),octet_length(pdf),'<script>alert(1)</script><img src="https://tracker.example/pixel">Please review https://example.com/policy','[]',2,'quarantined_unscanned','needs_review','allowed',now()),
    (message_two,family_id,alias_id,'mailpit_local','inbox-two','older@example.test','["family@example.test"]','Earlier note',pdf,repeat('2',64),octet_length(pdf),'No action yet','[]',0,'none','needs_review','allowed',now()-interval '2 days'),
    (foreign_message,other_family,other_alias,'mailpit_local','foreign-one','private@example.test','["private@example.test"]','Other Family secret',pdf,repeat('3',64),octet_length(pdf),'private','[]',0,'none','needs_review','allowed',now());
  insert into fp.inbound_attachments(id,inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,content,content_sha256,scan_status)
    values
    (attachment_id,message_one,family_id,'part-1','synthetic-invoice.pdf','application/pdf',octet_length(pdf),encode(extensions.digest(pdf,'sha256'),'hex'),pdf,encode(extensions.digest(pdf,'sha256'),'hex'),'clean'),
    (attachment_two,message_one,family_id,'part-2','synthetic-terms.pdf','application/pdf',octet_length(pdf),encode(extensions.digest(pdf,'sha256'),'hex'),pdf,encode(extensions.digest(pdf,'sha256'),'hex'),'clean');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','inbox-owner@example.test','role','authenticated')::text,true);
  result:=fp.inbox_workspace(null,'all',20,0);
  if jsonb_array_length(result->'items')<>2 or result->'items'->0->>'subject'<>'Insurance invoice' then raise exception 'Family list or ordering failed';end if;
  if exists(select 1 from jsonb_array_elements(result->'items')x where x->>'subject'='Other Family secret') then raise exception 'cross-Family message leaked';end if;
  if jsonb_array_length(fp.inbox_workspace('older','all',20,0)->'items')<>1 or jsonb_array_length(fp.inbox_workspace('nothing matches','all',20,0)->'items')<>0 then raise exception 'metadata search failed';end if;
  if jsonb_array_length(fp.inbox_workspace(null,'attachments',20,0)->'items')<>1 or jsonb_array_length(fp.inbox_workspace(null,'links',20,0)->'items')<>1 then raise exception 'Inbox filters failed';end if;
  if fp.inbox_message_detail(message_one)->>'body_text' like '%<%' or fp.inbox_message_detail(message_one)->>'body_text' like '%alert(1)%' then raise exception 'unsafe body returned';end if;
  perform fp.set_inbox_review_state(message_two,'reviewed',null);
  if jsonb_array_length(fp.inbox_workspace(null,'reviewed',20,0)->'items')<>1 then raise exception 'review state failed';end if;
  result:=fp.inbox_save_attachment(message_one,attachment_id,category_id,'[" Invoice ","invoice","Family"]','save-request-0001',false);
  first_document:=(result->>'document_id')::uuid;
  if result->'tags'<>'["family","invoice"]'::jsonb or exists(select 1 from fp.document_analysis_jobs where document_id=first_document) then raise exception 'metadata-first save failed';end if;
  result:=fp.inbox_message_detail(message_one);
  if result->>'review_state'<>'unreviewed' or jsonb_array_length(result->'attachments')<>2
    or result->'actions'->0->>'attachment_id'<>attachment_id::text
    or result->'actions'->0->'result'->>'document_id'<>first_document::text
    then raise exception 'partial Inbox review or saved-document receipt failed';end if;
  result:=fp.inbox_save_attachment(message_one,attachment_two,category_id,'[]','save-request-0002',false);
  if jsonb_array_length(fp.inbox_workspace(null,'all',20,0)->'items'->0->'actions')<>2
    then raise exception 'Inbox summary lost a completed attachment action';end if;
  second_document:=(result->>'document_id')::uuid;
  if second_document=first_document or (fp.inbox_message_detail(message_one)->>'review_state')<>'unreviewed'
    then raise exception 'second attachment was not independently reviewable';end if;
  if (fp.inbox_save_attachment(message_one,attachment_id,category_id,'[]','save-request-0001',false)->>'document_id')::uuid<>first_document then raise exception 'save idempotency failed';end if;
  result:=fp.inbox_save_attachment(message_one,attachment_id,category_id,'["invoice"]','ocr-request-0001',true);
  perform fp.inbox_save_attachment(message_one,attachment_id,category_id,'["invoice"]','ocr-request-0001',true);
  if result->>'document_id'<>first_document::text or result->>'duplicate'<>'true'
    or (select count(*) from fp.document_analysis_jobs where document_id=first_document)<>0
    then raise exception 'saved Inbox attachment was duplicated or OCR was started';end if;
  result:=fp.create_document_analysis_job('reselected.pdf','application/pdf',encode(pdf,'base64'),'document','home-dedupe-0001');
  home_document:=(result->>'document_id')::uuid;
  result:=fp.create_document_analysis_job('reselected.pdf','application/pdf',encode(pdf,'base64'),'document','home-dedupe-0002');
  if (result->>'document_id')::uuid<>home_document or result->>'duplicate'<>'true' then raise exception 'Home content deduplication failed';end if;
  if (select count(*) from fp.document_analysis_jobs where document_id=home_document)<>1 then raise exception 'Home duplicate OCR job created';end if;
  perform fp.inbox_create_reminder(message_one,'Review insurance','2027-01-20','14:00','none','reminder-request-0001');
  perform fp.inbox_create_reminder(message_one,'Review insurance','2027-01-20','14:00','none','reminder-request-0001');
  perform fp.inbox_create_reminder(message_one,'Review insurance','2027-01-20','14:00','none','reminder-request-0002');
  if (select count(*) from fp.reminders where household_id=family_id and title='Review insurance')<>1 then raise exception 'reminder idempotency failed';end if;
  perform fp.inbox_save_link(message_one,'https://example.com/policy','Insurance policy',link_category,'link-request-0001');
  perform fp.inbox_save_link(message_one,'https://example.com/policy','Insurance policy',link_category,'link-request-0001');
  perform fp.inbox_save_link(message_one,'https://example.com/policy','Insurance policy',link_category,'link-request-0002');
  if (select count(*) from fp.inbox_actions where request_id='link-request-0001')<>1 then raise exception 'link idempotency failed';end if;
  if (select count(*) from fp.inbox_actions where inbound_email_id=message_one and action_type='link_saved')<>1 then raise exception 'lost-response link retry created duplicate';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','inbox-viewer@example.test','role','authenticated')::text,true);
  if jsonb_array_length(fp.inbox_workspace(null,'all',20,0)->'items')<>2 or (fp.inbox_workspace(null,'all',20,0)->>'can_edit')::boolean then raise exception 'viewer read permission failed';end if;
  begin perform fp.set_inbox_review_state(message_one,'reviewed',null);raise exception 'viewer changed Inbox';exception when insufficient_privilege then null;end;
  begin perform fp.inbox_save_attachment(message_one,attachment_id,other_category,'[]','viewer-request-0001',false);raise exception 'cross-Family/viewer mutation accepted';exception when insufficient_privilege then null;end;
  update fp.members set status='suspended' where household_id=family_id and user_id=viewer_id;
  begin perform fp.inbox_message_detail(message_one);raise exception 'revoked member retained access';exception when sqlstate 'PT404' or insufficient_privilege then null;end;

  insert into fp.members(household_id,user_id,email,role)
    values(other_family,owner_id,'inbox-owner@example.test','adult_member');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','inbox-owner@example.test','role','authenticated')::text,true);
  perform fp.select_active_family(other_family);
  result:=fp.inbox_workspace(null,'all',20,0);
  if jsonb_array_length(result->'items')<>1 or result->'items'->0->>'subject'<>'Other Family secret'
    then raise exception 'Inbox did not follow selected Family';end if;
  begin perform fp.inbox_message_detail(message_one);raise exception 'previous Family detail exposed';exception when sqlstate 'PT404' then null;end;
  begin perform fp.set_inbox_review_state(message_one,'reviewed',null);raise exception 'previous Family review changed';exception when sqlstate 'PT404' then null;end;
  begin perform fp.inbox_save_attachment(message_one,attachment_id,category_id,'[]','foreign-save-0001',false);raise exception 'previous Family attachment saved';exception when sqlstate 'PT404' then null;end;
  begin perform fp.inbox_create_reminder(message_one,'Should fail','2027-01-20',null,'none','foreign-reminder-0001');raise exception 'previous Family reminder created';exception when sqlstate 'PT404' then null;end;
  begin perform fp.inbox_save_link(message_one,'https://example.com/policy','Should fail',link_category,'foreign-link-0001');raise exception 'previous Family link saved';exception when sqlstate 'PT404' then null;end;
end$$;

rollback;
