#!/usr/bin/env bash

# Tests for github-action.sh. The script is executed end-to-end with stub "gh" and "go-coverage-report" binaries on the
# PATH. The stubs serve fixtures from a temporary directory and log every call, so the tests can assert which baseline
# run was selected and whether a pull request comment was posted.
#
# Usage:
#     bash scripts/github-action_test.sh

set -u -o pipefail

type jq > /dev/null 2>&1 || { echo >&2 'ERROR: Tests require "jq"'; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACTION_SCRIPT="$SCRIPT_DIR/github-action.sh"

CURRENT_RUN_ID=999
PULL_REQUEST_NUMBER=42

# write_stubs creates the stub "gh" and "go-coverage-report" binaries in $1.
write_stubs(){
  local bin_dir=$1

  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
# Stub of the GitHub CLI. Fixtures are read from $FAKE_DIR:
# - runs.json:          the run list returned by "gh run list" without the --status=success filter
# - stale_runs.json:    the run list returned by "gh run list --status=success" (emulates GitHub's stale results)
# - artifacts/<id>.json the response of "gh api repos/<repo>/actions/runs/<id>/artifacts"
# - downloadable:       IDs of runs whose coverage artifact "gh run download" can download, one per line
set -u
echo "gh $*" >> "$FAKE_DIR/calls.log"

query=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-q" ]; then
    next=$((i + 1))
    query=${!next}
  fi
done

output_json(){
  if [ -n "$query" ]; then
    jq -r "$query" "$1"
  else
    cat "$1"
  fi
}

case "$1 $2" in
  "run list")
    if [[ " $* " == *" --status=success "* ]]; then
      output_json "$FAKE_DIR/stale_runs.json"
    else
      output_json "$FAKE_DIR/runs.json"
    fi
    ;;
  "run download")
    run_id=$3
    dir=""
    for arg in "$@"; do
      case "$arg" in --dir=*) dir=${arg#--dir=} ;; esac
    done
    if ! grep -qx "$run_id" "$FAKE_DIR/downloadable"; then
      echo "no valid artifacts found to download" >&2
      exit 1
    fi
    mkdir -p "$dir"
    echo "mode: set" > "$dir/coverage.txt"
    ;;
  "api repos/"*)
    case "$2" in
      */actions/runs/*/artifacts)
        run_id=${2%/artifacts}
        run_id=${run_id##*/}
        output_json "$FAKE_DIR/artifacts/$run_id.json"
        ;;
      */issues/*/comments)
        echo '[]' > "$FAKE_DIR/comments.json"
        output_json "$FAKE_DIR/comments.json"
        ;;
      *)
        echo "stub gh: unexpected api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "pr comment")
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
EOF

  cat > "$bin_dir/go-coverage-report" <<'EOF'
#!/usr/bin/env bash
echo "go-coverage-report $*" >> "$FAKE_DIR/calls.log"
echo "| Impacted Packages | Coverage Δ |"
EOF

  chmod +x "$bin_dir/gh" "$bin_dir/go-coverage-report"
}

# write_artifacts writes the artifact list fixture of run $1 with a single artifact of name $2 and expiry state $3.
write_artifacts(){
  local run_id=$1 name=$2 expired=$3
  echo "{\"total_count\":1,\"artifacts\":[{\"id\":${run_id}0,\"name\":\"$name\",\"expired\":$expired}]}" \
    > "$FAKE_DIR/artifacts/$run_id.json"
}

# write_no_artifacts writes an empty artifact list fixture for run $1 (artifacts are deleted after they expire).
write_no_artifacts(){
  echo '{"total_count":0,"artifacts":[]}' > "$FAKE_DIR/artifacts/$1.json"
}

# run_action executes github-action.sh in a fresh working directory and stores its exit code and output.
run_action(){
  local work_dir="$TEST_DIR/work"
  mkdir -p "$work_dir/.github/outputs"
  echo '["foo/foo.go"]' > "$work_dir/.github/outputs/all_modified_files.json"
  : > "$TEST_DIR/github_output"

  ACTION_OUTPUT=$(
    cd "$work_dir" &&
    env -u GITHUB_BASELINE_WORKFLOW_REF \
      PATH="$TEST_DIR/bin:$PATH" \
      FAKE_DIR="$FAKE_DIR" \
      GITHUB_OUTPUT="$TEST_DIR/github_output" \
      GITHUB_BASELINE_WORKFLOW="build.yml" \
      TARGET_BRANCH="main" \
      ROOT_PACKAGE="example.com/repo" \
      PROJECT_PATH="app" \
      TRIM_PACKAGE="" \
      SKIP_COMMENT="${SKIP_COMMENT:-false}" \
      bash "$ACTION_SCRIPT" "example/repo" "$PULL_REQUEST_NUMBER" "$CURRENT_RUN_ID" 2>&1
  )
  ACTION_EXIT_CODE=$?
}

# Default fixtures: the server-side --status=success filter returns stale run 100, whose artifact was deleted, while
# the actual run list contains newer runs in various states with run 200 being the newest successful one.
setup_stale_status_success_filter(){
  echo '[{"databaseId":100,"status":"completed","conclusion":"success"}]' > "$FAKE_DIR/stale_runs.json"
  cat > "$FAKE_DIR/runs.json" <<'EOF'
[
  {"databaseId":300,"status":"in_progress","conclusion":""},
  {"databaseId":250,"status":"completed","conclusion":"cancelled"},
  {"databaseId":200,"status":"completed","conclusion":"success"},
  {"databaseId":100,"status":"completed","conclusion":"success"}
]
EOF
  write_no_artifacts 100
  write_artifacts 200 code-coverage false
  printf '%s\n' "$CURRENT_RUN_ID" 200 > "$FAKE_DIR/downloadable"
}

test_github_action_stale_status_success_filter_uses_newest_successful_run(){
  setup_stale_status_success_filter
  run_action

  assert_exit_code 0
  assert_called "gh run download 200 "
  assert_not_called "gh run download 100 "
  assert_called "go-coverage-report "
  assert_called "gh pr comment $PULL_REQUEST_NUMBER "
}

test_github_action_newest_success_artifact_expired_falls_back_to_older_run(){
  echo '[{"databaseId":100,"status":"completed","conclusion":"success"}]' > "$FAKE_DIR/stale_runs.json"
  cat > "$FAKE_DIR/runs.json" <<'EOF'
[
  {"databaseId":200,"status":"completed","conclusion":"success"},
  {"databaseId":150,"status":"completed","conclusion":"success"},
  {"databaseId":100,"status":"completed","conclusion":"success"}
]
EOF
  write_artifacts 200 code-coverage true
  write_artifacts 150 code-coverage false
  write_no_artifacts 100
  printf '%s\n' "$CURRENT_RUN_ID" 150 > "$FAKE_DIR/downloadable"
  run_action

  assert_exit_code 0
  assert_called "gh run download 150 "
  assert_not_called "gh run download 200 "
  assert_called "gh pr comment $PULL_REQUEST_NUMBER "
}

test_github_action_no_baseline_warns_and_exits_zero(){
  echo '[]' > "$FAKE_DIR/stale_runs.json"
  cat > "$FAKE_DIR/runs.json" <<'EOF'
[
  {"databaseId":300,"status":"in_progress","conclusion":""},
  {"databaseId":250,"status":"completed","conclusion":"failure"},
  {"databaseId":200,"status":"completed","conclusion":"success"}
]
EOF
  write_artifacts 200 code-coverage true
  printf '%s\n' "$CURRENT_RUN_ID" > "$FAKE_DIR/downloadable"
  run_action

  assert_exit_code 0
  assert_output_contains "::warning::"
  assert_not_called "go-coverage-report "
  assert_not_called "gh pr comment "
}

test_github_action_skip_comment_still_writes_output(){
  setup_stale_status_success_filter
  SKIP_COMMENT=true run_action

  assert_exit_code 0
  if ! grep -q "coverage_report<<" "$TEST_DIR/github_output"; then
    fail "expected coverage_report output in \$GITHUB_OUTPUT"
  fi
  assert_not_called "gh pr comment "
}

TESTS=(
  test_github_action_stale_status_success_filter_uses_newest_successful_run
  test_github_action_newest_success_artifact_expired_falls_back_to_older_run
  test_github_action_no_baseline_warns_and_exits_zero
  test_github_action_skip_comment_still_writes_output
)

fail(){
  TEST_FAILURES+=("$1")
}

assert_exit_code(){
  if [ "$ACTION_EXIT_CODE" -ne "$1" ]; then
    fail "expected exit code $1, got $ACTION_EXIT_CODE"
  fi
}

assert_called(){
  if ! grep -qF -- "$1" "$FAKE_DIR/calls.log"; then
    fail "expected call matching \"$1\""
  fi
}

assert_not_called(){
  if grep -qF -- "$1" "$FAKE_DIR/calls.log"; then
    fail "unexpected call matching \"$1\""
  fi
}

assert_output_contains(){
  if ! grep -qF -- "$1" <<< "$ACTION_OUTPUT"; then
    fail "expected output to contain \"$1\""
  fi
}

FAILED=0
for test_name in "${TESTS[@]}"; do
  TEST_DIR=$(mktemp -d)
  FAKE_DIR="$TEST_DIR/fake"
  mkdir -p "$TEST_DIR/bin" "$FAKE_DIR/artifacts"
  : > "$FAKE_DIR/calls.log"
  write_stubs "$TEST_DIR/bin"

  TEST_FAILURES=()
  "$test_name"

  if [ ${#TEST_FAILURES[@]} -eq 0 ]; then
    echo "PASS: $test_name"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: $test_name"
    printf '    %s\n' "${TEST_FAILURES[@]}"
    echo "    --- calls ---"
    sed 's/^/    /' "$FAKE_DIR/calls.log"
    echo "    --- output ---"
    echo "    ${ACTION_OUTPUT//$'\n'/$'\n'    }"
  fi
  rm -rf "$TEST_DIR"
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "$FAILED of ${#TESTS[@]} tests failed"
  exit 1
fi
echo "All ${#TESTS[@]} tests passed"
