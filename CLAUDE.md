# Kosmos cluster (DeepOps fork)

Read these first, in this order:

1. `AGENTS.md` - upstream DeepOps operating guide: repository map, golden
   paths, operating rules, gotchas. Applies to this fork as is.
2. `docs/kosmos/porting-notes.md` - everything that is specific to the KOSMOS
   Slurm cluster: how this branch relates to upstream and to `master`, every
   deviation and why, open issues by priority, and the test recipe.
3. `skills/*/SKILL.md` - step-by-step procedures (deploy, validate, diagnose
   driver installs) when doing one of those tasks.

Site facts not in those files: the Ansible node is teuwen-ansible (Ubuntu
24.04), the shared venv is `/opt/kosmos-cluster/env`, sudo on cluster nodes
requires a password (run playbooks with `-K`), and the cluster runs Slurm
23.02 on Ubuntu 22.04 nodes until the clean reinstall from 2026-10-05, after
which it runs Slurm 26.05.4 on Ubuntu 24.04 with the HWE 7.0 kernel
(`docs/kosmos/reinstall-runbook.md`).

Agents do not run on teuwen-ansible (IT security decision, 2026-09-29). An
agent works in an admin's clone on another host and checks changes there with
a copy of env-26.07: `bash scripts/kosmos/check-env.sh` builds
`~/.venvs/env-26.07` with the `scripts/setup.sh` pins, the Galaxy content and
the submodules. Use it only for `ansible-lint`, `--syntax-check`,
`--list-tasks` and `ansible-inventory`, never to contact a host. Pipe
`ansible-playbook` output (`| cat`) when stdout is not a terminal. The admin
pulls and runs every playbook on teuwen-ansible and pastes the output back;
never assume a run happened without it.
