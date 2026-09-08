begin;

alter table fp.external_sources add column if not exists provider_parent_ids jsonb not null default '[]'::jsonb;
alter table fp.external_sources drop constraint if exists external_sources_status_check;
alter table fp.external_sources add constraint external_sources_status_check check(status in ('active','changed','moved','missing','inaccessible','disconnected'));
alter table fp.documents add column if not exists merged_into uuid references fp.documents(id) on delete set null;

create table if not exists fp.notification_outbox(
 id uuid primary key default gen_random_uuid(), household_id uuid not null references fp.households(id) on delete cascade,
 kind text not null check(kind in ('invitation','reminder')), recipient_email text not null,
 subject text not null check(char_length(subject) between 1 and 180), body_text text not null,
 dedupe_key text not null unique, status text not null default 'pending' check(status in ('pending','sending','sent','failed')),
 available_at timestamptz not null default now(), attempts integer not null default 0 check(attempts between 0 and 8),
 lease_until timestamptz, provider_message_id text, safe_error_code text, created_at timestamptz not null default now(), sent_at timestamptz
);
alter table fp.notification_outbox enable row level security; alter table fp.notification_outbox force row level security;
revoke all on fp.notification_outbox from public,anon,authenticated;

create or replace function fp.queue_invitation_email() returns trigger language plpgsql security definer set search_path=pg_catalog,fp as $$
declare family_name text; inviter text;
begin
 select h.name,coalesce(m.display_name,m.email) into family_name,inviter from fp.households h join fp.members m on m.household_id=h.id and m.user_id=new.invited_by where h.id=new.household_id;
 insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key)
 values(new.household_id,'invitation',new.email,'You are invited to '||family_name,
   inviter||' invited you to join '||family_name||' in Family Passport. Sign up or sign in with this exact email address, then choose Accept my invitation. The invitation expires on '||to_char(new.expires_at at time zone 'Pacific/Auckland','DD Mon YYYY')||'.',
   'invitation:'||new.id::text) on conflict(dedupe_key) do nothing;
 return new;
end $$;
drop trigger if exists invitations_queue_email on fp.invitations;
create trigger invitations_queue_email after insert on fp.invitations for each row execute function fp.queue_invitation_email();

create or replace function fp.edit_document_metadata(document uuid,document_title text,category uuid,confirmed_tags jsonb,confirmed_document_date date default null,confirmed_provider text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents;
begin
 select * into d from fp.documents where id=document and lifecycle_status<>'deleted' and (created_by=uid or fp.is_household_admin(household_id) or exists(select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=uid and p.access_level='manage')) for update;
 if d.id is null then raise exception 'not authorised' using errcode='42501'; end if;
 if char_length(trim(document_title)) not between 1 and 160 or not exists(select 1 from fp.categories c where c.id=category and c.household_id=d.household_id) or jsonb_typeof(confirmed_tags)<>'array' or jsonb_array_length(confirmed_tags)>12 then raise exception 'invalid metadata' using errcode='22023'; end if;
 if exists(select 1 from jsonb_array_elements_text(confirmed_tags) t where char_length(trim(t)) not between 1 and 40) then raise exception 'invalid tag' using errcode='22023'; end if;
 update fp.documents set title=trim(document_title),category_id=category,tags=(select coalesce(jsonb_agg(distinct lower(trim(v))),'[]'::jsonb) from jsonb_array_elements_text(confirmed_tags) q(v)),document_date=confirmed_document_date,provider_name=nullif(left(trim(confirmed_provider),120),'') where id=d.id;
 return jsonb_build_object('id',d.id,'updated',true);
end $$;

create table if not exists fp.document_merge_events(id uuid primary key default gen_random_uuid(),household_id uuid not null references fp.households(id) on delete cascade,primary_document_id uuid not null references fp.documents(id),duplicate_document_id uuid not null references fp.documents(id),merged_by uuid not null,merged_at timestamptz not null default now(),unique(duplicate_document_id));
alter table fp.document_merge_events enable row level security; alter table fp.document_merge_events force row level security; revoke all on fp.document_merge_events from public,anon,authenticated;
create or replace function fp.merge_documents(primary_document uuid,duplicate_document uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); a fp.documents; b fp.documents;
begin
 if primary_document=duplicate_document then raise exception 'documents must differ' using errcode='22023'; end if;
 select * into a from fp.documents where id=primary_document for update; select * into b from fp.documents where id=duplicate_document for update;
 if a.id is null or b.id is null or a.household_id<>b.household_id or a.lifecycle_status='deleted' or b.lifecycle_status='deleted' or not (fp.is_household_admin(a.household_id) or (a.created_by=uid and b.created_by=uid)) then raise exception 'not authorised' using errcode='42501'; end if;
 insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by,grant_source)
 select a.id,p.member_user_id,p.access_level,uid,'manual' from fp.document_permissions p where p.document_id=b.id
 on conflict(document_id,member_user_id) do update set access_level=case when fp.document_permissions.access_level='manage' or excluded.access_level='manage' then 'manage' when fp.document_permissions.access_level='contribute' or excluded.access_level='contribute' then 'contribute' else 'view' end;
 insert into fp.document_entities(document_id,entity_id,relationship,linked_by) select a.id,entity_id,relationship,uid from fp.document_entities where document_id=b.id on conflict do nothing;
 update fp.reminders set document_id=a.id where document_id=b.id;
 update fp.documents set lifecycle_status='archived',archived_at=now(),merged_into=a.id where id=b.id;
 insert into fp.document_merge_events(household_id,primary_document_id,duplicate_document_id,merged_by) values(a.household_id,a.id,b.id,uid);
 return jsonb_build_object('primary_document_id',a.id,'merged_document_id',b.id,'status','archived_with_provenance');
end $$;

create or replace function fp.explain_document_access(document uuid,member uuid default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); target uuid:=coalesce(member,uid); d fp.documents; m fp.members; reasons jsonb:='[]'::jsonb;
begin
 select * into d from fp.documents where id=document; if d.id is null then raise exception 'not found' using errcode='P0002'; end if;
 if target<>uid and not fp.is_household_admin(d.household_id) then raise exception 'not authorised' using errcode='42501'; end if;
 select * into m from fp.members where household_id=d.household_id and user_id=target and status='active'; if m.user_id is null then return jsonb_build_object('allowed',false,'reasons',reasons); end if;
 if d.created_by=target then reasons:=reasons||jsonb_build_array(jsonb_build_object('type','creator','label','Created this document')); end if;
 if m.role in ('owner','family_admin') then reasons:=reasons||jsonb_build_array(jsonb_build_object('type','household_admin','label','Household administrators can manage household documents')); end if;
 select reasons||coalesce(jsonb_agg(jsonb_build_object('type',case when p.grant_source='manual' then 'direct_share' else 'sharing_rule' end,'label',case when p.grant_source='manual' then 'Shared directly' else 'Matched a category or relationship sharing rule' end,'access_level',p.access_level,'rule_id',p.access_rule_id)),'[]'::jsonb) into reasons from fp.document_permissions p where p.document_id=d.id and p.member_user_id=target;
 return jsonb_build_object('allowed',jsonb_array_length(reasons)>0,'document_id',d.id,'member_user_id',target,'reasons',reasons);
end $$;

create or replace function fp.household_export() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
 select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1; if not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if; perform fp.require_aal2();
 return jsonb_build_object('schema_version',1,'exported_at',now(),'household',(select to_jsonb(h)-'owner_user_id' from fp.households h where id=hid),'members',(select coalesce(jsonb_agg(to_jsonb(m)-'household_id'),'[]'::jsonb) from fp.members m where household_id=hid),'categories',(select coalesce(jsonb_agg(to_jsonb(c)-'household_id'-'created_by'),'[]'::jsonb) from fp.categories c where household_id=hid),'documents',(select coalesce(jsonb_agg((to_jsonb(d)-'household_id'-'extracted_text')||jsonb_build_object('source_content_included',false)),'[]'::jsonb) from fp.documents d where household_id=hid),'entities',(select coalesce(jsonb_agg(to_jsonb(e)-'household_id'),'[]'::jsonb) from fp.entities e where household_id=hid),'reminders',(select coalesce(jsonb_agg(to_jsonb(r)-'household_id'),'[]'::jsonb) from fp.reminders r where household_id=hid),'external_sources',(select coalesce(jsonb_agg(to_jsonb(s)-'household_id'-'added_by'),'[]'::jsonb) from fp.external_sources s where household_id=hid));
end $$;

create or replace function fp.enqueue_due_notifications() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
 if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501'; end if;
 insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
 select r.household_id,'reminder',m.email,'Family Passport reminder: '||r.title,r.title||' is due on '||to_char(r.due_at,'DD Mon YYYY')||'. Sign in to review the confirmed document and mark the reminder complete.','reminder:'||r.id::text||':'||r.due_at::text,now()
 from fp.reminders r join fp.members m on m.household_id=r.household_id and m.status='active' and m.role in ('owner','family_admin') join fp.documents d on d.id=r.document_id and d.lifecycle_status='active'
 where r.status='upcoming' and r.due_at between current_date and current_date+7 on conflict(dedupe_key) do nothing; get diagnostics changed=row_count;
 return jsonb_build_object('queued',changed);
end $$;
create or replace function fp.claim_notification_batch(batch_size integer default 20) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501'; end if;
 with chosen as (select id from fp.notification_outbox where status in ('pending','failed') and available_at<=now() and (lease_until is null or lease_until<now()) and attempts<8 order by available_at for update skip locked limit least(greatest(batch_size,1),50)), updated as (update fp.notification_outbox o set status='sending',attempts=attempts+1,lease_until=now()+interval '2 minutes' from chosen where o.id=chosen.id returning o.*) select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'recipient_email',recipient_email,'subject',subject,'body_text',body_text)),'[]'::jsonb) into result from updated; return result; end $$;
create or replace function fp.complete_notification(notification uuid,sent boolean,provider_id text default null,error_code text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
begin if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501'; end if;
 update fp.notification_outbox set status=case when sent then 'sent' else 'failed' end,provider_message_id=case when sent then left(provider_id,200) end,safe_error_code=case when sent then null else left(coalesce(error_code,'delivery_failed'),80) end,sent_at=case when sent then now() end,lease_until=null,available_at=case when sent then available_at else now()+make_interval(secs=>least(3600,30*(2^least(attempts,7)))) end where id=notification; return jsonb_build_object('updated',found); end $$;

drop function if exists fp.update_google_drive_source(uuid,timestamptz,text,text,text);
drop function if exists fp.update_google_drive_source(uuid,text,text,bigint,timestamptz,text,text,jsonb,text);
create function fp.update_google_drive_source(source uuid,new_file_name text,mime_type text,size_bytes bigint,modified_time timestamptz,provider_version text,provider_checksum text,new_parent_ids jsonb,observed_status text default 'active') returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); row fp.external_sources; next_status text;
begin
 select * into row from fp.external_sources where id=source and exists(select 1 from fp.document_external_sources des join fp.documents d on d.id=des.document_id where des.external_source_id=source and (d.created_by=uid or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid)));
 if row.id is null then raise exception 'not authorised' using errcode='42501'; end if; if observed_status not in ('active','missing','inaccessible') then raise exception 'invalid status' using errcode='22023'; end if;
 next_status:=observed_status; if observed_status='active' then if row.provider_version<>provider_version or row.provider_checksum is distinct from lower(provider_checksum) or row.modified_time<>modified_time then next_status:='changed'; elsif row.provider_parent_ids='[]'::jsonb and row.checked_at=row.added_at then next_status:='active'; elsif row.file_name<>new_file_name or row.provider_parent_ids<>coalesce(new_parent_ids,'[]'::jsonb) then next_status:='moved'; end if; end if;
 update fp.external_sources set status=next_status,checked_at=now(),file_name=case when next_status in ('active','moved') then new_file_name else fp.external_sources.file_name end,provider_parent_ids=case when next_status in ('active','moved') then coalesce(new_parent_ids,'[]'::jsonb) else fp.external_sources.provider_parent_ids end where id=row.id;
 return jsonb_build_object('id',row.id,'status',next_status,'checked_at',now());
end $$;

revoke execute on function fp.edit_document_metadata(uuid,text,uuid,jsonb,date,text),fp.merge_documents(uuid,uuid),fp.explain_document_access(uuid,uuid),fp.household_export() from public,anon;
grant execute on function fp.edit_document_metadata(uuid,text,uuid,jsonb,date,text),fp.merge_documents(uuid,uuid),fp.explain_document_access(uuid,uuid),fp.household_export() to authenticated;
revoke execute on function fp.enqueue_due_notifications(),fp.claim_notification_batch(integer),fp.complete_notification(uuid,boolean,text,text),fp.update_google_drive_source(uuid,text,text,bigint,timestamptz,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function fp.enqueue_due_notifications(),fp.claim_notification_batch(integer),fp.complete_notification(uuid,boolean,text,text) to service_role;
grant execute on function fp.update_google_drive_source(uuid,text,text,bigint,timestamptz,text,text,jsonb,text) to authenticated;

commit;
