import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {readFile, readdir, mkdir, writeFile, open} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';
import {scannerVersion, assertFresh} from '../email-ingestion/clamd-client.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const docker = process.env.FD_DOCKER || 'docker';
const manualLibrary = process.argv.includes('--manual-library');
const prefix = `${manualLibrary ? 'fd-library' : 'fd-test'}-${randomBytes(6).toString('hex')}`;
const label = manualLibrary ? 'app.familydocuments.manual-runtime' : 'app.familydocuments.test-run';
const containers = [], networks = [], processes = [];
let keepManualRuntime = false;
const reservedPorts = new Set();
const env = {...process.env, FD_TEST_CONTEXT: 'isolated', FD_TEST_CONTAINER: `${prefix}-db`, GOTRUE_JWT_SECRET: randomBytes(48).toString('hex'), FD_TEST_HMAC_SECRET: randomBytes(32).toString('hex')};
const password = randomBytes(32).toString('hex');
const images = {
  db: 'kia/familydocuments-supabase-postgres:17.6.1.159-kia.3',
  auth: 'kia/familydocuments-supabase-auth:v2.195.0-kia.3',
  rest: 'postgrest/postgrest:v14.13', mail: 'public.ecr.aws/supabase/mailpit:v1.30.2',
  ocr: 'kia/family-passport-paddleocr-api:0.1.0', gateway: process.env.FD_GATEWAY_IMAGE || 'kia/familydocuments-inbound-gateway:0.5.4', clamd: 'clamav/clamav:1.5.4'
};

function command(bin, args, {input, quiet = false, childEnv = env} = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {cwd: root, env: childEnv, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']});
    let output = '';
    for (const stream of [child.stdout, child.stderr]) stream.on('data', data => {output += data; if (!quiet) process.stdout.write(data);});
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(output.trim()) : reject(new Error(`${bin} ${args[0]} failed (${code}): ${quiet ? output : 'see output above'}`)));
    child.stdin.end(input);
  });
}
async function freePort() {
  for (let attempt = 0; attempt < 100; attempt++) {
    const port = 57000 + Math.floor(Math.random() * 7000);
    if (reservedPorts.has(port)) continue;
    reservedPorts.add(port);
    const available = await new Promise(resolve => {const server = createServer(); server.once('error', () => resolve(false)); server.listen(port, '127.0.0.1', () => server.close(() => resolve(true)));});
    if (available) return port;
    reservedPorts.delete(port);
  }
  throw new Error('No isolated loopback port available');
}
async function run(name, image, args, commandArgs = []) {
  const full = `${prefix}-${name}`;
  await command(docker, ['image', 'inspect', image], {quiet: true}); // Never pull implicitly.
  containers.push(full); // Include failed starts in ownership-checked cleanup too.
  await command(docker, ['run', '-d', '--pull=never', '--name', full, '--label', `${label}=${prefix}`, '--security-opt', 'no-new-privileges:true', ...args, image, ...commandArgs], {quiet: true});
  return full;
}
async function ready(url, timeout = 120000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {const response = await fetch(url, {signal: AbortSignal.timeout(3000)}); if (response.ok) return;} catch {}
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  throw new Error(`Isolated service did not become ready: ${url}`);
}
async function sql(text, user = 'postgres') {return command(docker, ['exec', '-i', env.FD_TEST_CONTAINER, 'psql', '-U', user, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], {input: text, quiet: true});}
async function cleanup() {
  // Only resources created by this run, with a matching ownership label, can be removed.
  for (const child of processes.reverse()) {
    if (child.exitCode === null) child.kill();
  }
  for (const name of containers.reverse()) {
    const owner = await command(docker, ['inspect', '-f', `{{index .Config.Labels "${label}"}}`, name], {quiet: true}).catch(() => '');
    if (owner === prefix) await command(docker, ['rm', '-f', '-v', name], {quiet: true});
  }
  for (const name of networks.reverse()) {
    const owner = await command(docker, ['network', 'inspect', '-f', `{{index .Labels "${label}"}}`, name], {quiet: true}).catch(() => '');
    if (owner === prefix) await command(docker, ['network', 'rm', name], {quiet: true});
  }
}

const results = [];
try {
  console.log(`Starting ${prefix}: disposable synthetic database; no production credentials, volumes or external email.`);
  for (const scope of ['db', 'app']) {
    const name = `${prefix}_${scope}`;
    await command(docker, ['network', 'create', ...(scope === 'db' ? ['--internal'] : []), '--label', `${label}=${prefix}`, name], {quiet: true}); networks.push(name);
  }
  const ports = Object.fromEntries(await Promise.all(['AUTH', 'API', 'MAIL', 'OCR', 'SEARCH', 'SMTP', 'GATEWAY', 'CLAMD', 'WEB'].map(async key => [key, await freePort()])));
  for (const [key, port] of Object.entries(ports)) env[`FD_${key}_URL`] = `http://127.0.0.1:${port}`;
  Object.assign(env, {FP_API_URL: env.FD_API_URL, FP_OCR_URL: env.FD_OCR_URL, FP_MAILPIT_URL: env.FD_MAIL_URL, FP_SEARCH_PORT: String(ports.SEARCH), FP_OLLAMA_URL: process.env.FD_TEST_OLLAMA_URL || 'http://127.0.0.1:1'});
  Object.assign(env, {FP_CLAMD_HOST: '127.0.0.1', FP_CLAMD_PORT: String(ports.CLAMD)});
  await run('db', images.db, ['--network', networks[0], '--network-alias', 'db', '--tmpfs', '/var/lib/postgresql/data:rw,size=512m', '-e', `POSTGRES_PASSWORD=${password}`, '-e', 'POSTGRES_HOST=/var/run/postgresql', '-e', 'PGPORT=5432', '-e', 'POSTGRES_DB=postgres', '-e', `JWT_SECRET=${env.GOTRUE_JWT_SECRET}`, '-e', 'JWT_EXP=3600']);
  for (let attempt = 0; ; attempt++) {
    try {const health = await command(docker, ['inspect', '-f', '{{.State.Health.Status}}', env.FD_TEST_CONTAINER], {quiet: true}); if (health !== 'healthy') throw new Error('Database is still initializing'); await command(docker, ['exec', env.FD_TEST_CONTAINER, 'pg_isready', '-U', 'postgres'], {quiet: true}); break;}
    catch (error) {if (attempt === 90) throw error; await new Promise(resolve => setTimeout(resolve, 500));}
  }
  await sql(`ALTER ROLE supabase_auth_admin PASSWORD '${password}'; ALTER ROLE authenticator PASSWORD '${password}';`, 'supabase_admin');
  await sql('CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;');
  await run('mail', images.mail, ['--network', networks[1], '--network-alias', 'mail', '-p', `127.0.0.1:${ports.MAIL}:8025`, '-p', `127.0.0.1:${ports.SMTP}:1025`, '--tmpfs', '/data:rw,size=64m', '-e', 'MP_MAX_MESSAGES=500']);
  await ready(`${env.FD_MAIL_URL}/api/v1/messages`);
  await run('auth', images.auth, ['--network', networks[1], '--network', networks[0], '-p', `127.0.0.1:${ports.AUTH}:9999`, '--read-only', '--cap-drop', 'ALL', '--tmpfs', '/tmp:rw,size=16m,uid=65532,gid=65532', ...Object.entries({
    GOTRUE_API_HOST: '0.0.0.0', GOTRUE_API_PORT: '9999', API_EXTERNAL_URL: env.FD_AUTH_URL, GOTRUE_SITE_URL: 'http://127.0.0.1:3300', GOTRUE_DB_DRIVER: 'postgres', GOTRUE_DB_DATABASE_URL: `postgres://supabase_auth_admin:${password}@db:5432/postgres`, GOTRUE_DB_NAMESPACE: 'auth',
    GOTRUE_DISABLE_SIGNUP: 'false', GOTRUE_EXTERNAL_EMAIL_ENABLED: 'true', GOTRUE_EXTERNAL_GOOGLE_ENABLED: 'false', GOTRUE_MAILER_AUTOCONFIRM: 'false', GOTRUE_SMTP_HOST: 'mail', GOTRUE_SMTP_PORT: '1025', GOTRUE_SMTP_ADMIN_EMAIL: 'no-reply@family-passport.test', GOTRUE_SMTP_SENDER_NAME: 'Synthetic test',
    GOTRUE_JWT_SECRET: env.GOTRUE_JWT_SECRET, GOTRUE_JWT_EXP: '3600', GOTRUE_JWT_AUD: 'authenticated', GOTRUE_JWT_DEFAULT_GROUP_NAME: 'authenticated', GOTRUE_JWT_ADMIN_ROLES: 'service_role', GOTRUE_PASSWORD_MIN_LENGTH: '14', GOTRUE_RATE_LIMIT_EMAIL_SENT: '1000', GOTRUE_SMTP_MAX_FREQUENCY: '1s', GOTRUE_MFA_TOTP_ENROLL_ENABLED: 'true', GOTRUE_MFA_TOTP_VERIFY_ENABLED: 'true', GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED: 'true', GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: '0'
  }).flatMap(([key, value]) => ['-e', `${key}=${value}`])]);
  await ready(`${env.FD_AUTH_URL}/health`);
  for (const file of (await readdir(new URL('../migrations/', import.meta.url))).filter(file => file.endsWith('.sql')).sort()) {
    await sql(await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8'));
  }
  console.log('All migrations replayed in disposable PostgreSQL.');
  await run('rest', images.rest, ['--network', `name=${networks[1]},alias=rest`, '--network', networks[0], '-p', `127.0.0.1:${ports.API}:3000`, '--read-only', '--cap-drop', 'ALL', '-e', `PGRST_DB_URI=postgres://authenticator:${password}@db:5432/postgres`, '-e', 'PGRST_DB_SCHEMAS=fp', '-e', 'PGRST_DB_ANON_ROLE=anon', '-e', `PGRST_JWT_SECRET=${env.GOTRUE_JWT_SECRET}`]);
  await ready(env.FD_API_URL);
  await run('gateway', images.gateway, ['--network', networks[1], '-p', `127.0.0.1:${ports.GATEWAY}:8080`, '--read-only', '--cap-drop', 'ALL', '-e', `GOTRUE_JWT_SECRET=${env.GOTRUE_JWT_SECRET}`, '-e', `INGESTION_HMAC_SECRET=${env.FD_TEST_HMAC_SECRET}`, '-e', 'FP_API_URL=http://rest:3000', '-e', `AUTH_UPSTREAM_URL=http://${prefix}-auth:9999`, '-e', 'OCR_UPSTREAM_URL=http://ocr:8080', '-e', `FRONTEND_ORIGIN=http://127.0.0.1:${manualLibrary ? ports.WEB : 3300}`]);
  await ready(`${env.FD_GATEWAY_URL}/health`);
  env.FD_SEARCH_URL = `${env.FD_GATEWAY_URL}/search`;
  console.log(`Isolated database container: ${env.FD_TEST_CONTAINER}`);
  const suites = process.argv.slice(2).filter(value => value !== '--manual-library');
  const selected = suites.length ? suites : ['email-password-auth.mjs', 'family-foundation.mjs', 'totp-mfa-e2e.mjs', 'google-oauth-contract.mjs', 'email-ingestion-e2e.mjs', 'search-assistant-e2e.mjs', 'ocr-reminder-e2e.mjs', 'attachment-scanner-e2e.mjs', 'google-drive-exact-files.sql', 'operational-hardening.sql', 'ux-phase-a-original-sources.sql'];
  async function startOcr() {
    console.log('Starting isolated real PaddleOCR (models baked in cached image; no external AI).');
    await run('ocr', images.ocr, ['--network', networks[1], '--network-alias', 'ocr', '-p', `127.0.0.1:${ports.OCR}:8080`, '--read-only', '--cap-drop', 'ALL', '--memory', '4g', '--cpus', '2', '--tmpfs', '/tmp:rw,size=512m,uid=10001,gid=10001', '-e', `GOTRUE_JWT_SECRET=${env.GOTRUE_JWT_SECRET}`, '-e', 'HOME=/tmp']);
    await ready(`${env.FD_OCR_URL}/health`, 180000);
  }
  async function startScanner() {
    console.log('Starting isolated ClamAV; official signature updates only, no production signature volume.');
    const scanner = await run('clamd', images.clamd, ['--network', networks[1], '-p', `127.0.0.1:${ports.CLAMD}:3310`, '--user', '100:101', '--read-only', '--cap-drop', 'ALL', '--memory', '2g', '--cpus', '1', '--tmpfs', '/tmp:rw,size=384m,uid=100,gid=101', '--mount', `type=bind,source=${root}tests,target=/test,readonly`, '--entrypoint', '/bin/sh'], ['/test/start-isolated-scanner.sh']);
    const deadline = Date.now() + 240000;
    for (;;) {
      try {assertFresh(await scannerVersion('127.0.0.1', ports.CLAMD)); break;} catch {}
      const running = await command(docker, ['inspect', '-f', '{{.State.Running}}', scanner], {quiet: true});
      if (running !== 'true' || Date.now() > deadline) {
        await command(docker, ['logs', '--tail', '20', scanner]);
        throw new Error('Isolated scanner unavailable or definitions stale; production scanner was not used.');
      }
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  if (manualLibrary) {
    const runtimeDir = fileURLToPath(new URL(`../supabase/.temp/phase2b-manual-${prefix}/`, import.meta.url));
    await mkdir(runtimeDir, {recursive: true});
    await startOcr();
    const ollama = await fetch('http://127.0.0.1:11434/api/tags', {signal: AbortSignal.timeout(5000)}).then(response => response.json());
    if (!ollama.models?.some(item => String(item.name).startsWith('qwen3:4b'))) throw new Error('Local qwen3:4b is unavailable');

    async function createManualAccount(accountLabel) {
      const suffix = `${Date.now()}-${randomBytes(4).toString('hex')}`;
      const email = `${accountLabel}-${suffix}@family-passport.test`;
      const accountPassword = `Synthetic-${randomBytes(10).toString('base64url')}!9a`;
      const headers = {'content-type': 'application/json'};
      const signup = await fetch(`${env.FD_AUTH_URL}/signup`, {method: 'POST', headers, body: JSON.stringify({email, password: accountPassword})});
      if (!signup.ok) throw new Error(`Synthetic ${accountLabel} signup failed`);
      let message;
      for (let attempt = 0; attempt < 40 && !message; attempt++) {
        const listing = await (await fetch(`${env.FD_MAIL_URL}/api/v1/messages`)).json();
        message = listing.messages?.find(item => item.To?.some(to => to.Address === email));
        if (!message) await new Promise(resolve => setTimeout(resolve, 250));
      }
      if (!message) throw new Error(`Synthetic ${accountLabel} confirmation missing`);
      const detail = await (await fetch(`${env.FD_MAIL_URL}/api/v1/message/${message.ID}`)).json();
      const link = [detail.Text, detail.HTML].join('\n').match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;', '&');
      if (!link || new URL(link).origin !== env.FD_AUTH_URL) throw new Error('Synthetic confirmation was not disposable');
      await fetch(link, {redirect: 'manual'});
      const signin = await fetch(`${env.FD_AUTH_URL}/token?grant_type=password`, {method: 'POST', headers, body: JSON.stringify({email, password: accountPassword})});
      const session = await signin.json();
      if (!signin.ok) throw new Error(`Synthetic ${accountLabel} sign-in failed`);
      return {email, password: accountPassword, userId: session.user.id, token: session.access_token};
    }
    async function rpc(account, name, payload = {}) {
      const response = await fetch(`${env.FD_API_URL}/rpc/${name}`, {method: 'POST', headers: {authorization: `Bearer ${account.token}`, 'content-type': 'application/json'}, body: JSON.stringify(payload)});
      const body = await response.json();
      if (!response.ok) throw new Error(`Synthetic seed RPC ${name} failed`);
      return body;
    }

    const owner = await createManualAccount('library-owner');
    const viewer = await createManualAccount('library-viewer');
    const outsider = await createManualAccount('library-outsider');
    const ownerFamily = await rpc(owner, 'bootstrap_household', {household_name: 'Phase 2B synthetic Family', display_name: 'Synthetic owner'});
    const outsiderFamily = await rpc(outsider, 'bootstrap_household', {household_name: 'Other synthetic Family', display_name: 'Synthetic outsider'});
    await rpc(owner, 'create_category', {category_name: 'Documents'});
    await rpc(owner, 'create_category', {category_name: 'Finance'});
    const snapshot = await rpc(owner, 'household_snapshot');
    const category = name => snapshot.categories.find(item => item.name === name)?.id;
    const ids = Object.fromEntries(['passport','bill','flight','travelOther','rentalInsurance','rentalOther','medical','revocable','foreign','tripFiji','tripSydney','propertyOne','propertyTwo','linkCategory'].map(key => [key, crypto.randomUUID()]));
    const familyId = ownerFamily.household.id;
    const otherFamilyId = outsiderFamily.household.id;
    const otherCategory = outsiderFamily.categories[0].id;
    await sql(`
      insert into fp.members(household_id,user_id,email,display_name,role) values('${familyId}','${viewer.userId}','${viewer.email}','Synthetic viewer','viewer');
      insert into fp.documents(id,household_id,category_id,title,original_filename,mime_type,created_by,confirmation_status,tags,created_at) values
        ('${ids.passport}','${familyId}','${category('Documents')}','Synthetic passport','synthetic-passport.pdf','application/pdf','${owner.userId}','confirmed','["identity","travel"]',now()),
        ('${ids.bill}','${familyId}','${category('Finance')}','Synthetic electricity invoice','synthetic-bill.pdf','application/pdf','${owner.userId}','confirmed','["invoice","home"]',now()-interval '1 day'),
        ('${ids.flight}','${familyId}','${category('Travel')}','Fiji flight booking','synthetic-flight.pdf','application/pdf','${owner.userId}','confirmed','["flight","fiji"]',now()-interval '2 days'),
        ('${ids.travelOther}','${familyId}','${category('Travel')}','Unassigned travel notes','synthetic-travel-notes.pdf','application/pdf','${owner.userId}','confirmed','[]',now()-interval '3 days'),
        ('${ids.rentalInsurance}','${familyId}','${category('Rental records')}','Rental insurance policy','synthetic-rental-insurance.pdf','application/pdf','${owner.userId}','confirmed','["insurance","rental"]',now()-interval '4 days'),
        ('${ids.rentalOther}','${familyId}','${category('Rental records')}','Unassigned tenancy notes','synthetic-tenancy-notes.pdf','application/pdf','${owner.userId}','confirmed','[]',now()-interval '5 days'),
        ('${ids.medical}','${familyId}','${category('Home')}','Family medical record','synthetic-medical.pdf','application/pdf','${owner.userId}','confirmed','["medical"]',now()-interval '6 days'),
        ('${ids.revocable}','${familyId}','${category('Insurance')}','Revocable insurance document','synthetic-revocable.pdf','application/pdf','${owner.userId}','confirmed','["revocable"]',now()-interval '7 days'),
        ('${ids.foreign}','${otherFamilyId}','${otherCategory}','Other Family private record','synthetic-private.pdf','application/pdf','${outsider.userId}','confirmed','["private"]',now());
      insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by) values('${ids.revocable}','${viewer.userId}','view','${owner.userId}');
      insert into fp.travel_trips(id,household_id,name,destination,start_date,end_date,created_by) values
        ('${ids.tripFiji}','${familyId}','Fiji — January 2027','Fiji','2027-01-10','2027-01-20','${owner.userId}'),
        ('${ids.tripSydney}','${familyId}','Sydney — April 2027','Sydney','2027-04-02','2027-04-09','${owner.userId}');
      insert into fp.travel_records(household_id,trip_id,document_id,travel_kind,confirmed_by) values('${familyId}','${ids.tripFiji}','${ids.flight}','flight','${owner.userId}');
      insert into fp.entities(id,household_id,entity_type,name,created_by) values
        ('${ids.propertyOne}','${familyId}','property','12 Example Street','${owner.userId}'),
        ('${ids.propertyTwo}','${familyId}','property','8 Test Road','${owner.userId}');
      insert into fp.rental_properties(entity_id,household_id,address,created_by) values
        ('${ids.propertyOne}','${familyId}','12 Example Street, Wellington','${owner.userId}'),
        ('${ids.propertyTwo}','${familyId}','8 Test Road, Auckland','${owner.userId}');
      insert into fp.rental_bills(household_id,property_entity_id,document_id,expense_category,confirmed_by) values('${familyId}','${ids.propertyOne}','${ids.rentalInsurance}','insurance','${owner.userId}');
      insert into fp.saved_link_categories(id,household_id,owner_user_id,name) values('${ids.linkCategory}','${familyId}','${owner.userId}','Research');
      insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title) values
        ('${familyId}','${owner.userId}','${ids.linkCategory}','https://example.com/travel',repeat('8',64),'example.com','Synthetic travel research'),
        ('${familyId}','${owner.userId}','${ids.linkCategory}','https://example.org/home',repeat('9',64),'example.org','Synthetic home reference');
    `);

    const workerLogPath = `${runtimeDir}\\worker.log`;
    const flutterLogPath = `${runtimeDir}\\flutter.log`;
    const workerLog = await open(workerLogPath, 'a');
    const worker = spawn(process.execPath, ['document-analysis/worker.mjs', '--watch'], {cwd: root, env: {...env, FP_API_URL: env.FD_API_URL, FP_OCR_URL: env.FD_OCR_URL, FP_OLLAMA_URL: 'http://127.0.0.1:11434', FP_OLLAMA_MODEL: 'qwen3:4b'}, windowsHide: true, detached: true, stdio: ['ignore', workerLog.fd, workerLog.fd]});
    processes.push(worker);
    worker.unref();
    await workerLog.close();
    const flutterLog = await open(flutterLogPath, 'a');
    const flutterCommand = process.env.FD_FLUTTER || 'C:\\src\\flutter\\bin\\flutter.bat';
    const flutter = spawn(flutterCommand, ['run', '-d', 'web-server', '--web-hostname', '127.0.0.1', '--web-port', String(ports.WEB), `--dart-define=FAMILYDOCUMENTS_API_BASE_URL=${env.FD_GATEWAY_URL}`], {cwd: fileURLToPath(new URL('../../familydocuments_flutter/', import.meta.url)), env, shell: true, windowsHide: true, detached: true, stdio: ['ignore', flutterLog.fd, flutterLog.fd]});
    processes.push(flutter);
    flutter.unref();
    await flutterLog.close();
    await ready(`http://127.0.0.1:${ports.WEB}`, 240000);
    const credentialsPath = `${runtimeDir}\\credentials.txt`;
    await writeFile(credentialsPath, `Synthetic owner\nEmail: ${owner.email}\nPassword: ${owner.password}\n\nRead-only member\nEmail: ${viewer.email}\nPassword: ${viewer.password}\n`, {mode: 0o600});
    const runtimePath = `${runtimeDir}\\runtime.json`;
    await writeFile(runtimePath, JSON.stringify({runtime_id: prefix, label, created_at: new Date().toISOString(), containers, networks, processes: {worker: worker.pid, flutter: flutter.pid}, urls: {flutter: `http://127.0.0.1:${ports.WEB}`, gateway: env.FD_GATEWAY_URL, auth: env.FD_AUTH_URL, api: env.FD_API_URL, ocr: env.FD_OCR_URL}, logs: {worker: workerLogPath, flutter: flutterLogPath}, credentials_file: credentialsPath, fixtures: [fileURLToPath(new URL('../tests/fixtures/synthetic-bill.pdf', import.meta.url)), fileURLToPath(new URL('../tests/fixtures/synthetic-malformed.pdf', import.meta.url))], migration: '043_flutter_library.sql', seed: {documents: 8, trips: 2, rentals: 2, links: 2, read_only_member: true, inaccessible_family: true, revocable_document: ids.revocable}}, null, 2));
    keepManualRuntime = true;
    console.log(JSON.stringify({manual_library_runtime: 'READY', flutter_url: `http://127.0.0.1:${ports.WEB}`, credentials_file: credentialsPath, runtime_manifest: runtimePath, worker_pid: worker.pid, migration: '043_flutter_library.sql'}, null, 2));
  }
  for (const suite of manualLibrary ? [] : selected) {
    if (!/^[a-z0-9-]+\.(mjs|sql)$/.test(suite)) throw new Error('Invalid test suite name');
    console.log(`Running ${suite}`);
    try {
      if (suite === 'ocr-reminder-e2e.mjs' || suite === 'phase-1b-e2e.mjs') await startOcr();
      if (suite === 'attachment-scanner-e2e.mjs') await startScanner();
      if (suite.endsWith('.sql')) await sql(await readFile(new URL(`../tests/${suite}`, import.meta.url), 'utf8'));
      else await command(process.execPath, [`tests/${suite}`]);
      results.push({suite, status: 'PASS'});
    } catch (error) {results.push({suite, status: 'FAIL', message: error.message}); console.error(error.message);}
  }
  if (!manualLibrary && !suites.length) {
    try {await command(process.execPath, ['--test', 'tests/relative-date.test.mjs', 'tests/notification-template.test.mjs', 'tests/ux-source-retention.test.mjs']); results.push({suite: 'unit-and-source-retention', status: 'PASS'});}
    catch (error) {results.push({suite: 'unit-and-source-retention', status: 'FAIL', message: error.message});}
  }
  console.log(JSON.stringify({isolated_results: results}, null, 2));
  if (results.some(result => result.status === 'FAIL')) process.exitCode = 1;
} catch (error) {console.error(error.message); process.exitCode = 1;}
finally {
  if (!keepManualRuntime) {
    await cleanup();
    console.log('Disposable test containers and networks removed; production was not changed.');
  }
}
