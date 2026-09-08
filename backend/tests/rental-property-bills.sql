begin;
do $$
declare owner_id uuid:=gen_random_uuid(); viewer_id uuid:=gen_random_uuid(); outsider_id uuid:=gen_random_uuid(); hid uuid:=gen_random_uuid(); other_hid uuid:=gen_random_uuid(); cid uuid; doc uuid; doc2 uuid; property_id uuid; bill_id uuid; result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic Rentals',owner_id),(other_hid,'Other Household',outsider_id);
  insert into fp.members(household_id,user_id,email,display_name,role) values(hid,owner_id,'rental-owner@example.test','Owner','owner'),(hid,viewer_id,'rental-viewer@example.test','Viewer','viewer'),(other_hid,outsider_id,'rental-outsider@example.test','Outsider','owner');
  insert into fp.categories(household_id,name,created_by) values(hid,'Bills',owner_id) returning id into cid;
  insert into fp.documents(household_id,category_id,title,created_by,provider_name,amount,currency) values(hid,cid,'Synthetic council rates',owner_id,'Synthetic Council',425.50,'NZD') returning id into doc;
  insert into fp.documents(household_id,category_id,title,created_by,provider_name,amount,currency) values(hid,cid,'Synthetic manager invoice',owner_id,'Synthetic Manager',99.95,'NZD') returning id into doc2;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','rental-owner@example.test','aal','aal2')::text,true);
  result:=fp.create_rental_property('Rental One','1 Fictional Street','Family trust','Synthetic Manager','manager@example.test','000000000'); property_id:=(result->>'id')::uuid;
  result:=fp.create_rental_bill(property_id,doc,'rates',425.50,'NZD',current_date,'SYNTHETIC-1',null); bill_id:=(result->>'id')::uuid;
  result:=fp.create_rental_record(property_id,doc2,'maintenance','tax_support','Synthetic tax-support description','INV-SYNTHETIC-2',99.95,'NZD',current_date);
  if (select invoice_number from fp.rental_bills where document_id=doc2)<>'INV-SYNTHETIC-2' or (select record_purpose from fp.rental_bills where document_id=doc2)<>'tax_support' then raise exception 'rental email record fields failed'; end if;
  if jsonb_array_length(fp.rental_property_workspace()->'properties')<>1 or jsonb_array_length(fp.rental_property_export()->'rows')<>2 then raise exception 'owner workspace or export failed'; end if;
  perform fp.set_rental_bill_status(bill_id,'paid',current_date); if (select status from fp.rental_bills where id=bill_id)<>'paid' then raise exception 'paid lifecycle failed'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','rental-viewer@example.test','aal','aal1')::text,true); if jsonb_array_length(fp.rental_property_workspace()->'properties')<>0 then raise exception 'private property leaked to viewer'; end if;
  begin perform fp.rental_property_export(); raise exception 'viewer exported rental data'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider_id,'email','rental-outsider@example.test','aal','aal2')::text,true); if jsonb_array_length(fp.rental_property_workspace()->'bills')<>0 then raise exception 'rental bill leaked cross-household'; end if;
end $$;
rollback;
