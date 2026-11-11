#!/usr/bin/env bash
# Claude Code statusline
# stdin: JSON with session info — see https://code.claude.com/docs/en/statusline
#
# Customization via environment variables (all optional):
#   CCSL_BAR_WIDTH    context bar width in chars           (default 20, clamped 1–200)
#   CCSL_PR_TTL       PR number cache TTL in seconds        (default 300)
#   CCSL_TIME_FMT_5H  strftime for 5h (and daily) resets    (default '%H:%M')
#   CCSL_TIME_FMT_7D  strftime for weekly/monthly resets    (default '%-m/%-d %H:%M')
#   CCSL_SHOW_DIR / _GIT / _CONTEXT / _RATE / _PR   toggle each line (1/0, default 1)
#   CCSL_SHOW_LINES   show session +added/-removed lines    (1/0, default 0)
#   CCSL_SHOW_EFFORT  show effort level / fast mode         (1/0, default 1)
#   CCSL_REPO_OWNER   show the repo as owner/name           (1/0, default 1)
#   CCSL_LINKS        make the PR/MR number a clickable link (1/0, default 1)
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

usd() { # $1=non-negative number → "$500" / "$314.12" ("" if not a plain number)
  case "$1" in
    ''|*[!0-9.]*|*.*.*|.*|*.) return ;;
    *.*) LC_ALL=C printf '$%.2f' "$1" ;;
    *)   printf '$%s' "$1" ;;
  esac
}

# One rate-limit segment: "<label> <pct>%<extra> (🔄 <time>)".
rate_seg() { # $1=label  $2=pct  $3=resets_at  $4=strftime fmt  [$5=extra text after the %]
  local c t when=""
  c=$(color_for "$2")
  if [ -n "$3" ]; then
    t=$(reset_to_time "$3" "$4")
    [ -n "$t" ] && when=" (🔄 ${t})"
  fi
  printf '%s' "$1 ${c}$2%${RST}${5:-}${when}"
}

# ─── Single jq pass: extract every field at once (one value per line) ───
# `clean` strips control chars from every string so untrusted values (cwd,
# model, branch via the repo dir, reset stamps) can neither inject ANSI nor
# break the line-by-line read below. [[:cntrl:]] is a POSIX class Oniguruma
# (jq's regex engine) understands directly. `o` turns anything that is not an
# object into {} so one odd value (say "rate_limits":"x") cannot make jq fail
# and blank every other line.
{
  IFS= read -r CWD_RAW
  IFS= read -r MODEL
  IFS= read -r EFFORT
  IFS= read -r FAST
  IFS= read -r PCT
  IFS= read -r CTX_STATE
  IFS= read -r CTX_TOKENS
  IFS= read -r FIVE_PCT
  IFS= read -r FIVE_RESET
  IFS= read -r SEVEN_PCT
  IFS= read -r SEVEN_RESET
  IFS= read -r SPEND_PCT
  IFS= read -r SPEND_RESET
  IFS= read -r SPEND_USED
  IFS= read -r SPEND_LIMIT
  IFS= read -r SPEND_PERIOD
  IFS= read -r PR_NUM
  IFS= read -r PR_STATE
  IFS= read -r PR_KIND
  IFS= read -r PR_URL
  IFS= read -r REPO_FULL
  IFS= read -r LINES_ADD
  IFS= read -r LINES_DEL
  # Any further rows are extra rate-limit windows: label<TAB>pct<TAB>5h|7d<TAB>resets_at.
  # resets_at goes last because it may be empty, and read collapses a run of
  # tabs (whitespace IFS) — an empty field anywhere else would shift the rest.
  EX_LABEL=(); EX_PCT=(); EX_KIND=(); EX_RESET=()
  while IFS=$'\t' read -r ex_l ex_p ex_k ex_r; do
    EX_LABEL+=("$ex_l"); EX_PCT+=("$ex_p"); EX_KIND+=("$ex_k"); EX_RESET+=("$ex_r")
  done
} < <(printf '%s' "$JSON" | jq -r '
  def clean: if type == "string" then gsub("[[:cntrl:]]"; "") else (. | tostring) end;
  def o: if type == "object" then . else {} end;
  def pct: (tonumber? | floor) // "";
  # A short display name for a rate-limit window key. The status-line JSON has
  # only five_hour / seven_day / spend_limit today; this names any other window
  # Claude Code may add later (Claude Code calls seven_day_overage_included the
  # "Fable limit").
  def window_label:
    { "seven_day_overage_included": "Fable", "seven_day_opus": "Opus",
      "seven_day_sonnet": "Sonnet" }[.]
    // ( (if startswith("five_hour_") then "5h " else "" end)
         + (sub("^(seven_day|five_hour)_"; "") | gsub("[^A-Za-z0-9]+"; " ")
            | sub("^ +"; "") | sub(" +$"; ""))
       | if . == "" then "limit" else (.[0:1] | ascii_upcase) + .[1:] end );
  o
  | (.rate_limits | o) as $rl
  | (.workspace   | o) as $ws
  | (.pr          | o) as $pr
  | (.context_window | o) as $cw
  | ( $ws.current_dir // .cwd // ""                              | clean ),
  ( (.model | o).display_name // ""                              | clean ),
  ( (.effort | o).level // ""                                    | clean ),
  ( if .fast_mode == true then "1" else "" end ),
  # Context usage, or "" when it is not known. current_usage is null before the
  # first API call and again after a compaction (manual, auto or idle) until the
  # next call, so any used_percentage alongside it is not a live figure. When
  # used_percentage alone is missing, rebuild it the documented way: input
  # tokens only, against context_window_size.
  ( $cw
    | if has("current_usage") and .current_usage == null then ""
      elif (.used_percentage | type) == "number" then .used_percentage | floor
      elif (.current_usage | type) == "object" and (.context_window_size | type) == "number"
           and .context_window_size > 0 then
        ([ .current_usage | .input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens
           | numbers ] | add // 0) * 100 / .context_window_size | floor
      else "" end ),
  # "compacted" when that null comes after the session has had an API response
  # (prompt_cache only appears from then on), i.e. a compaction just finished.
  ( if ($cw | has("current_usage")) and $cw.current_usage == null
       and (.prompt_cache | type) == "object"
    then "compacted" else "" end ),
  ( $cw.total_input_tokens // 0                                  | clean ),
  # Each window is independently optional: a plan without a 5-hour limit
  # (Ultra) sends seven_day alone, and Claude Code drops any window once its
  # resets_at passes.
  ( ($rl.five_hour   | o).used_percentage                        | pct ),
  ( ($rl.five_hour   | o).resets_at // ""                        | clean ),
  ( ($rl.seven_day   | o).used_percentage                        | pct ),
  ( ($rl.seven_day   | o).resets_at // ""                        | clean ),
  # spend_limit: behind a Claude apps gateway. used_percentage can pass 100;
  # the dollar fields and period arrive later than the percentage, if at all.
  ( ($rl.spend_limit | o).used_percentage                        | pct ),
  ( ($rl.spend_limit | o).resets_at // ""                        | clean ),
  ( ($rl.spend_limit | o).used_usd  | if type == "number" and . >= 0 then tostring else "" end ),
  ( ($rl.spend_limit | o).limit_usd | if type == "number" and . >= 0 then tostring else "" end ),
  ( ($rl.spend_limit | o).period // ""                           | clean ),
  ( $pr.number // ""                                             | clean ),
  ( $pr.review_state // ""                                       | clean ),
  ( $pr.kind // ""                                               | clean ),
  # Only a plain http(s) URL may go inside the OSC 8 link sequence.
  ( $pr.url | if type == "string" and test("^https?://[A-Za-z0-9._~:/?#@!$&+,;=%-]+$")
              then . else "" end ),
  ( ($ws.repo | o)
    | if (.owner | type) == "string" and (.name | type) == "string"
         and .owner != "" and .name != ""
      then "\(.owner)/\(.name)" else "" end                      | clean ),
  ( (.cost | o).total_lines_added   // ""                        | clean ),
  ( (.cost | o).total_lines_removed // ""                        | clean ),
  ( $rl | to_entries[]
    | select(.key != "five_hour" and .key != "seven_day" and .key != "spend_limit")
    | select((.value | type) == "object" and (.value.used_percentage | type) == "number"
             and .value.used_percentage >= 0)
    | [ (.key | window_label),
        (.value.used_percentage | floor | tostring),
        (if (.key | startswith("five_hour")) then "5h" else "7d" end),
        (.value.resets_at // "" | clean) ]
    | join("\t") )
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
  # owner/name from the origin remote (workspace.repo) when Claude Code sends
  # it; otherwise — no origin, older Claude Code, or CCSL_REPO_OWNER=0 — the
  # work tree's directory name.
  if [ -n "$REPO_FULL" ] && [ "${CCSL_REPO_OWNER:-1}" = "1" ]; then
    REPO=$REPO_FULL
  else
    REPO=$(strip_ctrl "$(basename "$TOPLEVEL")")
  fi

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
  # An unknown figure is shown as such, not as 0%: right after a compaction the
  # real usage is only known once the next API response arrives.
  CTX_KNOWN=1
  case "$PCT" in ''|*[!0-9]*) CTX_KNOWN=0; PCT=0 ;; esac

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
  if [ "$CTX_KNOWN" = "0" ]; then
    :  # never warn on a figure that is not live (token totals may be stale too)
  elif [ "$WARN_PCT" -gt 0 ] && [ "$PCT" -ge "$WARN_PCT" ]; then
    WARN=" ${RED}⚠ ${WARN_PCT}%+${RST}"
  elif [ "$WARN_K" -gt 0 ] && [ "$CTX_TOKENS" -gt $((WARN_K * 1000)) ]; then
    WARN=" ${RED}⚠ ${WARN_K}k+${RST}"
  fi

  if [ "$CTX_KNOWN" = "1" ]; then
    USAGE="${PCT}%"
  elif [ "$CTX_STATE" = "compacted" ]; then
    USAGE="${CYN}↺ compacted${RST}"
  else
    USAGE="${DIM}--%${RST}"
  fi

  # Effort level and fast mode, next to the model they apply to. effort is
  # absent on models without the effort parameter; fast_mode is a boolean.
  MODEL_EXTRA=""
  if [ "${CCSL_SHOW_EFFORT:-1}" = "1" ]; then
    [ -n "$EFFORT" ] && MODEL_EXTRA+=" ${DIM}·${RST} ${EFFORT}"
    [ "$FAST" = "1" ] && MODEL_EXTRA+=" ${YLW}⚡${RST}"
  fi

  printf '%s\n' "🧠 ${BAR} ${USAGE}${WARN} │ 💪 ${BOLD}${MODEL}${RST}${MODEL_EXTRA}"
fi

# ─── Line 4: Rate limits (Pro / Max / Ultra, or a Claude apps gateway) ───
# Every window is optional and shown on its own:
#   - Ultra has no 5-hour limit, so its JSON carries seven_day alone.
#   - Claude Code drops a window once its resets_at passes (e.g. the 5h one
#     while a Pro/Max session sits idle); the others must stay.
#   - Behind a gateway there may be only spend_limit.
TIME_5H=${CCSL_TIME_FMT_5H:-%H:%M}
TIME_7D=${CCSL_TIME_FMT_7D:-%-m/%-d %H:%M}
if [ "${CCSL_SHOW_RATE:-1}" = "1" ]; then
  SEGS=()
  [ -n "$FIVE_PCT" ]  && SEGS+=("$(rate_seg 5h "$FIVE_PCT"  "$FIVE_RESET"  "$TIME_5H")")
  [ -n "$SEVEN_PCT" ] && SEGS+=("$(rate_seg 7d "$SEVEN_PCT" "$SEVEN_RESET" "$TIME_7D")")

  # Windows Claude Code may add later (for example a separate Fable limit).
  for ((i=0; i<${#EX_LABEL[@]}; i++)); do
    case "${EX_PCT[$i]}" in ''|*[!0-9]*) continue ;; esac
    fmt=$TIME_7D; [ "${EX_KIND[$i]}" = "5h" ] && fmt=$TIME_5H
    SEGS+=("$(rate_seg "${EX_LABEL[$i]}" "${EX_PCT[$i]}" "${EX_RESET[$i]}" "$fmt")")
  done

  if [ -n "$SPEND_PCT" ]; then
    # "spend 63% $314.12/$500 (🔄 12/1 09:00)" — the dollars only once the
    # gateway has sent both; a daily limit resets within the day.
    fmt=$TIME_7D; [ "$SPEND_PERIOD" = "daily" ] && fmt=$TIME_5H
    used=$(usd "$SPEND_USED"); limit=$(usd "$SPEND_LIMIT"); dollars=""
    [ -n "$used" ] && [ -n "$limit" ] && dollars=" ${used}/${limit}"
    SEGS+=("$(rate_seg spend "$SPEND_PCT" "$SPEND_RESET" "$fmt" "$dollars")")
  fi

  LINE=""
  for s in "${SEGS[@]}"; do
    [ -n "$LINE" ] && LINE+=" │ "
    LINE+=$s
  done
  [ -n "$LINE" ] && printf '%s\n' "💰 ${LINE}"
fi

# ─── Line 5: PR number ───
# Prefer pr.number straight from the JSON (zero network). Only when it is
# absent do we fall back to `gh`, cached per branch with a configurable TTL.
if [ "${CCSL_SHOW_PR:-1}" = "1" ]; then
  # pr.number from the JSON is shown regardless of local git state; the gh
  # fallback only runs inside a git work tree.
  if [ -z "$PR_NUM" ] && [ "$IN_GIT" = "1" ] && command -v gh >/dev/null 2>&1; then
    PR_URL=''; PR_KIND=''   # leftovers of a numberless pr object must not dress up gh's PR
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

    # A GitLab merge request arrives in the same fields with pr.kind "mr" and
    # is conventionally written !N. The gh fallback only ever finds GitHub PRs.
    if [ "$PR_KIND" = "mr" ]; then LABEL="MR !${PR_NUM}"; else LABEL="PR #${PR_NUM}"; fi

    # OSC 8 hyperlink to pr.url (Cmd/Ctrl+click). The URL was checked to be a
    # plain http(s) URL in the jq pass; it is absent on the gh fallback.
    if [ -n "$PR_URL" ] && [ "${CCSL_LINKS:-1}" = "1" ]; then
      LABEL=$'\033]8;;'"${PR_URL}"$'\033\\'"${LABEL}"$'\033]8;;\033\\'
    fi
    printf '%s\n' "${MAG}${LABEL}${RST}${BADGE}"
  fi
fi
