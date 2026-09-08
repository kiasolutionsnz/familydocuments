begin;

alter table fp.reminders add column if not exists audience text not null default 'personal';
alter table fp.reminders add column if not exists email_all_members boolean not null default false;
alter table fp.reminders drop constraint if exists reminders_audience_check;
alter table fp.reminders add constraint reminders_audience_check check(audience in ('personal','family'));
alter table fp.reminders drop constraint if exists reminders_family_email_check;
alter table fp.reminders add constraint reminders_family_email_check check(audience='family' or not email_all_members);

create table if not exists fp.reminder_member_responses(
  reminder_id uuid not null references fp.reminders(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  member_user_id uuid not null,
  status text not null default 'pending' check(status in ('pending','acknowledged','completed')),
  acknowledged_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(reminder_id,member_user_id)
);
create index if not exists reminder_member_responses_user on fp.reminder_member_responses(member_user_id,status,updated_at desc);
alter table fp.reminder_member_responses enable row level security;
alter table fp.reminder_member_responses force row level security;
revoke all on fp.reminder_member_responses from public,anon,authenticated;

create or replace function fp.set_reminder_audience(reminder uuid,new_audience text,email_everyone boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();r fp.reminders;
begin
  if new_audience not in ('personal','family') or (new_audience='personal' and email_everyone) then raise exception 'invalid reminder audience' using errcode='22023';end if;
  select * into r from fp.reminders where id=reminder for update;
  if r.id is null or r.created_by<>uid then raise exception 'not authorised' using errcode='42501';end if;
  if r.status<>'upcoming' then raise exception 'reminder already resolved' using errcode='22023';end if;
  update fp.reminders set audience=new_audience,email_all_members=case when new_audience='family' then email_everyone else false end,updated_at=now() where id=r.id;
  delete from fp.reminder_member_responses where reminder_id=r.id;
  if new_audience='family' then
    insert into fp.reminder_member_responses(reminder_id,household_id,member_user_id)
    select r.id,r.household_id,m.user_id from fp.members m where m.household_id=r.household_id and m.status='active'
    on conflict do nothing;
  end if;
  return jsonb_build_object('id',r.id,'audience',new_audience,'email_all_members',new_audience='family' and email_everyone);
end $$;

create or replace function fp.respond_to_family_reminder(reminder uuid,response_action text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();r fp.reminders;display_status text;
begin
  if response_action not in ('acknowledge','complete') then raise exception 'invalid response action' using errcode='22023';end if;
  select * into r from fp.reminders where id=reminder for update;
  if r.id is null or r.audience<>'family' or r.status<>'upcoming' or not exists(select 1 from fp.members m where m.household_id=r.household_id and m.user_id=uid and m.status='active') then raise exception 'not authorised' using errcode='42501';end if;
  display_status:=case when response_action='complete' then 'completed' else 'acknowledged' end;
  insert into fp.reminder_member_responses(reminder_id,household_id,member_user_id,status,acknowledged_at,completed_at,updated_at)
  values(r.id,r.household_id,uid,display_status,now(),case when response_action='complete' then now() end,now())
  on conflict(reminder_id,member_user_id) do update set status=excluded.status,acknowledged_at=coalesce(fp.reminder_member_responses.acknowledged_at,excluded.acknowledged_at),completed_at=excluded.completed_at,updated_at=now();
  if response_action='complete' then update fp.reminders set status='completed',completed_at=now(),completed_by=uid,completion_kind='completed',updated_at=now() where id=r.id;end if;
  return jsonb_build_object('id',r.id,'member_user_id',uid,'member_status',display_status,'reminder_status',(select status from fp.reminders where id=r.id));
end $$;

create or replace function fp.reminder_dashboard() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return jsonb_build_object('items','[]'::jsonb,'notifications','[]'::jsonb,'counts',jsonb_build_object('overdue',0,'due_soon',0,'unread',0));end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_time_zone',r.due_time_zone,'status',r.status,'recurrence',r.recurrence,'sequence_number',r.sequence_number,'snooze_count',r.snooze_count,'completion_kind',r.completion_kind,'completed_by',r.completed_by,'completed_by_name',(select coalesce(m.display_name,m.email) from fp.members m where m.household_id=r.household_id and m.user_id=r.completed_by),'audience',r.audience,'email_all_members',r.email_all_members,'my_response',(select x.status from fp.reminder_member_responses x where x.reminder_id=r.id and x.member_user_id=uid),'responses',coalesce((select jsonb_agg(jsonb_build_object('member_user_id',m.user_id,'name',coalesce(m.display_name,m.email),'status',coalesce(x.status,'pending'),'acknowledged_at',x.acknowledged_at,'completed_at',x.completed_at) order by coalesce(m.display_name,m.email)) from fp.members m left join fp.reminder_member_responses x on x.reminder_id=r.id and x.member_user_id=m.user_id where m.household_id=r.household_id and m.status='active'),'[]'::jsonb),'document_title',d.title,'category_name',c.name,'due_state',case when r.status='upcoming' and r.due_at<current_date then 'overdue' when r.status='upcoming' and r.due_at=current_date then 'today' when r.status='upcoming' then 'upcoming' else r.status end,'days_until',r.due_at-current_date) order by case when r.status='upcoming' then 0 else 1 end,r.due_at desc,r.due_time desc nulls last) from fp.reminders r join fp.documents d on d.id=r.document_id join fp.categories c on c.id=d.category_id where r.household_id=hid and d.lifecycle_status<>'deleted' and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'title',r.title,'due_at',r.due_at,'due_time',r.due_time,'due_state',case when r.due_at<current_date then 'overdue' when r.due_at=current_date then 'today' else 'due_soon' end,'audience',r.audience,'my_response',x.status) order by r.due_at,r.due_time nulls last) from fp.reminders r left join fp.reminder_member_responses x on x.reminder_id=r.id and x.member_user_id=uid join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<=current_date+7 and d.lifecycle_status='active' and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'[]'::jsonb),
    'counts',jsonb_build_object('overdue',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<current_date and d.lifecycle_status='active' and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'due_soon',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at between current_date and current_date+7 and d.lifecycle_status='active' and ((r.audience='personal' and r.created_by=uid) or r.audience='family')),'unread',(select count(*) from fp.reminders r left join fp.reminder_member_responses x on x.reminder_id=r.id and x.member_user_id=uid join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<=current_date+7 and d.lifecycle_status='active' and ((r.audience='personal' and r.created_by=uid) or (r.audience='family' and coalesce(x.status,'pending')='pending'))))
  );
end $$;

create or replace function fp.enqueue_due_notifications() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
  select r.household_id,'reminder',m.email,'Family Documents reminder: '||r.title,r.title||' is due on '||to_char(r.due_at,'DD Mon YYYY')||'. Sign in to acknowledge it or mark it complete.','reminder:'||r.id::text||':'||r.due_at::text||':'||m.user_id::text,now()
  from fp.reminders r join fp.documents d on d.id=r.document_id and d.lifecycle_status='active' join fp.members m on m.household_id=r.household_id and m.status='active' and ((r.audience='personal' and m.user_id=r.created_by) or (r.audience='family' and ((r.email_all_members) or m.user_id=r.created_by)))
  where r.status='upcoming' and r.due_at between current_date and current_date+7 on conflict(dedupe_key) do nothing;
  get diagnostics changed=row_count;return jsonb_build_object('queued',changed);
end $$;

revoke execute on function fp.set_reminder_audience(uuid,text,boolean),fp.respond_to_family_reminder(uuid,text),fp.reminder_dashboard() from public,anon;
grant execute on function fp.set_reminder_audience(uuid,text,boolean),fp.respond_to_family_reminder(uuid,text),fp.reminder_dashboard() to authenticated;
revoke execute on function fp.enqueue_due_notifications() from public,anon,authenticated;
grant execute on function fp.enqueue_due_notifications() to service_role;

commit;
