// Rehearses the Phase 2F migrations on an isolated restore of a verified
// production dump. Never connects to or writes the running production database.
import {execFileSync} from 'node:child_process';
import {readFile, readdir, writeFile, realpath} from 'node:fs/promises';
import {join, resolve, sep} from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const backend=resolve(fileURLToPath(new URL('..',import.meta.url)));
const releaseId=process.argv[2];
if(!/^fd-ux-\d{8}-\d{6}$/.test(releaseId??'')) throw Error('Expected a verified fd-ux release ID');
const backupRoot=await realpath(join(backend,'backups'));
const releaseDir=await realpath(join(backupRoot,releaseId));
if(!releaseDir.startsWith(backupRoot+sep)) throw Error('Backup path outside allowed root');
const verified=JSON.parse(await readFile(join(releaseDir,'verification.json'),'utf8'));
if(verified.status!=='BACKUP_RESTORE_AND_MIGRATION_REHEARSAL_PASS'||verified.release!==releaseId||verified.production_migrated!==false) throw Error('Backup verification missing');
const dump=await readFile(join(releaseDir,'database.dump'));
const hash=createHash('sha256').update(dump).digest('hex').toUpperCase();
if(dump.subarray(0,5).toString()!=='PGDMP'||hash!==verified.dump_sha256) throw Error('Backup hash mismatch');
const dockerExe='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
function docker(args,input) {
  try{return execFileSync(dockerExe,args,{input,windowsHide:true,stdio:['pipe','pipe','pipe'],maxBuffer:128*1024*1024});}
  catch(error){
    const safeError=String(error.stderr??'').split('\n').find(line=>line.includes('ERROR:'))??'';
    throw Error('Isolated Docker step failed: '+args[0]+' '+(args[1]??'')+' status='+error.status+' signal='+error.signal+' code='+error.code+' message='+String(error.message??'').slice(0,150)+' stderr_bytes='+String(error.stderr??'').length+' stdout_bytes='+String(error.stdout??'').length+' '+safeError.slice(0,180));
  }
}
const production=JSON.parse(docker(['inspect','family-passport-supabase-db-1']))[0];
if(production.State.Health?.Status!=='healthy'||!production.Config.Image.includes('familydocuments-supabase-postgres')) throw Error('Unexpected production database image/health');
const image=production.Image;
const candidate='fd-pb08-upgrade-'+releaseId.slice(6);
if(docker(['ps','-a','--filter','name=^/'+candidate+'$','--format','{{.Names}}']).toString().trim()) throw Error('Candidate container already exists');
const password=createHash('sha256').update(releaseId+':isolated').digest('hex');
let started=false;
let failedMigration=null;
const start=Date.now();
try {
  docker(['run','-d','--pull=never','--name',candidate,'--label','app.familydocuments.pb08-rehearsal='+releaseId,
    '--network','none','--security-opt','no-new-privileges:true','--tmpfs','/var/lib/postgresql/data:rw,size=1g',
    '-e','POSTGRES_PASSWORD='+password,'-e','POSTGRES_HOST=/var/run/postgresql','-e','PGPORT=5432','-e','POSTGRES_DB=postgres',image]);
  started=true;
  let ready=false;
  for(let i=0;i<90;i++) {
    try {if(docker(['inspect','--format','{{.State.Health.Status}}',candidate]).toString().trim()==='healthy'){ready=true;break;}}
    catch {}
    await new Promise(r=>setTimeout(r,500));
  }
  if(!ready) throw Error('Disposable database did not become healthy');
  docker(['exec',candidate,'createdb','-U','postgres','fd_upgrade']);
  docker(['exec',candidate,'psql','-U','postgres','-d','fd_upgrade','-v','ON_ERROR_STOP=1','-c',
    'CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions; CREATE SCHEMA IF NOT EXISTS auth; CREATE SCHEMA IF NOT EXISTS fp;']);
  docker(['cp',join(releaseDir,'database.dump'),candidate+':/tmp/database.dump']);
  docker(['exec',candidate,'pg_restore','-U','supabase_admin','-d','fd_upgrade','--schema=auth','--exit-on-error','/tmp/database.dump']);
  docker(['exec',candidate,'pg_restore','-U','supabase_admin','-d','fd_upgrade','--schema=fp','--exit-on-error','/tmp/database.dump']);
  const countsSql="select jsonb_build_object('households',(select count(*) from fp.households),'members',(select count(*) from fp.members),'documents',(select count(*) from fp.documents),'auth_users',(select count(*) from auth.users),'invalid_constraints',(select count(*) from pg_constraint where connamespace='fp'::regnamespace and not convalidated));";
  const counts=()=>JSON.parse(docker(['exec',candidate,'psql','-U','postgres','-d','fd_upgrade','-Atc',countsSql]).toString());
  const baseline=counts();
  const migrations=(await readdir(join(backend,'migrations'))).filter(n=>/^(0[4-6]\d)_.*\.sql$/.test(n)&&Number(n.slice(0,3))>=40).sort();
  for(const migration of migrations) {
    failedMigration=migration;
    const content=await readFile(join(backend,'migrations',migration));
    docker(['exec','-i',candidate,'psql','-X','-U','supabase_admin','-d','fd_upgrade','-v','ON_ERROR_STOP=1','-q'],content);
    console.log('Applied '+migration);
  }
  failedMigration=null;
  const after=counts();
  if(after.households!==baseline.households||after.members!==baseline.members||after.documents!==baseline.documents||after.auth_users!==baseline.auth_users||after.invalid_constraints!==0) throw Error('Counts or constraints differ after rehearsal');
  const report={status:'PASS',release:releaseId,dump_sha256:hash,migrations,baseline,after,isolated:true,
    production_migrated:false,elapsed_seconds:Math.round((Date.now()-start)/1000),at:new Date().toISOString()};
  await writeFile(join(releaseDir,'pb08-upgrade-rehearsal-with-auth.json'),JSON.stringify(report,null,2),{flag:'wx'});
  console.log(JSON.stringify(report));
} catch(error) {
  console.error('Upgrade rehearsal stopped at '+(failedMigration??'restore/verification')+': '+error.message);
  process.exitCode=1;
} finally {
  if(started) {
    const candidateInfo=JSON.parse(docker(['inspect',candidate]))[0];
    if(candidateInfo.Config.Labels['app.familydocuments.pb08-rehearsal']===releaseId) docker(['rm','-f','-v',candidate]);
  }
}
