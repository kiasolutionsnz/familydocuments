begin;

alter table fp.inbound_attachments drop constraint if exists inbound_attachments_content_state_check;
alter table fp.inbound_attachments add constraint inbound_attachments_content_state_check check(
  (scan_status='clean' and content is not null and content_sha256 is not null and quarantined_content is null)
  or (scan_status='pending' and content is null and quarantined_content is not null)
  or (scan_status in ('rejected','malformed','error') and content is null and quarantined_content is null)
  or (scan_status='unsupported' and content is null)
);

comment on constraint inbound_attachments_content_state_check on fp.inbound_attachments is
  'Unsupported bytes may exist only within the ingest statement and are cleared before commit; pending supported files remain quarantined until scanning.';

commit;
