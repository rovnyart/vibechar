#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -x "$root/.tooling/cargo/bin/cargo" ]]; then
  export RUSTUP_HOME="$root/.tooling/rustup"
  export CARGO_HOME="$root/.tooling/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
cd "$root"
exec cargo "$@"
