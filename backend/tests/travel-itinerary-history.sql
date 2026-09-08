begin;
do $$declare owner_id uuid:=gen_random_uuid();contributor_id uuid:=gen_random_uuid();viewer_id uuid:=gen_random_uuid();outsider_id uuid:=gen_random_uuid();hid uuid:=gen_random_uuid();other_hid uuid:=gen_random_uuid();trip uuid;entry uuid;result jsonb;denied boolean:=false;begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic Itinerary',owner_id),(other_hid,'Synthetic Other',outsider_id);
  insert into fp.members(household_id,user_id,email,display_name,role) values(hid,owner_id,'iti-owner@example.test','Owner','owner'),(hid,contributor_id,'iti-contributor@example.test','Contributor','contributor'),(hid,viewer_id,'iti-viewer@example.test','Viewer','viewer'),(other_hid,outsider_id,'iti-outsider@example.test','Outsider','owner');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);
  result:=fp.create_travel_trip('Synthetic South Island','Queenstown',current_date,current_date+5);trip:=(result->>'id')::uuid;
  perform fp.set_trip_share(trip,contributor_id,'contribute');perform fp.set_trip_share(trip,viewer_id,'view');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',contributor_id,'role','authenticated')::text,true);
  result:=fp.create_travel_itinerary_entry(trip,'flight','Flight to Queenstown','Synthetic Air','Auckland','Queenstown',now()+interval '1 day',now()+interval '1 day 2 hours','ABC123','Window seats');entry:=(result->>'id')::uuid;
  perform fp.update_travel_itinerary_entry(entry,'flight','Flight to Queenstown','Synthetic Air','Auckland','Queenstown',now()-interval '2 hours',now()-interval '1 hour','ABC123','Completed test','completed');
  if jsonb_array_length(fp.travel_workspace()->'itinerary_entries')<>1 or fp.travel_workspace()->'itinerary_entries'->0->>'status'<>'completed' then raise exception 'completed entry was not retained';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'role','authenticated')::text,true);denied:=false;begin perform fp.update_travel_itinerary_entry(entry,'flight','Changed',null,null,null,null,null,null,null,'planned');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'viewer mutated itinerary';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider_id,'role','authenticated')::text,true);if jsonb_array_length(fp.travel_workspace()->'itinerary_entries')<>0 then raise exception 'cross household itinerary leak';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);denied:=false;begin perform fp.create_travel_itinerary_entry(trip,'activity','Invalid times',null,null,null,now()+interval '2 hours',now(),null,null);exception when invalid_parameter_value then denied:=true;end;if not denied then raise exception 'invalid time range accepted';end if;
end$$;
rollback;
