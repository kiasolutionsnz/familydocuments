begin;

do $$
<<hardening>>
declare
  owner_id constant uuid:='26000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='26000000-0000-4000-8000-000000000002';
  other_owner constant uuid:='26000000-0000-4000-8000-000000000003';
  family_one constant uuid:='26000000-0000-4000-8000-000000000011';
  family_two constant uuid:='26000000-0000-4000-8000-000000000012';
  category_one constant uuid:='26000000-0000-4000-8000-000000000021';
  category_two constant uuid:='26000000-0000-4000-8000-000000000022';
  category_foreign constant uuid:='26000000-0000-4000-8000-000000000023';
  document_one constant uuid:='26000000-0000-4000-8000-000000000031';
  document_two constant uuid:='26000000-0000-4000-8000-000000000032';
  document_foreign constant uuid:='26000000-0000-4000-8000-000000000033';
  conversation_id uuid;confirmation_id uuid;reminder_id uuid;result jsonb;i integer;
begin
  if has_function_privilege('authenticated','fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean)','execute')
    or has_function_privilege('authenticated','fp.decide_conversation_confirmation(uuid,text)','execute')
    or has_function_privilege('authenticated','fp.stage_conversation_attachment(uuid,text,text,text)','execute')
    or has_function_privilege('authenticated','fp.consume_conversation_rate_limit(text,integer,integer)','execute') then
    raise exception 'trusted execution RPC is callable directly by authenticated clients';
  end if;
  if exists(
    select 1 from unnest(array['save_document','request_document_ocr','update_document_category','update_document_tags','create_reminder','update_reminder','save_link','mark_inbox_reviewed','dismiss_inbox_item']) action_name
    where not fp.conversation_requires_confirmation(action_name,'{}'::jsonb,true)
  ) then raise exception 'a model-derived mutation bypasses confirmation';end if;
  insert into fp.households(id,name,owner_user_id) values
    (family_one,'Hardening Family One',owner_id),(family_two,'Hardening Family Two',other_owner);
  insert into fp.members(household_id,user_id,email,role) values
    (family_one,owner_id,'hardening-owner@example.test','owner'),
    (family_two,owner_id,'hardening-owner@example.test','adult_member'),
    (family_one,viewer_id,'hardening-viewer@example.test','viewer'),
    (family_two,other_owner,'hardening-other@example.test','owner');
  insert into fp.saved_link_categories(household_id,owner_user_id,name) values(family_one,owner_id,'Travel');
  insert into fp.categories(id,household_id,name,created_by) values
    (category_one,family_one,'Hardening One',owner_id),(category_two,family_one,'Hardening Two',owner_id),(category_foreign,family_two,'Foreign',other_owner);
  insert into fp.documents(id,household_id,category_id,title,created_by,tags,confirmation_status) values
    (document_one,family_one,category_one,'Synthetic first record',owner_id,'["old"]','confirmed'),
    (document_two,family_one,category_one,'Synthetic second record',owner_id,'["old"]','confirmed'),
    (document_foreign,family_two,category_foreign,'Foreign record',other_owner,'[]','confirmed');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','hardening-owner@example.test','role','authenticated')::text,true);
  result:=fp.active_family_workspace();
  if (result->>'selection_required')::boolean is not true then raise exception 'multiple Families did not require an explicit selection';end if;
  perform fp.select_active_family(family_one);
  conversation_id:=(fp.start_conversation('hardening-conversation-0001')->>'id')::uuid;
  begin perform fp.normalise_saved_link_url('https://user:password@example.com');raise exception 'credential-bearing URL accepted';exception when invalid_parameter_value then null;end;
  begin perform fp.normalise_saved_link_url('https://8.8.8.8/path');raise exception 'IP-literal URL accepted';exception when invalid_parameter_value then null;end;

  result:=fp.submit_conversation_action(conversation_id,'hardening-document-category','update_document_category',1,jsonb_build_object('document_id',document_one,'category_name','Hardening Two'),'hardening-request-category',true);
  confirmation_id:=(result->'confirmation'->>'id')::uuid;
  update fp.documents set updated_at=clock_timestamp()+interval '1 second' where id=document_one;
  result:=fp.decide_conversation_confirmation(confirmation_id,'confirm');
  if result->>'state'<>'retryable' or (select category_id from fp.documents where id=document_one)<>category_one then raise exception 'stale document category confirmation executed';end if;

  result:=fp.submit_conversation_action(conversation_id,'hardening-document-tags','update_document_tags',1,jsonb_build_object('document_id',document_two,'tags',jsonb_build_array('New'),'operation','add'),'hardening-request-tags',true);
  confirmation_id:=(result->'confirmation'->>'id')::uuid;
  update fp.documents set updated_at=clock_timestamp()+interval '1 second' where id=document_two;
  result:=fp.decide_conversation_confirmation(confirmation_id,'confirm');
  if result->>'state'<>'retryable' or (select tags from fp.documents where id=document_two)<>jsonb_build_array('old') then raise exception 'stale document tag confirmation executed';end if;

  begin
    perform fp.submit_conversation_action(conversation_id,'hardening-foreign-document','update_document_category',1,jsonb_build_object('document_id',document_foreign,'category_name','Hardening Two'),'hardening-request-foreign',false);
    raise exception 'cross-Family target substitution was accepted';
  exception when insufficient_privilege then null;end;

  begin
    perform fp.submit_conversation_action(conversation_id,'hardening-action-unknown','save_link',1,'{"url":"https://example.com","category_name":"Travel","sql":"select 1"}','hardening-request-unknown',false);
    raise exception 'unknown action property was accepted';
  exception when invalid_parameter_value then null;end;

  result:=fp.submit_conversation_action(conversation_id,'hardening-action-link-0001','save_link',1,'{"url":"https://example.com/travel","category_name":"Travel"}','hardening-request-link-0001',true);
  if result->>'state'<>'awaiting_confirmation' then raise exception 'model mutation did not require confirmation';end if;
  confirmation_id:=(result->'confirmation'->>'id')::uuid;
  result:=fp.decide_conversation_confirmation(confirmation_id,'confirm');
  if result->>'state'<>'succeeded' or (select count(*) from fp.saved_links where household_id=family_one and owner_user_id=owner_id)<>1 then raise exception 'confirmed link did not execute once';end if;
  result:=fp.decide_conversation_confirmation(confirmation_id,'confirm');
  if (result->>'duplicate')::boolean is not true or (select count(*) from fp.saved_links where household_id=family_one and owner_user_id=owner_id)<>1 then raise exception 'confirmation replay duplicated a mutation';end if;
  result:=fp.submit_conversation_action(conversation_id,'hardening-action-link-0001','save_link',1,'{"url":"https://example.com/travel","category_name":"Travel"}','hardening-request-link-0001',true);
  if (result->>'duplicate')::boolean is not true then raise exception 'lost-response replay did not return the original outcome';end if;
  begin
    perform fp.submit_conversation_action(conversation_id,'hardening-action-link-0002','save_link',1,'{"url":"https://example.com/changed","category_name":"Travel"}','hardening-request-link-0001',true);
    raise exception 'idempotency substitution was accepted';
  exception when sqlstate 'PT409' then null;end;

  result:=fp.submit_conversation_action(conversation_id,'hardening-action-reminder-create','create_reminder',1,'{"title":"Synthetic appointment","due_date":"2027-01-20","due_time":"14:00"}','hardening-request-reminder-create',false);
  if result->>'state'<>'succeeded' then raise exception 'reminder creation failed: %',result;end if;
  reminder_id:=(result->'result'->>'reminder_id')::uuid;
  result:=fp.submit_conversation_action(conversation_id,'hardening-action-reminder-update','update_reminder',1,jsonb_build_object('reminder_id',reminder_id,'operation','one_week_before','expected_due_date','2027-01-20'),'hardening-request-reminder-update',true);
  confirmation_id:=(result->'confirmation'->>'id')::uuid;
  update fp.reminders set due_at='2027-01-21',updated_at=clock_timestamp()+interval '1 second' where id=reminder_id;
  result:=fp.decide_conversation_confirmation(confirmation_id,'confirm');
  if result->>'state'<>'retryable' or result->>'error_category'<>'stale_target' then raise exception 'stale reminder confirmation executed';end if;

  for i in 1..61 loop
    perform fp.append_conversation_message(conversation_id,'hardening-message-'||lpad(i::text,4,'0'),'user','text','Synthetic bounded message '||i,'{}');
  end loop;
  if (select count(*) from fp.conversation_messages m where m.conversation_id=hardening.conversation_id)>60 then raise exception 'server message bound was not enforced';end if;

  result:=fp.submit_conversation_action(conversation_id,'hardening-action-family-switch','save_link',1,'{"url":"https://example.com/pending","category_name":"Travel"}','hardening-request-family-switch',true);
  confirmation_id:=(result->'confirmation'->>'id')::uuid;
  perform fp.select_active_family(family_two);
  begin perform fp.decide_conversation_confirmation(confirmation_id,'confirm');raise exception 'confirmation survived Family change';exception when insufficient_privilege then null;end;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','hardening-viewer@example.test','role','authenticated')::text,true);
  perform fp.select_active_family(family_one);
  result:=fp.start_conversation('hardening-viewer-conversation');
  result:=fp.submit_conversation_action((result->>'id')::uuid,'hardening-viewer-save-link','save_link',1,'{"url":"https://example.com/viewer","category_name":"Travel"}','hardening-viewer-request',false);
  if result->>'state'<>'failed_before_mutation' or result->>'error_category'<>'permission_denied' then raise exception 'read-only mutation was not denied authoritatively';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','hardening-owner@example.test','role','authenticated')::text,true);
  perform fp.select_active_family(family_one);
  insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status,created_at)
    values(family_one,owner_id,conversation_id,'search_family_content',repeat('b',64),'succeeded',now()-interval '366 days');
  perform fp.start_conversation('hardening-retention-cleanup');
  if exists(select 1 from fp.conversation_security_receipts r where r.action_digest=repeat('b',64)) then raise exception 'expired security receipt was retained';end if;
  perform fp.delete_conversation(conversation_id);
  if exists(select 1 from fp.conversations c where c.id=hardening.conversation_id) then raise exception 'conversation deletion failed';end if;
  if not exists(select 1 from fp.conversation_security_receipts r where r.conversation_id=hardening.conversation_id and r.status='succeeded') then raise exception 'minimized audit receipt was deleted with transcript';end if;
  if (select count(*) from fp.saved_links where household_id=family_one and owner_user_id=owner_id)<>1 then raise exception 'conversation deletion changed saved content';end if;
end$$;

rollback;
