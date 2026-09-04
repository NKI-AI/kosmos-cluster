# Kosmos porting notes: DeepOps 26.07 branch

Branch `deepops-26.07` rebuilds this fork as **NVIDIA DeepOps tag 26.07 plus a
small set of overlay commits**. The overlay ports what is on `master` (fork
point: DeepOps 23.08, commit d248b658). Contents:

- **Before the first run**: the test recipe.
- **Check-run results**: what each `--check --diff` run showed, per date and node.
- **Running playbooks from teuwen-ansible**: how ssh authentication works
  (Kerberos, not keys), which hosts are the exception, ticket expiry.
- **1. Conscious deviations from master**: every place where the branch
  deliberately differs from `master`, why, and the commit. Other admins can
  review each row and flip it back if they disagree.
- **2. Things to address after the port**: problems and oddities found while
  porting that were left as they are on master, by priority.

Rule used while porting: port `master` as is. Deviate only with a stated
reason, and record it here. Design changes that nobody has asked for are
not applied; they go into section 2.

**Status (2026-09-04):** port complete; env-26.07 built, syntax checks pass, `--check` runs starting. Everything on `master` up
to e812a659 has been ported, dropped with a row below, or superseded upstream.

## Before the first run

Do these in order, on teuwen-ansible. Steps 1 and 2 are done (2026-09-04).

1. Build the 26.07 environment next to the shared one, without touching
   `/opt/kosmos-cluster/env` (ansible-core 2.16, in use by the other admins):
   `VENV_DIR=/opt/kosmos-cluster/env-26.07 bash scripts/setup.sh`. This gives
   ansible 10.7 / core 2.17 and installs the 26.07 Galaxy roles and
   collections into `roles/galaxy` and `collections` (both gitignored; the
   old `roles/galaxy` from 23.08 is not compatible). Roles and collections
   both come from `roles/requirements.yml`; there is no
   `collections/requirements.yml` in 26.07. Use `bash scripts/setup.sh`, not
   `./scripts/setup.sh`: the shebang is `bash --init-file`, so executing it
   directly leaves you in a new interactive shell. Two harmless messages:
   "Package(s) not found: ansible" (the version check on an empty venv) and
   the fact-cache warning below. The script also appends a `source .../activate`
   line to your `.bashrc`.
2. `source /opt/kosmos-cluster/env-26.07/bin/activate` for everything below.
3. Fix the default partition (section 2, "Urgent"). Done: `rtx2080ti`.
4. herakles: included in the tests as a normal node (decided 2026-09-04;
   see section 2, "Site config" for what a real run would change on it).
5. `ansible-playbook playbooks/slurm-cluster.yml --syntax-check`.
6. `ansible-playbook -kK --check --diff --limit gaia playbooks/slurm-cluster/slurm.yml`
   (`-k` for atlas and kosmos). **Blocked 2026-09-04**: kosmos refuses admin
   accounts, see "Running playbooks from teuwen-ansible". Note also that
   with `slurm_conf_symlink: true` slurm.conf is rendered only on atlas into
   `/sw/.slurm`; compute nodes get a symlink, so a gaia-only run shows the
   other role-managed files but not slurm.conf. Alternative while blocked:
   render the template locally with an ad-hoc play that gathers facts from
   `slurm-node` and diff against `/sw/.slurm/slurm.conf`. Expected
   differences: `KillWait`, the phased-out nodes disappearing, the default
   partition moving to rtx2080ti.
6b. While slurm.yml is blocked, `--check --diff` the playbooks the top-level
   playbook imports that do not need atlas or kosmos, limited to compute
   nodes (`--limit gaia,herakles` first, then all of `slurm-node`):
   `nvidia-software/nvidia-driver.yml` (must report no change with the
   per-host pins), `generic/software.yml`, `generic/chrony-client.yml`,
   `slurm-cluster/nhc.yml`, `nvidia-software/nvidia-dcgm.yml`,
   `generic/rsyslog-client.yml`, `slurm-cluster/prometheus-node-exporter.yml`,
   `slurm-cluster/nvidia-dcgm-exporter.yml`. These are where the 26.07 roles
   differ most from 23.08. Pass all playbooks to one `ansible-playbook`
   invocation so `-K` asks once. gaia may fail at fact gathering (section 2,
   "Fact gathering fails ..."); use herakles and eudoxus first.
7. Only then consider a real run, playbook by playbook, starting with the
   ones that are idempotent on the current nodes (motd, nvtop, create_mounts).

## Running playbooks from teuwen-ansible

Checked on 2026-09-04 from kosmas-ans's account; other admins should see the
same, but verify with `klist` and `ssh -v <node> true` if in doubt.

**ssh to the nodes uses Kerberos, not keys.** teuwen-ansible and the nodes
are joined to the `RHPC.NKI.NL` realm (sssd). Logging in gives you a ticket
(`klist`), and ssh authenticates with it over GSSAPI (`ssh -v gaia true`
shows `Authenticated to gaia using "gssapi-with-mic"`). Ansible runs the
same ssh, so it connects the same way: an ad-hoc `ansible gaia,herakles -m
ping` succeeds with no key file and no `-k`. Nobody needs to generate or
distribute ssh keys for the compute nodes, and every admin keeps their own
identity for free.

- **Tickets expire after about a day** (see the `krbtgt` line in `klist`).
  Interactive ssh then silently falls back to a password prompt; Ansible
  cannot answer one and fails with "Permission denied (publickey,gssapi...)"
  on every host. Run `kinit` and retry.
- **No `~/.ssh` needed on teuwen-ansible.** Upstream's `ansible.cfg` put
  the ssh control sockets in `~/.ssh/ansible-...`, which does not exist on a
  fresh account (homes on teuwen-ansible are local, not the NFS home the
  nodes share, and Ansible never writes `known_hosts` there). Plain ssh
  worked, the playbook did not. Likely cause of the "ssh works but the
  playbook cannot connect" seen on 2026-09-03 (not confirmed from the error
  text; the directory appeared when an `ssh-keygen` created it). Fixed on
  this branch by dropping the override (deviation 0c): sockets now go to
  `~/.ansible/cp`, which Ansible creates itself. No key pair is needed either
  (the one upstream play that wanted a `.pub` file is off, see below).
- **atlas and kosmos are the exception.** Both offer GSSAPI but reject the
  ticket, then fall through to password. Runs that touch them need `-k`
  (the first play of `playbooks/slurm-cluster/slurm.yml` gathers facts from
  every inventory host, so `-k` is needed there even with `--limit gaia`),
  or a key in your `authorized_keys` on those two hosts. Why the controller
  and login node behave differently from the compute nodes is an open
  question for the admins. **kosmos currently refuses admin accounts
  altogether (2026-09-04):** kosmas-ans and at least one other admin's
  `-ans` account are denied with password and Kerberos alike (PAM denies
  the account, the password prompt just repeats); regular user accounts get
  in. Probably an access restriction set by central IT; the cluster admins
  have no root on kosmos to check. The shared slurm.conf was last rendered
  2025-12-08, so it worked then. Any `slurm.yml` run, on this branch or on
  master, needs kosmos (fact gathering from every inventory host, and
  kosmos is in `slurm-login`), so **the Slurm playbook is blocked for
  everyone until admin access to kosmos is restored**. Being handled outside
  this branch. atlas takes the password.
- **Sudo on the nodes needs a password**: always `-K`. Same password as for
  `-k`.
- Node home directories are NFS from rhea, shared by all nodes; an
  `authorized_keys` entry made on one node applies to all of them. Your home
  on teuwen-ansible is separate.

**Two upstream places that assume keys; both need a decision:**

- `playbooks/slurm-cluster/slurm.yml`, second play, "Add SSH public key to
  root user authorized keys": upstream puts the running admin's public key
  (default `~/.ssh/id_rsa.pub`) into root's `authorized_keys` on every
  compute node, so every admin who runs the Slurm playbook gets passwordless
  root ssh everywhere, and the play fails when the file does not exist.
  **Off on this branch** (deviation 12, `slurm_add_root_ssh_key: false`).
  Nothing needs it: no playbook logs in as root, and pam_slurm_adopt does not
  block admins because their groups are in `/etc/localgroups`.
- `playbooks/bootstrap/bootstrap-ssh.yml` installs the admin's key on all
  hosts so that `-k` is not needed. With Kerberos that is redundant for the
  compute nodes; keep it disabled (it is, see section 2). If atlas and kosmos
  cannot be brought in line, a key on those two hosts is the fallback.

**Environments on teuwen-ansible (until the branch is merged):**
`/opt/kosmos-cluster/env` (ansible-core 2.16, master, other admins) and
`/opt/kosmos-cluster/env-26.07` (ansible-core 2.17, this branch). Both stay
until the merge; then the old one goes. The root disk of teuwen-ansible was
95 % full (1.6 GB free) on 2026-09-04.

## Check-run results

### 2026-09-04, herakles and eudoxus, `--check --diff`, env-26.07

Nine playbooks in one invocation (nvtop, motd, mount_scratch_disks,
nvidia-driver, software, chrony-client, rsyslog-client, nhc, nvidia-dcgm);
the run stopped at nvidia-dcgm on herakles, so prometheus-node-exporter and
nvidia-dcgm-exporter are still untested. Log: `~kosmas-ans/check-all.log`.
No playbook failed for a reason related to the port. What a real run would
change:

- **No change (good):** rsyslog-client on both; nvidia-driver, chrony and
  nvidia-dcgm on eudoxus (the per-host driver pins do what deviation 11
  says). mount_scratch_disks reported no change, but its `exportfs`/`mount -a`
  command tasks are skipped in check mode, so that says nothing yet.
- **nvtop, both nodes:** the git clone reports a change (unpinned HEAD,
  section 2). Build steps skipped in check mode.
- **motd, both nodes:** the role would overwrite Ubuntu's current
  `50-landscape-sysinfo` (a symlink to the caching wrapper) with its own
  older copy. Same on gaia (section 2). Recommendation: drop that task from
  `roles/motd`; only `00-header` is site content.
- **nvidia-driver, herakles: would reboot the node.** herakles was
  hand-driven with the `nvidia-driver-580-server` metapackage (a
  `nvidia-driver-570-server` metapackage is still installed next to it);
  the role's package list is `nvidia-headless-580-server`,
  `nvidia-headless-no-dkms-580-server`, `nvidia-utils-580-server`,
  `nvidia-kernel-source-580-server`. The two headless metapackages are
  missing ("0 upgraded, 2 newly installed", no driver change), the role
  would also create an empty `/etc/modprobe.d/nvidia.conf`, and because
  packages changed it triggers its reboot task
  (`nvidia_driver_skip_reboot: no`). Before the first real driver run on
  herakles either install the two metapackages by hand or run with
  `-e nvidia_driver_skip_reboot=yes`, then verify with a check run that the
  role is idle.
- **software, both nodes:** `dcmtk` (in `software_extra_packages`) is not
  installed on either node; herakles also lacks `linux-tools-generic`. So
  software.yml has not run since dcmtk was added. Harmless to apply.
- **chrony-client, herakles:** still on Ubuntu's stock `chrony.conf`
  (`ntp.ubuntu.com` pools); the role would switch it to the site template
  (`0-3.pool.ntp.org` from `chrony_config_server`, `makestep 10 3`) and
  restart chrony, which is what eudoxus already runs. Fine, unless the
  admins prefer an NKI-internal NTP server, in which case set
  `chrony_config_server` first.
- **nhc, herakles:** full first install (deepops.nhc checks, nhc.conf,
  sysconfig with `NHC_RM=slurm`), which is the intended state (section 2).
  **nhc, eudoxus:** `nhc.conf` changes by 1 MB in the `check_hw_physmem`
  bounds (26.07 template rounding) and the commented-out `check_hw_eth`
  lines are reordered and gain the docker bridge. Cosmetic.
- **nvidia-dcgm, herakles: check-mode artifact, not a bug.** The role
  "installs" the CUDA keyring .deb (check mode does not really add the apt
  source), so the following `apt install datacenter-gpu-manager` finds no
  such package. A real run installs `datacenter-gpu-manager` 1:3.3.9, the
  same as on gaia (checked with `apt-cache policy` there). To get past it in
  check mode, install the keyring on herakles by hand first, or accept the
  failure and run the exporter playbooks separately.

## 1. Conscious deviations from master

| # | Where | Branch does | Master does | Why | Commit |
|---|-------|-------------|-------------|-----|--------|
| 0a | `ansible.cfg` | `pipelining = True` (upstream) | `pipelining = False` (EricMarcus-ai, 2024-06-03, "Disable ansible pipelining", no reason given) | Pipelining halves the SSH round-trips per task. It only fails when sudo enforces `requiretty`, which the nodes do not (checked on gaia). Flip: set `pipelining = False` | (not applied, branch keeps upstream) |
| 0b | `ansible.cfg` | no `[galaxy]` section (upstream) | `[galaxy] server = https://old-galaxy.ansible.com/` (Musab, 2023-11-02) | Temporary workaround from the late-2023 Galaxy migration; the host no longer serves content and 26.07 requirements resolve on galaxy.ansible.com. Flip: re-add the section | (not applied, branch keeps upstream) |
| 0c | `ansible.cfg` | no `control_path` override: ssh control sockets go to Ansible's default `~/.ansible/cp`, which Ansible creates itself | upstream (since the 2018 initial commit, no reason given): `control_path = ~/.ssh/ansible-%%r@%%h:%%p` | With the upstream setting Ansible fails on a fresh account until `~/.ssh` exists, and nothing creates it (`UserKnownHostsFile=/dev/null` in the same file means ssh never writes `known_hosts` there either). Bit kosmas-ans on 2026-09-03. Where the sockets live makes no functional difference. Flip: restore the line and `mkdir -m 700 ~/.ssh` | chunk 7 |
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

| 12 | `playbooks/slurm-cluster/slurm.yml`, `config/group_vars/slurm-cluster.yml` | the "Add SSH public key to root user authorized keys" task runs only when `slurm_add_root_ssh_key` is true (site config: false) | upstream: unconditional (since 2020) | The play puts the running admin's `~/.ssh/id_rsa.pub` into root's `authorized_keys` on every compute node, and fails when that file does not exist. Neither is wanted here: no playbook logs in as root (Ansible connects as the admin over Kerberos and uses sudo), and the play's purpose, getting past pam_slurm_adopt, does not apply because the admin groups are in `/etc/localgroups`. Flip: set the variable to true and provide a key | chunk 7 |

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

- **Blocking the first Slurm run:** admin accounts cannot log in to kosmos
  (see "Running playbooks from teuwen-ansible"); not a branch issue, being
  handled with IT. (The missing default partition, 5a, is fixed on this
  branch; herakles turned out to be a normal node with two playbooks never
  run against it, 5b.)
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

### Ansible node (found while building env-26.07)

- `ansible.cfg` sets `fact_caching_connection = /var/tmp/ansible_cache`, but
  on teuwen-ansible that directory is `root:teu-ansible` mode 0700, so every
  admin gets "error in 'jsonfile' cache ... disabling plugin" and facts are
  gathered on every run instead of being cached. Harmless, but slow. Fix
  once the shared setup is decided: make the directory group-writable for the
  admin group, or point the cache at a per-user path.

### Fact gathering fails on nodes with many NFS submounts (found 2026-09-04)

- On gaia, `Gathering Facts` fails with `[Errno 24] Too many open files`
  from `udevadm info ... rhea:/project-pool/network_homes/<user>`, and the
  play stops for that host. Cause: Ansible's mount-facts collector runs one
  `udevadm` per mount entry in a thread pool of `min(mounts, cpu_count)`
  threads. gaia has 256 CPUs and 300+ mounts (273 NFSv4 submounts under
  `/projects`, one per project dataset touched, plus one per user home:
  rhea exports with crossmnt), and the ssh session's soft `nofile` limit is
  1024. The other nodes have ~50 mounts and are fine. The count fluctuates
  with user activity (submounts expire after `nfs_mountpoint_timeout`, 500 s,
  when unused), which is why the same step can pass at one moment and fail
  ten minutes later. **Not an upgrade regression:** ansible-core 2.16 in the
  old env fails identically. Roles that need hardware facts:
  `roles/nhc/templates/nhc.conf.j2` (`ansible_memtotal_mb`); the slurm.conf
  template uses only the custom facts.
- Fix options: (a) raise the soft `nofile` limit for login sessions on the
  nodes, e.g. `/etc/security/limits.d/90-nofile.conf` with
  `* soft nofile 65536` (hard limit is already 1048576; new ssh sessions
  only, so let Ansible's 5-minute control sockets expire first). Nothing in
  the repo manages limits today; this would be a small site addition.
  (b) `gather_subset: "!hardware"` for playbooks that do not need hardware
  facts (works, verified), not usable for nhc.yml. Prefer (a).
- Until fixed, run `--check` tests against nodes with few mounts
  (herakles, eudoxus, alanturing) and treat a gaia fact-gathering failure as
  this issue, not as a playbook problem.

### Top-level playbook wiring (chunk 4e)

- `bootstrap-ssh.yml` and `bootstrap-sudo.yml` are disabled by commenting
  them out in `playbooks/slurm-cluster.yml`, as on master (joren, 2024-06-05,
  no reason given; the effect is that admins keep typing their password with
  `-K`, and nobody gets `NOPASSWD` sudo on all nodes as a side effect of a
  playbook run). Keeping sudo password-protected is sensible for a shared
  cluster. **Resolved 2026-09-04:** ssh to the compute nodes works through
  Kerberos (see "Running playbooks from teuwen-ansible"), so re-enabling
  `bootstrap-ssh.yml` gains nothing there; the `-k` friction comes only from
  atlas and kosmos. Keep both disabled. A variable guard defaulting to off
  would still be cleaner than commented lines.
- `playbooks/slurm-cluster/mount_scratch_disks.yml` and
  `playbooks/container/apptainer.yml` are not in the top-level playbook on
  master either; they only run when someone runs them by hand.

### Inventory and host_vars (chunk 5a)

- **Fixed on this branch, still open on master: no default partition after
  the phase-out.** `partition_settings` marked `rtx2080ti_sm` as the default
  partition, but since e812a659 (2026-09-03) no active node in the
  inventory belongs to it (plato, schrodinger, carlos are commented out).
  The slurm.conf template only emits partitions that have nodes, so the next
  render on master produces a slurm.conf with no `Default=YES` partition and
  jobs submitted without `-p` are rejected. The live config on gaia still has
  the old layout with `rtx2080ti_sm` as default. This branch moves
  `default: true` to `rtx2080ti` (alanturing, hamilton), the closest match to
  the old default: the smallest GPU partition, so a forgotten `-p` lands
  somewhere cheap. Tell users, and update any documentation that names the
  default partition, before the first real Slurm run.
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

- **Nodes are not uniform: each one reflects the playbooks that were run by
  hand when it was last (re)provisioned.** Master's top-level
  `playbooks/slurm-cluster.yml` has not run on current Ansible for years
  (`include:` syntax), so admins ran individual playbooks, and skipped
  different ones on different nodes. Verified on the nodes 2026-09-04:
  - **herakles** was provisioned with the master roles on 2024-07-06/07
    (commit 5dce9a27): custom facts, Slurm built under
    `/opt/kosmos-cluster/build`, site prolog/epilog scripts, enroot,
    apptainer 1.3.3 (the role's pin), nvtop, motd, rsyslog forwarding, the
    fstab mount block, slurm.conf symlink. Never run against it: `nhc.yml`
    and `nvidia-dcgm.yml`, so it has no NHC and no DCGM although site config
    enables both. Consequence today: the shared slurm.conf sets
    `HealthCheckProgram=/usr/sbin/nhc`, which does not exist on herakles, so
    it is the only compute node whose health checks cannot run. A full run of
    the new branch would install both, which is the intended state. Also
    `podman-docker` (installed by hand 2025-08-07) provides `/usr/bin/docker`;
    it only conflicts with `playbooks/container/docker.yml`, which is not in
    the top-level playbook and must not be run against herakles until
    podman-docker is removed or docker-ce is decided against.
  - **eudoxus** (provisioned 2024-08) has docker-ce, NHC and DCGM but no
    running node exporter (`docker.node-exporter.service` present, inactive);
    the dcgm-exporter unit is also inactive. gaia (rebuilt 2025-02) and
    alanturing run both. `prometheus-node-exporter.yml` and
    `nvidia-dcgm-exporter.yml` were not (re)run on eudoxus.
  - docker-ce is on gaia and eudoxus only because someone ran
    `playbooks/container/docker.yml` by hand; no top-level playbook installs
    it on either branch. The node exporter and dcgm exporter run as docker
    containers, so a node without docker-ce gets no exporters.
  - The first `--check --diff` run of the new branch against all nodes will
    list these gaps per node; that output is the to-do list for bringing the
    nodes back in line.
- `slurm_password` / `slurm_db_password` are still the upstream placeholder
  strings, on master and here. They should live in an Ansible vault.
- `slurm_install_nhc: yes` with the default NHC config; the comment in the
  example recommends a site `nhc_config_template`.
- `slurm_enable_monitoring: true` but `[slurm-metric]` is empty (kosmos is
  commented out), so Prometheus/Grafana/Alertmanager have no target host and
  only the node/dcgm exporters get deployed.
