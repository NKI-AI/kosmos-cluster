# Kosmos porting notes: DeepOps 26.07 branch

Branch `deepops-26.07` rebuilds this fork as **NVIDIA DeepOps tag 26.07 plus a
small set of overlay commits**. The overlay ports what is on `master` (fork
point: DeepOps 23.08, commit d248b658). This file records every place where the
branch deliberately differs from `master`, and why, so the other admins can
review each decision and flip it back if they disagree. Each entry names the
commit that introduced it.

Rule used while porting: port `master` as is. Deviate only with a stated
reason, and record it here. Design changes that nobody has asked for are
shelved (listed at the end), not applied.

## Deviations from master

| # | Where | Branch does | Master does | Why | Commit |
|---|-------|-------------|-------------|-----|--------|
| 1 | `scripts/setup.sh` | venv default `/opt/kosmos-cluster/env` | venv in `./env` (upstream default) | Shared checkout and venv on teuwen-ansible, one environment for all admins | b084b7f1 |
| 2 | `roles/slurm/defaults/main.yml` | untouched upstream file | overrides `deepops_dir`, `slurm_build_dir`, `hwloc_build_dir`, `pmix_build_dir`, `hwloc_install_prefix`, `pmix_install_prefix` to `/opt/kosmos-cluster/...` and `slurm_cluster_name: kosmos` | Site values belong in `config/group_vars`, not in a vendored role; same values will be set there (site config chunk) | c9d86ffc |
| 3 | `roles/slurm/templates/etc/slurm/slurm.conf` | `KillWait=120` (upstream 26.07 value) | `KillWait=30` | 30 was the 23.08 default, not a site choice. Upstream raised it in Sept 2024 for more graceful job termination. Behavior change: jobs get 120 s instead of 30 s between SIGTERM and SIGKILL. Flip: set `KillWait=30` in the template | c9d86ffc |
| 4 | `playbooks/slurm-cluster/slurm.yml` | keeps `roles: [facts]` in the first play, in addition to the fact-gathering pre_task | removed the role, keeps only the pre_task | The role installs the custom fact scripts (`topology`, `memory`, `gpus`) that slurm.conf needs. Master relies on other playbooks having installed them. On existing nodes the role is a no-op (scripts unchanged since 23.08). Flip: delete the `roles:` block | 00ae45d2 |

## Not ported from master (already superseded upstream)

These master changes were not carried over because 26.07 already contains the
same fix or removed the code in question.

- `include:` in playbooks and roles. Removed in ansible-core 2.16; 26.07 uses
  `import_playbook` / `include_tasks` everywhere. Master's top-level
  `playbooks/slurm-cluster.yml` still uses `include:` and no longer runs on
  current Ansible.
- RHEL 7 `yum` tasks in the slurm role, old molecule images, older
  `50-exclusive-gpu` epilog: master is simply older than 26.07 here.

## Known behavior differences vs the running cluster

Things the upgrade changes even though we did not decide them. To be
completed as chunks are ported.

- `KillWait` 30 -> 120 (see deviation 3).

## Observations for later (not changed)

- `config/host_vars/{carlos,gaia,galileo,plato,ptolemaeus}` set
  `slurm_max_job_timelimit`, but the slurm.conf template only reads
  `partition_settings[<partition>].slurm_max_job_timelimit`, so those host
  values have no effect. Candidate for cleanup in the site config chunk.
- `slurm.conf` partition loop carries a `# TODO create this as a fact`
  (joren, 2024-06-04). The partition-to-nodes map could be computed in
  Ansible instead of Jinja. Not done: byte-identical output cannot be proven
  until the branch can render slurm.conf.
- `roles/slurm/templates/etc/localgroups` (admin groups) and
  `prolog.d/50-create-scratch` (`/processing` path) hardcode site values
  inside the role, as on master.

## Shelved suggestions

Ideas raised during the port and deliberately not applied, because they
change how things are done and the other admins have not been consulted.

- `run_once: true` on the "Gather facts from ALL hosts" pre_task in
  `playbooks/slurm-cluster/slurm.yml`, so one host does the delegated
  gathering instead of every host in the play.
