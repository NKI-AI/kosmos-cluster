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
23.02 on Ubuntu 22.04 nodes.
