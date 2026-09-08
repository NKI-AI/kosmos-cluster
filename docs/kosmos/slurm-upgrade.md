# Upgrading Slurm on KOSMOS: 23.02.4 -> 24.11.7 -> 26.05.4

Written 2026-09-08 for the admins who will run the upgrade during a patch
cycle. Nothing here has been run against the cluster yet; the playbooks were
syntax-checked and linted, and the template changes were proven with a local
render. Read the whole document once before the first hop.

Contents: caveats at a glance; why two hops; what changes; prechecks; the
run, hop by hop; what to watch; soak; hop 2; rollback; reference
(release-by-release caveats).

## 0. Caveats at a glance

Each one is explained in the section given.

- **Two hops, never one.** 26.05 does not accept 23.02; go to 24.11.7
  first, soak, then 26.05.4. The playbook refuses anything else (1, 4).
- **The database conversion is one-way.** The first start of the new
  slurmdbd rewrites the accounting tables; only the dump taken with
  slurmdbd stopped brings 23.02 back. Keep the backup directory until the
  hop has soaked (4.3, 8).
- **Conversion time is unknown until you look.** Minutes for a small
  database, hours for a large one; measure the job and step tables first,
  and tune MariaDB (the playbook writes the drop-in; check atlas RAM) (3, 5).
- **Munge key.** The build tasks re-template `/etc/munge/munge.key` from
  `slurm_password`. If the live key is not derived from the current value,
  upgrading atlas alone breaks authentication cluster-wide; the preflight
  refuses to start in that case. Apply the vault proposal on all hosts in
  one run, or not at all, before the upgrade (3).
- **kosmos gates hop 2.** 26.05 daemons reject clients older than 24.11;
  kosmos must get 24.11.7 client commands before hop 2, and admins cannot
  log in there today. Hop 1 can skip kosmos (3, 7).
- **Controller outage during the atlas build.** slurmctld is stopped while
  Slurm compiles (10-20 min) and while the database converts: no
  `sbatch`/`squeue`, no `sacct`; running jobs continue, nodes stay up
  because the timeouts are raised to 3600 s first (4.3, 5).
- **Per node, a window with no `slurmstepd` on disk.** The role removes the
  old installation before compiling the new one; new job steps cannot start
  on that node for those minutes, so the playbook drains it and resumes it
  afterwards. Steps launched inside an already running job on that node
  fail during the window (5).
- **The pin is the only supported input.** Bump `slurm_version` in
  `config/group_vars/slurm-cluster.yml` and commit; `-e slurm_version` is
  refused, because a stale pin plus a later `slurm.yml` run would rebuild
  the old version and wipe the controller state on the detected downgrade
  (2.1, 8).
- **First render of the branch's slurm.conf.** The upgrade applies the
  template to the live `/sw/.slurm/slurm.conf`, which also carries the
  documented drift (`KillWait`, phased-out nodes, default partition,
  `PriorityType`). Diff it beforehand; the preflight refuses unexpected
  changes unless confirmed (3, 4.2).
- **User-visible command removals** since 23.02 (`--uid/--gid`,
  `--export-file`, `scontrol abort`, `--cpu-bind=rank`, ...): announce
  before hop 1 (2.3).
- **Config keys that would be logged as defunct** (`CgroupAutomount`) and
  the scheduler default that would silently flip (`PriorityType`) are
  handled by the template changes committed with this document (2.1, 9).

## 1. Why two hops, and why 26.05.4

- The cluster runs **23.02.4** on all ten compute nodes and on atlas
  (verified 2026-09-08 with `slurmd --version` and `scontrol show config`;
  cluster RPC 9984).
- Slurm supports in-place upgrades from a limited set of older releases,
  and the database conversion only runs forward:

  | Target | Upgrades from | Source |
  |--------|---------------|--------|
  | 24.11 | 23.02, 23.11, 24.05 | 24.11 RELEASE_NOTES ("three previous major releases", new since 24.11) |
  | 25.05 | 23.11, 24.05, 24.11 | 25.05 RELEASE_NOTES |
  | 25.11 | 24.05, 24.11, 25.05 | 25.11 RELEASE_NOTES |
  | 26.05 | 24.11, 25.05, 25.11 | 26.05 RELEASE_NOTES |

  So 23.02 -> 24.11 -> 26.05 is the shortest supported path. Any other
  route needs three hops.
- There is no Slurm "26.07". DeepOps 26.07 (the base of this branch) pins
  Slurm **26.05.1**; the current patch release is **26.05.4** (2026-09-02).
  Patch releases inside a major do not change the database schema or the
  RPC protocol, so the newest patch is the right target: same role, fewer
  bugs. Same for the intermediate hop: **24.11.7** (2025-11-11) is the last
  24.11 patch.
- Order inside a hop, from SchedMD's upgrade guide: **slurmdbd, then
  slurmctld, then slurmd, then client commands** (the login node). A newer
  slurmdbd works with older slurmctld/slurmd inside the window, never the
  other way round.
- The hop is done **live**: running jobs survive slurmd and slurmctld
  restarts when `SlurmdTimeout`/`SlurmctldTimeout` are raised first. The
  playbook raises both to 3600 s for the duration and restores them at the
  end.

## 2. What changes

### 2.1 In this repository (committed with the playbooks, before hop 1)

Deviations 13-15 in `porting-notes.md`:

- `roles/slurm/templates/etc/slurm/cgroup.conf`: `CgroupAutomount=yes`
  removed. Slurm dropped the option in 23.11; newer daemons log
  `The option "CgroupAutomount" is defunct` at every start while it is there.
- `roles/slurm/templates/etc/slurm/slurm.conf`:
  - `PriorityType=priority/basic` is now explicit. The Slurm default
    flipped to `priority/multifactor` in 23.11; the cluster runs `basic`
    (FIFO) today and keeps it. Adopting multifactor is a separate decision.
  - `SlurmctldTimeout`/`SlurmdTimeout` are variables with the old values as
    defaults, so the upgrade playbook can raise them.
  - `SwitchType=switch/none`, `JobCompType=jobcomp/none` and the two
    `#JobCredential*` comment lines are gone. The `none` plugins were
    removed in 23.11; the parser silently ignores such values, so this is
    cosmetic.
- `config/group_vars/slurm-cluster.yml`: `slurm_version` is bumped one hop
  at a time (section 4). The upgrade playbook refuses to run when the
  effective `slurm_version` differs from this pin, so `-e slurm_version=`
  does not work on purpose: if the pin stayed at 23.02.4, a later
  `slurm.yml` run would rebuild 23.02.4 and `controller.yml` would run
  `slurmctld -i` on the "downgrade", wiping the controller state.
- New: `playbooks/slurm-cluster/slurm-backup.yml`,
  `playbooks/slurm-cluster/slurm-upgrade.yml`, `skills/upgrade-slurm/`.

### 2.2 On the cluster

- MariaDB on atlas gets `/etc/mysql/mariadb.conf.d/99-slurmdbd.cnf`
  (SchedMD's slurmdbd recommendations: InnoDB buffer pool 25 % of RAM up to
  4 GiB, `innodb_lock_wait_timeout=900`, log file 25 % of the pool,
  `max_allowed_packet=16M`, `innodb_snapshot_isolation=OFF`). Today MariaDB
  runs with Ubuntu defaults (128 MB pool, 50 s lock wait), which SchedMD
  warns can make the schema conversion fail on a large database.
- Backups under `/var/backups/slurm/<timestamp>-slurm-<version>-to-<target>`
  on atlas (database dump, state directory, configs, installed files,
  old source tarball) and a copy of the dump under `~/slurm-backups` on
  teuwen-ansible.
- The Slurm source tarball cache `/opt/kosmos-cluster/build/src/`.
- Rebuilt from source on every host: Slurm, `pam_slurm_adopt`, the contribs
  SPANK plugin `spank_pbs`. hwloc 2.5.0 and PMIx 3.2.3 are untouched (both
  still supported by 26.05; the role rebuilds them only when their version
  changes). Pyxis is not installed on this cluster (checked on the nodes),
  so there is no external SPANK plugin to recompile.

### 2.3 For users (announce before hop 1)

From the 23.11, 24.05 and 24.11 release notes, the changes that can break
existing scripts:

- `salloc`/`srun` `--uid` and `--gid` removed; `sbatch --export-file`
  removed; `scontrol abort` removed (23.11).
- `--constraint` with node counts per feature needs square brackets, e.g.
  `--constraint="[rack1*2&rack2*4]"` (23.11).
- `--cpus-per-task` now also sets `SLURM_TRES_PER_TASK=cpu:N` in the job
  environment; `SLURM_NODE_ALIASES` is gone (23.11).
- `sacctmgr list associations` no longer has the `lft` column; use
  `lineage` (23.11).
- `srun --cpu-bind=rank` and `salloc --get-user-env` removed (24.11).
- New and harmless: jobs may request several QOS (24.11), `sacctmgr ping`,
  `elevenses` as a time keyword, `scrontab @fika`.
- Hop 2 adds `srun --async` (26.05) and nothing that removes user options.

Scheduling order does not change (section 2.1). `KillWait` becomes 120 s
when the branch's slurm.conf is first rendered (deviation 3), independent
of the version.

## 3. Prechecks (by hand, days before)

1. **atlas resources.** `free -g`, `df -h / /var /opt`, `du -sh
   /var/lib/mysql /var/spool/slurm/ctld`. The backup needs about twice the
   database size free under `/var/backups`; the build needs ~2 GB under
   `/opt`. The buffer pool default is 25 % of RAM capped at 4 GiB; set
   `slurm_mariadb_buffer_pool_mb` in group_vars if atlas is small.
2. **Database size and shape**, on atlas as root:
   ```
   mysql -e 'SELECT table_name, ROUND((data_length+index_length)/1048576) MB FROM information_schema.tables WHERE table_schema="slurm_acct_db" ORDER BY MB DESC LIMIT 8'
   mysql -N -e 'SELECT COUNT(*) FROM slurm_acct_db.kosmos_job_table; SELECT COUNT(*) FROM slurm_acct_db.kosmos_step_table'
   ```
   The 23.02 -> 24.11 conversion rewrites the job and step tables (24.05
   started storing stdout/stderr/stdin paths). Roughly 5 800 jobs a week
   are recorded, so expect a few hundred thousand job rows per year of
   history; conversion takes minutes for a small database and can take
   hours for a large one. If the history is not needed, consider
   `PurgeJobAfter`/`PurgeStepAfter` in `slurmdbd.conf` **after** the
   upgrade, not before.
3. **Runaway jobs.** `sacctmgr show runawayjobs` on atlas; answer `y` to
   fix them by hand if it lists any. The playbooks only report them.
4. **Munge key.** The playbook refuses to run unless
   `/etc/munge/munge.key` on atlas and every node equals
   `password_hash(slurm_password, 'kosmos')`. If the vault proposal
   (`slurm-secrets-vault.md`) is applied first, do it on all hosts in one
   run and only then upgrade.
5. **Nodes.** All ten must report the same version (`ansible slurm-node -m
   shell -a '/usr/local/sbin/slurmd --version'`) and must be reachable over
   Kerberos. Nodes that are down or drained stay that way; note them
   (`sinfo -R`).
6. **kosmos.** Hop 1 can skip it (`-e slurm_upgrade_login=false`): a 24.11
   controller accepts 23.02 clients. Hop 2 cannot: see section 7.
7. **Repository.** `git pull`, activate `/opt/kosmos-cluster/env-26.07`,
   `kinit`, then:
   ```
   ansible-playbook playbooks/slurm-cluster/slurm-backup.yml playbooks/slurm-cluster/slurm-upgrade.yml --syntax-check
   ansible-playbook docs/kosmos/render-slurm-conf.yml -e out=/tmp/slurm.conf.new
   ssh gaia cat /sw/.slurm/slurm.conf | diff -u - /tmp/slurm.conf.new
   ```
   The diff is what the upgrade will apply to the live slurm.conf (plus the
   two timeout lines). Expected differences are listed in `porting-notes.md`,
   "Check-run results": `KillWait`, phased-out nodes, the default partition,
   `RealMemory`/`Procs` drift, and now `PriorityType`. Anything else: fix
   first. The preflight shows the same diff and refuses to continue unless
   it is only the timeout lines or you pass
   `-e slurm_upgrade_confirm_conf_diff=true`.
8. **Announce** the window to users (section 2.3 and the impact in
   section 5).

## 4. The run, hop by hop

Each hop is the same sequence; only the pin differs.

### 4.1 Bump the pin and commit

```
sed -i 's/^slurm_version: "23.02.4"/slurm_version: "24.11.7"/' config/group_vars/slurm-cluster.yml
git commit -am 'slurm: 23.02.4 -> 24.11.7 (hop 1 of 2, docs/kosmos/slurm-upgrade.md)'
```

(Hop 2: `24.11.7` -> `26.05.4`.) Push or not as you prefer, but every
admin's clone must have the new pin before anyone runs `slurm.yml` again.

### 4.2 Dry run of the checks

```
ansible-playbook -kK --check --diff --tags preflight playbooks/slurm-cluster/slurm-upgrade.yml
```

`-k` because atlas rejects the Kerberos ticket; `-K` for sudo. This runs
the probes and the preflight only: version window, pin, node versions,
munge key, services, informational state, the source tarball download (it
does download; harmless), the MariaDB drop-in (shown as a diff, not
written), and the slurm.conf diff. Nothing is restarted. Read the
"informational state" block.

### 4.3 Canary: controller plus one node

```
ansible-playbook -kK --diff --limit 'slurm-master,alanturing' playbooks/slurm-cluster/slurm-upgrade.yml
```

alanturing is one of the two rtx2080ti nodes, the cheapest partition. What
happens, in order:

1. Probes and preflight (as above, for real this time): the drop-in is
   written, slurm.conf gets the 3600 s timeouts, `scontrol reconfigure`.
2. **Backup** (`slurm-backup.yml`): slurmdbd is stopped, the database is
   dumped, state and configs archived, installed files tarred, the 23.02.4
   tarball downloaded, the dump fetched to `~/slurm-backups/atlas/...` on
   teuwen-ansible. slurmdbd stays stopped. alanturing's installed files are
   tarred too.
3. **Controller**: MariaDB restarted with the new settings; slurmctld
   stopped; state directory archived again; Slurm built and installed
   (the old installation is removed first; this is the outage window);
   unit files replaced; the new slurmdbd started in the foreground
   (`slurmdbd -D -vvv`, log in the backup directory) until it opens port
   6819, which it does only after the schema conversion; log checked for
   `fatal:`; `sacctmgr show cluster` must answer; the foreground daemon is
   stopped and slurmdbd started under systemd; slurmctld started; version
   verified; node states printed.
4. **alanturing**: drained with reason `slurm upgrade to 24.11.7`, built,
   `cgroup.conf` re-rendered, slurmd restarted, the controller must report
   `Version=24.11.7` and a state without `DOWN`/`NOT_RESPONDING`, then
   resumed (only if the drain reason is still ours).
5. **Finish**: refuses to restore the timeouts because nine nodes are still
   on 23.02.4. That is expected for the canary; the timeouts stay at 3600 s
   until the full run. (If you must stop here for a while, that is safe:
   the only effect of the raised timeouts is that a dead node takes an hour
   to be marked down.)

Submit a test job to the rtx2080ti partition, run `sacct -j <id>` after it
finishes, and check `sinfo -N -o '%N %v %T'`.

### 4.4 The rest of the nodes

```
ansible-playbook -kK --diff playbooks/slurm-cluster/slurm-upgrade.yml
```

Probes and preflight again (fast; the controller is already on the target,
the version window check passes as "same major"), backup again (a second
directory; this time slurmdbd keeps running, the dump is taken with
`--single-transaction`), the controller play ends immediately, then the
nodes two at a time
(`slurm_upgrade_serial`, raise with `-e slurm_upgrade_serial=5` once the
canary was clean), then finish: slurm.conf re-rendered with the normal
timeouts, `scontrol reconfigure`, summary. Finally the login play, which
skips kosmos with `-e slurm_upgrade_login=false` or when unreachable.

Then, on any node: `python3 scripts/validation/validate_slurm.py --json`
must report `"ok": true`, `gpu_job_ok: true`, `slurm_version` 24.11.7.

### 4.5 If something fails

- The playbook stops at the first failed host (`any_errors_fatal` /
  `max_fail_percentage: 0`). Read the failed task's output; the last
  lines of `/opt/kosmos-cluster/build/slurm/build.log` for build failures,
  the convert log in the backup directory for slurmdbd.
- Resume on the nodes and finish: `--tags compute,finish` (nodes already on
  the target are skipped; the preflight tasks that re-raise the timeouts run
  too).
- Restore the timeouts by hand: `--tags finish` (add
  `-e slurm_upgrade_allow_partial=true` if some nodes are deliberately
  left behind).
- A node left drained with our reason: `scontrol update nodename=X
  state=resume` after checking `systemctl status slurmd` there.
- Anything that suggests the database is wrong (`fatal:` in the convert
  log, `sacctmgr` errors): stop, do not start the old slurmdbd, go to
  section 8.

## 5. What to watch during the run

- On atlas: `tail -f /var/log/slurm/slurmdbd.log` during the conversion
  (`pre-converting job table`, `Conversion done: success!`), then
  `/var/log/slurm/slurmctld.log` for `error:` lines after the restart.
- On a node: `tail -f /var/log/slurm/slurmd.log` after its restart; a
  `defunct` message means a stale config option.
- User impact per phase:
  - backup + conversion: `sacct`, `sreport`, `sacctmgr` do not answer;
    submissions and scheduling continue (slurmctld queues the accounting
    records).
  - controller build until slurmctld is back (10-20 min): `sbatch`,
    `squeue`, `srun` from the login node fail with "Unable to contact slurm
    controller"; running jobs continue; nodes stay up thanks to the raised
    timeouts.
  - per node (10-20 min each, two at a time): no new jobs start there
    (drained); job steps launched inside a running job on that node
    (`srun` in a batch script) fail while the binaries are being replaced;
    the running steps themselves continue.
  - slurmd restart: running steps keep running (they belong to slurmstepd,
    not slurmd).

## 6. Soak (between hops, at least one to two weeks)

- Jobs of every partition complete and show up in `sacct` with the right
  state; `sreport cluster utilization` for the last day has numbers
  (rollups run).
- `sinfo -R` shows nothing new; NHC does not drain nodes (`nhc` runs
  every 300 s on idle nodes).
- `grep -c error: /var/log/slurm/slurmctld.log` does not grow unusually;
  `grep -i defunct /var/log/slurm/slurmd.log` on the nodes is empty.
- `sacctmgr show cluster format=Cluster,RPC` shows the new RPC number;
  write it down in `porting-notes.md`.
- Enroot jobs and the exclusive-node prolog/epilog scripts behave as
  before (they do not depend on the Slurm version, but the `PrologFlags`
  handling did change over the releases).
- Keep the backup directory until the soak is over, then delete the
  `usr-local-slurm-*.tgz` tarballs if space matters; keep the dump.

## 7. Hop 2 prerequisites (26.05.4)

- **kosmos must run client commands >= 24.11.** 26.05 daemons reject
  clients older than 24.11, and today admins cannot log in to kosmos
  (porting notes). Either access is restored and the login play does the
  build there, or whoever administers kosmos upgrades its `/usr/local`
  Slurm by hand to 24.11.7 (same configure line, `configure.txt` in the
  backup directory has it). The preflight refuses target 26.05 unless the
  login node reports >= 24.11 or you pass
  `-e slurm_upgrade_login_version_ack=<version>` after checking by hand.
- Re-read the 26.05 release notes for `slurm.conf` keys that are removed
  (checked 2026-09-08: nothing this site uses; `Exclusive=` replaces
  `ExclusiveUser`/`ExclusiveTopo` on partitions, cgroup/v2 directories are
  keyed by SLUID instead of job id, `SchedulerParameters=enable_job_state_cache`
  is gone).
- PMIx 3.2.3 is still accepted by 26.05's configure (v2 to v6). hwloc has
  no minimum.
- Repeat the prechecks (section 3) and run the same sequence (section 4).
  The database conversion is smaller than for hop 1.

## 8. Rollback

Only from the backup directory of the failed hop
(`/var/backups/slurm/<ts>-slurm-<old>-to-<new>`, path printed by the
playbook and listed in `MANIFEST.txt`). The database conversion cannot be
undone; the dump is the only way back. Anything recorded after the dump
(jobs that finished during the attempt) is lost from accounting, and the
controller state restored below forgets jobs submitted after it was taken.

On atlas:

```
systemctl stop slurmctld slurmdbd
B=/var/backups/slurm/<dir>
tar -xzf $B/usr-local-slurm-<old>.tgz -C /                      # old binaries, plugins, libraries, pam module
tar -xzf $B/etc.tgz -C / etc/systemd/system                      # old unit files
systemctl daemon-reload
mysql -e 'DROP DATABASE slurm_acct_db'
zcat $B/slurm_acct_db.sql.gz | mysql --max_allowed_packet=64M    # the dump contains CREATE DATABASE
rm -rf /var/spool/slurm/ctld && tar -xzf $B/statesave-ctld-stopped.tgz -C /var/spool/slurm
cp $B/slurm.conf.orig /sw/.slurm/slurm.conf                      # or re-render from the old pin
systemctl start slurmdbd && sleep 5 && sacctmgr -n show cluster
systemctl start slurmctld && scontrol ping
```

On every node that was upgraded (their tarballs are in the same-named
directory under `/var/backups/slurm` on each node):

```
systemctl stop slurmd
tar -xzf /var/backups/slurm/<dir>/usr-local-slurm-<old>.tgz -C /
systemctl daemon-reload && systemctl start slurmd
```

Then set the pin back in `config/group_vars/slurm-cluster.yml` and commit.
Never "roll back" by running `slurm.yml` or the upgrade playbook with the
old pin: the role would rebuild the old version from source (fine) and
`controller.yml` would wipe the state on the detected downgrade (not fine);
the upgrade playbook refuses downgrades for that reason.

## 9. Reference: release-by-release caveats checked for this site

Checked 2026-09-08 against the RELEASE_NOTES of 23.11, 24.05, 24.11, 25.05,
25.11 and 26.05 and against the 24.11/26.05 sources. "n/a" means the site
does not use the feature.

| Release | Change | Site impact |
|---------|--------|-------------|
| 23.11 | `select/cons_res` removed | n/a, site uses `cons_tres` |
| 23.11 | `none` plugins removed (all but auth, cred) | cosmetic, parser drops `*/none` values (deviation 15) |
| 23.11 | `CgroupAutomount`, `*Kmem*` removed from cgroup.conf | deviation 13 |
| 23.11 | `JobCredentialPrivateKey`/`PublicCertificate` removed | comment lines removed |
| 23.11 | default `PriorityType` -> multifactor | deviation 14 pins basic |
| 23.11 | default `TreeWidth` 50 -> 16 | none (10 nodes) |
| 23.11 | PMIx not built unless `--with-pmix` | already in `slurm_configure` |
| 23.11 | command options removed (section 2.3) | announce |
| 24.05 | `CoreSpecPlugin` removed; Cray XC removed | n/a; `--enable-really-no-cray` is now a no-op flag (upstream 26.07 still passes it) |
| 24.05 | default `UnkillableStepTimeout` | site sets 180 explicitly |
| 24.05 | cgroup/v2 needs dbus >= 1.11.16 | Ubuntu 22.04 has 1.12 |
| 24.05 | job stdout/err/in paths stored in the DB | conversion touches the job table; DB grows |
| 24.11 | upgrades from three releases back | enables the two-hop path |
| 24.11 | all SPANK plugins must be recompiled | only `spank_pbs` (contribs, rebuilt); no pyxis |
| 24.11 | `srun --cpu-bind=rank`, `salloc --get-user-env` removed | announce |
| 24.11 | slurmctld conmgr thread pool (`SlurmctldParameters=conmgr_*`) | defaults fine |
| 25.05 | cgroup/v1 deprecated; FrontEnd removed; TLS optional | site is cgroup v2; n/a |
| 25.11 | `JobContainerType` -> `NamespaceType`; `conmgr_threads` default 6 | not set |
| 26.05 | `Exclusive=` replaces `ExclusiveUser`/`ExclusiveTopo` | n/a |
| 26.05 | cgroup/v2 paths keyed by SLUID (`CgroupJobIdPaths` restores) | nothing on the nodes reads cgroup paths by job id (prolog/epilog/NHC checked) |
| 26.05 | `enable_job_state_cache` removed; v0.0.41 REST removed | n/a |
| 26.05 | MUNGE a weak dependency of the packages | n/a (source build, munge stays) |

Build dependencies: `roles/slurm/vars/ubuntu.yml` (libmunge-dev,
libmariadb-dev, libpam0g-dev, libdbus-1-dev, ...) is what upstream 26.07 uses
to build 26.05.1, so it is complete for both hops on Ubuntu 22.04.
