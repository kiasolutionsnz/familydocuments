begin;

create or replace function fp.current_aal() returns text
language sql stable set search_path=pg_catalog as $$ select coalesce(nullif(current_setting('request.jwt.claims',true)::jsonb->>'aal',''),'aal1') $$;
create or replace function fp.require_aal2() returns void
language plpgsql stable security definer set search_path=pg_catalog,fp as $$
begin if fp.current_aal()<>'aal2' then raise exception 'mfa step-up required' using errcode='42501'; end if; end $$;

create table if not exists fp.security_audit_events(
  id bigint generated always as identity primary key,
  household_id uuid not null references fp.households(id) on delete cascade,
  actor_user_id uuid not null,
  subject_user_id uuid,
  document_id uuid references fp.documents(id) on delete set null,
  event_type text not null check(event_type in ('source_opened','document_purged','member_role_changed','member_suspended','member_activated','member_removed','ownership_transferred','invitation_revoked')),
  details jsonb not null default '{}'::jsonb check(jsonb_typeof(details)='object'),
  created_at timestamptz not null default now()
);
alter table fp.security_audit_events enable row level security; alter table fp.security_audit_events force row level security;
drop policy if exists security_audit_admin_read on fp.security_audit_events;
create policy security_audit_admin_read on fp.security_audit_events for select using(fp.is_household_admin(household_id));

create or replace function fp.document_source(document uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; a fp.inbound_attachments; e fp.inbound_emails; bytes bytea; mime text; fname text;
begin
  select * into d from fp.documents where id=document and lifecycle_status<>'deleted' and (created_by=uid or fp.is_household_admin(household_id) or exists(select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=uid));
  if d.id is null then raise exception 'source not found' using errcode='P0002'; end if;
  if d.source_attachment_id is not null then
    select * into a from fp.inbound_attachments where id=d.source_attachment_id and household_id=d.household_id and scan_status='clean';
    bytes:=a.content; mime:='application/pdf'; fname:=a.file_name;
  elsif d.inbound_email_id is not null then
    select * into e from fp.inbound_emails where id=d.inbound_email_id and household_id=d.household_id;
    bytes:=e.raw_email; mime:='message/rfc822'; fname:=regexp_replace(coalesce(d.source_name,'source-email'), '[^A-Za-z0-9._ -]', '_', 'g')||'.eml';
  else raise exception 'source unavailable' using errcode='P0002'; end if;
  if bytes is null or octet_length(bytes)>5242880 then raise exception 'source unavailable' using errcode='P0002'; end if;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(d.household_id,uid,d.id,'source_opened',jsonb_build_object('mime_type',mime,'size_bytes',octet_length(bytes)));
  return jsonb_build_object('document_id',d.id,'file_name',fname,'mime_type',mime,'size_bytes',octet_length(bytes),'sha256',encode(extensions.digest(bytes,'sha256'),'hex'),'content_base64',encode(bytes,'base64'));
end $$;

create or replace function fp.purge_document(document uuid,confirmation text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; aid uuid; eid uuid;
begin
  perform fp.require_aal2();
  select * into d from fp.documents where id=document for update;
  if d.id is null or not fp.is_household_admin(d.household_id) or d.lifecycle_status<>'deleted' or confirmation<>'PURGE' then raise exception 'not authorised' using errcode='42501'; end if;
  aid:=d.source_attachment_id; eid:=d.inbound_email_id;
  insert into fp.security_audit_events(household_id,actor_user_id,document_id,event_type,details) values(d.household_id,uid,d.id,'document_purged',jsonb_build_object('source_sha256',d.source_sha256));
  delete from fp.documents where id=d.id;
  if aid is not null and not exists(select 1 from fp.documents where source_attachment_id=aid) then delete from fp.inbound_attachments where id=aid; end if;
  if eid is not null and not exists(select 1 from fp.documents where inbound_email_id=eid) then delete from fp.inbound_emails where id=eid; end if;
  return jsonb_build_object('purged',true,'document_id',document);
end $$;

create or replace function fp.manage_member(member uuid,action text,new_role text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; actor_role text; target fp.members; ev text;
begin
  perform fp.require_aal2();
  select household_id,role into hid,actor_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  select * into target from fp.members where household_id=hid and user_id=member for update;
  if target.user_id is null or member=uid or actor_role not in ('owner','family_admin') or target.role='owner' then raise exception 'not authorised' using errcode='42501'; end if;
  if actor_role='family_admin' and target.role='family_admin' then raise exception 'owner required' using errcode='42501'; end if;
  if action='role' then
    if new_role not in ('family_admin','adult_member','contributor','viewer') or (new_role='family_admin' and actor_role<>'owner') then raise exception 'invalid role' using errcode='22023'; end if;
    update fp.members set role=new_role where household_id=hid and user_id=member; ev:='member_role_changed';
  elsif action='suspend' then update fp.members set status='suspended' where household_id=hid and user_id=member; ev:='member_suspended';
  elsif action='activate' then update fp.members set status='active' where household_id=hid and user_id=member; ev:='member_activated';
  elsif action='remove' then
    delete from fp.document_permissions p using fp.documents d where p.document_id=d.id and d.household_id=hid and p.member_user_id=member;
    delete from fp.access_rules where household_id=hid and member_user_id=member;
    delete from fp.members where household_id=hid and user_id=member; ev:='member_removed';
  else raise exception 'invalid action' using errcode='22023'; end if;
  insert into fp.security_audit_events(household_id,actor_user_id,subject_user_id,event_type,details) values(hid,uid,member,ev,jsonb_build_object('new_role',new_role));
  return jsonb_build_object('member_user_id',member,'action',action,'role',new_role);
end $$;

create or replace function fp.revoke_invitation(invitation uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); row fp.invitations;
begin
  perform fp.require_aal2(); select * into row from fp.invitations where id=invitation for update;
  if row.id is null or not fp.is_household_admin(row.household_id) or row.status<>'pending' then raise exception 'not authorised' using errcode='42501'; end if;
  update fp.invitations set status='revoked' where id=row.id;
  insert into fp.security_audit_events(household_id,actor_user_id,event_type,details) values(row.household_id,uid,'invitation_revoked',jsonb_build_object('email',row.email));
  return jsonb_build_object('id',row.id,'status','revoked');
end $$;

create or replace function fp.transfer_household_ownership(member uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  perform fp.require_aal2(); select household_id into hid from fp.members where user_id=uid and role='owner' and status='active' order by joined_at limit 1;
  if hid is null or not exists(select 1 from fp.members where household_id=hid and user_id=member and status='active') then raise exception 'not authorised' using errcode='42501'; end if;
  update fp.members set role='adult_member' where household_id=hid and user_id=uid;
  update fp.members set role='owner' where household_id=hid and user_id=member;
  update fp.households set owner_user_id=member where id=hid;
  insert into fp.security_audit_events(household_id,actor_user_id,subject_user_id,event_type) values(hid,uid,member,'ownership_transferred');
  return jsonb_build_object('household_id',hid,'owner_user_id',member);
end $$;

create or replace function fp.security_audit_summaries(result_limit integer default 30) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'event_type',x.event_type,'subject_name',coalesce(m.display_name,m.email),'document_title',d.title,'created_at',x.created_at) order by x.created_at desc) from (select * from fp.security_audit_events where household_id=hid order by created_at desc limit least(greatest(result_limit,1),50)) x left join fp.members m on m.household_id=x.household_id and m.user_id=x.subject_user_id left join fp.documents d on d.id=x.document_id),'[]'::jsonb);
end $$;

revoke all on fp.security_audit_events from public,anon,authenticated;
revoke execute on function fp.current_aal(),fp.require_aal2() from public,anon,authenticated;
revoke execute on function fp.document_source(uuid),fp.purge_document(uuid,text),fp.manage_member(uuid,text,text),fp.revoke_invitation(uuid),fp.transfer_household_ownership(uuid),fp.security_audit_summaries(integer) from public,anon;
grant execute on function fp.document_source(uuid),fp.purge_document(uuid,text),fp.manage_member(uuid,text,text),fp.revoke_invitation(uuid),fp.transfer_household_ownership(uuid),fp.security_audit_summaries(integer) to authenticated;

commit;
