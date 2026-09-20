[CmdletBinding()]
param([ValidateRange(1,100)][int]$Limit = 30)

$ErrorActionPreference = 'Stop'
$database = 'family-passport-supabase-db-1'
$query = @"
set role feedback_reviewer;
select jsonb_pretty(fp.feedback_review_list($Limit));
"@
& docker exec $database psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atc $query
if ($LASTEXITCODE -ne 0) { throw 'Read-only feedback retrieval failed.' }
