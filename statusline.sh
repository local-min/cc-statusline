#!/usr/bin/env bash
# Claude Code statusline
# stdin: JSON with session info

JSON=$(cat)
jv() { echo "$JSON" | jq -r "$1 // empty" 2>/dev/null; }

# Colors
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'
CYN='\033[36m'; MAG='\033[35m'

# ─── Line 1: Current directory ───
CWD=$(jv '.cwd')
CWD="${CWD/#$HOME/~}"
printf '%b\n' "📁 ${CYN}${CWD}${RST}"

# ─── Line 2: Repo | Branch + diff ───
if git rev-parse --is-inside-work-tree &>/dev/null; then
  REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
  BRANCH=$(git branch --show-current 2>/dev/null)

  STAGED=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNSTAGED=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

  DIFF=""
  [ "$STAGED" -gt 0 ] 2>/dev/null && DIFF+=" ${GRN}+${STAGED}${RST}"
  MOD=$((UNSTAGED + UNTRACKED))
  [ "$MOD" -gt 0 ] 2>/dev/null && DIFF+=" ${YLW}~${MOD}${RST}"

  printf '%b\n' "🐙 ${BOLD}${REPO}${RST} │ 🌿 ${GRN}${BRANCH}${RST}${DIFF}"
fi

# ─── Line 3: Context bar | Model ───
PCT=$(echo "$JSON" | jq '.context_window.used_percentage // 0' 2>/dev/null | awk '{printf "%d", $1}')
MODEL=$(jv '.model.display_name')
OVER200K=$(echo "$JSON" | jq -r '.exceeds_200k_tokens // false' 2>/dev/null)

W=20; F=$((PCT * W / 100)); E=$((W - F))
if   [ "$PCT" -lt 50 ]; then BC="$GRN"
elif [ "$PCT" -lt 80 ]; then BC="$YLW"
else BC="$RED"; fi

BAR="${BC}"
for ((i=0; i<F; i++)); do BAR+="█"; done
BAR+="${DIM}"
for ((i=0; i<E; i++)); do BAR+="░"; done
BAR+="${RST}"

WARN=""
[ "$OVER200K" = "true" ] && WARN=" ${RED}⚠ 200k+${RST}"

printf '%b\n' "🧠 ${BAR} ${PCT}%${WARN} │ 💪 ${BOLD}${MODEL}${RST}"

# ─── Line 4: Rate limits (Claude Max/Pro) ───
FIVE_PCT=$(echo "$JSON" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
if [ -n "$FIVE_PCT" ]; then
  FIVE_RESET=$(echo "$JSON" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
  SEVEN_PCT=$(echo "$JSON" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
  SEVEN_RESET=$(echo "$JSON" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

  FIVE_INT=${FIVE_PCT%.*}
  if   [ "$FIVE_INT" -lt 50 ] 2>/dev/null; then FC="$GRN"
  elif [ "$FIVE_INT" -lt 80 ] 2>/dev/null; then FC="$YLW"
  else FC="$RED"; fi

  FIVE_TIME=""
  if [ -n "$FIVE_RESET" ]; then
    FIVE_TIME=$(LC_ALL=C date -r "$FIVE_RESET" '+%l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ -n "$FIVE_TIME" ] && FIVE_TIME=" (🔄 ${FIVE_TIME})"
  fi

  LINE="💰 5h ${FC}${FIVE_INT}%${RST}${FIVE_TIME}"

  if [ -n "$SEVEN_PCT" ]; then
    SEVEN_INT=${SEVEN_PCT%.*}
    if   [ "$SEVEN_INT" -lt 50 ] 2>/dev/null; then SC="$GRN"
    elif [ "$SEVEN_INT" -lt 80 ] 2>/dev/null; then SC="$YLW"
    else SC="$RED"; fi

    SEVEN_TIME=""
    if [ -n "$SEVEN_RESET" ]; then
      SEVEN_TIME=$(LC_ALL=C date -r "$SEVEN_RESET" '+%-m/%-d %l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g; s/^ *//')
      [ -n "$SEVEN_TIME" ] && SEVEN_TIME=" (🔄 ${SEVEN_TIME})"
    fi

    LINE+=" │ 7d ${SC}${SEVEN_INT}%${RST}${SEVEN_TIME}"
  fi

  printf '%b\n' "$LINE"
fi

# ─── Line 5: PR number (cached, 5min TTL) ───
if git rev-parse --is-inside-work-tree &>/dev/null; then
  CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  BRANCH_KEY=$(echo "$(git rev-parse --show-toplevel 2>/dev/null):${BRANCH}" | md5 -q 2>/dev/null || echo "none")
  PR_CACHE="${CACHE_DIR}/pr-${BRANCH_KEY}"

  NOW=$(date +%s)
  if [ -f "$PR_CACHE" ]; then
    AGE=$(stat -f %m "$PR_CACHE" 2>/dev/null || echo 0)
    if [ $((NOW - AGE)) -gt 300 ]; then
      PR_NUM=$(gh pr view --json number -q '.number' 2>/dev/null || true)
      printf '%s' "$PR_NUM" > "$PR_CACHE" 2>/dev/null
    else
      PR_NUM=$(cat "$PR_CACHE" 2>/dev/null)
    fi
  else
    PR_NUM=$(gh pr view --json number -q '.number' 2>/dev/null || true)
    printf '%s' "$PR_NUM" > "$PR_CACHE" 2>/dev/null
  fi

  if [ -n "$PR_NUM" ]; then
    printf '%b\n' "${MAG}PR #${PR_NUM}${RST}"
  fi
fi
