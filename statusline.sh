#!/usr/bin/env bash
# Claude Code statusline
# stdin: JSON with session info
#
# Customization via environment variables (all optional):
#   CCSL_BAR_WIDTH    context bar width in chars         (default 20)
#   CCSL_PR_TTL       PR number cache TTL in seconds      (default 300)
#   CCSL_TIME_FMT_5H  strftime for 5h reset time          (default '%H:%M')
#   CCSL_TIME_FMT_7D  strftime for 7d reset time          (default '%-m/%-d %H:%M')
#   CCSL_SHOW_DIR / _GIT / _CONTEXT / _RATE / _PR  toggle each line (1/0, default 1)
#   CCSL_NO_COLOR=1   disable ANSI colors (the standard NO_COLOR is also honored)

JSON=$(cat)

# ─── jq is required ───
if ! command -v jq &>/dev/null; then
  printf '%b\n' "📁 (statusline) jq not found — install: brew install jq (mac) / apt install jq (linux)"
  exit 0
fi
jv() { printf '%s' "$JSON" | jq -r "$1 // empty" 2>/dev/null; }

# ─── Colors (honor NO_COLOR / CCSL_NO_COLOR) ───
if [ -n "$NO_COLOR" ] || [ "${CCSL_NO_COLOR:-0}" = "1" ]; then
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''; MAG=''
else
  RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
  RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'
  CYN='\033[36m'; MAG='\033[35m'
fi

# ─── Platform-specific helpers (BSD/macOS vs GNU/Linux) ───
case "$(uname -s)" in
  Darwin|*BSD) IS_BSD=1 ;;
  *)           IS_BSD=0 ;;
esac

epoch_to_time() { # $1=epoch  $2=strftime fmt → local time, lowercased
  local out
  if [ "$IS_BSD" = "1" ]; then
    out=$(LC_ALL=C date -r "$1" "+$2" 2>/dev/null)
  else
    out=$(LC_ALL=C date -d "@$1" "+$2" 2>/dev/null)
  fi
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g; s/^ *//'
}

file_mtime() { # $1=file → epoch
  if [ "$IS_BSD" = "1" ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

hash_str() { # stdin → hex digest
  if command -v md5 &>/dev/null; then
    md5 -q
  elif command -v md5sum &>/dev/null; then
    md5sum | cut -d' ' -f1
  else
    cksum | cut -d' ' -f1
  fi
}

color_for() { # $1=int → bar/value color (green <50, yellow <80, red >=80)
  if   [ "$1" -lt 50 ] 2>/dev/null; then printf '%s' "$GRN"
  elif [ "$1" -lt 80 ] 2>/dev/null; then printf '%s' "$YLW"
  else printf '%s' "$RED"; fi
}

# ─── Line 1: Current directory ───
if [ "${CCSL_SHOW_DIR:-1}" = "1" ]; then
  CWD=$(jv '.cwd')
  CWD="${CWD/#$HOME/~}"
  printf '%b\n' "📁 ${CYN}${CWD}${RST}"
fi

# ─── Git context (computed once, reused by Line 2 and Line 5) ───
IN_GIT=0; TOPLEVEL=''; BRANCH=''
if git rev-parse --is-inside-work-tree &>/dev/null; then
  IN_GIT=1
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  BRANCH=$(git branch --show-current 2>/dev/null)
fi

# ─── Line 2: Repo | Branch + diff ───
if [ "$IN_GIT" = "1" ] && [ "${CCSL_SHOW_GIT:-1}" = "1" ]; then
  REPO=$(basename "$TOPLEVEL")

  # Single `git status --porcelain` pass → staged / unstaged / untracked counts
  read -r STAGED UNSTAGED UNTRACKED < <(git status --porcelain 2>/dev/null | awk '
      /^\?\?/ { u++; next }
      {
        if (substr($0, 1, 1) != " ") s++
        if (substr($0, 2, 1) != " ") m++
      }
      END { printf "%d %d %d", s, m, u }')

  DIFF=""
  [ "${STAGED:-0}" -gt 0 ] 2>/dev/null && DIFF+=" ${GRN}+${STAGED}${RST}"
  MOD=$(( ${UNSTAGED:-0} + ${UNTRACKED:-0} ))
  [ "$MOD" -gt 0 ] 2>/dev/null && DIFF+=" ${YLW}~${MOD}${RST}"

  printf '%b\n' "🐙 ${BOLD}${REPO}${RST} │ 🌿 ${GRN}${BRANCH}${RST}${DIFF}"
fi

# ─── Line 3: Context bar | Model ───
if [ "${CCSL_SHOW_CONTEXT:-1}" = "1" ]; then
  PCT=$(printf '%s' "$JSON" | jq '.context_window.used_percentage // 0' 2>/dev/null | awk '{printf "%d", $1}')
  [ -z "$PCT" ] && PCT=0
  MODEL=$(jv '.model.display_name')
  OVER200K=$(printf '%s' "$JSON" | jq -r '.exceeds_200k_tokens // false' 2>/dev/null)

  W=${CCSL_BAR_WIDTH:-20}
  F=$((PCT * W / 100)); [ "$F" -gt "$W" ] && F=$W; [ "$F" -lt 0 ] && F=0
  E=$((W - F))
  BC=$(color_for "$PCT")

  BAR="${BC}"
  for ((i=0; i<F; i++)); do BAR+="█"; done
  BAR+="${DIM}"
  for ((i=0; i<E; i++)); do BAR+="░"; done
  BAR+="${RST}"

  WARN=""
  [ "$OVER200K" = "true" ] && WARN=" ${RED}⚠ 200k+${RST}"

  printf '%b\n' "🧠 ${BAR} ${PCT}%${WARN} │ 💪 ${BOLD}${MODEL}${RST}"
fi

# ─── Line 4: Rate limits (Claude Max/Pro) ───
if [ "${CCSL_SHOW_RATE:-1}" = "1" ]; then
  FIVE_PCT=$(printf '%s' "$JSON" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
  if [ -n "$FIVE_PCT" ]; then
    FIVE_RESET=$(printf '%s' "$JSON" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
    SEVEN_PCT=$(printf '%s' "$JSON" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
    SEVEN_RESET=$(printf '%s' "$JSON" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

    FIVE_INT=${FIVE_PCT%.*}
    FC=$(color_for "$FIVE_INT")

    FIVE_TIME=""
    if [ -n "$FIVE_RESET" ]; then
      t=$(epoch_to_time "$FIVE_RESET" "${CCSL_TIME_FMT_5H:-%H:%M}")
      [ -n "$t" ] && FIVE_TIME=" (🔄 ${t})"
    fi

    LINE="💰 5h ${FC}${FIVE_INT}%${RST}${FIVE_TIME}"

    if [ -n "$SEVEN_PCT" ]; then
      SEVEN_INT=${SEVEN_PCT%.*}
      SC=$(color_for "$SEVEN_INT")

      SEVEN_TIME=""
      if [ -n "$SEVEN_RESET" ]; then
        t=$(epoch_to_time "$SEVEN_RESET" "${CCSL_TIME_FMT_7D:-%-m/%-d %H:%M}")
        [ -n "$t" ] && SEVEN_TIME=" (🔄 ${t})"
      fi

      LINE+=" │ 7d ${SC}${SEVEN_INT}%${RST}${SEVEN_TIME}"
    fi

    printf '%b\n' "$LINE"
  fi
fi

# ─── Line 5: PR number (cached, TTL configurable) ───
if [ "$IN_GIT" = "1" ] && [ "${CCSL_SHOW_PR:-1}" = "1" ] && command -v gh &>/dev/null; then
  PR_TTL=${CCSL_PR_TTL:-300}
  CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  BRANCH_KEY=$(printf '%s' "${TOPLEVEL}:${BRANCH}" | hash_str 2>/dev/null || echo none)
  PR_CACHE="${CACHE_DIR}/pr-${BRANCH_KEY}"

  NOW=$(date +%s)
  PR_NUM=""
  if [ -f "$PR_CACHE" ]; then
    AGE=$(file_mtime "$PR_CACHE"); [ -z "$AGE" ] && AGE=0
    if [ $((NOW - AGE)) -gt "$PR_TTL" ]; then
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
