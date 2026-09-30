# Reinstall runbook (maintenance from 2026-10-05)

IT clean-installs Ubuntu 24.04.5 Server on the twelve hosts: atlas
(controller, slurmdbd), kosmos (login VM on gorgophone), gaia (CPU) and the
GPU nodes aristarchus, galileo, ptolemaeus, euctemon, eudoxus, herakles,
alanturing, hamilton, roentgen. We move them to the HWE 7.0 kernel and deploy
Slurm 26.05.4 fresh with a new accounting database (job IDs restart at 1).
carlos, plato, mariecurie and schrodinger are gone. gorgophone and the file
servers are not part of this maintenance.

The order below matters; how long each step takes does not. Nothing in the
repo depends on which nodes come first: every playbook takes `-l`.

Rules for every step:

- Run on teuwen-ansible, in a login shell (for `KOSMOS_SLURM_SECRETS_FILE`,
  `docs/kosmos/slurm-secrets.md`), with
  `source /opt/kosmos-cluster/env-26.07/bin/activate`, from an up-to-date
  `deepops-26.07` (`git pull`). Every host must be deployed from this one
  env, or the munge keys differ.
- Every command uses `-kK` (ssh password, sudo password): atlas has no
  Kerberos host principal, and the reinstalled hosts may not have one yet.
- **Every Slurm run includes atlas** (`-l atlas,<nodes>`). Compute nodes read
  `slurm.conf` from `/sw/.slurm`, which only the controller play writes, and
  a node joins `slurm.conf` in the run that first reaches it (deviation 26).
- **The first playbook on a reinstalled host runs with `--flush-cache`**
  (step 2.2): the fact cache may still hold its 22.04 facts, and with them
  the HWE kernel is skipped and the wrong repositories are chosen.
- A step that fails: fix it on a branch, merge into `deepops-26.07`, pull,
  rerun the same command. All playbooks are idempotent; a converged rerun
  ends with `changed=0`.

## 0. Before the maintenance

1. **QOS limits.** Copied into `slurm_qos` in
   `config/group_vars/slurm-cluster.yml` from `sacctmgr -P show qos` on
   2026-09-30. If anyone changes a QOS on the live cluster before the wipe,
   update it there too; `sacctmgr-qos.txt` from step 1.2 is the final check.
2. **Secrets.** Done: `slurm_password` and `slurm_db_password` come from the
   shared file on teuwen-ansible. The munge key is derived from
   `slurm_password`, so every host gets the new key on its first run.
3. **Dry run against the live cluster** (22.04, nothing changes), from a
   checkout of `reinstall-prep` before it is merged:

   ```bash
   ansible-playbook -kK --check --diff --flush-cache \
     -l atlas,kosmos,gaia,aristarchus,herakles playbooks/slurm-cluster.yml | tee ~/check-reinstall-prep.log
   ```

   Must reach the end without undefined-variable or template errors. Expected
   noise: hwloc/PMIx/Slurm "uninstall and rebuild", grub and kernel diffs
   (the HWE packages are skipped on 22.04), docker version changes.
4. Merge `reinstall-prep` into `deepops-26.07` (pull request).
5. Announcement (Daan): section 5 below.

## 1. Before the wipe (cluster drained)

1. Stop new work and let the queue empty (or cancel what is left):
   `scontrol update nodename=ALL state=drain reason="reinstall 2026-10-05"`.
2. **Slurm database, accounts and job history:**

   ```bash
   ansible-playbook -kK -l atlas playbooks/slurm-cluster/slurm-backup.yml
   ```

   Fetches the MariaDB dump, `sacctmgr-dump.cfg`, `sacctmgr-qos.txt`,
   `sacctmgr-assoc.txt`, the job history (`sacct-all.txt.gz`), `etc.tgz` and
   `SHA256SUMS` to `~/slurm-backups/atlas/<date>-slurm-23.02.4/` on
   teuwen-ansible. Check that the directory has all of them.
3. **Host snapshot** of all twelve hosts:

   ```bash
   ansible-playbook -kK docs/kosmos/pre-reinstall-snapshot.yml
   ```

   Then check which nodes booted with which options and adjust
   `kernel_cmdline_gpu` / `kernel_cmdline_extra` if they differ from what
   `playbooks/generic/kernel.yml` would write (`pci=realloc=off` on GPU
   nodes; gaia also had `iommu=pt`):
   `grep -A1 '### cat /proc/cmdline' ~/reinstall-snapshot/*/info.txt`.
   Secure Boot state is in the same file (`mokutil --sb-state`).
4. Copy `~/slurm-backups` and `~/reinstall-snapshot` off teuwen-ansible.
5. IT starts installing.

## 2. Deploy, per batch of nodes IT hands over

`N` = the hosts that are ready. The first batch must contain atlas; it is
most useful with one host of every kind: atlas, kosmos, gaia, aristarchus
(two dead GPUs), herakles (NVSwitch).

Hosts that IT has not reinstalled yet are expected to be off. A host that
is still running 22.04 is reachable and still has its old facts, so it is
listed in `slurm.conf` and shows as DOWN in `sinfo` until it is reinstalled.
That is harmless; power it off or ignore it.

1. Reachability and Secure Boot:

   ```bash
   ansible -kK -m ping -l N all
   ansible -kK -b -m command -a 'mokutil --sb-state' -l N slurm-node
   ```

   Secure Boot must be off on the compute nodes: the 580 driver is built by
   DKMS and an unsigned module does not load. If it is on, ask IT.
2. Kernel, alone first to isolate kernel problems (also part of step 3):

   ```bash
   ansible-playbook -kK --flush-cache playbooks/generic/kernel.yml -l N
   ```

   Ends with the running kernel per host: `7.0.0-*`.
3. Everything else:

   ```bash
   ansible-playbook -kK playbooks/slurm-cluster.yml -l atlas,N
   ```

   Driver 580 (and fabric manager on herakles), DCGM 4, Slurm 26.05.4 build,
   munge, MariaDB/slurmdbd/slurmctld and the QOS on atlas, slurmd on the
   nodes, NHC, Apptainer on the compute nodes, monitoring, motd, nvtop,
   nodestat.
   Nodes that cannot be reached are listed as "left out of slurm.conf".
4. **First batch only, accounting.** Copy `sacctmgr-dump.cfg` from step 1.2
   to atlas, then `sacctmgr load file=sacctmgr-dump.cfg` **without `-i`**:
   it prints what it will add and asks before committing. Compare
   `sacctmgr -P show assoc` with `sacctmgr-assoc.txt`.
5. Same command as step 3 again: `changed=0`.
6. Tests (as a normal user on kosmos unless noted):
   - `munge -n | ssh <node> unmunge` from atlas for each node; `sinfo`;
     `scontrol show node <node>`: CPUTot and RealMemory match `slurmd -C` on
     the node, `Gres=gpu:N(S:...)` (the `S:` part is GPU-CPU affinity).
   - aristarchus: GPU count in the `gpus` fact = `nvidia-smi -L` = `Gres`,
     node not drained. herakles: `nvidia-smi -q | grep -A2 Fabric` shows
     `Completed` / `Success` for all eight GPUs; an 8-GPU NCCL all-reduce
     (nccl-tests `all_reduce_perf`) reaches NVLink bandwidth.
   - `validate_slurm.py` (copy it from `scripts/validation/` to kosmos):
     `python3 validate_slurm.py --json --allow-unavailable-nodes` until all
     twelve hosts are in; `ok: true`, `gpu_job_ok: true`.
   - A job in every partition with each of its QOS; a job with a QOS the
     partition does not allow is rejected.
   - ssh to a compute node without a job is refused for a normal user and
     works for an admin (pam_slurm_adopt, `/etc/localgroups`); files a job
     leaves in `/tmp` are gone after it ends (epilog).
   - NHC: `sinfo -R` shows no drain reasons on healthy nodes.
   - Apptainer on a compute node, as a normal user:
     `srun apptainer exec docker://alpine true` (user namespaces under
     24.04's AppArmor); kosmos has no Apptainer.
   - One ssh login per host type: banner once, sysinfo block once.
   - `nodestat`, `nodestat -j`, `nodestat -g` on kosmos: every node that is
     in, CPU/GPU/memory counts that match `sinfo` and `squeue`.
   - Logs on atlas and a node: `grep -Ei 'defunct|deprecated|error'
     /var/log/slurm/*.log`.
   - Load: `sbatch --array=1-500 -p <partition> --wrap 'sleep 30'` on the
     CPU and a GPU partition together; all complete, nothing drains.
7. Fix, merge, pull, rerun step 3 with the same `-l`.

## 3. Go-live (all twelve hosts deployed)

1. `ansible-playbook -kK playbooks/slurm-cluster.yml`, then again:
   `changed=0` on every host, no unreachable node.
2. `python3 validate_slurm.py --json` (without `--allow-unavailable-nodes`)
   clean, every node idle, `sinfo -R` empty.
3. `scontrol update nodename=ALL state=resume` if anything is still drained
   from testing; send the announcement.

Fallbacks: the GA 6.8 kernel stays installed and selectable in grub; the
driver branch is one variable (`nvidia_driver_branch`); there is no way back
to 23.02 other than the backups from step 1.

## 4. After go-live, once things run smoothly

1. Record the results in `docs/kosmos/porting-notes.md` (check-run results
   section) and what was deferred: gorgophone, the file servers, Apptainer
   on kosmos.
2. Branch cleanup. Everything from these branches is on `deepops-26.07` or
   deliberately left behind (the stepped-upgrade playbook; nodestat is now
   a role). Tag
   each tip `archive/<branch>` and push the tags, then delete
   `slurm-upgrade-fixes`, `merge/slurm-upgrade-into-deepops`,
   `slurm-upgrade-26.04`, `nvidia-drivers-26.04`, `nodestat`,
   `local-lint-venv` and `reinstall-prep` locally and on origin; remove the
   worktrees `merge-review`, `merge-redo`, `local-lint-venv`. `master` stays
   as the frozen pre-port branch.

## What changed on purpose

Deviations 23-34 in `docs/kosmos/porting-notes.md`, plus the 25 upstream
commits cherry-picked onto `reinstall-prep` (exporter restart and local
build, retired Singularity wrapper, epilog/prolog fixes, NHC sshd match,
pam_slurm_adopt guard, slurmd PATH).

## 5. For users (announcement)

Slurm goes from 23.02 to 26.05 and the nodes from Ubuntu 22.04 to 24.04.
Changes that can break existing scripts (Slurm release notes 23.11-26.05):

- `salloc`/`srun` `--uid` and `--gid`, `sbatch --export-file` and
  `scontrol abort` are gone; so are `srun --cpu-bind=rank` and
  `salloc --get-user-env`.
- `--constraint` with node counts per feature needs square brackets, e.g.
  `--constraint="[rack1*2&rack2*4]"`.
- `--cpus-per-task` also sets `SLURM_TRES_PER_TASK=cpu:N`;
  `SLURM_NODE_ALIASES` is gone.
- `sacctmgr list associations` has no `lft` column any more (`lineage`).
- Jobs get 120 s between SIGTERM and SIGKILL (was 30 s).
- Job IDs start again at 1. Accounting history from before the maintenance
  is not in `sacct`; the admins keep an export.
- Ubuntu 24.04: system Python 3.12, glibc 2.39. Software compiled on the old
  nodes may need rebuilding; conda/virtual environments that use the system
  Python need recreating.
- NVIDIA driver 580 on every GPU node (CUDA 13 capable; older CUDA
  containers keep working).
- Apptainer 1.5.4 on every compute node (not on kosmos).
- New and harmless: several QOS per job, `srun --async`.
