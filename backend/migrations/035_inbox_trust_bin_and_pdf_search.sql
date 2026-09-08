begin;

alter table fp.inbound_emails add column if not exists sender_disposition text not null default 'allowed';
alter table fp.inbound_emails add column if not exists deleted_at timestamptz;
alter table fp.inbound_emails add column if not exists deleted_by uuid;
alter table fp.inbound_emails drop constraint if exists inbound_emails_sender_disposition_check;
alter table fp.inbound_emails add constraint inbound_emails_sender_disposition_check check(sender_disposition in ('allowed','quarantined','blocked'));
create index if not exists inbound_emails_household_active on fp.inbound_emails(household_id,ingested_at desc) where deleted_at is null;

create table if not exists fp.inbound_sender_rules(
  id uuid primary key default gen_random_uuid(), household_id uuid not null references fp.households(id) on delete cascade,
  sender_address text not null check(sender_address=lower(sender_address) and sender_address~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  action text not null check(action in ('allow','block')), created_by uuid not null, created_at timestamptz not null default now(),
  unique(household_id,sender_address)
);
alter table fp.inbound_sender_rules enable row level security;alter table fp.inbound_sender_rules force row level security;
create policy inbound_sender_rules_admin_read on fp.inbound_sender_rules for select using(fp.is_household_admin(household_id));
revoke all on fp.inbound_sender_rules from public,anon,authenticated;

-- Preserve current behaviour by trusting addresses already accepted before activation.
insert into fp.inbound_sender_rules(household_id,sender_address,action,created_by)
select distinct e.household_id,lower(e.sender_address),'allow',h.owner_user_id from fp.inbound_emails e join fp.households h on h.id=e.household_id
where e.sender_address~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' on conflict do nothing;

create or replace function fp.apply_inbound_sender_disposition() returns trigger language plpgsql security definer set search_path=pg_catalog,fp as $$
declare rule_action text;
begin
  select action into rule_action from fp.inbound_sender_rules where household_id=new.household_id and sender_address=lower(new.sender_address);
  new.sender_disposition:=case rule_action when 'allow' then 'allowed' when 'block' then 'blocked' else 'quarantined' end;
  return new;
end$$;
drop trigger if exists inbound_email_sender_disposition on fp.inbound_emails;
create trigger inbound_email_sender_disposition before insert on fp.inbound_emails for each row execute function fp.apply_inbound_sender_disposition();

alter table fp.inbound_attachments drop constraint if exists inbound_attachments_scan_status_check;
alter table fp.inbound_attachments add constraint inbound_attachments_scan_status_check check(scan_status in ('pending','clean','rejected','malformed','unsupported','error','quarantined_sender'));
alter table fp.inbound_attachments drop constraint if exists inbound_attachments_content_state_check;
alter table fp.inbound_attachments add constraint inbound_attachments_content_state_check check(
  (scan_status='clean' and content is not null and content_sha256 is not null and quarantined_content is null)
  or(scan_status='pending' and content is null and quarantined_content is not null)
  or(scan_status='quarantined_sender' and content is null)
  or(scan_status in ('rejected','malformed','error') and content is null and quarantined_content is null)
  or(scan_status='unsupported' and content is null)
);
create or replace function fp.quarantine_untrusted_inbound_attachment() returns trigger language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if exists(select 1 from fp.inbound_emails e where e.id=new.inbound_email_id and e.sender_disposition<>'allowed') then new.scan_status:='quarantined_sender';end if;
  return new;
end$$;
drop trigger if exists inbound_attachment_sender_quarantine on fp.inbound_attachments;
create trigger inbound_attachment_sender_quarantine before insert on fp.inbound_attachments for each row execute function fp.quarantine_untrusted_inbound_attachment();

alter table fp.inbound_attachments add column if not exists search_text text check(search_text is null or char_length(search_text)<=100000);
create or replace function fp.store_attachment_search_text(job_id uuid,extracted_text text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare j fp.email_classification_jobs;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  select * into j from fp.email_classification_jobs where id=job_id and status='processing';
  if j.id is null then raise exception 'job not processing' using errcode='22023';end if;
  if j.source_attachment_id is not null then update fp.inbound_attachments set search_text=left(extracted_text,100000) where id=j.source_attachment_id and scan_status='clean';end if;
  return jsonb_build_object('stored',j.source_attachment_id is not null);
end$$;

create or replace function fp.pending_attachment_search_backfill(batch_size integer default 10) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(jsonb_build_object('attachment_id',a.id,'source_sha256',a.content_sha256,'content_base64',encode(a.content,'base64')) order by a.created_at) from(select a.* from fp.inbound_attachments a join fp.inbound_emails e on e.id=a.inbound_email_id where a.scan_status='clean' and a.search_text is null and e.sender_disposition='allowed' and e.deleted_at is null and exists(select 1 from fp.documents d where d.source_attachment_id=a.id and d.lifecycle_status<>'deleted' and d.confirmation_status='confirmed') order by a.created_at limit least(greatest(batch_size,1),20))a),'[]'::jsonb);
end$$;
create or replace function fp.store_attachment_search_backfill(attachment_id uuid,provided_sha256 text,extracted_text text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  update fp.inbound_attachments set search_text=left(extracted_text,100000) where id=attachment_id and scan_status='clean' and content_sha256=lower(provided_sha256) and search_text is null;get diagnostics changed=row_count;
  if changed<>1 then raise exception 'attachment unavailable or integrity mismatch' using errcode='22023';end if;return jsonb_build_object('stored',true);
end$$;

create or replace function fp.pending_email_classifications(batch_size integer default 5) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then raise exception 'service role required' using errcode='42501';end if;
  insert into fp.email_classification_jobs(household_id,inbound_email_id,source_attachment_id)
  select a.household_id,a.inbound_email_id,a.id from fp.inbound_attachments a join fp.inbound_emails e on e.id=a.inbound_email_id where a.scan_status='clean' and e.sender_disposition='allowed' and e.deleted_at is null on conflict do nothing;
  insert into fp.email_classification_jobs(household_id,inbound_email_id,source_attachment_id)
  select e.household_id,e.id,null from fp.inbound_emails e where e.attachment_count=0 and e.sender_disposition='allowed' and e.deleted_at is null on conflict do nothing;
  with leased as(select j.id from fp.email_classification_jobs j join fp.inbound_emails e on e.id=j.inbound_email_id where e.sender_disposition='allowed' and e.deleted_at is null and ((j.status in ('pending','retry_wait') and j.next_attempt_at<=now()) or(j.status='processing' and j.locked_at<now()-interval '5 minutes')) and j.attempts<5 order by j.next_attempt_at,j.created_at for update of j skip locked limit least(greatest(batch_size,1),10)),updated as(update fp.email_classification_jobs j set status='processing',attempts=j.attempts+1,locked_at=now(),updated_at=now() from leased where j.id=leased.id returning j.*)
  select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'email_id',e.id,'subject',e.subject,'sender_address',e.sender_address,'body_text',left(coalesce(e.body_text,''),20000),'source_sha256',coalesce(a.content_sha256,e.raw_sha256),'attachment_id',a.id,'file_name',a.file_name,'content_base64',case when a.id is null then null else encode(a.content,'base64') end,'attempt',j.attempts,'categories',(select coalesce(jsonb_agg(c.name order by c.name),'[]'::jsonb) from fp.categories c where c.household_id=e.household_id)) order by j.created_at),'[]'::jsonb) into result from updated j join fp.inbound_emails e on e.id=j.inbound_email_id left join fp.inbound_attachments a on a.id=j.source_attachment_id;
  return result;
end$$;

create or replace function fp.inbound_email_summaries() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;
begin select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'sender_address',e.sender_address,'subject',e.subject,'sent_at',e.sent_at,'attachment_count',e.attachment_count,'attachment_status',case when e.sender_disposition<>'allowed' then 'sender_quarantine' when e.attachment_count=0 then 'none' when exists(select 1 from fp.inbound_attachments a where a.inbound_email_id=e.id and a.scan_status in ('rejected','malformed','error')) then 'rejected' when not exists(select 1 from fp.inbound_attachments a where a.inbound_email_id=e.id and a.scan_status in ('pending','unsupported','quarantined_sender')) then 'clean' else 'quarantined_unscanned' end,'processing_status',e.processing_status,'sender_disposition',e.sender_disposition,'deleted_at',e.deleted_at,'ingested_at',e.ingested_at,'raw_sha256',e.raw_sha256) order by e.ingested_at desc) from fp.inbound_emails e where e.household_id=hid),'[]'::jsonb);end$$;

create or replace function fp.inbound_email_detail(email uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();e fp.inbound_emails;
begin select * into e from fp.inbound_emails where id=email;if e.id is null or not fp.is_household_admin(e.household_id) then raise exception 'not authorised' using errcode='42501';end if;
return jsonb_build_object('id',e.id,'sender_address',e.sender_address,'recipient_addresses',e.recipient_addresses,'subject',e.subject,'sent_at',e.sent_at,'ingested_at',e.ingested_at,'body_text',e.body_text,'attachment_count',e.attachment_count,'sender_disposition',e.sender_disposition,'deleted_at',e.deleted_at,'attachments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'file_name',a.file_name,'content_type',a.claimed_content_type,'size_bytes',a.expected_size_bytes,'scan_status',a.scan_status) order by a.created_at) from fp.inbound_attachments a where a.inbound_email_id=e.id),'[]'::jsonb));end$$;

create or replace function fp.inbound_sender_rule_summaries() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare uid uuid:=fp.current_user_id();hid uuid;begin select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;return coalesce((select jsonb_agg(jsonb_build_object('id',id,'sender_address',sender_address,'action',action,'created_at',created_at) order by sender_address) from fp.inbound_sender_rules where household_id=hid),'[]'::jsonb);end$$;
create or replace function fp.set_inbound_sender_rule(sender text,rule_action text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare uid uuid:=fp.current_user_id();hid uuid;address text:=lower(trim(sender));begin select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;if address!~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or rule_action not in ('allow','block','remove') then raise exception 'invalid sender rule' using errcode='22023';end if;if rule_action='remove' then delete from fp.inbound_sender_rules where household_id=hid and sender_address=address;else insert into fp.inbound_sender_rules(household_id,sender_address,action,created_by) values(hid,address,rule_action,uid) on conflict(household_id,sender_address) do update set action=excluded.action,created_by=excluded.created_by,created_at=now();update fp.inbound_emails set sender_disposition=case when rule_action='allow' then 'allowed' else 'blocked' end where household_id=hid and sender_address=address and deleted_at is null;update fp.inbound_attachments a set scan_status=case when rule_action='allow' then 'pending' else 'quarantined_sender' end from fp.inbound_emails e where a.inbound_email_id=e.id and e.household_id=hid and e.sender_address=address and a.scan_status in ('pending','quarantined_sender');end if;return jsonb_build_object('sender_address',address,'action',rule_action);end$$;

create or replace function fp.move_inbound_email_to_bin(email uuid,restore boolean default false) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare uid uuid:=fp.current_user_id();e fp.inbound_emails;begin select * into e from fp.inbound_emails where id=email for update;if e.id is null or not fp.is_household_admin(e.household_id) then raise exception 'not authorised' using errcode='42501';end if;if exists(select 1 from fp.documents d where d.inbound_email_id=e.id and d.lifecycle_status<>'deleted') then raise exception 'archive or delete the confirmed document first' using errcode='23503';end if;if restore then update fp.inbound_emails set deleted_at=null,deleted_by=null where id=e.id;else update fp.inbound_emails set deleted_at=now(),deleted_by=uid where id=e.id;update fp.email_classification_proposals set status='rejected',reviewed_by=uid,reviewed_at=now() where inbound_email_id=e.id and status='needs_review';delete from fp.email_classification_jobs where inbound_email_id=e.id and status<>'proposed';end if;return jsonb_build_object('id',e.id,'deleted',not restore);end$$;

create or replace function fp.search_household_records(search_query text,result_limit integer default 20) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;admin boolean;q text;tokens text[];
begin q:=lower(trim(regexp_replace(coalesce(search_query,''),'\s+',' ','g')));if char_length(q) not between 2 and 120 then raise exception 'search query must be 2 to 120 characters' using errcode='22023';end if;select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then return '[]'::jsonb;end if;admin:=fp.is_household_admin(hid);tokens:=array(select distinct t from unnest(regexp_split_to_array(q,'[^a-z0-9]+')) t where char_length(t)>=2 limit 12);
return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'title',x.title,'category_name',x.category_name,'provider_name',x.provider_name,'document_type',x.document_type,'document_date',x.document_date,'critical_date',x.critical_date,'amount',x.amount,'currency',x.currency,'tags',x.tags,'source_name',x.source_name,'source_sha256',x.source_sha256,'email_subject',x.email_subject,'evidence_excerpt',x.evidence_excerpt,'rank',x.rank) order by x.rank desc,x.document_date desc nulls last,x.title) from(select d.id,d.title,c.name category_name,d.provider_name,d.document_type,d.document_date,d.critical_date,d.amount,d.currency,d.tags,d.source_name,d.source_sha256,e.subject email_subject,left(coalesce(nullif(a.search_text,''),nullif(e.body_text,''),d.extracted_text,''),600) evidence_excerpt,(case when lower(d.title)=q then 100 when lower(d.title) like '%'||q||'%' then 50 else 0 end+case when lower(coalesce(d.provider_name,'')) like '%'||q||'%' then 30 else 0 end+case when lower(coalesce(a.search_text,e.body_text,d.extracted_text,'')) like '%'||q||'%' then 40 else 0 end+(select count(*)*5 from unnest(tokens)t where lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject,a.search_text,e.body_text,d.extracted_text)) like '%'||t||'%'))::integer rank from fp.documents d join fp.categories c on c.id=d.category_id left join fp.inbound_emails e on e.id=d.inbound_email_id left join fp.inbound_attachments a on a.id=d.source_attachment_id where d.household_id=hid and d.lifecycle_status<>'deleted' and(d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))and(lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject,a.search_text,e.body_text,d.extracted_text)) like '%'||q||'%' or exists(select 1 from unnest(tokens)t where lower(concat_ws(' ',d.title,d.provider_name,d.document_type,c.name,d.tags::text,d.document_date::text,d.critical_date::text,e.subject,a.search_text,e.body_text,d.extracted_text)) like '%'||t||'%'))order by rank desc,d.created_at desc limit least(greatest(result_limit,1),30))x),'[]'::jsonb);end$$;

revoke execute on function fp.apply_inbound_sender_disposition(),fp.quarantine_untrusted_inbound_attachment(),fp.store_attachment_search_text(uuid,text),fp.pending_attachment_search_backfill(integer),fp.store_attachment_search_backfill(uuid,text,text) from public,anon,authenticated;
grant execute on function fp.store_attachment_search_text(uuid,text),fp.pending_attachment_search_backfill(integer),fp.store_attachment_search_backfill(uuid,text,text),fp.pending_email_classifications(integer) to service_role;
grant execute on function fp.inbound_email_detail(uuid),fp.inbound_sender_rule_summaries(),fp.set_inbound_sender_rule(text,text),fp.move_inbound_email_to_bin(uuid,boolean),fp.search_household_records(text,integer) to authenticated;
commit;
