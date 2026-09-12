begin;

-- Document opening is always scoped to the currently selected Family.
create or replace function fp.authorized_source_document(document uuid) returns fp.documents
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();row fp.documents;
begin
  select d.* into row from fp.documents d
  where d.id=document and d.household_id=hid and d.lifecycle_status<>'deleted'
    and (d.created_by=uid or fp.is_household_admin(hid)
      or exists(select 1 from fp.document_permissions p
        where p.document_id=d.id and p.member_user_id=uid));
  if row.id is null then raise exception 'source not found' using errcode='PT404';end if;
  return row;
end $$;

-- A missing source is distinguishable only after the caller has passed the
-- document permission check. Unauthorized IDs retain the same 404 response.
create or replace function fp.document_preview_source(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare d fp.documents;s fp.external_sources;result jsonb;
begin
  d:=fp.authorized_source_document(document);
  select es.* into s from fp.document_external_sources des
    join fp.external_sources es on es.id=des.external_source_id
    where des.document_id=d.id and es.household_id=d.household_id limit 1;
  if s.id is not null and s.status='disconnected' then
    return jsonb_build_object('status','provider_disconnected');
  end if;
  begin
    result:=fp.document_source(document);
    return result;
  exception when sqlstate 'PT404' then
    return jsonb_build_object('status','file_unavailable');
  end;
end $$;

-- One saved document per Inbox attachment. The attachment lock also covers
-- retries that arrive with a new request key after a lost response.
create or replace function fp.inbox_save_attachment(
  message uuid,attachment uuid,category uuid,selected_tags jsonb,
  request_id text,request_ocr boolean default false
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;
  e fp.inbound_emails;a fp.inbound_attachments;existing fp.inbox_actions;
  d fp.documents;j fp.document_analysis_jobs;tags jsonb;digest text;result jsonb;
begin
  select role into member_role from fp.members
    where user_id=uid and household_id=hid and status='active';
  if not fp.inbox_can_edit(member_role) then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if request_id is null or char_length(request_id) not between 8 and 100 then
    raise exception 'invalid request id' using errcode='22023';
  end if;
  select * into e from fp.inbound_emails
    where id=message and household_id=hid and deleted_at is null;
  select * into a from fp.inbound_attachments
    where id=attachment and inbound_email_id=e.id and household_id=hid
      and scan_status='clean';
  if e.id is null or a.id is null then
    raise exception 'attachment not available' using errcode='PT404';
  end if;
  if not exists(select 1 from fp.categories c
      where c.id=category and c.household_id=hid) then
    raise exception 'invalid category' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||a.id::text,0));
  select * into existing from fp.inbox_actions x
    where x.household_id=hid and x.inbound_email_id=e.id
      and x.attachment_id=a.id and x.action_type in ('document_saved','ocr_requested')
    order by x.created_at limit 1;
  if existing.id is not null then
    return existing.result||jsonb_build_object('duplicate',true);
  end if;
  select * into existing from fp.inbox_actions x
    where x.household_id=hid and x.actor_user_id=uid and x.request_id=inbox_save_attachment.request_id;
  if existing.id is not null then
    raise exception 'request key used for another action' using errcode='22023';
  end if;
  if jsonb_typeof(coalesce(selected_tags,'[]'::jsonb))<>'array' then
    raise exception 'invalid tags' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(value order by value),'[]'::jsonb) into tags
    from (select distinct lower(trim(value)) value
      from jsonb_array_elements_text(coalesce(selected_tags,'[]'::jsonb))
      where char_length(trim(value)) between 1 and 40 limit 12)t;
  perform fp.validate_document_bytes(a.claimed_content_type,a.content);
  digest:=encode(extensions.digest(a.content,'sha256'),'hex');
  insert into fp.documents(household_id,category_id,title,created_by,
    source_name,source_sha256,mime_type,confirmation_status,storage_provider,
    original_filename,file_size,source_status,inbound_email_id,
    source_attachment_id,tags)
  values(hid,category,left(regexp_replace(a.file_name,'\.[^.]+$',''),120),uid,
    a.file_name,digest,a.claimed_content_type,'confirmed','home_server',
    a.file_name,octet_length(a.content),'available',e.id,a.id,tags)
  returning * into d;
  insert into fp.manual_document_sources(household_id,document_id,file_name,
    mime_type,content,sha256,created_by)
  values(hid,d.id,a.file_name,a.claimed_content_type,a.content,digest,uid);
  if request_ocr then
    insert into fp.document_analysis_jobs(household_id,document_id,
      requested_by,mode,idempotency_key)
    values(hid,d.id,uid,
      case when lower(a.file_name) like '%invoice%' or lower(a.file_name) like '%bill%'
        then 'invoice' else 'document' end,request_id)
    returning * into j;
  end if;
  result:=jsonb_build_object('document_id',d.id,'title',d.title,
    'category_id',category,'tags',tags,'job_id',j.id,'job_status',j.status,
    'duplicate',false);
  insert into fp.inbox_actions(household_id,inbound_email_id,attachment_id,
    actor_user_id,action_type,request_id,result)
  values(hid,e.id,a.id,uid,
    case when request_ocr then 'ocr_requested' else 'document_saved' end,
    request_id,result);
  return result;
end $$;

-- Preserve action targets in the Inbox detail response, allowing completed
-- attachments to be opened and independently reviewed after a refresh.
create or replace function fp.inbox_workspace(
  search_query text default null,state_filter text default 'all',
  result_limit integer default 30,result_offset integer default 0
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
  member_role text;q text:=regexp_replace(lower(trim(coalesce(search_query,''))),
    '[[:space:]]+',' ','g');
begin
  select role into member_role from fp.members
    where user_id=uid and household_id=hid and status='active';
  if state_filter not in ('all','unreviewed','attachments','links','reviewed')
    or result_limit not between 1 and 60 or result_offset not between 0 and 10000
    then raise exception 'invalid inbox filter' using errcode='22023';end if;
  return jsonb_build_object(
    'can_edit',fp.inbox_can_edit(member_role),
    'total',(select count(*) from fp.inbound_emails x
      where x.household_id=hid and x.deleted_at is null
      and x.review_state<>'dismissed'
      and (state_filter='all' or state_filter='unreviewed' and x.review_state='unreviewed'
        or state_filter='reviewed' and x.review_state='reviewed'
        or state_filter='attachments' and x.attachment_count>0
        or state_filter='links' and regexp_count(fp.inbox_safe_text(x.body_text),
          'https?://[^[:space:]<>"'']+',1,'i')>0)
      and (q='' or regexp_replace(lower(concat_ws(' ',x.sender_address,
        x.subject,left(x.body_text,2000))),'[[:space:]]+',' ','g') like '%'||q||'%')),
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,
      'name',c.name) order by c.name) from fp.categories c
      where c.household_id=hid),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(t.tag order by t.tag)
      from (select distinct lower(value) tag from fp.documents d
        cross join lateral jsonb_array_elements_text(d.tags)value
        where d.household_id=hid and d.lifecycle_status<>'deleted')t),'[]'::jsonb),
    'link_categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,
      'name',c.name) order by c.name) from fp.saved_link_categories c
      where c.household_id=hid and c.owner_user_id=uid and c.status='active'),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'id',e.id,'sender',e.sender_address,'subject',e.subject,
      'received_at',coalesce(e.sent_at,e.ingested_at),
      'source',case when e.source_system like '%chat%' then 'Chat' else 'Email' end,
      'preview',left(fp.inbox_safe_text(e.body_text),220),
      'attachment_count',e.attachment_count,
      'link_count',regexp_count(fp.inbox_safe_text(e.body_text),
        'https?://[^[:space:]<>"'']+',1,'i'),
      'review_state',e.review_state,'updated_at',e.review_updated_at,
      'actions',coalesce((select jsonb_agg(a.action_type order by a.created_at,a.id)
        from fp.inbox_actions a where a.inbound_email_id=e.id),'[]'::jsonb))
      order by coalesce(e.sent_at,e.ingested_at) desc,e.id desc)
      from (select x.* from fp.inbound_emails x
        where x.household_id=hid and x.deleted_at is null
          and x.review_state<>'dismissed'
          and (state_filter='all' or state_filter='unreviewed' and x.review_state='unreviewed'
            or state_filter='reviewed' and x.review_state='reviewed'
            or state_filter='attachments' and x.attachment_count>0
            or state_filter='links' and regexp_count(fp.inbox_safe_text(x.body_text),
              'https?://[^[:space:]<>"'']+',1,'i')>0)
          and (q='' or regexp_replace(lower(concat_ws(' ',x.sender_address,
            x.subject,left(x.body_text,2000))),'[[:space:]]+',' ','g') like '%'||q||'%')
        order by coalesce(x.sent_at,x.ingested_at) desc,x.id desc
        limit result_limit offset result_offset)e),'[]'::jsonb)
  );
end $$;

create or replace function fp.inbox_message_detail(message uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;e fp.inbound_emails;
begin
  select m.role into member_role from fp.members m
    where m.user_id=uid and m.household_id=hid and m.status='active';
  select * into e from fp.inbound_emails
    where id=message and household_id=hid and deleted_at is null;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  return jsonb_build_object(
    'id',e.id,'sender',e.sender_address,'recipients',e.recipient_addresses,
    'subject',e.subject,'received_at',coalesce(e.sent_at,e.ingested_at),
    'source',case when e.source_system like '%chat%' then 'Chat' else 'Email' end,
    'body_text',fp.inbox_safe_text(e.body_text),'review_state',e.review_state,
    'updated_at',e.review_updated_at,'can_edit',fp.inbox_can_edit(member_role),
    'attachments',coalesce((select jsonb_agg(jsonb_build_object(
      'id',a.id,'file_name',a.file_name,'mime_type',a.claimed_content_type,
      'size_bytes',a.expected_size_bytes,'status',a.scan_status) order by a.created_at)
      from fp.inbound_attachments a where a.inbound_email_id=e.id),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(u.url order by u.url) from
      (select distinct (regexp_matches(fp.inbox_safe_text(e.body_text),
        'https?://[^[:space:]<>"'']+','gi'))[1] url)u),'[]'::jsonb),
    'actions',coalesce((select jsonb_agg(jsonb_build_object(
      'type',a.action_type,'attachment_id',a.attachment_id,
      'result',case when a.action_type='link_saved' then
        a.result||jsonb_build_object('url',l.url) else a.result end,
      'created_at',a.created_at) order by a.created_at)
      from fp.inbox_actions a left join fp.saved_links l
        on l.id::text=a.result->>'id' and l.household_id=hid
      where a.inbound_email_id=e.id and a.household_id=hid),'[]'::jsonb)
  );
end $$;

create or replace function fp.set_inbox_review_state(
  message uuid,new_state text,expected_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
  member_role text;e fp.inbound_emails;
begin
  select role into member_role from fp.members
    where user_id=uid and household_id=hid and status='active';
  if not fp.inbox_can_edit(member_role) then
    raise exception 'not authorised' using errcode='42501';end if;
  if new_state not in ('unreviewed','reviewed','dismissed') then
    raise exception 'invalid review state' using errcode='22023';end if;
  select * into e from fp.inbound_emails
    where id=message and household_id=hid and deleted_at is null for update;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  if expected_updated_at is not null and e.review_updated_at<>expected_updated_at
    then raise exception 'message changed' using errcode='40001';end if;
  update fp.inbound_emails set review_state=new_state,
    reviewed_at=case when new_state='reviewed' then now() else null end,
    reviewed_by=case when new_state='reviewed' then uid else null end,
    review_updated_at=now() where id=e.id returning * into e;
  return jsonb_build_object('id',e.id,'review_state',e.review_state,
    'updated_at',e.review_updated_at);
end $$;

create or replace function fp.inbox_save_link(
  message uuid,link_url text,link_title text,category uuid,request_id text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
  member_role text;e fp.inbound_emails;parsed jsonb;existing fp.inbox_actions;
  row fp.saved_links;previous uuid;result jsonb;
begin
  select role into member_role from fp.members
    where user_id=uid and household_id=hid and status='active';
  if not fp.inbox_can_edit(member_role) then
    raise exception 'not authorised' using errcode='42501';end if;
  if request_id is null or char_length(request_id) not between 8 and 100
    or char_length(trim(link_title)) not between 1 and 160
    then raise exception 'invalid link request' using errcode='22023';end if;
  select * into e from fp.inbound_emails
    where id=message and household_id=hid and deleted_at is null;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  if not exists(select 1 from (select distinct
    (regexp_matches(fp.inbox_safe_text(e.body_text),
      'https?://[^[:space:]<>"'']+','gi'))[1] url)u
    where u.url=link_url) then
    raise exception 'link not found' using errcode='22023';end if;
  if not exists(select 1 from fp.saved_link_categories c
    where c.id=category and c.household_id=hid and c.owner_user_id=uid
      and c.status='active') then
    raise exception 'invalid category' using errcode='42501';end if;
  parsed:=fp.normalise_saved_link_url(link_url);
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||e.id::text||
    ':'||(parsed->>'hash'),0));
  select a.* into existing from fp.inbox_actions a
    join fp.saved_links l on l.id::text=a.result->>'id'
      and l.household_id=hid and l.owner_user_id=uid
    where a.household_id=hid and a.inbound_email_id=e.id
      and a.action_type='link_saved' and l.normalized_url_hash=parsed->>'hash'
    order by a.created_at limit 1;
  if existing.id is not null then
    return existing.result||jsonb_build_object('duplicate',true);
  end if;
  if exists(select 1 from fp.inbox_actions a where a.household_id=hid
      and a.actor_user_id=uid and a.request_id=inbox_save_link.request_id) then
    raise exception 'request key used for another action' using errcode='22023';end if;
  select id into previous from fp.saved_links l where l.household_id=hid
    and l.owner_user_id=uid and l.normalized_url_hash=parsed->>'hash'
    and l.status='active' order by l.created_at limit 1;
  insert into fp.saved_links(household_id,owner_user_id,category_id,url,
    normalized_url_hash,source_host,title,note)
  values(hid,uid,category,parsed->>'url',parsed->>'hash',parsed->>'host',
    trim(link_title),null) returning * into row;
  insert into fp.saved_link_security_events(household_id,owner_user_id,
    actor_user_id,link_id,event_type)
  values(hid,uid,uid,row.id,'created');
  result:=jsonb_build_object('id',row.id,'title',row.title,'private',true,
    'duplicate_of',previous,'duplicate',false);
  insert into fp.inbox_actions(household_id,inbound_email_id,actor_user_id,
    action_type,request_id,result)
  values(hid,e.id,uid,'link_saved',request_id,result);
  return result;
end $$;

create or replace function fp.inbox_create_reminder(
  message uuid,reminder_title text,due_date date,due_time_value time,
  repeat text,request_id text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
  member_role text;e fp.inbound_emails;existing fp.inbox_actions;
  row fp.reminders;result jsonb;april_first date;september_last date;
  autumn_transition date;spring_transition date;
begin
  select role into member_role from fp.members
    where user_id=uid and household_id=hid and status='active';
  if not fp.inbox_can_edit(member_role) then
    raise exception 'not authorised' using errcode='42501';end if;
  if request_id is null or char_length(request_id) not between 8 and 100
    or char_length(trim(reminder_title)) not between 1 and 160
    or due_date is null or repeat not in ('none','monthly','yearly') then
    raise exception 'invalid reminder' using errcode='22023';end if;
  select * into e from fp.inbound_emails
    where id=message and household_id=hid and deleted_at is null;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  if due_time_value is not null and due_time_value>=time '02:00'
    and due_time_value<time '03:00' then
    april_first:=make_date(extract(year from due_date)::integer,4,1);
    september_last:=make_date(extract(year from due_date)::integer,9,30);
    autumn_transition:=april_first+((7-extract(dow from april_first)::integer)%7);
    spring_transition:=september_last-extract(dow from september_last)::integer;
    if due_date in (autumn_transition,spring_transition) then
      raise exception 'ambiguous or nonexistent Auckland local time' using errcode='22023';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||e.id::text||
    ':'||lower(trim(reminder_title))||':'||due_date::text||':'||
    coalesce(due_time_value::text,'')||':'||repeat,0));
  select a.* into existing from fp.inbox_actions a
    join fp.reminders r on r.id::text=a.result->>'id'
      and r.household_id=hid and r.created_by=uid
    where a.household_id=hid and a.inbound_email_id=e.id
      and a.action_type='reminder_created'
      and lower(r.title)=lower(trim(reminder_title)) and r.due_at=due_date
      and r.due_time is not distinct from due_time_value
      and r.recurrence=repeat
    order by a.created_at limit 1;
  if existing.id is not null then
    return existing.result||jsonb_build_object('duplicate',true);
  end if;
  if exists(select 1 from fp.inbox_actions a where a.household_id=hid
      and a.actor_user_id=uid and a.request_id=inbox_create_reminder.request_id)
    then raise exception 'request key used for another action' using errcode='22023';end if;
  insert into fp.reminders(household_id,title,due_at,due_time,
    due_time_zone,created_by,client_request_id,recurrence,
    root_reminder_id,original_due_at,original_due_time)
  values(hid,trim(reminder_title),due_date,due_time_value,
    'Pacific/Auckland',uid,request_id,repeat,null,
    case when repeat='none' then null else due_date end,
    case when repeat='none' then null else due_time_value end)
  returning * into row;
  result:=jsonb_build_object('id',row.id,'title',row.title,
    'due_at',row.due_at,'due_time',row.due_time,
    'due_time_zone',row.due_time_zone,'document_id',row.document_id,
    'status',row.status,'recurrence',row.recurrence,'duplicate',false);
  insert into fp.inbox_actions(household_id,inbound_email_id,actor_user_id,
    action_type,request_id,result)
  values(hid,e.id,uid,'reminder_created',request_id,result);
  return result;
end $$;

-- The existing explicit category-creation buttons must also follow the active
-- Family; a second membership must not redirect creation to the first Family.
create or replace function fp.create_category(category_name text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();row fp.categories;
begin
  if not fp.is_household_admin(hid) then
    raise exception 'not authorised' using errcode='42501';end if;
  if char_length(trim(category_name)) not between 1 and 80 then
    raise exception 'invalid category name' using errcode='22023';end if;
  insert into fp.categories(household_id,name,created_by)
    values(hid,trim(category_name),uid) returning * into row;
  return jsonb_build_object('id',row.id,'name',row.name,
    'is_system',row.is_system);
end $$;

create or replace function fp.create_saved_link_category(category_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
  row fp.saved_link_categories;
begin
  if char_length(trim(category_name)) not between 1 and 40 then
    raise exception 'invalid category name' using errcode='22023';end if;
  insert into fp.saved_link_categories(household_id,owner_user_id,name)
    values(hid,uid,trim(category_name)) returning * into row;
  return jsonb_build_object('id',row.id,'name',row.name);
exception when unique_violation then
  raise exception 'category already exists' using errcode='23505';
end $$;

revoke execute on function fp.document_preview_source(uuid),fp.inbox_workspace(text,text,integer,integer),
  fp.inbox_message_detail(uuid),fp.set_inbox_review_state(uuid,text,timestamptz),
  fp.inbox_save_attachment(uuid,uuid,uuid,jsonb,text,boolean),
  fp.inbox_save_link(uuid,text,text,uuid,text),
  fp.inbox_create_reminder(uuid,text,date,time,text,text),
  fp.create_category(text),fp.create_saved_link_category(text)
  from public,anon;
grant execute on function fp.document_preview_source(uuid),fp.inbox_workspace(text,text,integer,integer),
  fp.inbox_message_detail(uuid),fp.set_inbox_review_state(uuid,text,timestamptz),
  fp.inbox_save_attachment(uuid,uuid,uuid,jsonb,text,boolean),
  fp.inbox_save_link(uuid,text,text,uuid,text),
  fp.inbox_create_reminder(uuid,text,date,time,text,text),
  fp.create_category(text),fp.create_saved_link_category(text)
  to authenticated;

commit;
