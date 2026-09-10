begin;

create table fp.conversations(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  status text not null default 'active' check(status in ('active','archived')),
  request_id text not null check(request_id ~ '^[A-Za-z0-9:_-]{8,100}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,user_id,request_id)
);
create unique index conversations_one_active_per_user
  on fp.conversations(household_id,user_id) where status='active';
create index conversations_user_updated
  on fp.conversations(household_id,user_id,updated_at desc);

create table fp.conversation_messages(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  client_message_id text not null check(client_message_id ~ '^[A-Za-z0-9:_-]{8,100}$'),
  role text not null check(role in ('user','assistant')),
  kind text not null check(kind in ('text','attachment','clarification','confirmation','progress','result','error')),
  content text not null check(char_length(content) between 1 and 2000),
  message_data jsonb not null default '{}'::jsonb check(jsonb_typeof(message_data)='object' and octet_length(message_data::text)<=16384),
  created_at timestamptz not null default now(),
  unique(conversation_id,client_message_id)
);
create index conversation_messages_order
  on fp.conversation_messages(conversation_id,created_at,id);

create table fp.conversation_confirmations(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  action_id text not null check(action_id ~ '^[A-Za-z0-9:_-]{8,100}$'),
  action_type text not null,
  action_version integer not null default 1 check(action_version=1),
  parameters jsonb not null check(jsonb_typeof(parameters)='object' and octet_length(parameters::text)<=8192),
  summary text not null check(char_length(summary) between 1 and 240),
  target_label text not null check(char_length(target_label) between 1 and 160),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  unique(conversation_id,action_id),
  check(expires_at>created_at)
);

create table fp.conversation_action_receipts(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  action_id text not null check(action_id ~ '^[A-Za-z0-9:_-]{8,100}$'),
  action_type text not null,
  status text not null check(status in ('succeeded','failed','cancelled')),
  target_type text,
  target_id uuid,
  result_summary jsonb not null default '{}'::jsonb check(jsonb_typeof(result_summary)='object' and octet_length(result_summary::text)<=8192),
  created_at timestamptz not null default now(),
  unique(conversation_id,action_id)
);

alter table fp.conversations enable row level security;
alter table fp.conversations force row level security;
alter table fp.conversation_messages enable row level security;
alter table fp.conversation_messages force row level security;
alter table fp.conversation_confirmations enable row level security;
alter table fp.conversation_confirmations force row level security;
alter table fp.conversation_action_receipts enable row level security;
alter table fp.conversation_action_receipts force row level security;
revoke all on fp.conversations,fp.conversation_messages,fp.conversation_confirmations,fp.conversation_action_receipts from public,anon,authenticated;

create or replace function fp.conversation_member(conversation uuid) returns fp.conversations
language sql security definer stable set search_path=pg_catalog,fp as $$
  select c from fp.conversations c
  join fp.members m on m.household_id=c.household_id and m.user_id=c.user_id and m.status='active'
  where c.id=conversation and c.user_id=fp.current_user_id()
$$;

create or replace function fp.start_conversation(request_id text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;existing fp.conversations;created fp.conversations;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then raise exception 'not authorised' using errcode='42501';end if;
  if request_id is null or request_id !~ '^[A-Za-z0-9:_-]{8,100}$' then raise exception 'invalid request id' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':conversation',0));
  select * into existing from fp.conversations c where c.household_id=hid and c.user_id=uid and c.request_id=start_conversation.request_id;
  if existing.id is not null then return jsonb_build_object('id',existing.id,'status',existing.status,'duplicate',true);end if;
  update fp.conversations set status='archived',updated_at=clock_timestamp() where household_id=hid and user_id=uid and status='active';
  insert into fp.conversations(household_id,user_id,request_id) values(hid,uid,request_id) returning * into created;
  return jsonb_build_object('id',created.id,'status',created.status,'duplicate',false);
end$$;

create or replace function fp.conversation_workspace(conversation uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;selected fp.conversations;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then return jsonb_build_object('conversation',null,'messages','[]'::jsonb,'pending_confirmation',null);end if;
  if conversation is null then
    select * into selected from fp.conversations c where c.household_id=hid and c.user_id=uid and c.status='active' order by c.updated_at desc limit 1;
  else
    select * into selected from fp.conversations c where c.id=conversation and c.household_id=hid and c.user_id=uid;
  end if;
  if selected.id is null then return jsonb_build_object('conversation',null,'messages','[]'::jsonb,'pending_confirmation',null);end if;
  return jsonb_build_object(
    'conversation',jsonb_build_object('id',selected.id,'status',selected.status,'created_at',selected.created_at,'updated_at',selected.updated_at),
    'messages',coalesce((select jsonb_agg(value order by created_at,id) from (
      select m.created_at,m.id,jsonb_build_object('id',m.id,'client_message_id',m.client_message_id,'role',m.role,'kind',m.kind,'content',m.content,'data',m.message_data,'created_at',m.created_at) value
      from fp.conversation_messages m where m.conversation_id=selected.id order by m.created_at desc,m.id desc limit 60
    ) recent),'[]'::jsonb),
    'pending_confirmation',(select jsonb_build_object('action_id',p.action_id,'action_type',p.action_type,'version',p.action_version,'parameters',p.parameters,'summary',p.summary,'target_label',p.target_label,'expires_at',p.expires_at)
      from fp.conversation_confirmations p where p.conversation_id=selected.id and p.consumed_at is null and p.cancelled_at is null and p.expires_at>now() order by p.created_at desc limit 1)
  );
end$$;

create or replace function fp.append_conversation_message(
  conversation uuid,client_message_id text,message_role text,message_kind text,message_content text,message_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;row fp.conversation_messages;affected bigint:=0;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  if client_message_id is null or client_message_id !~ '^[A-Za-z0-9:_-]{8,100}$' or message_role not in ('user','assistant')
    or message_kind not in ('text','attachment','clarification','confirmation','progress','result','error')
    or char_length(trim(message_content)) not between 1 and 2000 or jsonb_typeof(coalesce(message_data,'{}'::jsonb))<>'object'
    or octet_length(coalesce(message_data,'{}'::jsonb)::text)>16384 then raise exception 'invalid conversation message' using errcode='22023';end if;
  insert into fp.conversation_messages(conversation_id,household_id,user_id,client_message_id,role,kind,content,message_data)
    values(current.id,current.household_id,current.user_id,client_message_id,message_role,message_kind,trim(message_content),coalesce(message_data,'{}'::jsonb))
    on conflict on constraint conversation_messages_conversation_id_client_message_id_key do nothing returning * into row;
  get diagnostics affected=row_count;
  if row.id is null then select * into row from fp.conversation_messages m where m.conversation_id=current.id and m.client_message_id=append_conversation_message.client_message_id;end if;
  update fp.conversations set updated_at=clock_timestamp() where id=current.id;
  return jsonb_build_object('id',row.id,'duplicate',affected=0);
end$$;

create or replace function fp.set_conversation_confirmation(
  conversation uuid,action_id text,action_type text,action_version integer,parameters jsonb,confirmation_summary text,confirmation_target text,expires_at timestamptz
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;row fp.conversation_confirmations;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  if action_id !~ '^[A-Za-z0-9:_-]{8,100}$' or action_version<>1 or action_type not in ('search_family_content','save_document','request_document_ocr','update_document_category','update_document_tags','create_reminder','update_reminder','save_link','mark_inbox_reviewed','dismiss_inbox_item','open_app_destination')
    or jsonb_typeof(parameters)<>'object' or octet_length(parameters::text)>8192
    or char_length(trim(confirmation_summary)) not between 1 and 240 or char_length(trim(confirmation_target)) not between 1 and 160
    or expires_at<=now() or expires_at>now()+interval '15 minutes'
    then raise exception 'invalid confirmation' using errcode='22023';end if;
  update fp.conversation_confirmations set cancelled_at=clock_timestamp() where conversation_id=current.id and consumed_at is null and cancelled_at is null;
  insert into fp.conversation_confirmations(conversation_id,household_id,user_id,action_id,action_type,action_version,parameters,summary,target_label,expires_at)
    values(current.id,current.household_id,current.user_id,action_id,action_type,action_version,parameters,trim(confirmation_summary),trim(confirmation_target),expires_at)
    on conflict on constraint conversation_confirmations_conversation_id_action_id_key do nothing returning * into row;
  if row.id is null then raise exception 'confirmation already exists' using errcode='PT409';end if;
  return jsonb_build_object('action_id',row.action_id,'expires_at',row.expires_at);
end$$;

create or replace function fp.consume_conversation_confirmation(conversation uuid,action_id text,cancel boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;row fp.conversation_confirmations;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  select * into row from fp.conversation_confirmations p where p.conversation_id=current.id and p.action_id=consume_conversation_confirmation.action_id for update;
  if row.id is null or row.consumed_at is not null or row.cancelled_at is not null then raise exception 'confirmation unavailable' using errcode='PT409';end if;
  if row.expires_at<=now() then raise exception 'confirmation expired' using errcode='PT410';end if;
  if cancel then update fp.conversation_confirmations set cancelled_at=clock_timestamp() where id=row.id;
  else update fp.conversation_confirmations set consumed_at=clock_timestamp() where id=row.id;end if;
  return jsonb_build_object('action_id',row.action_id,'cancelled',cancel,'parameters',row.parameters,'action_type',row.action_type,'version',row.action_version);
end$$;

create or replace function fp.record_conversation_action(
  conversation uuid,action_id text,action_type text,action_status text,target_type text default null,target_id uuid default null,result_summary jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;row fp.conversation_action_receipts;affected bigint:=0;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null then raise exception 'conversation not available' using errcode='42501';end if;
  if action_id !~ '^[A-Za-z0-9:_-]{8,100}$' or action_status not in ('succeeded','failed','cancelled')
    or action_type not in ('search_family_content','save_document','request_document_ocr','update_document_category','update_document_tags','create_reminder','update_reminder','save_link','mark_inbox_reviewed','dismiss_inbox_item','open_app_destination','request_clarification','request_confirmation','unsupported_request')
    or target_type is not null and target_type not in ('document','reminder','link','inbox','destination')
    or jsonb_typeof(coalesce(result_summary,'{}'::jsonb))<>'object' or octet_length(coalesce(result_summary,'{}'::jsonb)::text)>8192
    then raise exception 'invalid action receipt' using errcode='22023';end if;
  insert into fp.conversation_action_receipts(conversation_id,household_id,user_id,action_id,action_type,status,target_type,target_id,result_summary)
    values(current.id,current.household_id,current.user_id,action_id,action_type,action_status,target_type,target_id,coalesce(result_summary,'{}'::jsonb))
    on conflict on constraint conversation_action_receipts_conversation_id_action_id_key do nothing returning * into row;
  get diagnostics affected=row_count;
  if row.id is null then select * into row from fp.conversation_action_receipts r where r.conversation_id=current.id and r.action_id=record_conversation_action.action_id;end if;
  return jsonb_build_object('action_id',row.action_id,'status',row.status,'duplicate',affected=0);
end$$;

-- A deliberately narrow reminder mutation used by confirmed conversational
-- follow-ups. The expected date prevents a stale confirmation overwriting a
-- reminder that changed elsewhere.
create or replace function fp.update_conversation_reminder(
  reminder uuid,operation text,expected_due_date date
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.reminders;new_due date;local_today date:=(now() at time zone 'Pacific/Auckland')::date;
begin
  if operation<>'one_week_before' or expected_due_date is null then
    raise exception 'invalid reminder change' using errcode='22023';
  end if;
  select * into row from fp.reminders r where r.id=reminder for update;
  if row.id is null or not fp.can_manage_reminder(row) then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if row.status<>'upcoming' or row.due_at is distinct from expected_due_date then
    raise exception 'stale reminder' using errcode='40001';
  end if;
  new_due:=row.due_at-7;
  if new_due<=local_today then raise exception 'reminder date is no longer available' using errcode='22023';end if;
  update fp.reminders set original_due_at=coalesce(original_due_at,due_at),due_at=new_due,updated_at=clock_timestamp() where id=row.id;
  return jsonb_build_object('id',row.id,'title',row.title,'due_at',new_due,'due_time',row.due_time,'due_time_zone',row.due_time_zone);
end$$;

revoke execute on function fp.conversation_member(uuid),fp.start_conversation(text),fp.conversation_workspace(uuid),
  fp.append_conversation_message(uuid,text,text,text,text,jsonb),fp.set_conversation_confirmation(uuid,text,text,integer,jsonb,text,text,timestamptz),
  fp.consume_conversation_confirmation(uuid,text,boolean),fp.record_conversation_action(uuid,text,text,text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function fp.start_conversation(text),fp.conversation_workspace(uuid),
  fp.append_conversation_message(uuid,text,text,text,text,jsonb),fp.set_conversation_confirmation(uuid,text,text,integer,jsonb,text,text,timestamptz),
  fp.consume_conversation_confirmation(uuid,text,boolean),fp.record_conversation_action(uuid,text,text,text,text,uuid,jsonb),
  fp.update_conversation_reminder(uuid,text,date) to authenticated;

revoke execute on function fp.update_conversation_reminder(uuid,text,date) from public,anon;

commit;
