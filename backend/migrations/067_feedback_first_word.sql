begin;

-- Migration 066 installed the matching colon/dash rule. Expand that narrowly
-- to any message whose first word is Feedback, preserving all other guards.
do $migration$
declare definition text;
begin
  select pg_get_functiondef(
    'fp.feedback_request(text,text,text,text,uuid,text)'::regprocedure
  ) into definition;
  if position(
    $old$feedback[[:space:]]*[:-]$old$ in definition
  ) = 0 or position(
    $old$(?i)^feedback[[:space:]]*[:-][[:space:]]*$old$
    in definition
  ) = 0 then
    raise exception 'unexpected feedback function version' using errcode='PT409';
  end if;
  definition := replace(
    definition,
    $old$feedback[[:space:]]*[:-]$old$,
    $new$feedback\y$new$
  );
  definition := replace(
    definition,
    $old$(?i)^feedback[[:space:]]*[:-][[:space:]]*$old$,
    $new$(?i)^feedback\y[[:space:]]*[:-]?[[:space:]]*$new$
  );
  execute definition;
end $migration$;

revoke all on function fp.feedback_request(text,text,text,text,uuid,text) from public,anon,authenticated;
grant execute on function fp.feedback_request(text,text,text,text,uuid,text) to service_role;
commit;
