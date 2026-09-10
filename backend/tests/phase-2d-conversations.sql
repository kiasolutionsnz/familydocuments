begin;

do $$
<<phase2d>>
declare
  owner_id constant uuid:='24000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='24000000-0000-4000-8000-000000000002';
  outsider_id constant uuid:='24000000-0000-4000-8000-000000000003';
  family_id uuid:=gen_random_uuid();other_family uuid:=gen_random_uuid();
  conversation_id uuid;duplicate_id uuid;reminder_id uuid;result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_id,'Conversation test Family',owner_id),
    (other_family,'Other conversation Family',outsider_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_id,owner_id,'conversation-owner@example.test','owner'),
    (family_id,viewer_id,'conversation-viewer@example.test','viewer'),
    (other_family,outsider_id,'conversation-outsider@example.test','owner');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','conversation-owner@example.test','role','authenticated')::text,true);
  conversation_id:=(fp.start_conversation('conversation-request-0001')->>'id')::uuid;
  duplicate_id:=(fp.start_conversation('conversation-request-0001')->>'id')::uuid;
  if duplicate_id<>conversation_id then raise exception 'conversation start was not idempotent';end if;

  perform fp.append_conversation_message(conversation_id,'message-request-0001','user','text','Find my passport','{}');
  perform fp.append_conversation_message(conversation_id,'message-request-0001','user','text','Find my passport','{}');
  if (select count(*) from fp.conversation_messages m where m.conversation_id=phase2d.conversation_id)<>1 then
    raise exception 'message append was not idempotent';
  end if;
  result:=fp.conversation_workspace(conversation_id);
  if result->'conversation'->>'id'<>conversation_id::text or jsonb_array_length(result->'messages')<>1 then
    raise exception 'conversation restore failed';
  end if;

  perform fp.set_conversation_confirmation(
    conversation_id,'action-create-category-0001','save_document',1,
    '{"attachment_id":"current-attachment","category_name":"Travel","create_category":true}',
    'Create Travel and save this document there?','Selected document',now()+interval '10 minutes'
  );
  perform fp.consume_conversation_confirmation(conversation_id,'action-create-category-0001',true);

  result:=fp.create_reminder('Synthetic appointment','2027-01-20','14:00','Pacific/Auckland',null,'conversation-reminder-0001');
  reminder_id:=(result->>'id')::uuid;
  perform fp.set_conversation_confirmation(
    conversation_id,'action-update-reminder-0001','update_reminder',1,
    jsonb_build_object('reminder_id',reminder_id,'operation','one_week_before','expected_due_date','2027-01-20'),
    'Move this reminder one week earlier?','Synthetic appointment',now()+interval '10 minutes'
  );
  if fp.conversation_workspace(conversation_id)->'pending_confirmation'->>'target_label'<>'Synthetic appointment' then
    raise exception 'confirmation was not restorable';
  end if;
  perform fp.consume_conversation_confirmation(conversation_id,'action-update-reminder-0001',false);
  begin
    perform fp.consume_conversation_confirmation(conversation_id,'action-update-reminder-0001',false);
    raise exception 'confirmation executed twice';
  exception when sqlstate 'PT409' then null;end;
  result:=fp.update_conversation_reminder(reminder_id,'one_week_before','2027-01-20');
  if result->>'due_at'<>'2027-01-13' then raise exception 'confirmed reminder update failed';end if;
  begin
    perform fp.update_conversation_reminder(reminder_id,'one_week_before','2027-01-20');
    raise exception 'stale reminder update succeeded';
  exception when serialization_failure then null;end;

  perform fp.record_conversation_action(conversation_id,'action-receipt-0001','update_reminder','succeeded','reminder',reminder_id,'{"result_type":"update_reminder"}');
  result:=fp.record_conversation_action(conversation_id,'action-receipt-0001','update_reminder','succeeded','reminder',reminder_id,'{}');
  if (result->>'duplicate')::boolean is not true or (select count(*) from fp.conversation_action_receipts where action_id='action-receipt-0001')<>1 then
    raise exception 'action receipt was not idempotent';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','conversation-viewer@example.test','role','authenticated')::text,true);
  if fp.conversation_workspace(conversation_id)->>'conversation' is not null then raise exception 'another user restored the owner conversation';end if;
  begin
    perform fp.update_conversation_reminder(reminder_id,'one_week_before','2027-01-13');
    raise exception 'read-only user changed reminder';
  exception when insufficient_privilege then null;end;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider_id,'email','conversation-outsider@example.test','role','authenticated')::text,true);
  if fp.conversation_workspace(conversation_id)->>'conversation' is not null then raise exception 'cross-Family conversation leaked';end if;
  begin
    perform fp.update_conversation_reminder(reminder_id,'one_week_before','2027-01-13');
    raise exception 'cross-Family reminder changed';
  exception when insufficient_privilege then null;end;

  update fp.members set status='suspended' where household_id=family_id and user_id=owner_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','conversation-owner@example.test','role','authenticated')::text,true);
  begin
    perform fp.append_conversation_message(conversation_id,'message-request-0002','user','text','Still here','{}');
    raise exception 'revoked member retained conversation access';
  exception when insufficient_privilege then null;end;
end$$;

rollback;
