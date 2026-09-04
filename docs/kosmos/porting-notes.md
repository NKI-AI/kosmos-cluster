# Kosmos porting notes: DeepOps 26.07 branch

Branch `deepops-26.07` rebuilds this fork as **NVIDIA DeepOps tag 26.07 plus a
small set of overlay commits**. The overlay ports what is on `master` (fork
point: DeepOps 23.08, commit d248b658). Contents:

- **Before the first run**: the test recipe.
- **1. Conscious deviations from master**: every place where the branch
  deliberately differs from `master`, why, and the commit. Other admins can
  review each row and flip it back if they disagree.
- **2. Things to address after the port**: problems and oddities found while
  porting that were left as they are on master, by priority.

Rule used while porting: port `master` as is. Deviate only with a stated
reason, and record it here. Design changes that nobody has asked for are
not applied; they go into section 2.

**Status (2026-09-04):** port complete, untested. Everything on `master` up
to e812a659 has been ported, dropped with a row below, or superseded upstream.

## Before the first run

Do these in order, on teuwen-ansible with the shared venv
(`/opt/kosmos-cluster/env`, ansible-core 2.16):

1. `ansible-galaxy role install -r roles/requirements.yml -p roles/galaxy` and
   `ansible-galaxy collection install -r collections/requirements.yml -p collections`
   (26.07 pins; the old `roles/galaxy` from 23.08 is not compatible).
2. Fix the default partition (section 2, "Urgent").
3. Decide what to do with herakles (section 2, "Site config").
4. `ansible-playbook playbooks/slurm-cluster.yml --syntax-check`.
5. `ansible-playbook -K playbooks/slurm-cluster/slurm.yml --check --diff --limit gaia`
   and compare the rendered `slurm.conf` diff against `/etc/slurm/slurm.conf`
   on gaia. Expected differences: `KillWait`, the phased-out nodes disappearing.
6. Only then consider a real run, playbook by playbook, starting with the
   ones that are idempotent on the current nodes (motd, nvtop, create_mounts).

## 1. Conscious deviations from master

| # | Where | Branch does | Master does | Why | Commit |
|---|-------|-------------|-------------|-----|--------|
| 0a | `ansible.cfg` | `pipelining = True` (upstream) | `pipelining = False` (EricMarcus-ai, 2024-06-03, "Disable ansible pipelining", no reason given) | Pipelining halves the SSH round-trips per task. It only fails when sudo enforces `requiretty`, which the nodes do not (checked on gaia). Flip: set `pipelining = False` | (not applied, branch keeps upstream) |
| 0b | `ansible.cfg` | no `[galaxy]` section (upstream) | `[galaxy] server = https://old-galaxy.ansible.com/` (Musab, 2023-11-02) | Temporary workaround from the late-2023 Galaxy migration; the host no longer serves content and 26.07 requirements resolve on galaxy.ansible.com. Flip: re-add the section | (not applied, branch keeps upstream) |
| 1 | `scripts/setup.sh` | venv default `/opt/kosmos-cluster/env` | venv in `./env` (upstream default) | Shared checkout and venv on teuwen-ansible, one environment for all admins | b084b7f1 |
| 1b | `.github/workflows/setup.yml` | activates `/opt/kosmos-cluster/env` | upstream activates `/opt/deepops/env` (master still has the 23.08 workflows) | Follows deviation 1; the CI job failed on every push until the path matched. Flip together with deviation 1 | chunk 6 |
| 2 | `roles/{slurm,nhc,nvidia-dcgm-exporter,nginx-docker-registry-cache,standalone-container-registry,pyxis}/defaults/main.yml` | untouched upstream files | overrides build/config paths to `/opt/kosmos-cluster/...`, `slurm_cluster_name: kosmos`, `standalone_container_registry_name: kosmos-registry`, `slurm_pyxis_version: 0.19.0` | Site values belong in `config/group_vars`, not in vendored roles. All of them are now set in `config/group_vars/{all,slurm-cluster}.yml`, derived from `deepops_dir` | c9d86ffc, chunk 5b |
| 3 | `roles/slurm/templates/etc/slurm/slurm.conf` | `KillWait=120` (upstream 26.07 value) | `KillWait=30` | 30 was the 23.08 default, not a site choice. Upstream raised it in Sept 2024 for more graceful job termination. Behavior change: jobs get 120 s instead of 30 s between SIGTERM and SIGKILL. Flip: set `KillWait=30` in the template | c9d86ffc |
| 4 | `playbooks/slurm-cluster/slurm.yml` | keeps `roles: [facts]` in the first play, in addition to the fact-gathering pre_task | removed the role, keeps only the pre_task | The role installs the custom fact scripts (`topology`, `memory`, `gpus`) that slurm.conf needs. Master relies on other playbooks having installed them. On existing nodes the role is a no-op (scripts unchanged since 23.08). Flip: delete the `roles:` block | 00ae45d2 |
| 5 | `roles/spack.environment`, `playbooks/slurm-cluster/spack-modules.yml`, `roles/spack/defaults/main.yml` | untouched upstream (no spack.environment role, upstream spack-modules.yml, upstream spack pin v1.2.0) | adds a role that installs Spack profile scripts on all hosts plus zsh support, a play for it in spack-modules.yml, and pins spack v0.20.2 with gcc/gfortran deps (EricMarcus-ai and joren, June 2024) | Spack was never rolled out: `/sw` (shared NFS) has no spack directory, no node has `/etc/profile.d/z00_spack.*`, `spack` is not on the path, and `slurm_install_spack` is `false` in config so the play never runs. Confirmed with the admin that nobody uses Spack. Flip: `git checkout master -- roles/spack.environment playbooks/slurm-cluster/spack-modules.yml` and set `spack_version`/`spack_ubuntu_deps` in group_vars (upstream already has gcc/gfortran) | (not applied, chunk 4d) |
| 6 | `config/group_vars/slurm-cluster.yml` | `slurm_cluster_install_singularity: no` | `yes` | Apptainer replaced Singularity on the nodes (chunk 4c) and upstream's singularity playbook is broken in 26.07 (`abims_sbr.singularity` dropped from requirements). Flip: set `yes` (and expect the playbook to fail) | chunk 5b |
| 7 | `config/group_vars/slurm-cluster.yml` | `slurm_version: "23.02.4"` pinned | no pin in config (master pinned it in `roles/slurm/defaults`) | Upstream 26.07 defaults to 26.05.1. Slurm supports upgrading at most two major versions at once, so 23.02 -> 26.05 must be stepped; a Slurm upgrade is a separate project. Flip: remove the pin | chunk 5b |
| 8 | `config/group_vars/slurm-cluster.yml` | `slurm_default_group`, `slurm_organization_name`, `slurm_install_spack` removed | defines them | No role or playbook on either branch reads the first two; the third follows from deviation 5. Flip: re-add the lines | chunk 5b |
| 9 | `config/group_vars/all.yml` | rebuilt from the 26.07 `config.example` with the four site values (DNS, timezone, extra packages, `deepops_dir`) | 23.08 example with the same four values | Master's file was otherwise untouched 23.08 example text; the 26.07 example adds the driver branch and open-kernel-module knobs and updates MAAS/NGC defaults. Flip: `git checkout master -- config/group_vars/all.yml` | chunk 5b |
| 10 | `config/group_vars/all.yml` | `users: []` | example `users:` block defining an `nvidia` sudo user with a published password hash | Nothing in the Slurm flow runs the users role and no node has that user, but a sudo account with a public hash should not sit in site config. Flip: restore the block | chunk 5b |
| 11 | `roles/requirements.yml`, `config/group_vars/all.yml`, `config/host_vars/{alanturing,hamilton,roentgen}` | upstream `nvidia.nvidia_driver v2.3.1`; `nvidia_driver_branch: "580"` in all.yml, `"550"` in host_vars of the three older nodes | `https://github.com/NKI-AI/ansible-role-nvidia-driver` (master), which is upstream v2.3.1 code with only the default branch changed from 515 to 550 | The fork adds nothing but a default. Live drivers (2026-09-04, all Ubuntu `-server` packages, which is what the role installs): 580 on aristarchus, ptolemaeus, galileo, eudoxus, euctemon, herakles; 550 on alanturing, hamilton, roentgen. Per-host pins are the only setting under which a driver run changes no node; master's single 550 would downgrade six nodes. Flip: set one branch in all.yml and delete the host_vars lines | chunk 5b |

### Master changes not carried over (superseded upstream)

These master changes were not carried over because 26.07 already contains the
same fix or removed the code in question.

- `include:` in playbooks and roles. Removed in ansible-core 2.16; 26.07 uses
  `import_playbook` / `include_tasks` everywhere. Master's top-level
  `playbooks/slurm-cluster.yml` still uses `include:` and no longer runs on
  current Ansible.
- RHEL 7 `yum` tasks in the slurm role, old molecule images, older
  `50-exclusive-gpu` epilog: master is simply older than 26.07 here.
- `playbooks/container/docker.yml`: master fixed the kubespray-defaults path
  (`kubespray-defaults/defaults/main/main.yml`); 26.07 ships its own fix for
  the newer kubespray (`kubespray_defaults/...`, underscore). Master's path
  does not exist in the kubespray version the branch carries.
- `playbooks/slurm-cluster.yml`: master commented out the nfs-server line.
  Upstream guards it with `slurm_enable_nfs_server`, which site config sets
  to `false`, so the line is left as upstream has it. Same effect.
- `playbooks/slurm-cluster.yml`: master adds `spack-modules.yml` guarded by
  `slurm_install_spack`. Not added, follows from deviation 5.
- `.gitmodules` / `submodules/`: master removed `packer-maas` and bumped
  kubespray; 26.07 carries its own submodule set (kubespray 2.31).
- `config/nvidia-mig-config.yml`: master deleted the `all-7g.80gb` profile
  from the example. Taken from the 26.07 example as is; `mig_manager_profile`
  is `all-disabled` so no profile is applied.
- Deleted upstream directories (k8s, DGX, PXE, virtual, ~8000 lines) are not
  deleted on this branch. Keeping the tree identical to the tag makes future
  upgrades a clean rebase.

### Behavior differences vs the running cluster

Changes the upgrade brings that we accept rather than pin back. Also listed
in the table above where a flip is possible.

- `KillWait` 30 -> 120 (see deviation 3).
- `nvidia-dcgm-exporter` container image: `2.1.8-2.4.0-rc.2-ubuntu20.04` ->
  `4.5.3-4.8.2-distroless` (role default; monitoring is enabled).
- `standalone-container-registry` image `registry:2.8` -> `3.1.1` and
  nginx cache proxy `0.6.4` -> `0.6.5`: both features are off in site config.
- Galaxy roles/collections move to the 26.07 pins (`ansible.posix`,
  `community.general`, `community.docker`, `devsec.hardening` replaces the
  old `dev-sec` roles). Run `scripts/setup.sh` or `ansible-galaxy install`
  against the new requirements before the first run.

## 2. Things to address after the port

Found while porting, deliberately left as on master. Not fixed because the
port should not change how things are done without consulting the other
admins.

**By priority:**

- **Blocking the first Slurm run:** no default partition after the phase-out
  (5a). herakles differs from every other node (5b).
- **Should be fixed soon:** Slurm passwords are the upstream placeholders (5b);
  dead per-host overrides in host_vars silently ignored (5a); nvtop builds an
  unpinned git HEAD (4b); apptainer pin does not match the nodes (4c).
- **Cleanup when convenient:** everything else below.

### Slurm role (commit c9d86ffc)

- `roles/slurm/templates/etc/slurm/slurm.conf` carries
  `# TODO create this as a fact` (joren, 2024-06-04): the partition-to-nodes
  map is built with Jinja dict tricks inside the template. Computing it in
  Ansible (`set_fact`) would be cleaner. Do it only once the branch can render
  slurm.conf, so byte-identical output can be proven.
- `roles/slurm/templates/etc/localgroups` (admin groups `sudo`,
  `teuwen-sudoers`) and `prolog.d/50-create-scratch` (`/processing` path)
  hardcode site values inside the role, as on master. Candidates for
  variables in `config/group_vars`.

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

### nvtop and motd (chunk 4b)

- `roles/nvtop` clones the Syllo/nvtop GitHub repository with `update: yes`
  and builds whatever HEAD is that day. Nodes can end up on different
  versions, and the cmake / make install tasks report "changed" on every run.
  Pinning a tag (gaia currently runs 3.1.0) would fix both. Reason the role
  exists: Ubuntu 22.04's packaged nvtop is 1.2.2, too old for current GPUs.
- `playbooks/slurm-cluster/nvtop.yml` sets a `has_gpus` fact from the custom
  `gpus` fact, but the nvtop role never reads it, so nvtop is also built on
  CPU-only nodes such as gaia.
- `roles/motd` installs its own copy of Ubuntu's `50-landscape-sysinfo`. On
  gaia that file is now a symlink to `/usr/share/landscape/landscape-sysinfo.wrapper`
  (dated 2026-01-05), so a package update replaced the role's file after the
  last motd run. The role would put its copy back on the next run.

### Apptainer (chunk 4c)

Ported as on master because nothing in 26.07 has the same name, but this
area has several leftovers that need a decision (update or remove).

- **Version drift.** `roles/apptainer/defaults/main.yml` pins 1.3.3. gaia
  runs 1.4.0 (installed from a .deb, so someone ran the role with a newer
  version or installed by hand). Current upstream release is 1.5.3. The pin
  should match what the nodes run, and belongs in `config/group_vars`
  rather than in the role's defaults.
- **Two container runtimes on the nodes.** Besides apptainer, gaia still has
  Singularity 3.7.1 in `/usr/local/bin/singularity` (config under
  `/usr/local/etc/singularity`) and Go 1.20.6 under `/opt/go`, both left by
  DeepOps' `singularity_wrapper` role before apptainer arrived. Apptainer
  ships its own `singularity` alias, so the old binary is shadowed only if
  `/usr/bin` wins in `PATH`. Candidate for removal once nobody depends on it.
- **Not wired into the top-level playbook.** `playbooks/container/apptainer.yml`
  is run by hand, on master and here. Adding it to `playbooks/slurm-cluster.yml`
  behind a variable would make apptainer part of a normal node build.
  (Singularity install is off since deviation 6; upstream's singularity
  playbook is broken in 26.07 anyway.)

### Spack and modules (chunk 4d, not ported)

- `roles/motd/templates/00-header.yml.j2` tells users "Loading of modules
  can be done using 'spack'", but Spack is not installed anywhere. Either
  remove the line or roll Spack out.
- Lmod on the nodes is version 6.6 (2016). Check what the upstream `lmod`
  role installs in 26.07 before the first run of the new branch.
- If Spack is rolled out later: upstream 26.07 pins v1.2.0 and installs the
  profile scripts only on the host that clones Spack (`slurm-master[0]`),
  while the install lives on shared NFS. Master's all-hosts play and zsh
  template (see deviation 5) would still be needed.

### Top-level playbook wiring (chunk 4e)

- `bootstrap-ssh.yml` and `bootstrap-sudo.yml` are disabled by commenting
  them out in `playbooks/slurm-cluster.yml`, as on master (joren, 2024-06-05,
  no reason given; the effect is that admins keep typing their password with
  `-K`, and nobody gets `NOPASSWD` sudo on all nodes as a side effect of a
  playbook run). Keeping sudo password-protected is sensible for a shared
  cluster. **Revisit after the port, during `--check` testing:** re-enabling
  only `bootstrap-ssh.yml` (key-based ssh for the admin running Ansible)
  would remove the `-k` / ssh friction while keeping the sudo policy. A
  variable guard defaulting to off would also be cleaner than commented lines.
- `playbooks/slurm-cluster/mount_scratch_disks.yml` and
  `playbooks/container/apptainer.yml` are not in the top-level playbook on
  master either; they only run when someone runs them by hand.

### Inventory and host_vars (chunk 5a)

- **Urgent, pre-existing on master: no default partition after the
  phase-out.** `partition_settings` marks `rtx2080ti_sm` as the default
  partition, but since e812a659 (2026-09-03) no active node in the
  inventory belongs to it (plato, schrodinger, carlos are commented out).
  The slurm.conf template only emits partitions that have nodes, so the next
  render, on either branch, produces a slurm.conf with no `Default=YES`
  partition and jobs submitted without `-p` are rejected. The live config on
  gaia still has the old 17-node layout. Pick a new default partition in
  `config/group_vars/slurm-cluster.yml` before running the Slurm playbook.
- `slurm_def_mem_per_cpu` and `slurm_max_job_timelimit` in
  `config/host_vars/*` are dead: the slurm.conf template reads both only
  from `partition_settings[<partition>]`. gaia (1900 vs 1000), galileo
  (3800 vs 7000, 20160 vs 10080), ptolemaeus (20160 vs 10080) and hamilton
  (6000 vs 5700) differ from their partition, so someone intended per-host
  overrides that never took effect. Either drop the host values or make the
  template honour them.
- `config/host_vars/{carlos,mariecurie,plato,schrodinger}` (with their
  `gpu_topology` overrides) describe phased-out nodes; remove once the nodes
  are gone for good.
- Upstream 26.07 adds `scripts/maas_inventory.py` to the inventory path in
  `ansible.cfg` (dynamic inventory from a Canonical MAAS server). Without
  MAAS credentials it returns an empty inventory and exits 0, so it is inert
  here. Left as upstream ships it; the static `config/inventory` remains the
  source of truth.

### Site config (chunk 5b)

- **herakles was not provisioned by the playbooks.** Unlike gaia, eudoxus and
  alanturing it has no NHC, no DCGM, no docker-ce, no exporters, and has
  `podman-docker` installed. Site config enables NHC, DCGM, monitoring and
  rsyslog for all nodes, so a full run against herakles would try to install
  docker-ce next to podman-docker (conflicting `docker` command) and deploy
  everything the other nodes have. Decide first whether herakles should be
  brought in line or excluded (host_vars: `install_dcgm: false`,
  `slurm_install_nhc: no`, ...).
- eudoxus has `docker.dcgm-exporter.service` and `docker.node-exporter.service`
  present but inactive; alanturing and gaia have them running.
- `slurm_password` / `slurm_db_password` are still the upstream placeholder
  strings, on master and here. They should live in an Ansible vault.
- `slurm_install_nhc: yes` with the default NHC config; the comment in the
  example recommends a site `nhc_config_template`.
- `slurm_enable_monitoring: true` but `[slurm-metric]` is empty (kosmos is
  commented out), so Prometheus/Grafana/Alertmanager have no target host and
  only the node/dcgm exporters get deployed.
