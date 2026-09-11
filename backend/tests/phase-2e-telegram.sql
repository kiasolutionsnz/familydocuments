begin;

do $$
declare
  owner_id constant uuid:='29000000-0000-4000-8000-000000000001';
  other_id constant uuid:='29000000-0000-4000-8000-000000000002';
  family_one constant uuid:='29000000-0000-4000-8000-000000000011';
  family_two constant uuid:='29000000-0000-4000-8000-000000000012';
  conversation_id uuid; link_id uuid; callback_nonce text; update_id uuid; lease uuid; result jsonb;
begin
  if has_function_privilege('authenticated','fp.ingest_telegram_update(text,bigint,text,text,text,jsonb)','execute')
    or has_function_privilege('authenticated','fp.consume_telegram_link_token(text,text,text,text,jsonb)','execute')
    or has_function_privilege('anon','fp.telegram_connection_status()','execute') then
    raise exception 'transport service boundary is exposed';
  end if;
  insert into fp.households(id,name,owner_user_id) values(family_one,'Telegram Family',owner_id),(family_two,'Other Family',other_id);
  insert into fp.members(household_id,user_id,email,role) values(family_one,owner_id,'telegram-owner@example.test','owner'),(family_two,other_id,'telegram-other@example.test','owner');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','telegram-owner@example.test','role','authenticated')::text,true);
  result:=fp.create_telegram_link_token(family_one,'test-bot',repeat('a',64));
  if result->>'expires_at' is null then raise exception 'link token was not created';end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  result:=fp.consume_telegram_link_token('test-bot',repeat('a',64),'123456','123456','{"display_name":"Synthetic"}');
  link_id:=(result->>'identity_link_id')::uuid;
  begin perform fp.consume_telegram_link_token('test-bot',repeat('a',64),'123456','123456','{}');raise exception 'link token replay succeeded';exception when sqlstate 'PT410' then null;end;
  result:=fp.telegram_transport_context('test-bot','123456','123456');
  if (result->>'linked')::boolean is not true or (result->>'family_id')::uuid<>family_one then raise exception 'numeric identity did not bind to Family';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','telegram-owner@example.test','role','authenticated','family_id',family_one)::text,true);
  if fp.active_family_id()<>family_one then raise exception 'request-scoped Family was not selected';end if;
  conversation_id:=(fp.start_conversation('telegram-conversation-0001')->>'id')::uuid;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform fp.bind_telegram_conversation('test-bot','123456','123456',conversation_id);
  result:=fp.create_telegram_callback(link_id,conversation_id,'confirmation','29000000-0000-4000-8000-000000000099','confirm');
  callback_nonce:=result->>'nonce';
  begin perform fp.consume_telegram_callback('test-bot','999999','999999',callback_nonce);raise exception 'wrong Telegram user consumed callback';exception when sqlstate 'PT410' then null;end;
  result:=fp.consume_telegram_callback('test-bot','123456','123456',callback_nonce);
  if result->>'value'<>'confirm' then raise exception 'bound callback was not returned';end if;
  begin perform fp.consume_telegram_callback('test-bot','123456','123456',callback_nonce);raise exception 'callback replay succeeded';exception when sqlstate 'PT410' then null;end;
  result:=fp.ingest_telegram_update('test-bot',42,'123456','123456','message','{"update_id":42}');update_id:=(result->>'id')::uuid;
  if (result->>'duplicate')::boolean then raise exception 'new update was marked duplicate';end if;
  result:=fp.ingest_telegram_update('test-bot',42,'123456','123456','message','{"update_id":42}');
  if (result->>'duplicate')::boolean is not true or (select count(*) from fp.transport_updates where provider_update_id=42)<>1 then raise exception 'update replay was not deduplicated';end if;
  result:=fp.claim_telegram_updates('test-bot',1);lease:=(result->0->>'lease_token')::uuid;
  perform fp.complete_telegram_update(update_id,lease,'handled','[{"request_key":"telegram:42:reply","text":"Done"}]');
  if (select count(*) from fp.transport_outbox where request_key='telegram:42:reply')<>1 then raise exception 'durable outbox was not created';end if;
  if (select envelope from fp.transport_updates where id=update_id)<>'{}'::jsonb then raise exception 'completed payload was retained';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','telegram-owner@example.test','role','authenticated','family_id',family_one)::text,true);
  perform fp.disconnect_telegram(family_one,'test-bot');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  if (fp.telegram_transport_context('test-bot','123456','123456')->>'linked')::boolean then raise exception 'disconnect did not revoke link';end if;
end$$;

rollback;
