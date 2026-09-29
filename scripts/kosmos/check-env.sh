#!/usr/bin/env bash
# Build a local Ansible environment for lint and syntax checks, off the cluster.
#
# Mirrors /opt/kosmos-cluster/env-26.07 on teuwen-ansible: the pip pins are
# read from scripts/setup.sh (so they cannot drift), Python is 3.12 like
# Ubuntu 24.04, and the Galaxy roles and collections come from
# roles/requirements.yml into this checkout, as in the README, plus the git
# submodules. No sudo, no apt, no .bashrc edit. Needs uv.
#
# Only for checks that never contact a host: ansible-lint, --syntax-check,
# --list-tasks, ansible-inventory. Playbooks run on teuwen-ansible only.
#
# Usage: bash scripts/kosmos/check-env.sh     (again whenever the pins change)
#        source ~/.venvs/env-26.07/bin/activate

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_DIR="${VENV_DIR:-${HOME}/.venvs/env-26.07}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

# Default of NAME="${NAME:-value}" in scripts/setup.sh
pin() {
    local value
    value="$(sed -n "s/^$1=\"\\\${$1:-\([^}]*\)}\".*/\1/p" "${ROOT_DIR}/scripts/setup.sh")"
    if [ -z "${value}" ]; then
        echo "Cannot read $1 from scripts/setup.sh" >&2
        exit 1
    fi
    echo "${value}"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi

uv venv --quiet --clear --managed-python --python "${PYTHON_VERSION}" "${VENV_DIR}"
uv pip install --quiet --python "${VENV_DIR}/bin/python" \
    "ansible==$(pin ANSIBLE_VERSION)" \
    "ansible-lint==$(pin ANSIBLE_LINT_VERSION)" \
    "Jinja2==$(pin JINJA2_VERSION)" \
    netaddr \
    packaging \
    ruamel.yaml \
    PyMySQL \
    passlib \
    paramiko \
    "jmespath==$(pin JMESPATH_VERSION)" \
    "MarkupSafe==$(pin MARKUPSAFE_VERSION)" \
    selinux

cd "${ROOT_DIR}"
"${VENV_DIR}/bin/ansible-galaxy" install -r roles/requirements.yml
# slurm-cluster.yml imports container/docker.yml, which needs kubespray's roles
git submodule update --init

echo
"${VENV_DIR}/bin/ansible" --version | head -1
"${VENV_DIR}/bin/ansible-lint" --version 2>/dev/null | head -1
echo "Activate with: source ${VENV_DIR}/bin/activate"
