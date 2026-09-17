// Apply the rehearsed Phase 2F migration sequence to the existing production DB.
// Intentionally does not change containers, volumes, or public routing.
import {execFileSync} from 'node:child_process';
import {readFileSync, readdirSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

if (process.argv[2] !== '--apply-production') throw Error('Pass --apply-production to run');
const backend = resolve(fileURLToPath(new URL('..', import.meta.url)));
const dockerExe = 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = 'family-passport-supabase-db-1';
function docker(args, input) {
  try {
    return execFileSync(dockerExe, args, {
      input, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024,
    }).toString();
  } catch (error) {
    const detail = String(error.stderr ?? '').split('\n').find(line => line.includes('ERROR:')) ?? '';
    throw Error(`Docker ${args[0]} failed (${error.status ?? error.code}): ${detail.slice(0, 240)}`);
  }
}
const info = JSON.parse(docker(['inspect', container]))[0];
if (info.State.Health?.Status !== 'healthy' ||
    info.Config.Labels?.['com.docker.compose.project'] !== 'family-passport-supabase' ||
    info.Config.Labels?.['com.docker.compose.service'] !== 'db') {
  throw Error('Production database identity or health check failed');
}
const query = sql => docker(['exec', container, 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-Atc', sql]).trim();
if (query("select to_regclass('fp.household_lists') is null and to_regclass('fp.conversations') is null") !== 't') {
  throw Error('Expected pre-Phase-2F schema not found; refusing a partial or repeat migration');
}
const countsSql = "select jsonb_build_object('households',(select count(*) from fp.households),'members',(select count(*) from fp.members),'documents',(select count(*) from fp.documents),'auth_users',(select count(*) from auth.users),'invalid_constraints',(select count(*) from pg_constraint where connamespace='fp'::regnamespace and not convalidated));";
const before = JSON.parse(query(countsSql));
if (before.invalid_constraints !== 0) throw Error('Invalid production constraints before migration');
const names = readdirSync(join(backend, 'migrations')).filter(name =>
  /^(0[4-6]\d)_.*\.sql$/.test(name) && Number(name.slice(0, 3)) >= 40).sort();
if (names.length !== 29 || names[0] !== '040_phase_1b_reminders_async_ocr.sql' ||
    names.at(-1) !== '069_household_list_conversations.sql') {
  throw Error('Unexpected Phase 2F migration set');
}
console.log(`Production migration starting: ${names.length} files; baseline counts ${JSON.stringify(before)}`);
for (const name of names) {
  try {
    const sql = readFileSync(join(backend, 'migrations', name));
    docker(['exec', '-i', container, 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'], sql);
    console.log(`PASS ${name}`);
  } catch (error) {
    throw Error(`STOPPED at ${name}: ${error.message}`);
  }
}
const after = JSON.parse(query(countsSql));
if (after.invalid_constraints !== 0 ||
    after.households < before.households || after.members < before.members ||
    after.documents < before.documents || after.auth_users < before.auth_users) {
  throw Error(`Post-migration count/constraint check failed: ${JSON.stringify(after)}`);
}
if (query("select to_regclass('fp.household_lists') is not null and to_regclass('fp.conversations') is not null") !== 't') {
  throw Error('Phase 2F schema markers absent after migration');
}
console.log(`Production migration PASS; after counts ${JSON.stringify(after)}`);
