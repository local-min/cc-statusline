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

check "GitLab merge request shown as MR !N" "MR !12" \
  "$(echo '{"cwd":"/tmp","pr":{"number":12,"kind":"mr","review_state":"pending"}}' | sl)"

# pr.url → OSC 8 hyperlink around the label, only for a plain http(s) URL.
ESC=$(printf '\033')
pr_link=$(echo '{"cwd":"/tmp","pr":{"number":5,"url":"https://github.com/o/r/pull/5"}}' | CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")
check "pr.url becomes an OSC 8 link" "${ESC}]8;;https://github.com/o/r/pull/5${ESC}\\PR #5${ESC}]8;;${ESC}\\" "$pr_link"
checknot "CCSL_LINKS=0 prints the plain label" "${ESC}]8" \
  "$(echo '{"cwd":"/tmp","pr":{"number":5,"url":"https://github.com/o/r/pull/5"}}' | CCSL_LINKS=0 CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")"
bad_url=$(echo '{"cwd":"/tmp","pr":{"number":5,"url":"javascript:alert(1)"}}' | CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")
check    "a non-http pr.url still shows the PR" "PR #5" "$bad_url"
checknot "a non-http pr.url is not linked" "${ESC}]8" "$bad_url"
checknot "a pr.url with spaces is not linked" "${ESC}]8" \
  "$(echo '{"cwd":"/tmp","pr":{"number":5,"url":"https://x.example/a b"}}' | CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")"

# effort / fast mode next to the model
check "effort level after the model" "💪 Opus 5.5 · xhigh" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Opus 5.5"},"effort":{"level":"xhigh"}}' | sl)"
check "fast mode marker" "Opus 5.5 · high ⚡" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"fast_mode":true}' | sl)"
checknot "no effort field → no separator" "·" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Haiku"},"fast_mode":false}' | sl)"
checknot "CCSL_SHOW_EFFORT=0 hides effort and fast mode" "xhigh" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Opus"},"effort":{"level":"xhigh"},"fast_mode":true}' | CCSL_SHOW_EFFORT=0 CCSL_NO_COLOR=1 bash "$SL")"

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

# workspace.current_dir is the documented field; cwd holds the same value.
j_ws=$(printf '{"cwd":"/nonexistent","workspace":{"current_dir":"%s"}}' "$REPO")
check "workspace.current_dir preferred over cwd" "🐙 $(basename "$REPO")" "$(printf '%s' "$j_ws" | sl)"

j_owner=$(printf '{"cwd":"%s","workspace":{"repo":{"host":"github.com","owner":"acme","name":"widgets"}}}' "$REPO")
check "workspace.repo shown as owner/name" "🐙 acme/widgets │" "$(printf '%s' "$j_owner" | sl)"
check "CCSL_REPO_OWNER=0 keeps the directory name" "🐙 $(basename "$REPO") │" \
  "$(printf '%s' "$j_owner" | CCSL_REPO_OWNER=0 CCSL_NO_COLOR=1 bash "$SL")"
j_nonowner=$(printf '{"cwd":"%s","workspace":{"repo":{"host":"github.com","name":"widgets"}}}' "$REPO")
check "workspace.repo without owner falls back to the directory name" "🐙 $(basename "$REPO") │" \
  "$(printf '%s' "$j_nonowner" | sl)"

# $HOME → ~ must use an exact match (no ~2 mangling of /home/me2).
# Disable git/PR lines so the assertion only inspects the dir line — otherwise
# a "~N" git diff count from the fallback repo can false-match the needle.
checknot "no ~2 mangling" "~2/proj" \
  "$(echo '{"cwd":"/home/me2/proj"}' | HOME=/home/me CCSL_SHOW_GIT=0 CCSL_SHOW_PR=0 CCSL_NO_COLOR=1 bash "$SL")"
# shellcheck disable=SC2088  # "~/proj" is the literal expected output, not a path
check "HOME collapses to ~" "~/proj" \
  "$(echo '{"cwd":"/home/me/proj"}' | HOME=/home/me CCSL_SHOW_GIT=0 CCSL_SHOW_PR=0 CCSL_NO_COLOR=1 bash "$SL")"

check    "null used_percentage → --% (unknown, not 0%)" "--%" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":null}}' | sl)"
checknot "null used_percentage is not shown as 0%" " 0%" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":null}}' | sl)"

# Right after a compaction (manual, auto or idle) current_usage is null until
# the next API call; prompt_cache tells it apart from a brand-new session.
j_compacted='{"cwd":"/tmp","context_window":{"used_percentage":null,"current_usage":null,"total_input_tokens":0},"prompt_cache":{"warm":true}}'
check    "null current_usage after an API response → compacted" "↺ compacted" "$(printf '%s' "$j_compacted" | sl)"
checknot "compacted state is not shown as 0%" " 0%" "$(printf '%s' "$j_compacted" | sl)"
j_stale='{"cwd":"/tmp","context_window":{"used_percentage":49,"current_usage":null,"total_input_tokens":490000},"prompt_cache":{"warm":true}}'
check    "stale used_percentage beside a null current_usage → compacted" "↺ compacted" "$(printf '%s' "$j_stale" | sl)"
checknot "stale used_percentage is not shown" "49%" "$(printf '%s' "$j_stale" | sl)"
checknot "stale token total never warns" "k+" \
  "$(printf '%s' "$j_stale" | CCSL_CTX_WARN_K=300 CCSL_NO_COLOR=1 bash "$SL")"
j_fresh='{"cwd":"/tmp","context_window":{"used_percentage":null,"current_usage":null}}'
check    "null current_usage before the first response → --%" "--%" "$(printf '%s' "$j_fresh" | sl)"
checknot "a new session is not reported as compacted" "compacted" "$(printf '%s' "$j_fresh" | sl)"
check "missing used_percentage rebuilt from current_usage (input only)" "25%" \
  "$(echo '{"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":9000,"cache_read_input_tokens":40000,"output_tokens":5000}}}' | sl)"
check "used_percentage wins over current_usage when both are present" "42%" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":42,"context_window_size":200000,"current_usage":{"input_tokens":1000}}}' | sl)"
check "non-object context_window → --%" "--%" \
  "$(echo '{"cwd":"/tmp","model":{"display_name":"Opus"},"context_window":"weird"}' | sl)"

# context-usage warning threshold (default 70%, configurable, 0 = off)
check "usage warning fires at 70%" "70%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":70,"total_input_tokens":700000}}' | sl)"
checknot "no usage warning at 69.9% (floored to 69)" "%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":69.9,"total_input_tokens":699000}}' | sl)"
# The case the old absolute default never caught: a 200k window at 75% is
# 150k tokens, far below 300k.
check "usage warning fires in a 200k window" "70%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":75,"total_input_tokens":150000,"context_window_size":200000}}' | sl)"
check "CCSL_CTX_WARN_PCT=50 lowers threshold" "50%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":55}}' | CCSL_CTX_WARN_PCT=50 CCSL_NO_COLOR=1 bash "$SL")"
checknot "CCSL_CTX_WARN_PCT=0 disables the warning" "%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":95}}' | CCSL_CTX_WARN_PCT=0 CCSL_NO_COLOR=1 bash "$SL")"
check "garbage CCSL_CTX_WARN_PCT falls back to 70" "70%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":80}}' | CCSL_CTX_WARN_PCT=abc CCSL_NO_COLOR=1 bash "$SL")"
checknot "null used_percentage never warns" "%+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":null}}' | sl)"

# context-token warning threshold (default off, configurable)
checknot "no token warning by default (300k is 30% of a 1M window)" "k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":35,"total_input_tokens":350000}}' | sl)"
check "CCSL_CTX_WARN_K=300 restores the absolute warning" "300k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":35,"total_input_tokens":350000}}' | CCSL_CTX_WARN_K=300 CCSL_NO_COLOR=1 bash "$SL")"
checknot "token warning silent at or below its threshold" "k+" \
  "$(echo '{"cwd":"/tmp","context_window":{"used_percentage":25,"total_input_tokens":250000}}' | CCSL_CTX_WARN_K=300 CCSL_NO_COLOR=1 bash "$SL")"
both=$(echo '{"cwd":"/tmp","context_window":{"used_percentage":80,"total_input_tokens":800000}}' | CCSL_CTX_WARN_K=300 CCSL_NO_COLOR=1 bash "$SL")
check    "usage warning wins when both fire" "70%+" "$both"
checknot "token warning suppressed when both fire" "300k+" "$both"

checknot "non-numeric rate limit hidden" "5h" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":"oops"}}}' | sl)"

check "rate limit floored to integer" "5h 23%" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":23.7,"resets_at":1743850800}}}' | sl)"

# Claude Code drops a window once its resets_at passes (e.g. 5h while idle);
# the remaining window must still be shown.
only7=$(echo '{"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":36,"resets_at":1793000000}}}' | sl)
check    "7d shown when the 5h window is absent" "💰 7d 36%" "$only7"
checknot "no 5h segment when the 5h window is absent" "5h" "$only7"
both_rl=$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":36}}}' | sl)
check "both windows joined on one line" "💰 5h 12% │ 7d 36%" "$both_rl"

# Ultra has no 5-hour limit: its JSON carries seven_day alone (captured from
# Claude Code v2.1.322 on an Ultra plan).
ultra=$(echo '{"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":8,"resets_at":1794679200}}}' | sl)
check    "Ultra (no five_hour): 7d alone" "💰 7d 8%" "$ultra"
checknot "Ultra (no five_hour): no 5h segment" "5h" "$ultra"

# A Claude apps gateway sends spend_limit, possibly on its own and over 100%.
spend=$(echo '{"cwd":"/tmp","rate_limits":{"spend_limit":{"used_percentage":62.8,"resets_at":1796000000,"used_usd":314.12,"limit_usd":500,"period":"monthly"}}}' | sl)
check "spend_limit alone shows the line" "💰 spend 62%" "$spend"
check "spend_limit dollars" "\$314.12/\$500" "$spend"
check "spend_limit percentage before the dollars arrive" "💰 spend 62% (🔄" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"spend_limit":{"used_percentage":62.8,"resets_at":1796000000}}}' | sl)"
check "spend_limit over 100%" "spend 104%" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"spend_limit":{"used_percentage":104.2}}}' | sl)"
checknot "non-numeric spend dollars are dropped" '$' \
  "$(echo '{"cwd":"/tmp","rate_limits":{"spend_limit":{"used_percentage":5,"used_usd":"1;x","limit_usd":500}}}' | CCSL_SHOW_DIR=0 CCSL_NO_COLOR=1 bash "$SL")"
check "spend_limit joins the other windows" "7d 36% │ spend 5%" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":36},"spend_limit":{"used_percentage":5}}}' | sl)"

# Windows the status-line JSON may gain later (e.g. a separate Fable limit).
extra=$(echo '{"cwd":"/tmp","rate_limits":{"seven_day":{"used_percentage":36},"seven_day_overage_included":{"used_percentage":51.5,"resets_at":1794679200},"seven_day_new_thing":{"used_percentage":3},"odd":"x","bad":{"used_percentage":"9"}}}' | sl)
check    "overage-included weekly window is labelled Fable" "Fable 51% (🔄" "$extra"
check    "an unknown window gets a readable label" "New thing 3%" "$extra"
checknot "a non-object window is ignored" "Odd" "$extra"
checknot "a window without a numeric percentage is ignored" "Bad" "$extra"
inj_key=$(jq -nc '{cwd:"/tmp", rate_limits:{("seven_day_x\u001b[31m"):{used_percentage:4}}}')
checknot "no ESC from a window name reaches the output" "$(printf '\033')" "$(printf '%s' "$inj_key" | sl)"
# jq streams its outputs, so a failure part-way would blank every field after
# it — pr.number comes after rate_limits in the extraction.
check "a non-object rate_limits does not blank the later fields" "PR #9" \
  "$(echo '{"cwd":"/tmp","rate_limits":"weird","pr":{"number":9}}' | sl)"
check "a non-object rate_limits window does not blank the later fields" "PR #9" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":3},"pr":{"number":9}}' | sl)"

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

# PR cache: per-user, private, never through a symlink, digits only.
FAKEBIN=$(mktemp -d 2>/dev/null || mktemp -d -t ccslbin)
CACHE_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ccsltmp)
trap 'rm -rf "$REPO" "$FAKEBIN" "$CACHE_TMP"' EXIT
printf '#!/bin/sh\necho 42\n' > "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"
j_nopr=$(printf '{"cwd":"%s"}' "$REPO")
uid=$(id -u)
out=$(printf '%s' "$j_nopr" | PATH="$FAKEBIN:$PATH" TMPDIR="$CACHE_TMP" CCSL_NO_COLOR=1 bash "$SL")
check "gh fallback shows the PR" "PR #42" "$out"
if [ -d "$CACHE_TMP/claude-statusline-$uid" ] && [ ! -L "$CACHE_TMP/claude-statusline-$uid" ]; then
  printf 'PASS  cache directory is per-user\n'; pass=$((pass + 1))
else
  printf 'FAIL  cache directory is per-user (no %s)\n' "$CACHE_TMP/claude-statusline-$uid"; fail=$((fail + 1))
fi
mode=$(stat -f %Lp "$CACHE_TMP/claude-statusline-$uid" 2>/dev/null || stat -c %a "$CACHE_TMP/claude-statusline-$uid" 2>/dev/null)
check "cache directory is mode 700" "700" "mode=$mode"
for f in "$CACHE_TMP/claude-statusline-$uid"/pr-*; do printf '9\033[31mX' > "$f"; done
out=$(printf '%s' "$j_nopr" | PATH="$FAKEBIN:$PATH" TMPDIR="$CACHE_TMP" CCSL_NO_COLOR=1 bash "$SL")
checknot "a corrupted cache value is not printed" "PR #" "$out"
checknot "no ESC from the cache reaches the output" "$(printf '\033')" "$out"
rm -rf "$CACHE_TMP/claude-statusline-$uid"
mkdir "$CACHE_TMP/elsewhere"
ln -s "$CACHE_TMP/elsewhere" "$CACHE_TMP/claude-statusline-$uid"
out=$(printf '%s' "$j_nopr" | PATH="$FAKEBIN:$PATH" TMPDIR="$CACHE_TMP" CCSL_NO_COLOR=1 bash "$SL")
check "a symlinked cache directory falls back to an uncached lookup" "PR #42" "$out"
if [ -z "$(ls -A "$CACHE_TMP/elsewhere")" ]; then
  printf 'PASS  nothing written through a symlinked cache directory\n'; pass=$((pass + 1))
else
  printf 'FAIL  wrote through a symlinked cache directory: %s\n' "$(ls -A "$CACHE_TMP/elsewhere")"; fail=$((fail + 1))
fi
j_urlonly=$(printf '{"cwd":"%s","pr":{"url":"https://gitlab.com/g/p/-/merge_requests/3","kind":"mr"}}' "$REPO")
out=$(printf '%s' "$j_urlonly" | PATH="$FAKEBIN:$PATH" TMPDIR="$CACHE_TMP" CCSL_NO_COLOR=1 bash "$SL")
check    "gh fallback still runs when pr has no number" "PR #42" "$out"
checknot "a numberless pr.url is not put on gh's PR" "$(printf '\033')]8" "$out"
checknot "rate line absent when no window is usable" "💰" \
  "$(echo '{"cwd":"/tmp","rate_limits":{"five_hour":{},"seven_day":{"used_percentage":null},"x":{"used_percentage":-1}}}' | sl)"
checknot "a non-numeric pr.number is not printed" "PR #" \
  "$(echo '{"cwd":"/tmp","pr":{"number":"7; rm"}}' | sl)"

if echo '{}' | sl >/dev/null 2>&1; then
  echo "PASS  empty object does not crash"; pass=$((pass + 1))
else
  echo "FAIL  empty object crashed"; fail=$((fail + 1))
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
