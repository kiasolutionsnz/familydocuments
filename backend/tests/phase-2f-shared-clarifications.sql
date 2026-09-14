begin;

do $$
declare
  owner_id constant uuid := '52000000-0000-4000-8000-000000000001';
  outsider_id constant uuid := '52000000-0000-4000-8000-000000000002';
  family_id constant uuid := '52000000-0000-4000-8000-000000000011';
  other_family constant uuid := '52000000-0000-4000-8000-000000000012';
  test_conversation uuid;
  attachment_id uuid;
  clarification_id uuid;
  result jsonb;
  presented jsonb;
  extra_category uuid;
  foreign_category uuid;
  drive_reservation jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_id,'Clarification Family',owner_id),
    (other_family,'Other Clarification Family',outsider_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_id,owner_id,'clarification-owner@example.test','owner'),
    (other_family,outsider_id,'clarification-other@example.test','owner');
  insert into fp.categories(household_id,name,created_by) values
    (family_id,'Home',owner_id),
    (family_id,'Insurance',owner_id),
    (family_id,'Finance',owner_id),
    (family_id,'Rentals',owner_id),
    (family_id,'Travel',owner_id),
    (other_family,'Private category',outsider_id)
    on conflict(household_id,name) do nothing;
  select id into extra_category from fp.categories
    where household_id=family_id and name='Travel';
  select id into foreign_category from fp.categories
    where household_id=other_family and name='Private category';
  perform set_config('request.jwt.claims',jsonb_build_object(
    'sub',owner_id,'email','clarification-owner@example.test',
    'role','authenticated','family_id',family_id)::text,true);
  test_conversation := (fp.start_conversation('shared-clarification-test')->>'id')::uuid;
  insert into fp.google_drive_credentials(household_id,encrypted_refresh_token,token_nonce,scopes,connected_by)
    values(family_id,repeat('x',48),repeat('x',16),'https://www.googleapis.com/auth/drive.file',owner_id);
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,status,configured_by)
    values(family_id,'google_drive','clarification-folder-001','Family files','active',owner_id);
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  drive_reservation:=fp.reserve_conversation_drive_upload(test_conversation,owner_id,family_id,
    'clarification-file-001','synthetic-bill.pdf','application/pdf',9,repeat('c',64));
  attachment_id:=(fp.finish_conversation_drive_upload((drive_reservation->>'id')::uuid,owner_id,family_id,test_conversation,
    'clarification-file-001','2026-09-14T00:00:00Z','1',repeat('d',32))->>'id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object(
    'sub',owner_id,'email','clarification-owner@example.test',
    'role','authenticated','family_id',family_id)::text,true);
  result := fp.submit_conversation_action(test_conversation,'clarification-action-0001',
    'request_clarification',1,jsonb_build_object('question',
      'Which category should I save this document in?',
      'missing_parameter','category_name','attachment_id',attachment_id,
      'tags','[]'::jsonb),'clarification-request-0001',false);
  clarification_id := (result->>'execution_id')::uuid;
  if result->>'state' <> 'awaiting_clarification'
    or jsonb_array_length(result#>'{result,choices}') > 3
    or not (result#>'{result,choices}') ? 'Finance'
    or not (result#>'{result,choices}') ? 'Read document'
  then raise exception 'shared primary category options are missing or unbounded'; end if;
  select m.message_data into presented from fp.conversation_messages m
    where m.conversation_id=test_conversation
      and m.client_message_id='outcome-'||clarification_id;
  if presented->>'clarification_id' <> clarification_id::text
    or presented->>'show_more_categories' <> 'true'
    or presented->>'can_save' <> 'true'
    or presented->'choices' is distinct from result#>'{result,choices}'
  then raise exception 'response and restoration use different options'; end if;
  if presented::text like '%Private category%' then
    raise exception 'other Family category leaked into presentation';
  end if;
  begin
    perform fp.select_conversation_category(clarification_id,foreign_category);
    raise exception 'cross-Family category was accepted';
  exception when insufficient_privilege then null;
  end;
  update fp.members set role='viewer' where user_id=owner_id and household_id=family_id;
  if (fp.conversation_category_options(test_conversation,attachment_id)->>'can_save')::boolean then
    raise exception 'read-only member can save';
  end if;
  begin
    result := fp.select_conversation_category(clarification_id,extra_category);
    if result->>'state'='succeeded' then raise exception 'read-only save succeeded';end if;
  exception when insufficient_privilege then null;
  end;
  if exists(select 1 from fp.documents where household_id=family_id) then
    raise exception 'denied category selection changed documents';
  end if;
  update fp.members set role='owner' where user_id=owner_id and household_id=family_id;
  result := fp.submit_conversation_action(test_conversation,'clarification-action-0002',
    'request_clarification',1,jsonb_build_object('question',
      'Which category should I save this document in?',
      'missing_parameter','category_name','attachment_id',attachment_id,
      'tags','[]'::jsonb),'clarification-request-0002',false);
  clarification_id := (result->>'execution_id')::uuid;
  result := fp.select_conversation_category(clarification_id,extra_category);
  if result->>'state' <> 'succeeded'
    or (select count(*) from fp.documents where household_id=family_id) <> 1
    or (select count(*) from fp.documents where household_id=family_id
      and category_id=extra_category) <> 1
    or (select count(*) from fp.document_analysis_jobs j join fp.documents d
      on d.id=j.document_id where d.household_id=family_id) <> 0
  then raise exception 'secondary category selection did not save once without OCR'; end if;
  if (select message_data->>'resolved' from fp.conversation_messages
    where client_message_id='outcome-'||clarification_id) <> 'true'
  then raise exception 'resolved clarification remained interactive'; end if;
  begin
    perform fp.select_conversation_category(clarification_id,extra_category);
    raise exception 'replayed category selection succeeded';
  exception when sqlstate 'PT409' then null;
  end;
  result := fp.submit_conversation_action(test_conversation,'reminder-draft-0001',
    'request_clarification',1,jsonb_build_object('question','What should I remind you about?',
      'missing_parameter','reminder_title','draft_date','2027-01-20',
      'draft_time','11:00:00'),'reminder-draft-request-0001',false);
  if result->>'state'<>'awaiting_clarification' then raise exception 'reminder draft rejected';end if;
  presented := fp.conversation_workspace(test_conversation);
  if not exists(select 1 from jsonb_array_elements(presented->'messages') m
      where m#>>'{data,action,parameters,draft_date}'='2027-01-20'
        and m#>>'{data,action,parameters,draft_time}'='11:00:00') then
    raise exception 'reminder draft fields were not restored';
  end if;
end $$;

rollback;
