begin;

create or replace function fp.telegram_connection_status() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id();
  hid uuid;
  link fp.external_identity_links;
  pending fp.external_link_tokens;
  had_link boolean:=false;
begin
  begin
    hid:=fp.active_family_id(false);
  exception when insufficient_privilege then
    return jsonb_build_object(
      'state','membership_revoked','selection_required',false,
      'family_id',null,'family_name',null,'display_name',null,
      'username',null,'connected_at',null,'link_expires_at',null
    );
  end;
  if hid is null then
    return jsonb_build_object(
      'state','not_connected','selection_required',true,
      'family_id',null,'family_name',null,'display_name',null,
      'username',null,'connected_at',null,'link_expires_at',null
    );
  end if;
  select * into link from fp.external_identity_links l
   where l.provider='telegram' and l.user_id=uid and l.household_id=hid
     and l.revoked_at is null order by l.connected_at desc limit 1;
  select * into pending from fp.external_link_tokens t
   where t.provider='telegram' and t.user_id=uid and t.household_id=hid
     and t.consumed_at is null and t.revoked_at is null and t.expires_at>now()
   order by t.created_at desc limit 1;
  select exists(select 1 from fp.external_identity_links l
    where l.provider='telegram' and l.user_id=uid and l.household_id=hid)
    into had_link;
  return jsonb_build_object(
    'state',case when link.id is not null then 'connected'
                 when pending.id is not null then 'link_pending'
                 when had_link then 'disconnected'
                 else 'not_connected' end,
    'selection_required',false,
    'family_id',hid,
    'family_name',(select name from fp.households where id=hid),
    'display_name',case when link.id is null then null else link.display_metadata->>'display_name' end,
    'username',case when link.id is null then null else link.display_metadata->>'username' end,
    'connected_at',link.connected_at,
    'link_expires_at',pending.expires_at
  );
end$$;

create or replace function fp.conversation_category_options(
  conversation uuid,
  attachment uuid,
  file_name text default null
) returns jsonb
language plpgsql security definer stable set search_path=pg_catalog,fp as $$
declare
  current fp.conversations;
  staged fp.conversation_attachments;
  role text;
  hint text:=lower(coalesce(file_name,''));
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then
    raise exception 'conversation not available' using errcode='42501';
  end if;
  select * into staged from fp.conversation_attachments a
   where a.id=attachment and a.conversation_id=current.id
     and a.household_id=current.household_id and a.user_id=current.user_id
     and a.expires_at>now();
  if staged.id is null then raise exception 'attachment unavailable' using errcode='42501';end if;
  hint:=lower(coalesce(nullif(staged.file_name,''),file_name,''));
  select m.role into role from fp.members m
   where m.user_id=current.user_id and m.household_id=current.household_id
     and m.status='active';
  return jsonb_build_object(
    'can_save',role in ('owner','family_admin','adult_member','contributor'),
    'can_create',role in ('owner','family_admin'),
    'categories',coalesce((
      select jsonb_agg(jsonb_build_object('id',ranked.id,'name',ranked.name,'relevant',ranked.relevant)
        order by ranked.relevant desc,ranked.last_used desc nulls last,ranked.is_system desc,lower(ranked.name))
      from (
        select c.id,c.name,c.is_system,
          (lower(c.name)='finance' and hint ~ '(bill|invoice|receipt|statement)')
          or (lower(c.name) in ('rentals','rental records') and hint ~ '(rental|tenancy|lease|inspection)')
          or (lower(c.name)='travel' and hint ~ '(travel|flight|hotel|passport|visa)') as relevant,
          (select max(d.created_at) from fp.documents d where d.category_id=c.id) as last_used
        from fp.categories c where c.household_id=current.household_id
      ) ranked
    ),'[]'::jsonb)
  );
end$$;

revoke execute on function fp.telegram_connection_status(),fp.conversation_category_options(uuid,uuid,text) from public,anon,authenticated;
grant execute on function fp.telegram_connection_status(),fp.conversation_category_options(uuid,uuid,text) to authenticated;
grant execute on function fp.telegram_connection_status(),fp.conversation_category_options(uuid,uuid,text) to service_role;

commit;
