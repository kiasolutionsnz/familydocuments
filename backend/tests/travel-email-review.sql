begin;
do $$ declare owner_id uuid:=gen_random_uuid();viewer_id uuid:=gen_random_uuid();outsider_id uuid:=gen_random_uuid();hid uuid:=gen_random_uuid();other_hid uuid:=gen_random_uuid();cid uuid;doc uuid;trip uuid;result jsonb;begin
 insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic Travel',owner_id),(other_hid,'Other',outsider_id);
 insert into fp.members(household_id,user_id,email,display_name,role) values(hid,owner_id,'travel-owner@example.test','Owner','owner'),(hid,viewer_id,'travel-viewer@example.test','Viewer','viewer'),(other_hid,outsider_id,'travel-outsider@example.test','Outsider','owner');
 select id into cid from fp.categories where household_id=hid and name='Travel';insert into fp.documents(household_id,category_id,title,created_by) values(hid,cid,'Synthetic flight',owner_id) returning id into doc;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','travel-owner@example.test','aal','aal2')::text,true);result:=fp.create_travel_trip('Synthetic Queenstown','Queenstown',current_date,current_date+3);trip:=(result->>'id')::uuid;perform fp.create_travel_record(trip,doc,'flight','SYN123','Synthetic Air','Auckland','Queenstown',now(),now()+interval '2 hours',199.00,'NZD','Synthetic only');
 if jsonb_array_length(fp.travel_workspace()->'trips')<>1 or jsonb_array_length(fp.travel_workspace()->'records')<>1 then raise exception 'owner travel workspace failed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','travel-viewer@example.test','aal','aal1')::text,true);if jsonb_array_length(fp.travel_workspace()->'records')<>0 then raise exception 'private travel record leaked';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider_id,'email','travel-outsider@example.test','aal','aal2')::text,true);if jsonb_array_length(fp.travel_workspace()->'trips')<>0 then raise exception 'travel trip leaked cross-household';end if;
end $$;
rollback;
