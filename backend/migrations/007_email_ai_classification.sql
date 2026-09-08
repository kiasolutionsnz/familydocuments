begin;

create table if not exists fp.email_classification_proposals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  inbound_email_id uuid not null unique references fp.inbound_emails(id) on delete cascade,
  source_attachment_id uuid references fp.inbound_attachments(id) on delete set null,
  model_name text not null check(char_length(model_name) between 1 and 80),
  category_name text not null check(char_length(category_name) between 1 and 80),
  title text not null check(char_length(title) between 1 and 160),
  document_type text not null check(char_length(document_type) between 1 and 80),
  provider_name text,
  document_date date,
  due_date date,
  amount numeric(14,2),
  currency text check(currency is null or currency ~ '^[A-Z]{3}$'),
  tags jsonb not null default '[]'::jsonb check(jsonb_typeof(tags)='array' and jsonb_array_length(tags)<=12),
  confidence numeric(5,4) not null check(confidence between 0 and 1),
  evidence_excerpt text not null check(char_length(evidence_excerpt) between 1 and 1200),
  source_sha256 text not null check(source_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'needs_review' check(status in ('needs_review','confirmed','rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  confirmed_document_id uuid references fp.documents(id) on delete set null
);
alter table fp.email_classification_proposals enable row level security;
alter table fp.email_classification_proposals force row level security;
drop policy if exists classification_admin_read on fp.email_classification_proposals;
create policy classification_admin_read on fp.email_classification_proposals for select using(fp.is_household_admin(household_id));

create or replace function fp.pending_email_classifications(batch_size integer default 5) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'email_id',e.id,'subject',e.subject,'sender_address',e.sender_address,'body_text',left(coalesce(e.body_text,''),20000),
    'source_sha256',coalesce(a.content_sha256,e.raw_sha256),'attachment_id',a.id,'file_name',a.file_name,
    'content_base64',case when a.id is null then null else encode(a.content,'base64') end,
    'categories',(select coalesce(jsonb_agg(c.name order by c.name),'[]'::jsonb) from fp.categories c where c.household_id=e.household_id)
  ) order by e.ingested_at)
  from (select x.* from fp.inbound_emails x
    where not exists(select 1 from fp.email_classification_proposals p where p.inbound_email_id=x.id)
      and (x.attachment_count=0 or exists(select 1 from fp.inbound_attachments z where z.inbound_email_id=x.id and z.scan_status='clean'))
    order by x.ingested_at limit least(greatest(batch_size,1),10)) e
  left join lateral (select z.* from fp.inbound_attachments z where z.inbound_email_id=e.id and z.scan_status='clean' order by z.created_at limit 1) a on true),'[]'::jsonb);
end $$;

create or replace function fp.record_email_classification(
  email_id uuid,attachment_id uuid,model text,proposed_category text,proposed_title text,
  proposed_document_type text,proposed_provider text,proposed_document_date date,proposed_due_date date,
  proposed_amount numeric,proposed_currency text,proposed_tags jsonb,proposed_confidence numeric,
  proposed_evidence text,provided_source_sha256 text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.inbound_emails; a fp.inbound_attachments; row_id uuid;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  select * into e from fp.inbound_emails where id=email_id;
  if e.id is null then raise exception 'email not found' using errcode='P0002'; end if;
  if attachment_id is not null then select * into a from fp.inbound_attachments where id=attachment_id and inbound_email_id=email_id and scan_status='clean'; end if;
  if attachment_id is not null and a.id is null then raise exception 'clean attachment required' using errcode='22023'; end if;
  if lower(provided_source_sha256)<>coalesce(a.content_sha256,e.raw_sha256) then raise exception 'source integrity mismatch' using errcode='22023'; end if;
  if jsonb_typeof(proposed_tags)<>'array' or jsonb_array_length(proposed_tags)>12 then raise exception 'invalid tags' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.household_id=e.household_id and lower(c.name)=lower(proposed_category)) then proposed_category:='Other'; end if;
  insert into fp.email_classification_proposals(household_id,inbound_email_id,source_attachment_id,model_name,category_name,title,document_type,provider_name,document_date,due_date,amount,currency,tags,confidence,evidence_excerpt,source_sha256)
  values(e.household_id,e.id,a.id,left(model,80),left(proposed_category,80),left(trim(proposed_title),160),left(trim(proposed_document_type),80),nullif(left(trim(proposed_provider),120),''),proposed_document_date,proposed_due_date,proposed_amount,case when proposed_currency~'^[A-Z]{3}$' then proposed_currency else null end,proposed_tags,least(greatest(proposed_confidence,0),1),left(trim(proposed_evidence),1200),lower(provided_source_sha256))
  on conflict(inbound_email_id) do nothing returning id into row_id;
  return jsonb_build_object('recorded',row_id is not null,'proposal_id',row_id);
end $$;

create or replace function fp.email_classification_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'email_id',p.inbound_email_id,'email_subject',e.subject,'sender_address',e.sender_address,'file_name',a.file_name,'category_name',p.category_name,'title',p.title,'document_type',p.document_type,'provider_name',p.provider_name,'document_date',p.document_date,'due_date',p.due_date,'amount',p.amount,'currency',p.currency,'tags',p.tags,'confidence',p.confidence,'evidence_excerpt',p.evidence_excerpt,'source_sha256',p.source_sha256,'model_name',p.model_name,'status',p.status,'created_at',p.created_at) order by p.created_at desc) from fp.email_classification_proposals p join fp.inbound_emails e on e.id=p.inbound_email_id left join fp.inbound_attachments a on a.id=p.source_attachment_id where p.household_id=hid),'[]'::jsonb);
end $$;

create or replace function fp.confirm_email_classification(proposal uuid,category uuid,confirmed_title text,confirmed_document_type text,confirmed_provider text,confirmed_document_date date,confirmed_due_date date,confirmed_tags jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); p fp.email_classification_proposals; d fp.documents; reminder_id uuid;
begin
  select * into p from fp.email_classification_proposals where id=proposal for update;
  if p.id is null or not fp.is_household_admin(p.household_id) then raise exception 'not authorised' using errcode='42501'; end if;
  if p.status<>'needs_review' then raise exception 'proposal already reviewed' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.id=category and c.household_id=p.household_id) then raise exception 'invalid category' using errcode='22023'; end if;
  if jsonb_typeof(confirmed_tags)<>'array' or jsonb_array_length(confirmed_tags)>12 then raise exception 'invalid tags' using errcode='22023'; end if;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,extracted_text,document_type,provider_name,critical_date,ocr_confidence,confirmation_status)
  select p.household_id,category,left(trim(confirmed_title),160),uid,coalesce(a.file_name,e.subject),p.source_sha256,case when a.id is null then 'message/rfc822' else 'application/pdf' end,p.evidence_excerpt,left(trim(confirmed_document_type),80),nullif(left(trim(confirmed_provider),120),''),confirmed_due_date,p.confidence,'confirmed'
  from fp.inbound_emails e left join fp.inbound_attachments a on a.id=p.source_attachment_id where e.id=p.inbound_email_id returning * into d;
  if confirmed_due_date is not null then insert into fp.reminders(household_id,document_id,title,due_at,created_by) values(p.household_id,d.id,concat(d.title,' — payment or renewal due'),confirmed_due_date,uid) returning id into reminder_id; end if;
  update fp.email_classification_proposals set status='confirmed',reviewed_by=uid,reviewed_at=now(),confirmed_document_id=d.id,document_date=confirmed_document_date,tags=confirmed_tags where id=p.id;
  return jsonb_build_object('document_id',d.id,'reminder_id',reminder_id,'status','confirmed');
end $$;

create or replace function fp.reject_email_classification(proposal uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); changed integer;
begin
  update fp.email_classification_proposals p set status='rejected',reviewed_by=uid,reviewed_at=now() where p.id=proposal and p.status='needs_review' and fp.is_household_admin(p.household_id);
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'not authorised or already reviewed' using errcode='42501'; end if;
  return jsonb_build_object('status','rejected');
end $$;

revoke all on fp.email_classification_proposals from public,anon,authenticated;
revoke execute on function fp.pending_email_classifications(integer),fp.record_email_classification(uuid,uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text) from public,anon,authenticated;
grant execute on function fp.pending_email_classifications(integer),fp.record_email_classification(uuid,uuid,text,text,text,text,text,date,date,numeric,text,jsonb,numeric,text,text) to service_role;
grant execute on function fp.email_classification_summaries(),fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb),fp.reject_email_classification(uuid) to authenticated;

commit;
