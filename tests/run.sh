#!/usr/bin/env bash
# Regression tests for statusline.sh — pure stdin/stdout, no network.
# Runnable locally and in CI (creates a throwaway git repo for git/PR cases).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SL="$HERE/../statusline.sh"

pass=0
fail=0
check() {    # $1=desc  $2=needle  $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    printf 'PASS  %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      expected to contain: %s\n      got: %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}
checknot() { # $1=desc  $2=needle  $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    printf 'FAIL  %s\n      should NOT contain: %s\n      got: %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  else
    printf 'PASS  %s\n' "$1"; pass=$((pass + 1))
  fi
}
sl() { CCSL_NO_COLOR=1 bash "$SL"; }   # stdin → output, colors off

# Throwaway git repo so git/PR lines have something real to read.
REPO=$(mktemp -d 2>/dev/null || mktemp -d -t ccsl)
trap 'rm -rf "$REPO"' EXIT
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email tester@example.com
  git config user.name tester
  git commit --allow-empty -qm init
)

echo "== syntax =="
bash -n "$SL" && echo "bash -n OK"
echo
echo "== functional =="

check "model name shown" "Opus 4.6" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Opus 4.6"},"context_window":{"used_percentage":42}}' | sl)"

check "pr.number taken from JSON (no git, no gh)" "PR #324" \
  "$(echo '{"cwd":"/tmp","pr":{"number":324,"review_state":"approved"}}' | sl)"

check "review_state badge (draft)" "draft" \
  "$(echo '{"cwd":"/tmp","pr":{"number":7,"review_state":"draft"}}' | sl)"

# ANSI injection: real ESC byte, encoded as valid JSON by jq → must be stripped.
inj_raw=$(printf '/tmp/Xpre\033[31mEVIL')
inj_json=$(jq -nc --arg c "$inj_raw" '{cwd:$c, context_window:{used_percentage:5}}')
check    "ESC byte present in input is preserved as text" "EVIL" "$(printf '%s' "$inj_json" | sl)"
checknot "ESC byte stripped from output (no ANSI injection)" "$(printf '\033')" "$(printf '%s' "$inj_json" | sl)"

check "raw ESC byte in stdin → invalid JSON, rejected" "invalid JSON" \
  "$(printf '{"cwd":"/tmp/X\033bad"}' | sl)"

check "invalid JSON diagnostic" "invalid JSON" "$(echo 'not json' | sl)"

checknot "no git line outside a repo" "🐙" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":5}}' | sl)"

# Build JSON with printf into a variable first — nesting "$(echo "{…}" | sl)"
# trips bash 3.2 quote parsing and brace-expands the JSON.
j_repo=$(printf '{"cwd":"%s","context_window":{"used_percentage":5}}' "$REPO")
check "git line reads JSON cwd" "$(basename "$REPO")" "$(printf '%s' "$j_repo" | sl)"

# $HOME → ~ must use an exact match (no ~2 mangling of /home/me2).
# Disable git/PR lines so the assertion only inspects the dir line — otherwise
# a "~N" git diff count from the fallback repo can false-match the needle.
checknot "no ~2 mangling" "~2/proj" \
  "$(echo '{"cwd":"/home/me2/proj"}' | HOME=/home/me CCSL_SHOW_GIT=0 CCSL_SHOW_PR=0 CCSL_NO_COLOR=1 bash "$SL")"
# shellcheck disable=SC2088  # "~/proj" is the literal expected output, not a path
check "HOME collapses to ~" "~/proj" \
  "$(echo '{"cwd":"/home/me/proj"}' | HOME=/home/me CCSL_SHOW_GIT=0 CCSL_SHOW_PR=0 CCSL_NO_COLOR=1 bash "$SL")"

check "null used_percentage → 0%" "0%" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":null}}' | sl)"

# context-token warning threshold (default 300k, configurable, 0 = off)
check "context warning fires above 300k" "300k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":50,"total_input_tokens":350000}}' | sl)"
checknot "no warning at 250k" "300k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":50,"total_input_tokens":250000}}' | sl)"
check "CCSL_CTX_WARN_K=200 lowers threshold" "200k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":50,"total_input_tokens":250000}}' | CCSL_CTX_WARN_K=200 CCSL_NO_COLOR=1 bash "$SL")"
checknot "CCSL_CTX_WARN_K=0 disables the warning" "k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":50,"total_input_tokens":350000}}' | CCSL_CTX_WARN_K=0 CCSL_NO_COLOR=1 bash "$SL")"

checknot "non-numeric rate limit hidden" "5h" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":"oops"}}}' | sl)"

check "rate limit floored to integer" "5h 23%" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23.7,"resets_at":1743850800}}}' | sl)"

check "ISO8601 reset renders a time" "🔄" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":15,"resets_at":"2026-06-26T16:00:00Z"}}}' | sl)"

check "multibyte path preserved" "プロジェクト" \
  "$(echo '{"cwd":"/tmp/プロジェクト","context_window":{"used_percentage":5}}' | sl)"

j_lines=$(printf '{"cwd":"%s","cost":{"total_lines_added":120,"total_lines_removed":8}}' "$REPO")
check "session lines when CCSL_SHOW_LINES=1" "+120" \
  "$(printf '%s' "$j_lines" | CCSL_SHOW_LINES=1 CCSL_NO_COLOR=1 bash "$SL")"

checknot "dir line toggled off" "📁" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":5}}' | CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")"

# no stray stderr for a garbage CCSL_BAR_WIDTH
bw_err=$(echo '{"cwd":"/tmp","context_window":{"used_percentage":50}}' | CCSL_BAR_WIDTH=abc CCSL_NO_COLOR=1 bash "$SL" 2>&1 >/dev/null)
if [ -z "$bw_err" ]; then
  printf 'PASS  bad CCSL_BAR_WIDTH produces no stderr\n'; pass=$((pass + 1))
else
  printf 'FAIL  bad CCSL_BAR_WIDTH stderr: %s\n' "$bw_err"; fail=$((fail + 1))
fi

if echo '{}' | sl >/dev/null 2>&1; then
  echo "PASS  empty object does not crash"; pass=$((pass + 1))
else
  echo "FAIL  empty object crashed"; fail=$((fail + 1))
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
