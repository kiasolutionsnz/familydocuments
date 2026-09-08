import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {readFile, readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';
import {scannerVersion, assertFresh} from '../email-ingestion/clamd-client.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const docker = process.env.FD_DOCKER || 'docker';
const prefix = `fd-test-${randomBytes(6).toString('hex')}`;
const label = 'app.familydocuments.test-run';
const containers = [], networks = [];
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
  const ports = Object.fromEntries(await Promise.all(['AUTH', 'API', 'MAIL', 'OCR', 'SEARCH', 'SMTP', 'GATEWAY', 'CLAMD'].map(async key => [key, await freePort()])));
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
  await run('gateway', images.gateway, ['--network', networks[1], '-p', `127.0.0.1:${ports.GATEWAY}:8080`, '--read-only', '--cap-drop', 'ALL', '-e', `GOTRUE_JWT_SECRET=${env.GOTRUE_JWT_SECRET}`, '-e', `INGESTION_HMAC_SECRET=${env.FD_TEST_HMAC_SECRET}`, '-e', 'FP_API_URL=http://rest:3000', '-e', `AUTH_UPSTREAM_URL=http://${prefix}-auth:9999`, '-e', 'OCR_UPSTREAM_URL=http://ocr:8080', '-e', 'FRONTEND_ORIGIN=http://127.0.0.1:3300']);
  await ready(`${env.FD_GATEWAY_URL}/health`);
  env.FD_SEARCH_URL = `${env.FD_GATEWAY_URL}/search`;
  console.log(`Isolated database container: ${env.FD_TEST_CONTAINER}`);
  const suites = process.argv.slice(2);
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
  for (const suite of selected) {
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
  if (!suites.length) {
    try {await command(process.execPath, ['--test', 'tests/relative-date.test.mjs', 'tests/notification-template.test.mjs', 'tests/ux-source-retention.test.mjs']); results.push({suite: 'unit-and-source-retention', status: 'PASS'});}
    catch (error) {results.push({suite: 'unit-and-source-retention', status: 'FAIL', message: error.message});}
  }
  console.log(JSON.stringify({isolated_results: results}, null, 2));
  if (results.some(result => result.status === 'FAIL')) process.exitCode = 1;
} catch (error) {console.error(error.message); process.exitCode = 1;}
finally {await cleanup(); console.log('Disposable test containers and networks removed; production was not changed.');}
