begin;

create or replace function fp.document_analysis_job(job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();j fp.document_analysis_jobs;d fp.documents;c fp.categories;
begin
  select x.* into j from fp.document_analysis_jobs x where x.id=job and fp.is_active_member(x.household_id)
    and (x.requested_by=uid or fp.is_household_admin(x.household_id) or exists(
      select 1 from fp.document_permissions p where p.document_id=x.document_id and p.member_user_id=uid
    ));
  if j.id is null then raise exception 'job not found' using errcode='PT404';end if;
  select * into d from fp.documents where id=j.document_id and household_id=j.household_id and lifecycle_status<>'deleted';
  if d.id is null then raise exception 'job not found' using errcode='PT404';end if;
  select * into c from fp.categories where id=d.category_id and household_id=j.household_id;
  return jsonb_build_object(
    'job_id',j.id,'document_id',j.document_id,'status',j.status,'attempts',j.attempts,
    'created_at',j.created_at,'started_at',j.started_at,'completed_at',j.completed_at,'updated_at',j.updated_at,
    'title',d.title,'category',c.name,'tags',d.tags,'result',j.result,
    'failure',case when j.status in ('failed','permanent_failed') then 'This document could not be read.' else null end,
    'retry_allowed',j.status in ('failed','permanent_failed')
  );
end $$;

create or replace function fp.family_timeline(
  before_time timestamptz default null,
  before_key text default null,
  search_query text default null,
  result_limit integer default 40
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;admin boolean;q text:=lower(trim(coalesce(search_query,'')));answer jsonb;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then return jsonb_build_object('items','[]'::jsonb,'has_more',false,'next_cursor',null);end if;
  if result_limit not between 1 and 100 or char_length(q)>120 then raise exception 'invalid timeline request' using errcode='22023';end if;
  admin:=fp.is_household_admin(hid);

  with events as (
    select d.id,'document:'||d.id::text event_key,'document' kind,'document_saved' event_type,
      d.title||' saved' title,c.name context,d.created_at occurred_at,null::text status,d.id document_id,
      null::uuid job_id,c.name category,d.tags,null::text url,false retry_allowed,
      lower(concat_ws(' ',d.title,c.name,d.document_type,d.provider_name,d.tags::text,d.source_name)) search_text
    from fp.documents d join fp.categories c on c.id=d.category_id
    where d.household_id=hid and d.lifecycle_status<>'deleted'
      and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))
      and not exists(select 1 from fp.document_analysis_jobs j where j.document_id=d.id)
    union all
    select j.id,'analysis:'||j.id::text,'document','document_processing',
      case j.status
        when 'queued' then d.title||' queued for reading'
        when 'retry_wait' then d.title||' queued for reading'
        when 'processing' then 'Reading '||d.title||'…'
        when 'succeeded' then 'Finished reading '||d.title
        when 'failed' then 'I couldn’t read this document.'
        when 'permanent_failed' then 'I couldn’t read this document.'
        else d.title||' saved'
      end,
      c.name,coalesce(j.completed_at,j.updated_at,j.created_at),j.status,d.id,j.id,c.name,d.tags,null::text,
      j.status in ('failed','permanent_failed'),
      lower(concat_ws(' ',d.title,c.name,d.document_type,d.provider_name,d.tags::text,d.source_name))
    from fp.document_analysis_jobs j join fp.documents d on d.id=j.document_id and d.household_id=j.household_id
      join fp.categories c on c.id=d.category_id
    where j.household_id=hid and j.status<>'dismissed' and d.lifecycle_status<>'deleted'
      and (j.requested_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))
    union all
    select r.id,'reminder-created:'||r.id::text,'reminder','reminder_created',r.title||' reminder created',
      coalesce(d.title,c.name,'Reminders'),r.created_at,r.status,r.document_id,null::uuid,c.name,'[]'::jsonb,null::text,false,
      lower(concat_ws(' ',r.title,d.title,c.name,r.status))
    from fp.reminders r left join fp.documents d on d.id=r.document_id and d.household_id=r.household_id
      left join fp.categories c on c.id=d.category_id
    where r.household_id=hid and (r.document_id is null or d.lifecycle_status<>'deleted')
      and ((r.audience='personal' and r.created_by=uid) or r.audience='family')
      and (r.document_id is null or admin or d.created_by=uid or exists(
        select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid
      ))
    union all
    select r.id,'reminder-completed:'||r.id::text,'reminder','reminder_completed',r.title||' completed',
      coalesce(d.title,c.name,'Reminders'),r.completed_at,r.status,r.document_id,null::uuid,c.name,'[]'::jsonb,null::text,false,
      lower(concat_ws(' ',r.title,d.title,c.name,'completed'))
    from fp.reminders r left join fp.documents d on d.id=r.document_id and d.household_id=r.household_id
      left join fp.categories c on c.id=d.category_id
    where r.household_id=hid and r.completed_at is not null and (r.document_id is null or d.lifecycle_status<>'deleted')
      and ((r.audience='personal' and r.created_by=uid) or r.audience='family')
      and (r.document_id is null or admin or d.created_by=uid or exists(
        select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid
      ))
    union all
    select l.id,'link:'||l.id::text,'link','saved_link_added',l.title||' saved',
      case when l.owner_user_id=uid then coalesce(c.name,l.source_host) else 'Shared by '||coalesce(m.display_name,m.email) end,
      l.created_at,l.status,null::uuid,null::uuid,case when l.owner_user_id=uid then c.name end,'[]'::jsonb,l.url,false,
      lower(concat_ws(' ',l.title,l.note,l.url,l.source_host,c.name,m.display_name,m.email))
    from fp.saved_links l left join fp.saved_link_categories c on c.id=l.category_id
      left join fp.members m on m.household_id=l.household_id and m.user_id=l.owner_user_id
    where l.household_id=hid and l.status='active' and (l.owner_user_id=uid or exists(
      select 1 from fp.saved_link_permissions p join fp.members active_member
        on active_member.household_id=l.household_id and active_member.user_id=p.member_user_id and active_member.status='active'
      where p.link_id=l.id and p.member_user_id=uid
    ))
    union all
    select e.id,'message:'||e.id::text,'message','message_received',coalesce(nullif(e.subject,''),'Message received'),
      coalesce(nullif(e.sender_address,''),'Email'),e.ingested_at,e.processing_status,null::uuid,null::uuid,null::text,'[]'::jsonb,null::text,false,
      lower(concat_ws(' ',e.subject,e.sender_address,e.processing_status))
    from fp.inbound_emails e where e.household_id=hid and admin and e.deleted_at is null
  ), filtered as (
    select * from events where (q='' or search_text like '%'||q||'%')
      and (before_time is null or occurred_at<before_time or (occurred_at=before_time and event_key<coalesce(before_key,'')))
  ), limited as (
    select * from filtered order by occurred_at desc,event_key desc limit result_limit+1
  ), page as (
    select * from limited order by occurred_at desc,event_key desc limit result_limit
  )
  select jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(p)-'search_text' order by occurred_at desc,event_key desc) from page p),'[]'::jsonb),
    'has_more',(select count(*) from limited)>result_limit,
    'next_cursor',case when (select count(*) from limited)>result_limit then
      (select jsonb_build_object('occurred_at',occurred_at,'event_key',event_key) from page order by occurred_at,event_key limit 1)
      else null end
  ) into answer;
  return answer;
end $$;

revoke execute on function fp.family_timeline(timestamptz,text,text,integer) from public,anon;
grant execute on function fp.family_timeline(timestamptz,text,text,integer) to authenticated;

commit;
