begin;
do $$
declare uid uuid:='56000000-0000-4000-8000-000000000001';hid uuid:='56000000-0000-4000-8000-000000000011';
 cid uuid;attachment uuid;result jsonb;p jsonb;confirmation uuid;doc uuid;property uuid;replay jsonb;foreign_property uuid;
begin
 insert into fp.households(id,name,owner_user_id) values(hid,'Rental test Family',uid);
 insert into fp.members(household_id,user_id,email,role) values(hid,uid,'rental@example.test','owner');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated','family_id',hid)::text,true);
 cid:=(fp.start_conversation('rental-conversation-001')->>'id')::uuid;
 insert into fp.conversation_attachments(conversation_id,household_id,user_id,file_name,mime_type,content,sha256,expires_at)
 values(cid,hid,uid,'synthetic-expense.pdf','application/pdf','synthetic',repeat('c',64),now()+interval '1 hour') returning id into attachment;
 p:=jsonb_build_object('attachment_id',attachment,'property_name','Kilbirnie');
 result:=fp.submit_conversation_action(cid,'rental-action-0001','record_rental_expense',1,p,'rental-request-0001');
 if result->>'state'<>'awaiting_clarification' or result#>>'{result,message}' not like '%could not find%' then raise exception 'missing rental did not clarify';end if;
 if not exists(select 1 from fp.conversation_messages where conversation_id=cid and message_data->'choices' ? 'Create rental') then raise exception 'creation route missing';end if;
 if exists(select 1 from fp.rental_properties where household_id=hid) or not exists(select 1 from fp.conversation_attachments where id=attachment) then raise exception 'draft mutated';end if;
 p:=p||jsonb_build_object('create_property',true);
 result:=fp.submit_conversation_action(cid,'rental-action-0002','record_rental_expense',1,p,'rental-request-0002');
 if result#>>'{result,message}' not like '%address%' then raise exception 'address not requested';end if;
 p:=p||jsonb_build_object('address','12 Synthetic Street');
 result:=fp.submit_conversation_action(cid,'rental-action-0003','record_rental_expense',1,p,'rental-request-0003');
 if result#>>'{result,message}' not like '%amount%' then raise exception 'amount not requested';end if;
 p:=p||jsonb_build_object('amount','125.00','currency','NZD');
 result:=fp.submit_conversation_action(cid,'rental-action-0004','record_rental_expense',1,p,'rental-request-0004');
 if result->>'state'<>'awaiting_confirmation' or result#>>'{confirmation,summary}' not like '%125.00%' then raise exception 'confirmation missing';end if;
 confirmation:=(result#>>'{confirmation,id}')::uuid;
 result:=fp.decide_conversation_confirmation(confirmation,'confirm');
 if result->>'state'<>'succeeded' then raise exception 'expense failed: %',result->>'error_category';end if;
 doc:=(result#>>'{result,document_id}')::uuid;property:=(result#>>'{result,property_id}')::uuid;
 if (select count(*) from fp.rental_bills where household_id=hid)<>1 then raise exception 'expense count wrong';end if;
 if exists(select 1 from fp.document_analysis_jobs where household_id=hid) then raise exception 'implicit OCR';end if;
 replay:=fp.decide_conversation_confirmation(confirmation,'confirm');
 if (select count(*) from fp.rental_bills where household_id=hid)<>1 then raise exception 'confirmation duplicated';end if;
 replay:=fp.submit_conversation_action(cid,'rental-action-0004','record_rental_expense',1,p,'rental-request-0004');
 if replay->>'execution_id'<>result->>'execution_id' then raise exception 'lost response duplicated';end if;
 p:=jsonb_build_object('document_id',doc,'property_id',property,'amount','125.00');
 result:=fp.submit_conversation_action(cid,'rental-action-0005','record_rental_expense',1,p,'rental-request-0005');
 update fp.rental_properties set updated_at=clock_timestamp() where entity_id=property;
 result:=fp.decide_conversation_confirmation((result#>>'{confirmation,id}')::uuid,'confirm');
 if result->>'state'='succeeded' then raise exception 'stale property accepted';end if;
 begin
   perform fp.assert_conversation_action_v1('record_rental_expense',p||'{"household_id":"forged"}');raise exception 'unknown property accepted';
 exception when invalid_parameter_value then null;end;
 insert into fp.households(id,name,owner_user_id) values('56000000-0000-4000-8000-000000000012','Other Family','56000000-0000-4000-8000-000000000002');
 insert into fp.entities(household_id,entity_type,name,created_by) values('56000000-0000-4000-8000-000000000012','property','Private rental','56000000-0000-4000-8000-000000000002') returning id into foreign_property;
 insert into fp.rental_properties(entity_id,household_id,address,created_by) values(foreign_property,'56000000-0000-4000-8000-000000000012','Other address','56000000-0000-4000-8000-000000000002');
 begin
   perform fp.submit_conversation_action(cid,'rental-action-foreign','record_rental_expense',1,p||jsonb_build_object('property_id',foreign_property),'rental-request-foreign');raise exception 'cross-Family allowed';
 exception when insufficient_privilege then null;end;
 insert into fp.conversation_attachments(conversation_id,household_id,user_id,file_name,mime_type,content,sha256,expires_at)
 values(cid,hid,uid,'synthetic-expired.pdf','application/pdf','synthetic',repeat('d',64),now()+interval '1 hour') returning id into attachment;
 result:=fp.submit_conversation_action(cid,'rental-action-rollback','record_rental_expense',1,jsonb_build_object('attachment_id',attachment,'property_name','Must roll back','create_property',true,'address','42 Synthetic Street','amount','50'),'rental-request-rollback');
 update fp.conversation_attachments set expires_at=now()-interval '1 minute' where id=attachment;
 result:=fp.decide_conversation_confirmation((result#>>'{confirmation,id}')::uuid,'confirm');
 if result->>'state'='succeeded' or exists(select 1 from fp.entities where household_id=hid and name='Must roll back') then raise exception 'failed save left partial rental';end if;
 result:=fp.submit_conversation_action(cid,'rental-action-revoked','record_rental_expense',1,p,'rental-request-revoked');
 update fp.entities set status='archived' where id=property;
 result:=fp.decide_conversation_confirmation((result#>>'{confirmation,id}')::uuid,'confirm');
 if result->>'state'='succeeded' then raise exception 'archived rental allowed';end if;
 update fp.members set role='viewer' where user_id=uid and household_id=hid;
 result:=fp.submit_conversation_action(cid,'rental-action-0006','record_rental_expense',1,p,'rental-request-0006');
 if result->>'state'<>'failed_before_mutation' then raise exception 'viewer allowed mutation';end if;
end $$;
rollback;
