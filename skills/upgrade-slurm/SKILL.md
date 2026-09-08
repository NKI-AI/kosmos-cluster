---
name: upgrade-slurm
description: Upgrade Slurm on the KOSMOS cluster one major release at a time (23.02 -> 24.11 -> 26.05) with a backup first, using the site playbooks. Use when asked to upgrade, update or bump Slurm on this cluster, or to back up the Slurm accounting database.
---

# Upgrade Slurm on KOSMOS

Site-specific. The full procedure with rationale, user-visible changes,
timings and rollback is `docs/kosmos/slurm-upgrade.md`; this is the short
form. Never run these playbooks from an AI session without an admin
present: they stop daemons on the production cluster.

## Preconditions

- Target within the SchedMD window: 24.11 from 23.02/23.11/24.05; 26.05
  from 24.11/25.05/25.11. From 23.02 that is two hops with a soak period
  between them.
- Every compute node and atlas report the same installed version
  (`ansible slurm-node -m shell -a '/usr/local/sbin/slurmd --version'`).
- `kinit` done, `/opt/kosmos-cluster/env-26.07` activated, clone up to date,
  run from the repository root. atlas needs `-k`, sudo needs `-K`.
- `sacctmgr show runawayjobs` fixed by hand; `sinfo -R` noted.
- Enough space on atlas: `du -sh /var/lib/mysql` x2 under `/var/backups`.
- `/etc/munge/munge.key` on all hosts derived from the current
  `slurm_password` (the playbook checks; see
  `docs/kosmos/slurm-secrets-vault.md` if it fails).
- For target 26.05: the kosmos client commands already on >= 24.11.

## Procedure

1. Bump the pin and commit (never `-e slurm_version`):

   ```bash
   sed -i 's/^slurm_version: "23.02.4"/slurm_version: "24.11.7"/' config/group_vars/slurm-cluster.yml
   git commit -am 'slurm: 23.02.4 -> 24.11.7 (hop 1 of 2)'
   ```

2. Check the rendered slurm.conf against the live one and the checks only:

   ```bash
   ansible-playbook docs/kosmos/render-slurm-conf.yml -e out=/tmp/slurm.conf.new
   ssh gaia cat /sw/.slurm/slurm.conf | diff -u - /tmp/slurm.conf.new
   ansible-playbook -kK --check --diff --tags preflight playbooks/slurm-cluster/slurm-upgrade.yml
   ```

   Expected: the diff shows only documented drift (`porting-notes.md`,
   "Check-run results") plus `PriorityType`; the preflight ends with the
   "informational state" block and no failed task.

3. Canary (controller and one cheap node), then the rest:

   ```bash
   ansible-playbook -kK --diff --limit 'slurm-master,alanturing' playbooks/slurm-cluster/slurm-upgrade.yml
   ansible-playbook -kK --diff playbooks/slurm-cluster/slurm-upgrade.yml
   ```

   Expected on the canary: backup directory printed, `Conversion done:
   success!` (or "no schema conversion was needed") in the conversion log
   summary, "Controller now runs Slurm 24.11.7", alanturing
   `Version=24.11.7`, and the finish play refusing to restore the timeouts
   because nine nodes are still old. Expected on the full run: nodes two at
   a time, then "Timeouts restored", then the login play skipped or done.

4. Validate on a node, the success signal is this, not the play recap:

   ```bash
   python3 scripts/validation/validate_slurm.py --json
   sacctmgr -n show cluster format=Cluster,RPC
   sacct -a -X -S now-1hour -o JobID,State | tail
   ```

   Require `"ok": true`, `gpu_job_ok: true`, `slurm_version` equal to the
   pin, and finished jobs listed by `sacct`.

5. Soak one to two weeks (`docs/kosmos/slurm-upgrade.md`, section 6), then
   repeat from step 1 with `26.05.4`.

Backup only (any time, no upgrade):

```bash
ansible-playbook -kK playbooks/slurm-cluster/slurm-backup.yml -e slurm_backup_stop_slurmdbd=true
```

## Failure branches

- **Preflight: "slurm_version is X but ... pins Y"**: the pin in
  group_vars was not bumped, or `-e slurm_version` was passed. Fix the pin.
- **Preflight: "Slurm X accepts upgrades from ... only"**: wrong hop; go to
  24.11 first.
- **Preflight: munge key mismatch**: someone rotated the key or the vault
  was applied with a new `slurm_password`. Set `slurm_password` to the seed
  of the live key; do not continue.
- **Preflight: "differs from the live file in more than the two timeout
  lines"**: read the diff; if it is the documented drift, rerun with
  `-e slurm_upgrade_confirm_conf_diff=true`.
- **Backup: "has ... free, the database ... take"**: free space on atlas or
  `-e slurm_backup_dir=/other/fs`.
- **Controller: the conversion wait says "slurmdbd exited"**: read
  `<backup dir>/slurmdbd-convert.log`. `Database schema is too old`
  means the window was violated (should be impossible after the
  preflight); MariaDB errors usually mean lock wait or packet size, check
  `99-slurmdbd.cnf` was applied (`mysql -e 'SELECT @@innodb_lock_wait_timeout'`).
  Do not start the old slurmdbd; follow the rollback in the doc.
- **Controller: the wait runs for hours**: normal for a big database; watch
  `tail -f /var/log/slurm/slurmdbd.log` on atlas for `pre-converting`
  lines. The default limit is 12 h (`slurm_dbd_convert_timeout`).
- **Compute: "wait for the controller to see the node" times out**:
  `systemctl status slurmd` and `tail /var/log/slurm/slurmd.log` on the
  node. `Incompatible plugin version` means a plugin from the old build
  survived in `/usr/local/lib/slurm`; `defunct` means a stale config key.
  Fix, then resume with `--tags compute,finish`.
- **Node left drained with reason "slurm upgrade to ..."**: after fixing,
  `scontrol update nodename=<node> state=resume`.
- **Finish: "Not on ... yet"**: some nodes are still old; resume with
  `--tags compute,finish`, or accept with
  `-e slurm_upgrade_allow_partial=true` (nodes then have 300 s to answer).
- **kosmos unreachable**: hop 1 continues without it
  (`-e slurm_upgrade_login=false`); hop 2 is blocked until its client
  commands are >= 24.11 (`docs/kosmos/slurm-upgrade.md`, section 7).
- **Fact gathering fails on gaia with "Too many open files"**: the plays
  gather without hardware facts on purpose; if it still fails, see
  `porting-notes.md`, "Fact gathering fails on nodes with many NFS
  submounts".
