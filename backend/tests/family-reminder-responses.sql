begin;

do $$
declare
  owner_id constant uuid:='10000000-0000-4000-8000-000000000001';
  member_id constant uuid:='10000000-0000-4000-8000-000000000002';
  household_id uuid:=gen_random_uuid();category_id uuid:=gen_random_uuid();document_id uuid:=gen_random_uuid();v_reminder_id uuid:=gen_random_uuid();result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(household_id,'Reminder acceptance household',owner_id);
  insert into fp.members(household_id,user_id,email,display_name,role) values
    (household_id,owner_id,'reminder-owner@example.test','Owner','owner'),
    (household_id,member_id,'reminder-member@example.test','Member','adult_member');
  insert into fp.categories(id,household_id,name,is_system,created_by) values(category_id,household_id,'Tasks',true,owner_id);
  insert into fp.documents(id,household_id,category_id,title,created_by,confirmation_status,privacy_mode) values(document_id,household_id,category_id,'Synthetic family task',owner_id,'confirmed','private');
  insert into fp.reminders(id,household_id,document_id,title,due_at,created_by) values(v_reminder_id,household_id,document_id,'Synthetic family task',current_date+1,owner_id);

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','reminder-owner@example.test','role','authenticated')::text,true);
  result:=fp.set_reminder_audience(v_reminder_id,'family',true);
  if result->>'audience'<>'family' or (result->>'email_all_members')::boolean is not true then raise exception 'family audience was not enabled';end if;
  if (select count(*) from fp.reminder_member_responses x where x.reminder_id=v_reminder_id)<>2 then raise exception 'active family response rows were not created';end if;

  perform fp.enqueue_due_notifications();
  if (select count(*) from fp.notification_outbox where dedupe_key like 'reminder_due_day:'||v_reminder_id::text||':%')<>2 then raise exception 'family due-day email was not queued for every active member';end if;
  if exists(
    select 1 from fp.notification_outbox
    where dedupe_key like 'reminder_due_day:'||v_reminder_id::text||':%'
      and available_at<>((current_date+1+time '08:00') at time zone 'Pacific/Auckland')
  ) then raise exception 'family reminder was not scheduled for 08:00 Pacific/Auckland on its due date';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',member_id,'email','reminder-member@example.test','role','authenticated')::text,true);
  result:=fp.reminder_dashboard();
  if jsonb_array_length(result->'items')<>1 or result#>>'{items,0,audience}'<>'family' then raise exception 'family reminder was not visible to the member';end if;
  result:=fp.respond_to_family_reminder(v_reminder_id,'acknowledge');
  if result->>'member_status'<>'acknowledged' then raise exception 'acknowledgement was not recorded';end if;
  result:=fp.respond_to_family_reminder(v_reminder_id,'complete');
  if result->>'reminder_status'<>'completed' or (select completed_by from fp.reminders where id=v_reminder_id)<>member_id then raise exception 'family completion actor was not recorded';end if;
end $$;

rollback;
