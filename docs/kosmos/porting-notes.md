# Kosmos porting notes: DeepOps 26.07 branch

Branch `deepops-26.07` rebuilds this fork as **NVIDIA DeepOps tag 26.07 plus a
small set of overlay commits**. The overlay ports what is on `master` (fork
point: DeepOps 23.08, commit d248b658). This file has two sections:

1. **Conscious deviations from master**: every place where the branch
   deliberately differs from `master`, why, and the commit. Other admins can
   review each row and flip it back if they disagree.
2. **Things to address after the port**: problems and oddities found while
   porting that were left as they are on master. To be worked through once
   the port is done.

Rule used while porting: port `master` as is. Deviate only with a stated
reason, and record it here. Design changes that nobody has asked for are
shelved (listed at the end), not applied.

## 1. Conscious deviations from master

| # | Where | Branch does | Master does | Why | Commit |
|---|-------|-------------|-------------|-----|--------|
| 0a | `ansible.cfg` | `pipelining = True` (upstream) | `pipelining = False` (EricMarcus-ai, 2024-06-03, "Disable ansible pipelining", no reason given) | Pipelining halves the SSH round-trips per task. It only fails when sudo enforces `requiretty`, which the nodes do not (checked on gaia). Flip: set `pipelining = False` | (not applied, branch keeps upstream) |
| 0b | `ansible.cfg` | no `[galaxy]` section (upstream) | `[galaxy] server = https://old-galaxy.ansible.com/` (Musab, 2023-11-02) | Temporary workaround from the late-2023 Galaxy migration; the host no longer serves content and 26.07 requirements resolve on galaxy.ansible.com. Flip: re-add the section | (not applied, branch keeps upstream) |
| 1 | `scripts/setup.sh` | venv default `/opt/kosmos-cluster/env` | venv in `./env` (upstream default) | Shared checkout and venv on teuwen-ansible, one environment for all admins | b084b7f1 |
| 2 | `roles/slurm/defaults/main.yml` | untouched upstream file | overrides `deepops_dir`, `slurm_build_dir`, `hwloc_build_dir`, `pmix_build_dir`, `hwloc_install_prefix`, `pmix_install_prefix` to `/opt/kosmos-cluster/...` and `slurm_cluster_name: kosmos` | Site values belong in `config/group_vars`, not in a vendored role; same values will be set there (site config chunk) | c9d86ffc |
| 3 | `roles/slurm/templates/etc/slurm/slurm.conf` | `KillWait=120` (upstream 26.07 value) | `KillWait=30` | 30 was the 23.08 default, not a site choice. Upstream raised it in Sept 2024 for more graceful job termination. Behavior change: jobs get 120 s instead of 30 s between SIGTERM and SIGKILL. Flip: set `KillWait=30` in the template | c9d86ffc |
| 4 | `playbooks/slurm-cluster/slurm.yml` | keeps `roles: [facts]` in the first play, in addition to the fact-gathering pre_task | removed the role, keeps only the pre_task | The role installs the custom fact scripts (`topology`, `memory`, `gpus`) that slurm.conf needs. Master relies on other playbooks having installed them. On existing nodes the role is a no-op (scripts unchanged since 23.08). Flip: delete the `roles:` block | 00ae45d2 |

### Master changes not carried over (superseded upstream)
These master changes were not carried over because 26.07 already contains the
same fix or removed the code in question.

- `include:` in playbooks and roles. Removed in ansible-core 2.16; 26.07 uses
  `import_playbook` / `include_tasks` everywhere. Master's top-level
  `playbooks/slurm-cluster.yml` still uses `include:` and no longer runs on
  current Ansible.
- RHEL 7 `yum` tasks in the slurm role, old molecule images, older
  `50-exclusive-gpu` epilog: master is simply older than 26.07 here.

### Behavior differences vs the running cluster

Changes the upgrade brings that we accept rather than pin back. Also listed
in the table above where a flip is possible.

- `KillWait` 30 -> 120 (see deviation 3).

## 2. Things to address after the port

Found while porting, deliberately left as on master. Not fixed because the
port should not change how things are done without consulting the other
admins.

### Slurm role (commit c9d86ffc)
### Facts gathering (commit 00ae45d2)

- `run_once: true` on the "Gather facts from ALL hosts" pre_task in
  `playbooks/slurm-cluster/slurm.yml`, so one host does the delegated
  gathering instead of every host in the play repeating the same loop.

### NFS mounts (chunk 4a)

- `roles/create-mounts/tasks/main.yml` hardcodes the kronos and rhea export
  list and mount options inside the role. Upstream's `nfs` role takes the same
  information from `nfs_mounts` in `config/group_vars`; moving it there would
  keep site data out of role code.
- The fstab block in that role uses Ansible's default `blockinfile` marker
  text. Any other `blockinfile` on `/etc/fstab` with the default marker would
  replace it. Nothing in 26.07 does, but a custom marker would be safer.
- `playbooks/slurm-cluster/create_mounts.yml` targets an `outside` group that
  is commented out in `config/inventory`, so it is silently skipped.
- `playbooks/slurm-cluster/mount_scratch_disks.yml` runs `exportfs -a` and
  `mount -a` unconditionally on every run (always reports "changed").
- `playbooks/generic/nfs-general.yml` exists only to install `nfs-common`;
  upstream's `nfs-client.yml` would do the same if
  `slurm_enable_nfs_client_nodes` were on, but that also expects `nfs_mounts`.
