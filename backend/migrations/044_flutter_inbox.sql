begin;

alter table fp.inbound_emails add column if not exists review_state text not null default 'unreviewed';
alter table fp.inbound_emails add column if not exists reviewed_at timestamptz;
alter table fp.inbound_emails add column if not exists reviewed_by uuid;
alter table fp.inbound_emails add column if not exists review_updated_at timestamptz not null default now();
alter table fp.inbound_emails drop constraint if exists inbound_emails_review_state_check;
alter table fp.inbound_emails add constraint inbound_emails_review_state_check
  check(review_state in ('unreviewed','reviewed','dismissed'));
create index if not exists inbound_emails_review_queue
  on fp.inbound_emails(household_id,review_state,ingested_at desc) where deleted_at is null;

create table if not exists fp.inbox_actions(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  inbound_email_id uuid not null references fp.inbound_emails(id) on delete cascade,
  attachment_id uuid references fp.inbound_attachments(id) on delete set null,
  actor_user_id uuid not null,
  action_type text not null check(action_type in ('document_saved','ocr_requested','reminder_created','link_saved')),
  request_id text not null check(char_length(request_id) between 8 and 100),
  result jsonb not null default '{}'::jsonb check(jsonb_typeof(result)='object'),
  created_at timestamptz not null default now(),
  unique(household_id,actor_user_id,request_id)
);
create index if not exists inbox_actions_email_created on fp.inbox_actions(inbound_email_id,created_at);
alter table fp.inbox_actions enable row level security;
alter table fp.inbox_actions force row level security;
revoke all on fp.inbox_actions from public,anon,authenticated;

create or replace function fp.inbox_can_edit(member_role text) returns boolean
language sql immutable as $$select member_role in ('owner','family_admin','adult_member','contributor')$$;

create or replace function fp.inbox_safe_text(input text) returns text
language sql immutable as $$
  select trim(regexp_replace(regexp_replace(regexp_replace(coalesce(input,''),'(?is)<(script|style)[^>]*>.*?</\1>',' ','g'),'<[^>]+>',' ','g'),'[[:space:]]+',' ','g'))
$$;

create or replace function fp.inbox_workspace(
  search_query text default null,
  state_filter text default 'all',
  result_limit integer default 30,
  result_offset integer default 0
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;q text:=regexp_replace(lower(trim(coalesce(search_query,''))),'[[:space:]]+',' ','g');
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null then raise exception 'not authorised' using errcode='42501';end if;
  if state_filter not in ('all','unreviewed','attachments','links','reviewed') or result_limit not between 1 and 60 or result_offset not between 0 and 10000 then raise exception 'invalid inbox filter' using errcode='22023';end if;
  return jsonb_build_object(
    'can_edit',fp.inbox_can_edit(member_role),
    'total',(select count(*) from fp.inbound_emails x where x.household_id=hid and x.deleted_at is null and x.review_state<>'dismissed'
      and (state_filter='all' or state_filter='unreviewed' and x.review_state='unreviewed' or state_filter='reviewed' and x.review_state='reviewed'
        or state_filter='attachments' and x.attachment_count>0 or state_filter='links' and regexp_count(fp.inbox_safe_text(x.body_text),'https?://[^[:space:]<>"'']+',1,'i')>0)
      and (q='' or regexp_replace(lower(concat_ws(' ',x.sender_address,x.subject,left(x.body_text,2000))),'[[:space:]]+',' ','g') like '%'||q||'%')),
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from fp.categories c where c.household_id=hid),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(t.tag order by t.tag) from (select distinct lower(value) tag from fp.documents d cross join lateral jsonb_array_elements_text(d.tags)value where d.household_id=hid and d.lifecycle_status<>'deleted')t),'[]'::jsonb),
    'link_categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from fp.saved_link_categories c where c.household_id=hid and c.owner_user_id=uid and c.status='active'),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'id',e.id,'sender',e.sender_address,'subject',e.subject,'received_at',coalesce(e.sent_at,e.ingested_at),
      'source',case when e.source_system like '%chat%' then 'Chat' else 'Email' end,
      'preview',left(fp.inbox_safe_text(e.body_text),220),
      'attachment_count',e.attachment_count,
      'link_count',regexp_count(fp.inbox_safe_text(e.body_text),'https?://[^[:space:]<>"'']+',1,'i'),
      'review_state',e.review_state,'updated_at',e.review_updated_at,
      'actions',coalesce((select jsonb_agg(distinct a.action_type) from fp.inbox_actions a where a.inbound_email_id=e.id),'[]'::jsonb)
    ) order by coalesce(e.sent_at,e.ingested_at) desc,e.id desc)
    from (select x.* from fp.inbound_emails x where x.household_id=hid and x.deleted_at is null and x.review_state<>'dismissed'
      and (state_filter='all' or state_filter='unreviewed' and x.review_state='unreviewed' or state_filter='reviewed' and x.review_state='reviewed'
        or state_filter='attachments' and x.attachment_count>0 or state_filter='links' and regexp_count(fp.inbox_safe_text(x.body_text),'https?://[^[:space:]<>"'']+',1,'i')>0)
      and (q='' or regexp_replace(lower(concat_ws(' ',x.sender_address,x.subject,left(x.body_text,2000))),'[[:space:]]+',' ','g') like '%'||q||'%')
      order by coalesce(x.sent_at,x.ingested_at) desc,x.id desc limit result_limit offset result_offset)e),'[]'::jsonb)
  );
end$$;

create or replace function fp.inbox_message_detail(message uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;e fp.inbound_emails;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  select * into e from fp.inbound_emails where id=message and household_id=hid and deleted_at is null;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  return jsonb_build_object(
    'id',e.id,'sender',e.sender_address,'recipients',e.recipient_addresses,'subject',e.subject,
    'received_at',coalesce(e.sent_at,e.ingested_at),'source',case when e.source_system like '%chat%' then 'Chat' else 'Email' end,
    'body_text',fp.inbox_safe_text(e.body_text),'review_state',e.review_state,'updated_at',e.review_updated_at,'can_edit',fp.inbox_can_edit(member_role),
    'attachments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'file_name',a.file_name,'mime_type',a.claimed_content_type,'size_bytes',a.expected_size_bytes,'status',a.scan_status) order by a.created_at) from fp.inbound_attachments a where a.inbound_email_id=e.id),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(u.url order by u.url) from (select distinct (regexp_matches(fp.inbox_safe_text(e.body_text),'https?://[^[:space:]<>"'']+','gi'))[1] url)u),'[]'::jsonb),
    'actions',coalesce((select jsonb_agg(jsonb_build_object('type',a.action_type,'result',a.result,'created_at',a.created_at) order by a.created_at) from fp.inbox_actions a where a.inbound_email_id=e.id),'[]'::jsonb)
  );
end$$;

create or replace function fp.set_inbox_review_state(message uuid,new_state text,expected_updated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;e fp.inbound_emails;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null or not fp.inbox_can_edit(member_role) then raise exception 'not authorised' using errcode='42501';end if;
  if new_state not in ('unreviewed','reviewed','dismissed') then raise exception 'invalid review state' using errcode='22023';end if;
  select * into e from fp.inbound_emails where id=message and household_id=hid and deleted_at is null for update;
  if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  if expected_updated_at is not null and e.review_updated_at<>expected_updated_at then raise exception 'message changed' using errcode='40001';end if;
  update fp.inbound_emails set review_state=new_state,reviewed_at=case when new_state='reviewed' then now() else null end,
    reviewed_by=case when new_state='reviewed' then uid else null end,review_updated_at=now() where id=e.id returning * into e;
  return jsonb_build_object('id',e.id,'review_state',e.review_state,'updated_at',e.review_updated_at);
end$$;

create or replace function fp.inbox_save_attachment(
  message uuid,attachment uuid,category uuid,selected_tags jsonb,request_id text,request_ocr boolean default false
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;e fp.inbound_emails;a fp.inbound_attachments;existing fp.inbox_actions;saved jsonb;document_id uuid;job fp.document_analysis_jobs;normalized_tags jsonb;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null or not fp.inbox_can_edit(member_role) then raise exception 'not authorised' using errcode='42501';end if;
  if request_id is null or char_length(request_id) not between 8 and 100 then raise exception 'invalid request id' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||request_id,0));
  select * into existing from fp.inbox_actions where household_id=hid and actor_user_id=uid and fp.inbox_actions.request_id=inbox_save_attachment.request_id;
  if existing.id is not null then return existing.result||jsonb_build_object('duplicate',true);end if;
  select * into e from fp.inbound_emails where id=message and household_id=hid and deleted_at is null;
  select * into a from fp.inbound_attachments where id=attachment and inbound_email_id=e.id and household_id=hid and scan_status='clean';
  if e.id is null or a.id is null then raise exception 'attachment not available' using errcode='PT404';end if;
  if not exists(select 1 from fp.categories c where c.id=category and c.household_id=hid) then raise exception 'invalid category' using errcode='42501';end if;
  select coalesce(jsonb_agg(value order by value),'[]'::jsonb) into normalized_tags from (select distinct lower(trim(value)) value from jsonb_array_elements_text(coalesce(selected_tags,'[]'::jsonb)) where char_length(trim(value)) between 1 and 40 limit 12)t;
  saved:=fp.create_manual_document(a.file_name,category,a.file_name,a.claimed_content_type,encode(a.content,'base64'),null,null);
  document_id:=(saved->>'document_id')::uuid;
  update fp.documents d set inbound_email_id=e.id,source_attachment_id=a.id,tags=normalized_tags where d.id=document_id;
  if request_ocr then
    insert into fp.document_analysis_jobs(household_id,document_id,requested_by,mode,idempotency_key)
      values(hid,document_id,uid,case when lower(a.file_name) like '%invoice%' or lower(a.file_name) like '%bill%' then 'invoice' else 'document' end,request_id) returning * into job;
  end if;
  saved:=jsonb_build_object('document_id',document_id,'title',saved->>'title','category_id',category,'tags',normalized_tags,'job_id',job.id,'job_status',job.status,'duplicate',false);
  insert into fp.inbox_actions(household_id,inbound_email_id,attachment_id,actor_user_id,action_type,request_id,result)
    values(hid,e.id,a.id,uid,case when request_ocr then 'ocr_requested' else 'document_saved' end,request_id,saved);
  return saved;
end$$;

create or replace function fp.inbox_create_reminder(message uuid,reminder_title text,due_date date,due_time_value time,repeat text,request_id text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;e fp.inbound_emails;existing fp.inbox_actions;result jsonb;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null or not fp.inbox_can_edit(member_role) then raise exception 'not authorised' using errcode='42501';end if;
  select * into e from fp.inbound_emails where id=message and household_id=hid and deleted_at is null;if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||request_id,0));select * into existing from fp.inbox_actions where household_id=hid and actor_user_id=uid and fp.inbox_actions.request_id=inbox_create_reminder.request_id;
  if existing.id is not null then return existing.result||jsonb_build_object('duplicate',true);end if;
  result:=fp.create_reminder(reminder_title,due_date,due_time_value,'Pacific/Auckland',null,request_id);
  if repeat is not null and repeat<>'none' then result:=result||fp.set_reminder_recurrence((result->>'id')::uuid,repeat);end if;
  insert into fp.inbox_actions(household_id,inbound_email_id,actor_user_id,action_type,request_id,result) values(hid,e.id,uid,'reminder_created',request_id,result);
  return result;
end$$;

create or replace function fp.inbox_save_link(message uuid,link_url text,link_title text,category uuid,request_id text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;member_role text;e fp.inbound_emails;existing fp.inbox_actions;result jsonb;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at,household_id limit 1;
  if hid is null or not fp.inbox_can_edit(member_role) then raise exception 'not authorised' using errcode='42501';end if;
  select * into e from fp.inbound_emails where id=message and household_id=hid and deleted_at is null;if e.id is null then raise exception 'message not found' using errcode='PT404';end if;
  if not exists(select 1 from (select distinct (regexp_matches(fp.inbox_safe_text(e.body_text),'https?://[^[:space:]<>"'']+','gi'))[1] url)u where u.url=link_url) then raise exception 'link not found' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||request_id,0));select * into existing from fp.inbox_actions where household_id=hid and actor_user_id=uid and fp.inbox_actions.request_id=inbox_save_link.request_id;
  if existing.id is not null then return existing.result||jsonb_build_object('duplicate',true);end if;
  result:=fp.create_saved_link(link_url,link_title,null,category);
  insert into fp.inbox_actions(household_id,inbound_email_id,actor_user_id,action_type,request_id,result) values(hid,e.id,uid,'link_saved',request_id,result);
  return result;
end$$;

revoke execute on function fp.inbox_can_edit(text),fp.inbox_safe_text(text),fp.inbox_workspace(text,text,integer,integer),fp.inbox_message_detail(uuid),fp.set_inbox_review_state(uuid,text,timestamptz),fp.inbox_save_attachment(uuid,uuid,uuid,jsonb,text,boolean),fp.inbox_create_reminder(uuid,text,date,time,text,text),fp.inbox_save_link(uuid,text,text,uuid,text) from public,anon;
grant execute on function fp.inbox_workspace(text,text,integer,integer),fp.inbox_message_detail(uuid),fp.set_inbox_review_state(uuid,text,timestamptz),fp.inbox_save_attachment(uuid,uuid,uuid,jsonb,text,boolean),fp.inbox_create_reminder(uuid,text,date,time,text,text),fp.inbox_save_link(uuid,text,text,uuid,text) to authenticated;

commit;
