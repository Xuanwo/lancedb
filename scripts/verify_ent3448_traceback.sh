#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <evidence-dir>" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence_dir=$1
mkdir -p "$evidence_dir"

log_path="$evidence_dir/ent3448-sdk.log"
exit_path="$evidence_dir/ent3448-sdk.exit"
start_sha_path="$evidence_dir/ent3448-sdk.start-sha"
end_sha_path="$evidence_dir/ent3448-sdk.end-sha"

exec > >(tee -a "$log_path") 2>&1

write_exit() {
  local status=$1
  local temporary="$exit_path.tmp.$$"
  printf '%s\n' "$status" >"$temporary"
  mv "$temporary" "$exit_path"
}

finish() {
  local status=$?
  trap - EXIT
  git -C "$repo_root" rev-parse HEAD >"$end_sha_path"
  printf 'ENT3448_SDK_EXIT=%s\n' "$status"
  write_exit "$status"
  exit "$status"
}
trap finish EXIT

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"

cd "$repo_root"
git rev-parse HEAD | tee "$start_sha_path"
printf 'HOST=%s\n' "$(hostname)"
printf 'ARCH=%s\n' "$(uname -m)"
rustup show active-toolchain
mbx --version 2>/dev/null || true
uv --version
git status --short

run_step() {
  local name=$1
  shift
  printf '\nENT3448_STEP_START %s\n' "$name"
  "$@"
  printf 'ENT3448_STEP_PASS %s\n' "$name"
}

run_step rust_fmt mbx fmt --all -- --check
run_step python_fmt ruff format --check python/python/tests/test_remote_db.py python/python/lancedb/_lancedb.pyi
run_step python_lint ruff check python/python/tests/test_remote_db.py python/python/lancedb/_lancedb.pyi
run_step job_failure_legacy mbx test --quiet --features remote -p lancedb test_job_wait_surfaces_failure
run_step job_failure_traceback mbx test --quiet --features remote -p lancedb test_job_wait_reports_the_server_failure_reason
run_step function_error_traceback mbx test --quiet --features remote -p lancedb test_function_errors_lists_the_rows_a_refresh_skipped
run_step binding_check mbx check --quiet -p lancedb-python -p lancedb-nodejs

cd "$repo_root/python"
run_step python_extension uv run --extra tests --extra dev maturin develop --extras tests,dev
run_step python_jobs uv run --extra tests pytest python/tests/test_remote_db.py::test_remote_connection_jobs_surface -q
run_step python_function_errors uv run --extra tests pytest python/tests/test_remote_db.py::test_remote_function_errors_lists_the_rows_a_refresh_skipped -q

write_exit 0
