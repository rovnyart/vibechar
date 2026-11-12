#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bash scripts/cargo.sh fmt --all -- --check
bash scripts/cargo.sh clippy --workspace --all-targets --locked -- -D warnings
bash scripts/cargo.sh test --workspace --locked
bash scripts/cargo.sh build --release --workspace --locked
python3 scripts/test-terminal.py
python3 scripts/test-selection.py
python3 scripts/test-find.py
python3 scripts/test-tools.py
python3 scripts/test-multi.py
python3 scripts/test-history.py
python3 scripts/test-large.py
python3 scripts/test-handoff.py
if [[ "$(uname -s)" == "Darwin" ]]; then
  bash scripts/build-mac.sh
fi
