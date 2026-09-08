begin;

create or replace function fp.sync_inbound_email_review_status() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if new.status='proposed' and old.status is distinct from new.status then
    update fp.inbound_emails
    set processing_status='needs_review'
    where id=new.inbound_email_id and processing_status='awaiting_classification';
  end if;
  return new;
end $$;

drop trigger if exists classification_job_syncs_inbound_status on fp.email_classification_jobs;
create trigger classification_job_syncs_inbound_status
after update of status on fp.email_classification_jobs
for each row execute function fp.sync_inbound_email_review_status();

update fp.inbound_emails e
set processing_status='needs_review'
where e.processing_status='awaiting_classification'
  and exists(
    select 1 from fp.email_classification_jobs j
    join fp.email_classification_proposals p on p.classification_job_id=j.id
    where j.inbound_email_id=e.id and j.status='proposed' and p.status='needs_review'
  );

revoke execute on function fp.sync_inbound_email_review_status() from public,anon,authenticated;

commit;
