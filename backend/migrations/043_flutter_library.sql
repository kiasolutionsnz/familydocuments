begin;

alter table fp.documents add column if not exists updated_at timestamptz not null default now();

create or replace function fp.touch_document_updated_at() returns trigger
language plpgsql set search_path=pg_catalog,fp as $$
begin
  new.updated_at:=clock_timestamp();
  return new;
end $$;
drop trigger if exists document_updated_at on fp.documents;
create trigger document_updated_at before update on fp.documents
for each row execute function fp.touch_document_updated_at();

create or replace function fp.library_workspace(
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
  hid uuid;
  member_role text;
  admin boolean;
  q text:=regexp_replace(lower(trim(coalesce(search_query,''))),'[[:space:]]+',' ','g');
  wanted_tag text:=lower(trim(coalesce(tag_filter,'')));
  answer jsonb;
begin
  select household_id,role into hid,member_role from fp.members
  where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then
    return jsonb_build_object('categories','[]'::jsonb,'documents','[]'::jsonb,'document_total',0,
      'trips','[]'::jsonb,'travel_records','[]'::jsonb,'rentals','[]'::jsonb,'rental_records','[]'::jsonb,
      'links','[]'::jsonb,'link_categories','[]'::jsonb,'tags','[]'::jsonb);
  end if;
  if sort_order not in ('newest','oldest','name') or result_limit not between 1 and 100
    or result_offset not between 0 and 10000 or char_length(q)>120 or char_length(wanted_tag)>40 then
    raise exception 'invalid library request' using errcode='22023';
  end if;
  if category_filter is not null and not exists(select 1 from fp.categories c where c.id=category_filter and c.household_id=hid) then
    raise exception 'invalid category' using errcode='22023';
  end if;
  admin:=fp.is_household_admin(hid);

  with authorised_documents as (
    select d.*,c.name category_name,
      (admin or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid and p.access_level='manage')) can_edit,
      coalesce((select j.status from fp.document_analysis_jobs j where j.document_id=d.id order by j.created_at desc limit 1),'') processing_status,
      coalesce((select string_agg(t.name,' ') from fp.travel_records r join fp.travel_trips t on t.id=r.trip_id where r.document_id=d.id),'') trip_names,
      coalesce((select string_agg(concat_ws(' ',e.name,p.address),' ') from fp.rental_bills b join fp.rental_properties p on p.entity_id=b.property_entity_id join fp.entities e on e.id=p.entity_id where b.document_id=d.id),'') rental_names
    from fp.documents d join fp.categories c on c.id=d.category_id
    where d.household_id=hid and d.lifecycle_status='active'
      and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))
  ), matching_documents as (
    select d.*,regexp_replace(lower(concat_ws(' ',d.title,d.source_name,d.original_filename,d.category_name,d.tags::text,d.trip_names,d.rental_names)),'[[:space:]]+',' ','g') search_text
    from authorised_documents d
    where (category_filter is null or d.category_id=category_filter)
      and (wanted_tag='' or exists(select 1 from jsonb_array_elements_text(d.tags) x(value) where lower(trim(x.value))=wanted_tag))
  ), filtered_documents as (
    select * from matching_documents where q='' or search_text like '%'||q||'%'
  ), document_page as (
    select * from filtered_documents
    order by
      case when sort_order='oldest' then created_at end asc,
      case when sort_order='name' then lower(title) end asc,
      case when sort_order='newest' then created_at end desc,
      id
    limit result_limit offset result_offset
  )
  select jsonb_build_object(
    'member_role',member_role,
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'is_system',c.is_system,
      'count',(select count(*) from authorised_documents d where d.category_id=c.id)) order by c.is_system desc,c.name)
      from fp.categories c where c.household_id=hid),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(jsonb_build_object(
      'id',d.id,'title',d.title,'file_name',coalesce(d.original_filename,d.source_name),'category_id',d.category_id,
      'category',d.category_name,'tags',d.tags,'saved_at',d.created_at,'updated_at',d.updated_at,
      'file_type',coalesce(d.mime_type,'document'),'document_date',d.document_date,'important_date',d.critical_date,
      'source_available',d.source_status='available','processing_status',nullif(d.processing_status,''),'can_edit',d.can_edit
    ) order by
      case when sort_order='oldest' then d.created_at end asc,
      case when sort_order='name' then lower(d.title) end asc,
      case when sort_order='newest' then d.created_at end desc,d.id) from document_page d),'[]'::jsonb),
    'document_total',(select count(*) from filtered_documents),
    'document_count',(select count(*) from authorised_documents),
    'travel_count',(select count(*) from authorised_documents d where lower(d.category_name)='travel' or exists(select 1 from fp.travel_records r where r.document_id=d.id)),
    'rental_count',(select count(*) from authorised_documents d where lower(d.category_name) in ('rentals','rental records') or exists(select 1 from fp.rental_bills b where b.document_id=d.id)),
    'tags',coalesce((select jsonb_agg(tag order by tag) from (select distinct lower(trim(x.value)) tag from authorised_documents d cross join lateral jsonb_array_elements_text(d.tags) x(value) where trim(x.value)<>'' ) tags),'[]'::jsonb),
    'trips',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'destination',t.destination,'start_date',t.start_date,'end_date',t.end_date,
      'document_count',(select count(*) from fp.travel_records r join authorised_documents d on d.id=r.document_id where r.trip_id=t.id)) order by coalesce(t.start_date,'9999-12-31'),t.name)
      from fp.travel_trips t where t.household_id=hid and fp.can_manage_trip(t.id,'view')
        and (q='' or regexp_replace(lower(concat_ws(' ',t.name,t.destination)),'[[:space:]]+',' ','g') like '%'||q||'%' or exists(select 1 from fp.travel_records r join matching_documents d on d.id=r.document_id where r.trip_id=t.id and d.search_text like '%'||q||'%'))),'[]'::jsonb),
    'travel_records',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'trip_id',r.trip_id,'document_id',d.id,'title',d.title,'kind',r.travel_kind,'category',d.category_name,'tags',d.tags,'saved_at',d.created_at) order by coalesce(r.starts_at,r.confirmed_at),d.title)
      from fp.travel_records r join fp.travel_trips t on t.id=r.trip_id join authorised_documents d on d.id=r.document_id
      where r.household_id=hid and fp.can_manage_trip(t.id,'view')),'[]'::jsonb),
    'unassigned_travel',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category',d.category_name,'tags',d.tags,'saved_at',d.created_at) order by d.created_at desc)
      from authorised_documents d where lower(d.category_name)='travel' and not exists(select 1 from fp.travel_records r where r.document_id=d.id)),'[]'::jsonb),
    'rentals',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'address',p.address,
      'document_count',(select count(*) from fp.rental_bills b join authorised_documents d on d.id=b.document_id where b.property_entity_id=e.id)) order by e.name)
      from fp.rental_properties p join fp.entities e on e.id=p.entity_id where p.household_id=hid and e.status='active'
        and (admin or p.created_by=uid or exists(select 1 from fp.access_rules a where a.household_id=hid and a.scope_type='entity' and a.entity_id=e.id and a.member_user_id=uid))
        and (q='' or regexp_replace(lower(concat_ws(' ',e.name,p.address)),'[[:space:]]+',' ','g') like '%'||q||'%' or exists(select 1 from fp.rental_bills b join matching_documents d on d.id=b.document_id where b.property_entity_id=e.id and d.search_text like '%'||q||'%'))),'[]'::jsonb),
    'rental_records',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'property_id',b.property_entity_id,'document_id',d.id,'title',d.title,'kind',b.expense_category,'category',d.category_name,'tags',d.tags,'saved_at',d.created_at) order by d.created_at desc)
      from fp.rental_bills b join authorised_documents d on d.id=b.document_id where b.household_id=hid),'[]'::jsonb),
    'unassigned_rentals',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category',d.category_name,'tags',d.tags,'saved_at',d.created_at) order by d.created_at desc)
      from authorised_documents d where lower(d.category_name) in ('rentals','rental records') and not exists(select 1 from fp.rental_bills b where b.document_id=d.id)),'[]'::jsonb),
    'link_categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name)
      from fp.saved_link_categories c where c.household_id=hid and c.owner_user_id=uid and c.status='active'),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'title',l.title,'url',l.url,'domain',l.source_host,
      'category_id',case when l.owner_user_id=uid then l.category_id end,'category',case when l.owner_user_id=uid then c.name else 'Shared links' end,
      'tags','[]'::jsonb,'saved_at',l.created_at,'owned_by_me',l.owner_user_id=uid) order by l.created_at desc)
      from fp.saved_links l left join fp.saved_link_categories c on c.id=l.category_id
      where l.household_id=hid and l.status='active' and (l.owner_user_id=uid or exists(select 1 from fp.saved_link_permissions p join fp.members m on m.household_id=hid and m.user_id=p.member_user_id and m.status='active' where p.link_id=l.id and p.member_user_id=uid))
        and (q='' or regexp_replace(lower(concat_ws(' ',l.title,l.source_host,case when l.owner_user_id=uid then c.name end)),'[[:space:]]+',' ','g') like '%'||q||'%')),'[]'::jsonb),
    'link_count',(select count(*) from fp.saved_links l where l.household_id=hid and l.status='active' and (l.owner_user_id=uid or exists(select 1 from fp.saved_link_permissions p join fp.members m on m.household_id=hid and m.user_id=p.member_user_id and m.status='active' where p.link_id=l.id and p.member_user_id=uid)))
  ) into answer;
  return answer;
end $$;

create or replace function fp.update_library_document(
  document uuid,
  category uuid,
  confirmed_tags jsonb,
  expected_updated_at timestamptz
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();d fp.documents;normalised jsonb;
begin
  select source.* into d from fp.documents source where source.id=document and source.lifecycle_status='active' and fp.is_active_member(source.household_id)
    and (source.created_by=uid or fp.is_household_admin(source.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=source.id and p.member_user_id=uid and p.access_level='manage')) for update;
  if d.id is null then raise exception 'not authorised' using errcode='42501';end if;
  if not exists(select 1 from fp.categories c where c.id=category and c.household_id=d.household_id) then raise exception 'invalid category' using errcode='22023';end if;
  if expected_updated_at is null or d.updated_at is distinct from expected_updated_at then raise exception 'document changed' using errcode='PT409';end if;
  if jsonb_typeof(confirmed_tags)<>'array' or jsonb_array_length(confirmed_tags)>12
    or exists(select 1 from jsonb_array_elements_text(confirmed_tags) x(value) where char_length(trim(x.value)) not between 1 and 40) then
    raise exception 'invalid tags' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(tag order by tag),'[]'::jsonb) into normalised from (
    select distinct lower(trim(x.value)) tag from jsonb_array_elements_text(confirmed_tags) x(value)
  ) tags;
  update fp.documents set category_id=category,tags=normalised,updated_at=clock_timestamp() where id=d.id returning * into d;
  return jsonb_build_object('id',d.id,'category_id',d.category_id,'tags',d.tags,'updated_at',d.updated_at);
end $$;

revoke execute on function fp.touch_document_updated_at(),fp.library_workspace(text,uuid,text,text,integer,integer),fp.update_library_document(uuid,uuid,jsonb,timestamptz) from public,anon,authenticated;
grant execute on function fp.library_workspace(text,uuid,text,text,integer,integer),fp.update_library_document(uuid,uuid,jsonb,timestamptz) to authenticated;

commit;
