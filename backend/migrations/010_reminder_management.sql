begin;

alter table fp.reminders add column if not exists recurrence text not null default 'none';
alter table fp.reminders add column if not exists original_due_at date;
alter table fp.reminders add column if not exists root_reminder_id uuid references fp.reminders(id) on delete set null;
alter table fp.reminders add column if not exists sequence_number integer not null default 1;
alter table fp.reminders add column if not exists completed_at timestamptz;
alter table fp.reminders add column if not exists completed_by uuid;
alter table fp.reminders add column if not exists completion_kind text;
alter table fp.reminders add column if not exists dismissed_at timestamptz;
alter table fp.reminders add column if not exists snooze_count integer not null default 0;
alter table fp.reminders add column if not exists updated_at timestamptz not null default now();
alter table fp.reminders drop constraint if exists reminders_recurrence_check;
alter table fp.reminders add constraint reminders_recurrence_check check(recurrence in ('none','monthly','yearly'));
alter table fp.reminders drop constraint if exists reminders_completion_kind_check;
alter table fp.reminders add constraint reminders_completion_kind_check check(completion_kind is null or completion_kind in ('completed','paid'));
alter table fp.reminders drop constraint if exists reminders_sequence_check;
alter table fp.reminders add constraint reminders_sequence_check check(sequence_number between 1 and 1200);
update fp.reminders set original_due_at=due_at where original_due_at is null;
create index if not exists reminders_household_due on fp.reminders(household_id,status,due_at);

create or replace function fp.configure_reminder(reminder uuid,repeat text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); r fp.reminders; d fp.documents;
begin
  select * into r from fp.reminders where id=reminder for update;
  select * into d from fp.documents where id=r.document_id;
  if r.id is null or not (d.created_by=uid or fp.is_household_admin(r.household_id)) then raise exception 'not authorised' using errcode='42501'; end if;
  if r.status<>'upcoming' or repeat not in ('none','monthly','yearly') then raise exception 'invalid reminder configuration' using errcode='22023'; end if;
  update fp.reminders set recurrence=repeat,root_reminder_id=coalesce(root_reminder_id,id),original_due_at=coalesce(original_due_at,due_at),updated_at=now() where id=r.id;
  return jsonb_build_object('id',r.id,'recurrence',repeat);
end $$;

create or replace function fp.act_on_reminder(reminder uuid,action text,snooze_until date default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); r fp.reminders; d fp.documents; next_due date; next_id uuid;
begin
  select * into r from fp.reminders where id=reminder for update;
  select * into d from fp.documents where id=r.document_id;
  if r.id is null or not (d.created_by=uid or fp.is_household_admin(r.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid and p.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501'; end if;
  if r.status<>'upcoming' then raise exception 'reminder already resolved' using errcode='22023'; end if;
  if action in ('complete','paid') then
    update fp.reminders set status='completed',completed_at=now(),completed_by=uid,completion_kind=case when action='paid' then 'paid' else 'completed' end,updated_at=now() where id=r.id;
    if r.recurrence<>'none' and d.lifecycle_status='active' then
      next_due:=case when r.recurrence='monthly' then (r.due_at+interval '1 month')::date else (r.due_at+interval '1 year')::date end;
      insert into fp.reminders(household_id,document_id,title,due_at,status,created_by,recurrence,original_due_at,root_reminder_id,sequence_number)
      values(r.household_id,r.document_id,r.title,next_due,'upcoming',r.created_by,r.recurrence,next_due,coalesce(r.root_reminder_id,r.id),r.sequence_number+1)
      on conflict(document_id,due_at) do nothing returning id into next_id;
    end if;
  elsif action='dismiss' then
    update fp.reminders set status='dismissed',dismissed_at=now(),updated_at=now() where id=r.id;
  elsif action='snooze' then
    if snooze_until is null or snooze_until<=current_date or snooze_until>current_date+365 then raise exception 'invalid snooze date' using errcode='22023'; end if;
    begin
      update fp.reminders set original_due_at=coalesce(original_due_at,due_at),due_at=snooze_until,snooze_count=snooze_count+1,updated_at=now() where id=r.id;
    exception when unique_violation then raise exception 'a reminder already exists on that date' using errcode='23505'; end;
  else raise exception 'invalid reminder action' using errcode='22023';
  end if;
  return jsonb_build_object('id',r.id,'action',action,'status',(select status from fp.reminders where id=r.id),'next_reminder_id',next_id,'next_due_at',next_due);
end $$;

create or replace function fp.reminder_dashboard() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return jsonb_build_object('items','[]'::jsonb,'notifications','[]'::jsonb,'counts',jsonb_build_object('overdue',0,'due_soon',0)); end if;
  admin:=fp.is_household_admin(hid);
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'original_due_at',r.original_due_at,'status',r.status,'recurrence',r.recurrence,'sequence_number',r.sequence_number,'snooze_count',r.snooze_count,'completion_kind',r.completion_kind,'document_title',d.title,'category_name',c.name,'due_state',case when r.status='upcoming' and r.due_at<current_date then 'overdue' when r.status='upcoming' and r.due_at=current_date then 'today' when r.status='upcoming' then 'upcoming' else r.status end,'days_until',r.due_at-current_date) order by case when r.status='upcoming' then 0 else 1 end,r.due_at desc) from fp.reminders r join fp.documents d on d.id=r.document_id join fp.categories c on c.id=d.category_id where r.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'title',r.title,'due_at',r.due_at,'due_state',case when r.due_at<current_date then 'overdue' when r.due_at=current_date then 'today' else 'due_soon' end) order by r.due_at) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<=current_date+7 and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb),
    'counts',jsonb_build_object('overdue',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at<current_date and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'due_soon',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and r.status='upcoming' and r.due_at between current_date and current_date+7 and d.lifecycle_status='active' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))))
  );
end $$;

revoke execute on function fp.configure_reminder(uuid,text),fp.act_on_reminder(uuid,text,date),fp.reminder_dashboard() from public,anon;
grant execute on function fp.configure_reminder(uuid,text),fp.act_on_reminder(uuid,text,date),fp.reminder_dashboard() to authenticated;

commit;
