begin;

alter table fp.documents add column if not exists tags jsonb not null default '[]'::jsonb;
alter table fp.documents add column if not exists document_date date;
alter table fp.documents add column if not exists amount numeric(14,2);
alter table fp.documents add column if not exists currency text;
alter table fp.documents add column if not exists inbound_email_id uuid references fp.inbound_emails(id) on delete set null;
alter table fp.documents add column if not exists source_attachment_id uuid references fp.inbound_attachments(id) on delete set null;
alter table fp.documents add column if not exists lifecycle_status text not null default 'active';
alter table fp.documents add column if not exists revision_of uuid references fp.documents(id) on delete set null;
alter table fp.documents add column if not exists replaced_by uuid references fp.documents(id) on delete set null;
alter table fp.documents add column if not exists archived_at timestamptz;
alter table fp.documents add column if not exists deleted_at timestamptz;
alter table fp.documents add column if not exists deleted_by uuid;
alter table fp.documents drop constraint if exists documents_tags_check;
alter table fp.documents add constraint documents_tags_check check(jsonb_typeof(tags)='array' and jsonb_array_length(tags)<=12);
alter table fp.documents drop constraint if exists documents_currency_check;
alter table fp.documents add constraint documents_currency_check check(currency is null or currency~'^[A-Z]{3}$');
alter table fp.documents drop constraint if exists documents_lifecycle_status_check;
alter table fp.documents add constraint documents_lifecycle_status_check check(lifecycle_status in ('active','archived','deleted'));
create index if not exists documents_household_lifecycle on fp.documents(household_id,lifecycle_status,created_at desc);
create index if not exists documents_household_source_hash on fp.documents(household_id,source_sha256) where source_sha256 is not null and lifecycle_status<>'deleted';

drop function if exists fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb);
drop function if exists fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb,uuid);
create function fp.confirm_email_classification(proposal uuid,category uuid,confirmed_title text,confirmed_document_type text,confirmed_provider text,confirmed_document_date date,confirmed_due_date date,confirmed_tags jsonb,replaces_document uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); p fp.email_classification_proposals; d fp.documents; prior fp.documents; existing fp.documents; reminder_id uuid;
begin
  select * into p from fp.email_classification_proposals where id=proposal for update;
  if p.id is null or not fp.is_household_admin(p.household_id) then raise exception 'not authorised' using errcode='42501'; end if;
  if p.status<>'needs_review' then raise exception 'proposal already reviewed' using errcode='22023'; end if;
  if not exists(select 1 from fp.categories c where c.id=category and c.household_id=p.household_id) then raise exception 'invalid category' using errcode='22023'; end if;
  if jsonb_typeof(confirmed_tags)<>'array' or jsonb_array_length(confirmed_tags)>12 then raise exception 'invalid tags' using errcode='22023'; end if;
  select * into existing from fp.documents where household_id=p.household_id and source_sha256=p.source_sha256 and lifecycle_status<>'deleted' order by created_at limit 1;
  if existing.id is not null then
    update fp.email_classification_proposals set status='confirmed',reviewed_by=uid,reviewed_at=now(),confirmed_document_id=existing.id where id=p.id;
    return jsonb_build_object('document_id',existing.id,'reminder_id',null,'status','confirmed','duplicate',true);
  end if;
  if replaces_document is not null then
    select * into prior from fp.documents where id=replaces_document and household_id=p.household_id and lifecycle_status='active' for update;
    if prior.id is null then raise exception 'replacement target is not active' using errcode='22023'; end if;
  end if;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,extracted_text,document_type,provider_name,critical_date,ocr_confidence,confirmation_status,tags,document_date,amount,currency,inbound_email_id,source_attachment_id,revision_of)
  select p.household_id,category,left(trim(confirmed_title),160),uid,coalesce(a.file_name,e.subject),p.source_sha256,case when a.id is null then 'message/rfc822' else 'application/pdf' end,p.evidence_excerpt,left(trim(confirmed_document_type),80),nullif(left(trim(confirmed_provider),120),''),confirmed_due_date,p.confidence,'confirmed',confirmed_tags,confirmed_document_date,p.amount,p.currency,p.inbound_email_id,p.source_attachment_id,prior.id
  from fp.inbound_emails e left join fp.inbound_attachments a on a.id=p.source_attachment_id where e.id=p.inbound_email_id returning * into d;
  if prior.id is not null then update fp.documents set lifecycle_status='archived',archived_at=now(),replaced_by=d.id where id=prior.id; end if;
  if confirmed_due_date is not null then insert into fp.reminders(household_id,document_id,title,due_at,created_by) values(p.household_id,d.id,concat(d.title,' — payment or renewal due'),confirmed_due_date,uid) returning id into reminder_id; end if;
  update fp.email_classification_proposals set status='confirmed',reviewed_by=uid,reviewed_at=now(),confirmed_document_id=d.id,document_date=confirmed_document_date,tags=confirmed_tags where id=p.id;
  return jsonb_build_object('document_id',d.id,'reminder_id',reminder_id,'status','confirmed','duplicate',false,'revision_of',prior.id);
end $$;

create or replace function fp.document_lifecycle_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return '[]'::jsonb; end if; admin:=fp.is_household_admin(hid);
  return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category_id',d.category_id,'category_name',c.name,'document_type',d.document_type,'provider_name',d.provider_name,'document_date',d.document_date,'critical_date',d.critical_date,'amount',d.amount,'currency',d.currency,'tags',d.tags,'lifecycle_status',d.lifecycle_status,'revision_of',d.revision_of,'replaced_by',d.replaced_by,'source_name',d.source_name,'source_sha256',d.source_sha256,'email_subject',e.subject,'sender_address',e.sender_address,'archived_at',d.archived_at,'deleted_at',d.deleted_at,'created_by',d.created_by,'created_at',d.created_at) order by d.created_at desc)
    from fp.documents d join fp.categories c on c.id=d.category_id left join fp.inbound_emails e on e.id=d.inbound_email_id
    where d.household_id=hid and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb);
end $$;

create or replace function fp.set_document_lifecycle(document uuid,action text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; admin boolean;
begin
  select * into d from fp.documents where id=document for update;
  if d.id is null then raise exception 'document not found' using errcode='P0002'; end if;
  admin:=fp.is_household_admin(d.household_id);
  if action='archive' and (admin or d.created_by=uid) and d.lifecycle_status='active' then
    update fp.documents set lifecycle_status='archived',archived_at=now() where id=d.id;
  elsif action='restore' and (admin or d.created_by=uid) and d.lifecycle_status in ('archived','deleted') and d.replaced_by is null then
    update fp.documents set lifecycle_status='active',archived_at=null,deleted_at=null,deleted_by=null where id=d.id;
  elsif action='delete' and admin and d.lifecycle_status<>'deleted' then
    update fp.documents set lifecycle_status='deleted',deleted_at=now(),deleted_by=uid where id=d.id;
    update fp.reminders set status='dismissed' where document_id=d.id and status='upcoming';
  else raise exception 'not authorised or invalid transition' using errcode='42501';
  end if;
  return jsonb_build_object('document_id',d.id,'action',action,'status',(select lifecycle_status from fp.documents where id=d.id));
end $$;

revoke execute on function fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb,uuid),fp.document_lifecycle_summaries(),fp.set_document_lifecycle(uuid,text) from public,anon;
grant execute on function fp.confirm_email_classification(uuid,uuid,text,text,text,date,date,jsonb,uuid),fp.document_lifecycle_summaries(),fp.set_document_lifecycle(uuid,text) to authenticated;

commit;
