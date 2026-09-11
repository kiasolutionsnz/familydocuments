begin;

do $$
declare
  owner_id constant uuid:='2a000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='2a000000-0000-4000-8000-000000000002';
  family_one constant uuid:='2a000000-0000-4000-8000-000000000011';
  family_two constant uuid:='2a000000-0000-4000-8000-000000000012';
  conversation_id uuid;
  attachment_id uuid;
  result jsonb;
  token_count bigint;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_one,'Status Family',owner_id),(family_two,'Second Status Family',owner_id);
  insert into fp.members(household_id,user_id,email,role,status) values
    (family_one,owner_id,'status-owner@example.test','owner','active'),
    (family_one,viewer_id,'status-viewer@example.test','viewer','active');
  insert into fp.categories(household_id,name,is_system,created_by) values
    (family_one,'Documents',true,owner_id),(family_one,'Finance',true,owner_id),(family_one,'Rentals',true,owner_id);

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','status-owner@example.test','role','authenticated')::text,true);
  select count(*) into token_count from fp.external_link_tokens where user_id=owner_id;
  result:=fp.telegram_connection_status();
  if result->>'state'<>'not_connected' or (result->>'selection_required')::boolean then raise exception 'new-user status was not stable';end if;
  if (select count(*) from fp.external_link_tokens where user_id=owner_id)<>token_count then raise exception 'status created a link token';end if;

  insert into fp.external_link_tokens(provider,provider_tenant,token_hash,user_id,household_id,purpose,expires_at)
    values('telegram','status-bot',repeat('a',64),owner_id,family_one,'connect',now()+interval '5 minutes');
  result:=fp.telegram_connection_status();
  if result->>'state'<>'link_pending' or result->>'link_expires_at' is null then raise exception 'pending status missing';end if;
  update fp.external_link_tokens set created_at=now()-interval '2 minutes',expires_at=now()-interval '1 minute';
  result:=fp.telegram_connection_status();
  if result->>'state'<>'not_connected' then raise exception 'expired pending link remained pending';end if;

  insert into fp.external_identity_links(provider,provider_tenant,provider_user_id,private_chat_id,user_id,household_id,display_metadata)
    values('telegram','status-bot','70001','70001',owner_id,family_one,'{}');
  result:=fp.telegram_connection_status();
  if result->>'state'<>'connected' or result->>'display_name' is not null then raise exception 'connected status or empty metadata failed';end if;
  update fp.external_identity_links set revoked_at=now() where user_id=owner_id;
  result:=fp.telegram_connection_status();
  if result->>'state'<>'disconnected' then raise exception 'historical disconnected status missing';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','status-viewer@example.test','role','authenticated')::text,true);
  if fp.telegram_connection_status()->>'state'<>'not_connected' then raise exception 'read-only status viewing failed';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','status-owner@example.test','role','authenticated')::text,true);
  insert into fp.members(household_id,user_id,email,role,status) values(family_two,owner_id,'status-owner@example.test','contributor','active');
  delete from fp.active_family_contexts where user_id=owner_id;
  result:=fp.telegram_connection_status();
  if (result->>'selection_required')::boolean is not true then raise exception 'multiple-Family status did not require selection';end if;
  perform fp.select_active_family(family_two);
  result:=fp.telegram_connection_status();
  if (result->>'family_id')::uuid<>family_two or result->>'state'<>'not_connected' then raise exception 'status leaked across Families';end if;
  begin perform fp.select_active_family(gen_random_uuid());raise exception 'cross-Family selection succeeded';exception when sqlstate '42501' then null;end;

  perform fp.select_active_family(family_one);
  conversation_id:=(fp.start_conversation('status-category-conversation')->>'id')::uuid;
  insert into fp.conversation_attachments(conversation_id,household_id,user_id,file_name,mime_type,content,sha256,expires_at)
    values(conversation_id,family_one,owner_id,'synthetic-bill.pdf','application/pdf','x',repeat('b',64),now()+interval '1 hour') returning id into attachment_id;
  result:=fp.conversation_category_options(conversation_id,attachment_id,null);
  if result->'categories'->0->>'name'<>'Finance' or (result->>'can_save')::boolean is not true then raise exception 'relevant category ordering failed';end if;

  update fp.members set status='suspended' where user_id=owner_id;
  result:=fp.telegram_connection_status();
  if result->>'state'<>'membership_revoked' then raise exception 'revoked membership status missing';end if;
  begin perform fp.conversation_category_options(conversation_id,attachment_id,null);raise exception 'revoked category access succeeded';exception when sqlstate '42501' then null;end;
end$$;

rollback;
