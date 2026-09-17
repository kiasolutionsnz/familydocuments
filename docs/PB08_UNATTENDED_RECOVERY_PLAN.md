# PB-08 unattended recovery plan — prepared 2026-09-17

## Current evidence

- Observed: this Windows Pro host runs the production FamilyDocuments containers
  in Docker Desktop's WSL engine. `com.docker.service` is Stopped/Manual while
  the Docker Desktop processes and containers are running in the signed-in
  user session. Docker Desktop's documented automatic-start setting starts it
  when a user signs in; setting its helper service to Automatic is not a
  supported proof of a no-login Linux engine.
- Observed: three FamilyDocuments watch tasks use logon triggers, and all six
  production FamilyDocuments tasks use Interactive principals. Their exact
  XML was saved privately under the ignored PB-08 backup directory. A
  reversible S4U/startup conversion script passed syntax and preview checks.
  Applying it was denied by Windows because the available shell lacks an
  administrator token. No task registration changed.
- Observed: the production stack has a PostgreSQL data volume and a ClamAV
  signature volume. The public API and inbound-email gateway currently route
  through shared Traefik/tunnel infrastructure on Docker Desktop. The public
  Flutter site is hosted separately, but is not useful when its API is down.
- Observed: the host has 31.9 GiB physical memory, about 10.3 GiB free at
  inspection, and ample C:/D: space. A hypervisor is present and Hyper-V
  cmdlets exist, but `Get-VM` is denied to the current non-admin shell. These
  facts do not yet prove a dedicated VM can be provisioned safely.

## Preferred target (planned, not deployed)

Run the **FamilyDocuments stack only** on a boot-time Linux Docker Engine,
provisionally a dedicated Linux VM that starts with Windows. Give it its own
outbound-only Cloudflare tunnel and FamilyDocuments-only HTTP ingress. Keep
the database, Auth, REST, OCR, ClamAV and inbound gateway on private VM
networks. No database or Docker socket is public. This avoids moving the other
applications simply to fix FamilyDocuments, although rerouting the existing
FamilyDocuments API and inbound-email hostnames still needs a coordinated
maintenance window. If the VM cannot meet boot, resource, ingress or backup
requirements, stop and present a host-wide Linux migration design instead.

## Preparation possible while owner is away

1. Inventory the exact production Compose configuration, image digests,
   volumes, secrets-file references, Cloudflare hostname routes, task actions
   and workers without disclosing secret values.
2. Size and validate the VM candidate; confirm Windows virtualization support,
   RAM/disk headroom and that VM auto-start is available. Do not install or
   start a new engine on the production host without approval.
3. Create a pinned, scanned, non-root candidate deployment and private networks
   in an isolated VM. Port all six Windows worker actions to boot-managed VM
   services or containers, replacing loopback/Docker Desktop references with
   private VM endpoints and preserving their retry and deduplication rules.
   Rehearse restore of the native PostgreSQL dump and the needed ClamAV
   signature lifecycle, Auth/REST/OCR/gateway health, workers and outbound-only
   tunnel using non-production routes.
4. Keep the existing Desktop stack and its tunnel as the rollback target.

## Owner-present change window

1. Obtain an administrator token for VM and task management. If the selected
   architecture keeps the workers on Windows with a proven boot-time engine,
   run `backend/scripts/enable-unattended-familydocuments-tasks.ps1 -Apply`
   and verify S4U/AtStartup behavior. **Do not apply that script as a substitute
   for moving workers into the dedicated VM**: their current loopback and
   Docker Desktop paths would be wrong after VM cutover.
2. Pause FamilyDocuments writers, take a fresh encrypted off-computer backup,
   integrity-check it and perform an isolated restore. Preserve current
   database, task XML, Compose definitions, image digests and Cloudflare route
   settings for rollback.
3. Move only FamilyDocuments application state and six worker roles to the
   candidate engine; stop the old worker instances before activating new ones
   to avoid duplicate processing. Do not copy a live PostgreSQL volume.
   Restore from a native dump, validate
   counts, constraints, RLS, Auth login, documents, reminders, inbox and
   outbound notifications before rerouting traffic.
4. Switch only the FamilyDocuments API and inbound-email hostnames to the new
   tunnel/ingress. Verify public health, exact-origin CORS, unauthenticated
   denial, email signature boundary, and that unrelated hostnames still route
   unchanged. Keep old stack idle but intact for rollback.
5. With the owner present in a planned outage window, reboot the Windows host
   and **do not sign in**. From another device, verify the VM, engine,
   containers, public API, inbound route and due-notification worker recover.
   Confirm private database isolation and no missing/duplicate jobs. Only
   this drill can close the no-login requirement.

## Go/no-go and rollback

No cutover if administrator access, VM auto-start, pinned-image security gate,
fresh restore, isolated ingress, monitoring or a rollback route is missing.
If post-switch acceptance fails, return the two FamilyDocuments hostnames to
the preserved old tunnel, restart only its app workers if needed, and keep
the new VM isolated for diagnosis. Never overwrite the old database to roll
back; reconcile writes created during the cutover window before reopening.

The user is away from the computer. No UAC prompt, task mutation, Docker
restart, route change or reboot should be attempted until they return and
approve the maintenance window.
