begin;

create or replace function fp.search_household_records(search_query text,result_limit integer default 20) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean; q text; tokens text[];
begin
  q:=lower(trim(regexp_replace(coalesce(search_query,''),'\s+',' ','g')));
  if char_length(q) not between 2 and 120 then raise exception 'search query must be 2 to 120 characters' using errcode='22023'; end if;
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return '[]'::jsonb; end if; admin:=fp.is_household_admin(hid);
  tokens:=array(select distinct t from unnest(regexp_split_to_array(q,'[^a-z0-9]+')) t where char_length(t)>=2 limit 12);
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'title',x.title,'category_name',x.category_name,'provider_name',x.provider_name,'document_type',x.document_type,'document_date',x.document_date,'critical_date',x.critical_date,'amount',x.amount,'currency',x.currency,'tags',x.tags,'source_name',x.source_name,'source_sha256',x.source_sha256,'email_subject',x.email_subject,'evidence_excerpt',x.evidence_excerpt,'rank',x.rank) order by x.rank desc,x.document_date desc nulls last,x.title) from (
    select d.id,d.title,c.name category_name,d.provider_name,d.document_type,d.document_date,d.critical_date,d.amount,d.currency,d.tags,d.source_name,d.source_sha256,e.subject email_subject,left(coalesce(d.extracted_text,''),600) evidence_excerpt,
      (case when lower(d.title)=q then 100 when lower(d.title) like '%'||q||'%' then 50 else 0 end + case when lower(coalesce(d.provider_name,'')) like '%'||q||'%' then 30 else 0 end + case when lower(c.name) like '%'||q||'%' then 25 else 0 end + case when d.tags ? q then 25 else 0 end + (select count(*)*5 from unnest(tokens) t where lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject)) like '%'||t||'%'))::integer rank
    from fp.documents d join fp.categories c on c.id=d.category_id left join fp.inbound_emails e on e.id=d.inbound_email_id
    where d.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))
      and (lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject)) like '%'||q||'%' or exists(select 1 from unnest(tokens) t where lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject)) like '%'||t||'%'))
    order by rank desc,d.created_at desc limit least(greatest(result_limit,1),30)
  ) x),'[]'::jsonb);
end $$;

revoke execute on function fp.search_household_records(text,integer) from public,anon;
grant execute on function fp.search_household_records(text,integer) to authenticated;
commit;
