begin;

create table fp.household_lists (
  id uuid primary key,
  household_id uuid not null references fp.households(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  kind text not null check (kind in ('groceries','errands','chores')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  unique (household_id,id)
);

create table fp.household_list_items (
  id uuid primary key,
  household_id uuid not null,
  list_id uuid not null,
  title text not null check (char_length(btrim(title)) between 1 and 240),
  quantity text not null default '' check (char_length(quantity) <= 80),
  notes text not null default '' check (char_length(notes) <= 2000),
  section text not null default '' check (char_length(section) <= 120),
  assigned_to uuid,
  due_on date,
  completed_at timestamptz,
  completed_by uuid,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1 check (version > 0),
  foreign key (household_id,list_id)
    references fp.household_lists(household_id,id) on delete cascade,
  check ((completed_at is null) = (completed_by is null))
);
create index household_list_items_family_list_idx
  on fp.household_list_items(household_id,list_id,created_at);

alter table fp.household_lists enable row level security;
alter table fp.household_lists force row level security;
alter table fp.household_list_items enable row level security;
alter table fp.household_list_items force row level security;
revoke all on fp.household_lists,fp.household_list_items from public,anon,authenticated;

-- RPC-only access, consistent with the existing Family-scoped API. Every RPC
-- independently checks active membership; table access is not granted to users.
create function fp.create_household_list(request_id uuid,list_title text,list_kind text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id();
  hid uuid:=fp.active_family_id();
  existing fp.household_lists;
begin
  if hid is null or uid is null or not exists (
    select 1 from fp.members where household_id=hid and user_id=uid and status='active'
  ) then raise exception 'not authorised' using errcode='42501'; end if;
  if request_id is null or list_title is null or
     char_length(btrim(list_title)) not between 1 and 120 or
     list_kind is null or list_kind not in ('groceries','errands','chores') then
    raise exception 'invalid list' using errcode='22023';
  end if;
  insert into fp.household_lists(id,household_id,title,kind,created_by)
    values(request_id,hid,btrim(list_title),list_kind,uid)
    on conflict(id) do nothing;
  select * into existing from fp.household_lists
    where id=request_id and household_id=hid and created_by=uid;
  if existing.id is null then
    raise exception 'request unavailable' using errcode='42501';
  end if;
  if existing.title<>btrim(list_title) or existing.kind<>list_kind then
    raise exception 'request already used for different list' using errcode='22023';
  end if;
  return to_jsonb(existing);
end $$;

create function fp.household_lists_dashboard()
returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
begin
  if hid is null or uid is null or not exists (
    select 1 from fp.members where household_id=hid and user_id=uid and status='active'
  ) then raise exception 'not authorised' using errcode='42501'; end if;
  return jsonb_build_object('lists',coalesce((
    select jsonb_agg(to_jsonb(l) order by l.created_at,l.id)
    from fp.household_lists l where l.household_id=hid
  ),'[]'::jsonb));
end $$;

revoke all on function fp.create_household_list(uuid,text,text),
  fp.household_lists_dashboard() from public,anon;
grant execute on function fp.create_household_list(uuid,text,text),
  fp.household_lists_dashboard() to authenticated;

alter table fp.household_list_items add column recurrence text not null default 'none'
  check (recurrence in ('none','daily','weekly','monthly'));
create table fp.household_list_history (
  id bigint generated always as identity primary key,
  household_id uuid not null references fp.households(id),
  item_id uuid not null references fp.household_list_items(id),
  actor uuid not null,
  action text not null,
  snapshot jsonb not null,
  created_at timestamptz not null default now()
);
alter table fp.household_list_history enable row level security;
alter table fp.household_list_history force row level security;
revoke all on fp.household_list_history from public,anon,authenticated;

create function fp.household_list_workspace(target_list uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
begin
  if not exists(select 1 from fp.members where household_id=hid and user_id=uid and status='active')
    or not exists(select 1 from fp.household_lists where id=target_list and household_id=hid)
  then raise exception 'not authorised' using errcode='42501';end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at,i.id) from fp.household_list_items i where i.household_id=hid and i.list_id=target_list),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(jsonb_build_object('id',user_id,'name',display_name)) from fp.members where household_id=hid and status='active'),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.id desc) from (select h.* from fp.household_list_history h join fp.household_list_items i on i.id=h.item_id where h.household_id=hid and i.list_id=target_list order by h.id desc limit 100) h),'[]'::jsonb));
end $$;

create function fp.save_household_list_item(target_list uuid,item_id uuid,expected_version integer,details jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();r fp.household_list_items;
  assignee uuid:=nullif(details->>'assigned_to','')::uuid;due date:=nullif(details->>'due_on','')::date;
  repeat_rule text:=coalesce(details->>'recurrence','none');
begin
  if not exists(select 1 from fp.members where household_id=hid and user_id=uid and status='active')
    or not exists(select 1 from fp.household_lists where id=target_list and household_id=hid)
  then raise exception 'not authorised' using errcode='42501';end if;
  if item_id is null or expected_version is null or expected_version<0 or details->>'title' is null then raise exception 'invalid item' using errcode='22023';end if;
  if assignee is not null and not exists(select 1 from fp.members where household_id=hid and user_id=assignee and status='active') then raise exception 'invalid assignee' using errcode='22023';end if;
  if repeat_rule<>'none' and (due is null or not exists(select 1 from fp.household_lists where id=target_list and kind='chores')) then raise exception 'recurrence requires a dated chore' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(item_id::text,0));
  select * into r from fp.household_list_items where id=item_id and household_id=hid and list_id=target_list for update;
  if r.id is null then
    if expected_version<>0 then raise exception 'item changed; refresh' using errcode='40001';end if;
    insert into fp.household_list_items(id,household_id,list_id,title,quantity,notes,section,assigned_to,due_on,recurrence,created_by)
    values(item_id,hid,target_list,btrim(details->>'title'),coalesce(details->>'quantity',''),coalesce(details->>'notes',''),coalesce(details->>'section',''),assignee,due,repeat_rule,uid) returning * into r;
  else
    -- A lost creation response can be retried only with the identical payload.
    if expected_version=0 and r.version=1 and r.created_by=uid and r.title=btrim(details->>'title') and r.quantity=coalesce(details->>'quantity','') and r.notes=coalesce(details->>'notes','') and r.section=coalesce(details->>'section','') and r.assigned_to is not distinct from assignee and r.due_on is not distinct from due and r.recurrence=repeat_rule then return to_jsonb(r);end if;
    if expected_version<>r.version then raise exception 'item changed; refresh' using errcode='40001';end if;
    update fp.household_list_items set title=btrim(details->>'title'),quantity=coalesce(details->>'quantity',''),notes=coalesce(details->>'notes',''),section=coalesce(details->>'section',''),assigned_to=assignee,due_on=due,recurrence=repeat_rule,version=version+1,updated_at=now() where id=item_id returning * into r;
  end if;
  insert into fp.household_list_history(household_id,item_id,actor,action,snapshot) values(hid,item_id,uid,'saved',to_jsonb(r));
  return to_jsonb(r);
end $$;

create function fp.complete_household_list_item(item_id uuid,expected_version integer,completed boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();r fp.household_list_items;next_date date;
begin
  if not exists(select 1 from fp.members where household_id=hid and user_id=uid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  select * into r from fp.household_list_items where id=item_id and household_id=hid for update;
  if r.id is null then raise exception 'not authorised' using errcode='42501';end if;
  if expected_version is null or expected_version<>r.version or completed is null then raise exception 'item changed; refresh' using errcode='40001';end if;
  if completed=(r.completed_at is not null) then return to_jsonb(r);end if;
  if completed and r.recurrence<>'none' then
    next_date:=(r.due_on+case r.recurrence when 'daily' then interval '1 day' when 'weekly' then interval '7 days' else interval '1 month' end)::date;
    insert into fp.household_list_history(household_id,item_id,actor,action,snapshot) values(hid,item_id,uid,'occurrence_completed',to_jsonb(r));
    update fp.household_list_items set due_on=next_date,version=version+1,updated_at=now() where id=item_id returning * into r;
  else
    update fp.household_list_items set completed_at=case when completed then now() end,completed_by=case when completed then uid end,version=version+1,updated_at=now() where id=item_id returning * into r;
    insert into fp.household_list_history(household_id,item_id,actor,action,snapshot) values(hid,item_id,uid,case when completed then 'completed' else 'reopened' end,to_jsonb(r));
  end if;
  return to_jsonb(r);
end $$;
revoke all on function fp.household_list_workspace(uuid),fp.save_household_list_item(uuid,uuid,integer,jsonb),fp.complete_household_list_item(uuid,integer,boolean) from public,anon;
grant execute on function fp.household_list_workspace(uuid),fp.save_household_list_item(uuid,uuid,integer,jsonb),fp.complete_household_list_item(uuid,integer,boolean) to authenticated;
commit;
