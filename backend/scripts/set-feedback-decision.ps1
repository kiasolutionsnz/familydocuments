[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$Ticket,
  [Parameter(Mandatory)][ValidateSet('Needs clarification','Accepted','Deferred','Declined','In progress','Testing','Ready for release','Released','Blocked')][string]$Status,
  [Parameter(Mandatory)][ValidateLength(1,1000)][string]$Message,
  [ValidateLength(0,1000)][string]$ReleaseEvidence = ''
)

$ErrorActionPreference = 'Stop'
$database = 'family-passport-supabase-db-1'
if ($Status -eq 'Released' -and $ReleaseEvidence.Trim().Length -lt 10) {
  throw 'Released requires a deployment evidence reference.'
}
$query = @"
set role feedback_reviewer;
select jsonb_pretty(fp.feedback_record_owner_decision(
  :'ticket'::bigint, :'decision', :'message', nullif(:'release_evidence','')
));
"@
& docker exec $database psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 `
  -v "ticket=$Ticket" -v "decision=$Status" -v "message=$Message" `
  -v "release_evidence=$ReleaseEvidence" -Atc $query
if ($LASTEXITCODE -ne 0) { throw 'Feedback decision was not recorded.' }
