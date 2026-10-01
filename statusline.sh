#!/usr/bin/env bash
# Claude Code statusline
# stdin: JSON with session info — see https://code.claude.com/docs/en/statusline
#
# Customization via environment variables (all optional):
#   CCSL_BAR_WIDTH    context bar width in chars           (default 20, clamped 1–200)
#   CCSL_PR_TTL       PR number cache TTL in seconds        (default 300)
#   CCSL_TIME_FMT_5H  strftime for 5h reset time            (default '%H:%M')
#   CCSL_TIME_FMT_7D  strftime for 7d reset time            (default '%-m/%-d %H:%M')
#   CCSL_SHOW_DIR / _GIT / _CONTEXT / _RATE / _PR   toggle each line (1/0, default 1)
#   CCSL_SHOW_LINES   show session +added/-removed lines    (1/0, default 0)
#   CCSL_CTX_WARN_PCT context-usage warning threshold (%)   (default 70, 0=off)
#   CCSL_CTX_WARN_K   context-token warning threshold (k)   (default 0=off)
#   CCSL_NO_COLOR=1   disable ANSI colors (the standard NO_COLOR is also honored)

JSON=$(cat)

# ─── jq is required ───
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "📁 (statusline) jq not found — install: brew install jq (mac) / apt install jq (linux)"
  exit 0
fi

# ─── Reject malformed JSON up front (otherwise every field silently blanks) ───
if ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
  printf '%s\n' "📁 (statusline) invalid JSON on stdin"
  exit 0
fi

# ─── Colors as real ESC sequences (honor NO_COLOR / CCSL_NO_COLOR) ───
# Defining the escapes here — rather than letting printf '%b' interpret them —
# means JSON-derived strings can be emitted with plain '%s' and can never
# inject their own ANSI sequences (see the jq `clean` filter below).
if [ -n "${NO_COLOR:-}" ] || [ "${CCSL_NO_COLOR:-0}" = "1" ]; then
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''; MAG=''
else
  RST=$'\033[0m';  BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'
  CYN=$'\033[36m'; MAG=$'\033[35m'
fi

# ─── Platform-specific helpers (BSD/macOS vs GNU/Linux) ───
case "$(uname -s)" in
  Darwin|*BSD) IS_BSD=1 ;;
  *)           IS_BSD=0 ;;
esac

# Strip control chars from a bash string (defence in depth for git-derived values).
strip_ctrl() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'; }

# epoch seconds OR ISO8601 → local time string, lowercased.
# The status-line spec sends epoch seconds; the ISO8601 branch is a defensive
# fallback so a future/alternate format degrades to a best-effort time instead
# of silently dropping it. (ISO8601 here is treated as wall-clock, not TZ-exact.)
reset_to_time() { # $1=value  $2=strftime fmt
  local v=$1 fmt=$2 out
  [ -z "$v" ] && return
  case "$v" in
    *[!0-9]*)  # contains a non-digit → assume ISO8601
      if [ "$IS_BSD" = "1" ]; then
        out=$(LC_ALL=C date -j -f '%Y-%m-%dT%H:%M:%S' "${v%%[+.Z]*}" "+$fmt" 2>/dev/null)
      else
        out=$(LC_ALL=C date -d "$v" "+$fmt" 2>/dev/null)
      fi
      ;;
    *)         # pure digits → epoch seconds
      if [ "$IS_BSD" = "1" ]; then
        out=$(LC_ALL=C date -r "$v" "+$fmt" 2>/dev/null)
      else
        out=$(LC_ALL=C date -d "@$v" "+$fmt" 2>/dev/null)
      fi
      ;;
  esac
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g; s/^ *//'
}

file_mtime() { # $1=file → epoch
  if [ "$IS_BSD" = "1" ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

hash_str() { # stdin → hex digest
  if command -v md5 >/dev/null 2>&1; then md5 -q
  elif command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1
  else cksum | cut -d' ' -f1; fi
}

color_for() { # $1=int → green <50, yellow <80, red >=80 (non-numeric → green)
  case "$1" in ''|*[!0-9]*) printf '%s' "$GRN"; return ;; esac
  if   [ "$1" -lt 50 ]; then printf '%s' "$GRN"
  elif [ "$1" -lt 80 ]; then printf '%s' "$YLW"
  else printf '%s' "$RED"; fi
}

# ─── Single jq pass: extract every field at once (one value per line) ───
# `clean` strips control chars from every string so untrusted values (cwd,
# model, branch via the repo dir, reset stamps) can neither inject ANSI nor
# break the line-by-line read below. [[:cntrl:]] is a POSIX class Oniguruma
# (jq's regex engine) understands directly.
{
  IFS= read -r CWD_RAW
  IFS= read -r MODEL
  IFS= read -r PCT
  IFS= read -r CTX_TOKENS
  IFS= read -r FIVE_PCT
  IFS= read -r FIVE_RESET
  IFS= read -r SEVEN_PCT
  IFS= read -r SEVEN_RESET
  IFS= read -r PR_NUM
  IFS= read -r PR_STATE
  IFS= read -r LINES_ADD
  IFS= read -r LINES_DEL
} < <(printf '%s' "$JSON" | jq -r '
  def clean: if type == "string" then gsub("[[:cntrl:]]"; "") else (. | tostring) end;
  ( .cwd // .workspace.current_dir // ""                         | clean ),
  ( .model.display_name // ""                                    | clean ),
  ( .context_window.used_percentage | if type == "number" then floor else 0 end ),
  ( .context_window.total_input_tokens // 0 ),
  ( .rate_limits.five_hour.used_percentage  | (tonumber? | floor) // "" ),
  ( .rate_limits.five_hour.resets_at  // ""                      | clean ),
  ( .rate_limits.seven_day.used_percentage  | (tonumber? | floor) // "" ),
  ( .rate_limits.seven_day.resets_at // ""                       | clean ),
  ( .pr.number // ""                                             | clean ),
  ( .pr.review_state // ""                                       | clean ),
  ( .cost.total_lines_added   // ""                              | clean ),
  ( .cost.total_lines_removed // ""                              | clean )
' 2>/dev/null)

# ─── Line 1: Current directory ───
if [ "${CCSL_SHOW_DIR:-1}" = "1" ]; then
  CWD=$CWD_RAW
  # Collapse $HOME → ~ with an exact path match (so /home/me2 is NOT mangled).
  if [ -n "${HOME:-}" ]; then
    # "~" here is a literal display shorthand, not a path to expand — keep it
    # in a variable so it never sits as a tilde inside quotes (avoids SC2088).
    home_short='~'
    case "$CWD" in
      "$HOME")   CWD=$home_short ;;
      "$HOME"/*) CWD="$home_short/${CWD#"$HOME"/}" ;;
    esac
  fi
  printf '%s\n' "📁 ${CYN}${CWD}${RST}"
fi

# ─── Git context (computed once, reused by Line 2 and Line 5) ───
# Use the session cwd from the JSON, not the script's own working directory,
# so git/PR info always reflects the directory Claude Code is showing.
GIT=(git)
if [ -n "$CWD_RAW" ] && [ -d "$CWD_RAW" ]; then GIT=(git -C "$CWD_RAW"); fi

IN_GIT=0; TOPLEVEL=''; BRANCH=''
if "${GIT[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
  TOPLEVEL=$("${GIT[@]}" rev-parse --show-toplevel 2>/dev/null)
  BRANCH=$(strip_ctrl "$("${GIT[@]}" branch --show-current 2>/dev/null)")
fi

# ─── Line 2: Repo | Branch + diff ───
if [ "$IN_GIT" = "1" ] && [ "${CCSL_SHOW_GIT:-1}" = "1" ]; then
  REPO=$(strip_ctrl "$(basename "$TOPLEVEL")")

  # Single `git status --porcelain` pass → staged / unstaged / untracked counts
  read -r STAGED UNSTAGED UNTRACKED < <("${GIT[@]}" status --porcelain 2>/dev/null | awk '
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

  # Optional: session lines changed (cost.total_lines_added/removed)
  LINESINFO=""
  if [ "${CCSL_SHOW_LINES:-0}" = "1" ]; then
    case "$LINES_ADD" in ''|*[!0-9]*) LINES_ADD=0 ;; esac
    case "$LINES_DEL" in ''|*[!0-9]*) LINES_DEL=0 ;; esac
    if [ "$LINES_ADD" -gt 0 ] 2>/dev/null || [ "$LINES_DEL" -gt 0 ] 2>/dev/null; then
      LINESINFO=" 📊 ${GRN}+${LINES_ADD}${RST} ${RED}-${LINES_DEL}${RST}"
    fi
  fi

  printf '%s\n' "🐙 ${BOLD}${REPO}${RST} │ 🌿 ${GRN}${BRANCH}${RST}${DIFF}${LINESINFO}"
fi

# ─── Line 3: Context bar | Model ───
if [ "${CCSL_SHOW_CONTEXT:-1}" = "1" ]; then
  case "$PCT" in ''|*[!0-9]*) PCT=0 ;; esac

  W=${CCSL_BAR_WIDTH:-20}
  case "$W" in ''|*[!0-9]*) W=20 ;; esac
  [ "$W" -lt 1 ]   && W=1
  [ "$W" -gt 200 ] && W=200

  F=$((PCT * W / 100)); [ "$F" -gt "$W" ] && F=$W; [ "$F" -lt 0 ] && F=0
  E=$((W - F))
  BC=$(color_for "$PCT")

  BAR="${BC}"
  for ((i=0; i<F; i++)); do BAR+="█"; done
  BAR+="${DIM}"
  for ((i=0; i<E; i++)); do BAR+="░"; done
  BAR+="${RST}"

  # Warn once the context window is filling up. The percentage is Claude Code's
  # own figure against the real window (200k or 1M), so one threshold means the
  # same thing on every model — an absolute token count does not: 300k is 30% of
  # a 1M window and never reached in a 200k one. The token threshold stays for
  # anyone who wants a fixed cap (default off); the percentage wins when both fire.
  WARN_PCT=${CCSL_CTX_WARN_PCT:-70}
  case "$WARN_PCT"   in ''|*[!0-9]*) WARN_PCT=70 ;; esac
  WARN_K=${CCSL_CTX_WARN_K:-0}
  case "$WARN_K"     in ''|*[!0-9]*) WARN_K=0 ;; esac
  case "$CTX_TOKENS" in ''|*[!0-9]*) CTX_TOKENS=0 ;; esac
  WARN=""
  if [ "$WARN_PCT" -gt 0 ] && [ "$PCT" -ge "$WARN_PCT" ]; then
    WARN=" ${RED}⚠ ${WARN_PCT}%+${RST}"
  elif [ "$WARN_K" -gt 0 ] && [ "$CTX_TOKENS" -gt $((WARN_K * 1000)) ]; then
    WARN=" ${RED}⚠ ${WARN_K}k+${RST}"
  fi

  printf '%s\n' "🧠 ${BAR} ${PCT}%${WARN} │ 💪 ${BOLD}${MODEL}${RST}"
fi

# ─── Line 4: Rate limits (Claude Max/Pro) ───
if [ "${CCSL_SHOW_RATE:-1}" = "1" ] && [ -n "$FIVE_PCT" ]; then
  FC=$(color_for "$FIVE_PCT")

  FIVE_TIME=""
  if [ -n "$FIVE_RESET" ]; then
    t=$(reset_to_time "$FIVE_RESET" "${CCSL_TIME_FMT_5H:-%H:%M}")
    [ -n "$t" ] && FIVE_TIME=" (🔄 ${t})"
  fi

  LINE="💰 5h ${FC}${FIVE_PCT}%${RST}${FIVE_TIME}"

  if [ -n "$SEVEN_PCT" ]; then
    SC=$(color_for "$SEVEN_PCT")

    SEVEN_TIME=""
    if [ -n "$SEVEN_RESET" ]; then
      t=$(reset_to_time "$SEVEN_RESET" "${CCSL_TIME_FMT_7D:-%-m/%-d %H:%M}")
      [ -n "$t" ] && SEVEN_TIME=" (🔄 ${t})"
    fi

    LINE+=" │ 7d ${SC}${SEVEN_PCT}%${RST}${SEVEN_TIME}"
  fi

  printf '%s\n' "$LINE"
fi

# ─── Line 5: PR number ───
# Prefer pr.number straight from the JSON (zero network). Only when it is
# absent do we fall back to `gh`, cached per branch with a configurable TTL.
if [ "${CCSL_SHOW_PR:-1}" = "1" ]; then
  # pr.number from the JSON is shown regardless of local git state; the gh
  # fallback only runs inside a git work tree.
  if [ -z "$PR_NUM" ] && [ "$IN_GIT" = "1" ] && command -v gh >/dev/null 2>&1; then
    PR_TTL=${CCSL_PR_TTL:-300}
    case "$PR_TTL" in ''|*[!0-9]*) PR_TTL=300 ;; esac
    # One cache directory per user, created private. On a shared /tmp (Linux)
    # a fixed name would let another user pre-create it, or plant symlinks in
    # it that our writes would follow; so the directory must be ours, not a
    # symlink, and mode 700 — otherwise we do a single uncached lookup.
    CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline-$(id -u 2>/dev/null || echo 0)"

    gh_pr() { ( cd "${CWD_RAW:-.}" 2>/dev/null && gh pr view --json number -q '.number' 2>/dev/null ); }

    if (umask 077 && mkdir -p "$CACHE_DIR") 2>/dev/null \
       && [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] \
       && chmod 700 "$CACHE_DIR" 2>/dev/null; then
      BRANCH_KEY=$(printf '%s' "${TOPLEVEL}:${BRANCH}" | hash_str 2>/dev/null || echo none)
      PR_CACHE="${CACHE_DIR}/pr-${BRANCH_KEY}"
      NOW=$(date +%s)
      if [ -f "$PR_CACHE" ]; then
        AGE=$(file_mtime "$PR_CACHE"); [ -z "$AGE" ] && AGE=0
        if [ $((NOW - AGE)) -gt "$PR_TTL" ]; then
          PR_NUM=$(gh_pr); printf '%s' "$PR_NUM" > "$PR_CACHE" 2>/dev/null
        else
          PR_NUM=$(cat "$PR_CACHE" 2>/dev/null)
        fi
      else
        PR_NUM=$(gh_pr); printf '%s' "$PR_NUM" > "$PR_CACHE" 2>/dev/null
      fi
    else
      # No writable cache dir → single uncached lookup (no stray stderr).
      PR_NUM=$(gh_pr)
    fi
  fi

  # A PR number is digits. Anything else — a corrupted cache file, an odd
  # JSON value — is dropped rather than printed.
  case "$PR_NUM" in *[!0-9]*) PR_NUM='' ;; esac

  if [ -n "$PR_NUM" ]; then
    BADGE=""
    case "$PR_STATE" in
      approved)          BADGE=" ${GRN}✓${RST}" ;;
      changes_requested) BADGE=" ${RED}✗${RST}" ;;
      pending)           BADGE=" ${YLW}…${RST}" ;;
      draft)             BADGE=" ${DIM}draft${RST}" ;;
    esac
    printf '%s\n' "${MAG}PR #${PR_NUM}${RST}${BADGE}"
  fi
fi
