begin;

alter table fp.categories add column if not exists visibility text not null default 'shared';
alter table fp.categories add column if not exists owner_user_id uuid;
alter table fp.categories drop constraint if exists categories_visibility_check;
alter table fp.categories add constraint categories_visibility_check check(visibility in ('private','shared'));
update fp.categories set visibility='shared',owner_user_id=null where owner_user_id is null;
alter table fp.categories add constraint categories_private_owner_check
  check((visibility='shared' and owner_user_id is null) or (visibility='private' and owner_user_id is not null));

drop policy if exists categories_household_read on fp.categories;
create policy categories_household_read on fp.categories for select using(
  fp.is_active_member(household_id)
  and (visibility='shared' or owner_user_id=fp.current_user_id())
);

create or replace function fp.create_library_category(
  category_name text,
  category_visibility text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id();
  hid uuid:=fp.active_family_id();
  member_role text;
  row fp.categories;
begin
  select role into member_role from fp.members
  where household_id=hid and user_id=uid and status='active';
  if member_role is null then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if char_length(trim(category_name)) not between 1 and 40
    or category_visibility not in ('private','shared') then
    raise exception 'invalid category' using errcode='22023';
  end if;
  if category_visibility='shared' then
    if member_role not in ('owner','family_admin') then
      raise exception 'family admin required' using errcode='42501';
    end if;
    perform fp.require_aal2();
  end if;
  insert into fp.categories(household_id,name,created_by,visibility,owner_user_id)
  values(hid,trim(category_name),uid,category_visibility,
    case when category_visibility='private' then uid else null end)
  returning * into row;
  return jsonb_build_object(
    'id',row.id,'name',row.name,'is_system',row.is_system,
    'visibility',row.visibility,'owned_by_me',row.owner_user_id=uid
  );
exception when unique_violation then
  raise exception 'category already exists' using errcode='23505';
end $$;

-- Keep legacy chat/category callers shared and apply the same server-side step-up.
create or replace function fp.create_category(category_name text) returns jsonb
language sql security definer set search_path=pg_catalog,fp as $$
  select fp.create_library_category(category_name,'shared')
$$;

-- Prevent a member from placing a document in another member's private category.
create or replace function fp.enforce_private_category_owner() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare owner_id uuid; mode text;
begin
  select visibility,owner_user_id into mode,owner_id from fp.categories
  where id=new.category_id and household_id=new.household_id;
  if mode='private' and (owner_id is distinct from new.created_by or owner_id is distinct from fp.current_user_id()) then
    raise exception 'private category unavailable' using errcode='42501';
  end if;
  return new;
end $$;
drop trigger if exists enforce_private_category_owner on fp.documents;
create trigger enforce_private_category_owner before insert or update of category_id on fp.documents
for each row execute function fp.enforce_private_category_owner();

-- Preserve the existing tested workspace implementation behind a non-callable
-- internal name, then filter its response at the category privacy boundary.
alter function fp.library_workspace(text,uuid,text,text,integer,integer)
  rename to library_workspace_unfiltered_076;
revoke all on function fp.library_workspace_unfiltered_076(text,uuid,text,text,integer,integer)
  from public,anon,authenticated,service_role;

create function fp.library_workspace(
  search_query text default null,
  category_filter uuid default null,
  tag_filter text default null,
  sort_order text default 'newest',
  result_limit integer default 40,
  result_offset integer default 0
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id();
  hid uuid:=fp.active_family_id();
  result jsonb;
  visible_categories jsonb;
  visible_documents jsonb;
begin
  if category_filter is not null and not exists(
    select 1 from fp.categories c where c.id=category_filter and c.household_id=hid
      and (c.visibility='shared' or c.owner_user_id=uid)
  ) then raise exception 'invalid category' using errcode='22023'; end if;

  result:=fp.library_workspace_unfiltered_076(
    search_query,category_filter,tag_filter,sort_order,result_limit,result_offset
  );
  select coalesce(jsonb_agg(item order by (item->>'is_system')::boolean desc,item->>'name'),'[]'::jsonb)
  into visible_categories
  from jsonb_array_elements(coalesce(result->'categories','[]'::jsonb)) item
  where exists(select 1 from fp.categories c where c.id=(item->>'id')::uuid
    and (c.visibility='shared' or c.owner_user_id=uid));
  visible_categories:=coalesce((select jsonb_agg(
    item||jsonb_build_object('visibility',c.visibility,'owned_by_me',c.owner_user_id=uid)
    order by (item->>'is_system')::boolean desc,item->>'name')
    from jsonb_array_elements(visible_categories) item
    join fp.categories c on c.id=(item->>'id')::uuid),'[]'::jsonb);

  select coalesce(jsonb_agg(item),'[]'::jsonb) into visible_documents
  from jsonb_array_elements(coalesce(result->'documents','[]'::jsonb)) item
  where exists(select 1 from fp.categories c where c.id=(item->>'category_id')::uuid
    and (c.visibility='shared' or c.owner_user_id=uid));

  return result
    || jsonb_build_object('categories',visible_categories,'documents',visible_documents,
      'document_total',jsonb_array_length(visible_documents))
    || jsonb_build_object('document_count',(
      select count(*) from fp.documents d join fp.categories c on c.id=d.category_id
      where d.household_id=hid and d.lifecycle_status='active'
        and (c.visibility='shared' or c.owner_user_id=uid)
        and (d.created_by=uid or fp.is_household_admin(hid)
          or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))
    ));
end $$;

revoke execute on function fp.create_library_category(text,text),fp.library_workspace(text,uuid,text,text,integer,integer)
  from public,anon;
grant execute on function fp.create_library_category(text,text),fp.library_workspace(text,uuid,text,text,integer,integer)
  to authenticated;

comment on function fp.create_library_category(text,text) is
  'Creates a private member category or an MFA-verified shared Family category.';

commit;
