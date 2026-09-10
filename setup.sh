#!/usr/bin/env bash
# One-time setup for a fresh clone. Safe to re-run.
# Writes .env (HOST_UID/HOST_GID, so containers write results/ as you, not
# root), pre-creates results/gc-logs, and builds analysis/venv (PEP 668
# blocks a bare pip install on Ubuntu 24.04+).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "HOST_UID=$(id -u)" > .env
echo "HOST_GID=$(id -g)" >> .env
echo "[setup] wrote .env (HOST_UID=$(id -u) HOST_GID=$(id -g))"

mkdir -p results/gc-logs
echo "[setup] results/gc-logs ready, owned by $(id -un)"

if [ ! -d analysis/venv ]; then
    python3 -m venv analysis/venv
    echo "[setup] created analysis/venv"
fi
analysis/venv/bin/pip install -q --upgrade pip
analysis/venv/bin/pip install -q -r analysis/requirements.txt
echo "[setup] analysis dependencies installed into analysis/venv"

cat <<'EOF'

[setup] Done. Next:
    docker compose build
    cd load-testing && ./run-smoke-test.sh        # verify the pipeline end-to-end
    # then, for the full suite:
    ./run-suite.sh
    ../analysis/venv/bin/python3 ../analysis/analyze-results.py
EOF