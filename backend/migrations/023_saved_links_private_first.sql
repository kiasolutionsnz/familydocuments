create table if not exists fp.saved_link_categories(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  owner_user_id uuid not null,
  name text not null check(char_length(trim(name)) between 1 and 40),
  system_key text check(system_key is null or system_key in ('watch_later','recipes','travel','home','shopping','health','learning','other')),
  status text not null default 'active' check(status in ('active','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists saved_link_category_owner_name on fp.saved_link_categories(household_id,owner_user_id,lower(name)) where status='active';
create unique index if not exists saved_link_category_owner_system on fp.saved_link_categories(household_id,owner_user_id,system_key) where system_key is not null;

create table if not exists fp.saved_links(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  owner_user_id uuid not null,
  category_id uuid not null references fp.saved_link_categories(id),
  url text not null check(char_length(url) between 9 and 2048),
  normalized_url_hash text not null check(normalized_url_hash ~ '^[0-9a-f]{64}$'),
  source_host text not null check(char_length(source_host) between 1 and 253),
  title text not null check(char_length(trim(title)) between 1 and 160),
  note text check(note is null or char_length(note)<=2000),
  status text not null default 'active' check(status in ('active','deleted')),
  deleted_at timestamptz,
  purge_after timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists saved_links_owner_hash on fp.saved_links(household_id,owner_user_id,normalized_url_hash) where status='active';
create index if not exists saved_links_owner_category on fp.saved_links(household_id,owner_user_id,category_id,created_at desc) where status='active';

create table if not exists fp.saved_link_permissions(
  link_id uuid not null references fp.saved_links(id) on delete cascade,
  member_user_id uuid not null,
  granted_by uuid not null,
  granted_at timestamptz not null default now(),
  primary key(link_id,member_user_id)
);

create table if not exists fp.saved_link_security_events(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  owner_user_id uuid not null,
  actor_user_id uuid not null,
  link_id uuid,
  subject_user_id uuid,
  event_type text not null check(event_type in ('created','updated','shared','unshared','deleted','restored','category_created','category_renamed','category_archived')),
  occurred_at timestamptz not null default now()
);

alter table fp.saved_link_categories enable row level security;alter table fp.saved_link_categories force row level security;
alter table fp.saved_links enable row level security;alter table fp.saved_links force row level security;
alter table fp.saved_link_permissions enable row level security;alter table fp.saved_link_permissions force row level security;
alter table fp.saved_link_security_events enable row level security;alter table fp.saved_link_security_events force row level security;
drop policy if exists saved_link_category_owner_read on fp.saved_link_categories;
create policy saved_link_category_owner_read on fp.saved_link_categories for select using(owner_user_id=fp.current_user_id() and fp.is_active_member(household_id));
drop policy if exists saved_link_authorised_read on fp.saved_links;
create policy saved_link_authorised_read on fp.saved_links for select using(fp.is_active_member(household_id) and (owner_user_id=fp.current_user_id() or exists(select 1 from fp.saved_link_permissions p join fp.members m on m.household_id=saved_links.household_id and m.user_id=p.member_user_id and m.status='active' where p.link_id=saved_links.id and p.member_user_id=fp.current_user_id())));
drop policy if exists saved_link_permission_party_read on fp.saved_link_permissions;
create policy saved_link_permission_party_read on fp.saved_link_permissions for select using(member_user_id=fp.current_user_id() or exists(select 1 from fp.saved_links l where l.id=link_id and l.owner_user_id=fp.current_user_id()));
drop policy if exists saved_link_event_owner_read on fp.saved_link_security_events;
create policy saved_link_event_owner_read on fp.saved_link_security_events for select using(owner_user_id=fp.current_user_id() and fp.is_active_member(household_id));

create or replace function fp.normalise_saved_link_url(input_url text) returns jsonb
language plpgsql immutable set search_path=pg_catalog,extensions as $$
declare raw text:=trim(input_url);authority text;host text;canonical text;
begin
  if char_length(raw) not between 9 and 2048 or raw !~ '^https://[^[:space:]]+$' or raw ~ '^https://[^/?#]*@' then raise exception 'invalid HTTPS link' using errcode='22023';end if;
  authority:=substring(raw from '^https://([^/?#]+)');host:=lower(split_part(authority,':',1));
  if host is null or host='' or host='localhost' or host like '%.localhost' or host ~ '^\[' or host ~ '^[0-9]+(\.[0-9]+){3}$' or host !~ '^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$' then raise exception 'invalid public hostname' using errcode='22023';end if;
  canonical:='https://'||lower(authority)||substring(raw from char_length('https://'||authority)+1);canonical:=regexp_replace(canonical,'#.*$','');canonical:=regexp_replace(canonical,'^https://([^/:]+):443(?=/|$)','https://\1');
  return jsonb_build_object('url',raw,'host',host,'canonical',canonical,'hash',encode(extensions.digest(canonical,'sha256'),'hex'));
end $$;

create or replace function fp.ensure_saved_link_defaults() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;item record;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then raise exception 'household required' using errcode='42501';end if;
  for item in select * from (values('watch_later','Watch later'),('recipes','Recipes'),('travel','Travel ideas'),('home','Home ideas'),('shopping','Shopping'),('health','Health & fitness'),('learning','Learning'),('other','Other')) v(key,label) loop
    insert into fp.saved_link_categories(household_id,owner_user_id,name,system_key) values(hid,uid,item.label,item.key) on conflict(household_id,owner_user_id,system_key) where system_key is not null do nothing;
  end loop;
  return jsonb_build_object('created',true);
end $$;

create or replace function fp.create_saved_link_category(category_name text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.saved_link_categories;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then raise exception 'household required' using errcode='42501';end if;
  if char_length(trim(category_name)) not between 1 and 40 then raise exception 'invalid category name' using errcode='22023';end if;
  insert into fp.saved_link_categories(household_id,owner_user_id,name) values(hid,uid,trim(category_name)) returning * into row;
  return jsonb_build_object('id',row.id,'name',row.name);
exception when unique_violation then raise exception 'category already exists' using errcode='23505';
end $$;

create or replace function fp.create_saved_link(link_url text,link_title text,link_note text,category uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;parsed jsonb;row fp.saved_links;duplicate uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then raise exception 'household required' using errcode='42501';end if;
  if char_length(trim(link_title)) not between 1 and 160 or link_note is not null and char_length(link_note)>2000 then raise exception 'invalid saved link' using errcode='22023';end if;
  if not exists(select 1 from fp.saved_link_categories c where c.id=category and c.household_id=hid and c.owner_user_id=uid and c.status='active') then raise exception 'invalid personal category' using errcode='22023';end if;
  parsed:=fp.normalise_saved_link_url(link_url);select id into duplicate from fp.saved_links where household_id=hid and owner_user_id=uid and normalized_url_hash=parsed->>'hash' and status='active' order by created_at limit 1;
  insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title,note) values(hid,uid,category,parsed->>'url',parsed->>'hash',parsed->>'host',trim(link_title),nullif(trim(link_note),'')) returning * into row;
  insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,event_type) values(hid,uid,uid,row.id,'created');
  return jsonb_build_object('id',row.id,'title',row.title,'private',true,'duplicate_of',duplicate);
end $$;

create or replace function fp.update_saved_link(link uuid,link_title text,link_note text,category uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();row fp.saved_links;
begin
  select * into row from fp.saved_links where id=link and owner_user_id=uid and status='active' and fp.is_active_member(household_id) for update;if row.id is null then raise exception 'saved link not found' using errcode='P0002';end if;
  if char_length(trim(link_title)) not between 1 and 160 or link_note is not null and char_length(link_note)>2000 or not exists(select 1 from fp.saved_link_categories c where c.id=category and c.household_id=row.household_id and c.owner_user_id=uid and c.status='active') then raise exception 'invalid saved link' using errcode='22023';end if;
  update fp.saved_links set title=trim(link_title),note=nullif(trim(link_note),''),category_id=category,updated_at=now() where id=row.id;
  insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,event_type) values(row.household_id,uid,uid,row.id,'updated');return jsonb_build_object('id',row.id,'updated',true);
end $$;

create or replace function fp.set_saved_link_shares(link uuid,member_ids uuid[]) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();row fp.saved_links;target uuid;old_target uuid;shared integer:=0;
begin
  select * into row from fp.saved_links where id=link and owner_user_id=uid and status='active' and fp.is_active_member(household_id) for update;if row.id is null then raise exception 'saved link not found' using errcode='P0002';end if;
  if coalesce(array_length(member_ids,1),0)>20 then raise exception 'too many recipients' using errcode='22023';end if;
  for target in select distinct unnest(coalesce(member_ids,'{}'::uuid[])) loop
    if target=uid or not exists(select 1 from fp.members where household_id=row.household_id and user_id=target and status='active') then raise exception 'invalid recipient' using errcode='22023';end if;
  end loop;
  for old_target in select member_user_id from fp.saved_link_permissions where link_id=row.id and not(member_user_id=any(coalesce(member_ids,'{}'::uuid[]))) loop insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,subject_user_id,event_type) values(row.household_id,uid,uid,row.id,old_target,'unshared');end loop;
  delete from fp.saved_link_permissions where link_id=row.id and not(member_user_id=any(coalesce(member_ids,'{}'::uuid[])));
  for target in select distinct unnest(coalesce(member_ids,'{}'::uuid[])) loop
    insert into fp.saved_link_permissions(link_id,member_user_id,granted_by) values(row.id,target,uid) on conflict do nothing;if found then insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,subject_user_id,event_type) values(row.household_id,uid,uid,row.id,target,'shared');end if;
  end loop;
  select count(*) into shared from fp.saved_link_permissions where link_id=row.id;return jsonb_build_object('id',row.id,'shared_with_count',shared);
end $$;

create or replace function fp.saved_link_workspace(search_query text default null,category uuid default null,visibility text default 'all',result_limit integer default 100) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;q text:=lower(trim(coalesce(search_query,'')));
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then return jsonb_build_object('categories','[]'::jsonb,'links','[]'::jsonb,'share_candidates','[]'::jsonb);end if;
  if visibility not in ('all','mine','shared_with_me') or result_limit not between 1 and 200 then raise exception 'invalid filter' using errcode='22023';end if;
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'system_key',c.system_key) order by c.name) from fp.saved_link_categories c where c.household_id=hid and c.owner_user_id=uid and c.status='active'),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(x.value order by x.created_at desc) from (select l.created_at,jsonb_build_object('id',l.id,'title',l.title,'note',l.note,'url',l.url,'source_host',l.source_host,'category_id',case when l.owner_user_id=uid then l.category_id else null end,'category_name',case when l.owner_user_id=uid then c.name else null end,'owned_by_me',l.owner_user_id=uid,'shared_by',case when l.owner_user_id<>uid then coalesce(m.display_name,m.email) end,'shared_with',case when l.owner_user_id=uid then coalesce((select jsonb_agg(jsonb_build_object('id',pm.user_id,'name',coalesce(pm.display_name,pm.email)) order by coalesce(pm.display_name,pm.email)) from fp.saved_link_permissions p join fp.members pm on pm.household_id=l.household_id and pm.user_id=p.member_user_id and pm.status='active' where p.link_id=l.id),'[]'::jsonb) else '[]'::jsonb end,'created_at',l.created_at) value from fp.saved_links l left join fp.saved_link_categories c on c.id=l.category_id left join fp.members m on m.household_id=l.household_id and m.user_id=l.owner_user_id where l.household_id=hid and l.status='active' and (l.owner_user_id=uid or exists(select 1 from fp.saved_link_permissions p join fp.members active_member on active_member.household_id=l.household_id and active_member.user_id=p.member_user_id and active_member.status='active' where p.link_id=l.id and p.member_user_id=uid)) and (visibility='all' or visibility='mine' and l.owner_user_id=uid or visibility='shared_with_me' and l.owner_user_id<>uid) and (category is null or l.owner_user_id=uid and l.category_id=category) and (q='' or lower(l.title) like '%'||q||'%' or lower(coalesce(l.note,'')) like '%'||q||'%' or lower(l.url) like '%'||q||'%' or lower(l.source_host) like '%'||q||'%') order by l.created_at desc limit result_limit) x),'[]'::jsonb),
    'share_candidates',coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(m.display_name,m.email)) order by coalesce(m.display_name,m.email)) from fp.members m where m.household_id=hid and m.status='active' and m.user_id<>uid),'[]'::jsonb)
  );
end $$;

create or replace function fp.delete_saved_link(link uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();row fp.saved_links;begin select * into row from fp.saved_links where id=link and owner_user_id=uid and status='active' and fp.is_active_member(household_id) for update;if row.id is null then raise exception 'saved link not found' using errcode='P0002';end if;update fp.saved_links set status='deleted',deleted_at=now(),purge_after=now()+interval '30 days',updated_at=now() where id=row.id;insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,event_type) values(row.household_id,uid,uid,row.id,'deleted');return jsonb_build_object('id',row.id,'status','deleted','purge_after',now()+interval '30 days');end $$;
create or replace function fp.restore_saved_link(link uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();row fp.saved_links;begin select * into row from fp.saved_links where id=link and owner_user_id=uid and status='deleted' and purge_after>now() and fp.is_active_member(household_id) for update;if row.id is null then raise exception 'saved link not found' using errcode='P0002';end if;update fp.saved_links set status='active',deleted_at=null,purge_after=null,updated_at=now() where id=row.id;insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,event_type) values(row.household_id,uid,uid,row.id,'restored');return jsonb_build_object('id',row.id,'status','active');end $$;

revoke all on fp.saved_link_categories,fp.saved_links,fp.saved_link_permissions,fp.saved_link_security_events from public,anon,authenticated;
revoke execute on function fp.normalise_saved_link_url(text),fp.ensure_saved_link_defaults(),fp.create_saved_link_category(text),fp.create_saved_link(text,text,text,uuid),fp.update_saved_link(uuid,text,text,uuid),fp.set_saved_link_shares(uuid,uuid[]),fp.saved_link_workspace(text,uuid,text,integer),fp.delete_saved_link(uuid),fp.restore_saved_link(uuid) from public,anon;
grant execute on function fp.ensure_saved_link_defaults(),fp.create_saved_link_category(text),fp.create_saved_link(text,text,text,uuid),fp.update_saved_link(uuid,text,text,uuid),fp.set_saved_link_shares(uuid,uuid[]),fp.saved_link_workspace(text,uuid,text,integer),fp.delete_saved_link(uuid),fp.restore_saved_link(uuid) to authenticated;
