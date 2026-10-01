#!/usr/bin/env bash
# ccbar v1.0.0
# Claude Code statusline — color-coded context bar + stats
# Receives session JSON on stdin from Claude Code

# -- Version flag --
if [[ "$1" == "--version" ]]; then
  echo "ccbar v1.0.0"
  exit 0
fi

# -- jq check --
if ! command -v jq &>/dev/null; then
  echo "ccbar: jq is required. Install: brew install jq (macOS) or apt install jq (Linux)" >&2
  exit 1
fi

# -- Default config values --
SHOW_BRANCH=true
SHOW_GIT_STATUS=true
SHOW_FOLDER=true
SHOW_CONTEXT_BAR=true
SHOW_TOKEN_COUNT=true
SHOW_MODEL=true
SHOW_COST=true
SHOW_DURATION=true
SHOW_SPEED=true
SHOW_WORKTREE=true
SHOW_GIT_SYNC=true
SHOW_SUBAGENTS=true

BAR_WIDTH=20
THRESHOLD_MID=40
THRESHOLD_HIGH=80

# Subagent scan guards: skip the parse above this many bytes of transcript, and
# hard-kill it after this many seconds so the statusline can never hang.
SUBAGENT_MAX_BYTES=80000000
SUBAGENT_TIMEOUT=3

COLOR_BRANCH=141
COLOR_GIT_STATUS=209
COLOR_FOLDER=117
COLOR_MODEL=222
COLOR_COST=114
COLOR_DURATION=251
COLOR_SPEED=111
COLOR_WORKTREE=179
COLOR_GIT_SYNC=215
COLOR_BAR_FILL=75
COLOR_SUBAGENT=176
COLOR_HEALTH_OK=114
COLOR_HEALTH_MID=222
COLOR_HEALTH_BAD=196

SEPARATOR="│"
BRANCH_MAX_LEN=20

# -- Safe config loader (no source — prevents code injection) --
load_config() {
  local cfg="${CCBAR_CONFIG:-$HOME/.config/ccbar/config}"
  [[ -f "$cfg" ]] || return
  while IFS='=' read -r key val; do
    key="${key%%#*}"; key="${key#"${key%%[! ]*}"}"; key="${key%"${key##*[! ]}"}"
    val="${val%%#*}"; val="${val#"${val%%[! ]*}"}"; val="${val%"${val##*[! ]}"}"
    # Strip matched surrounding quotes (handles users writing KEY="value")
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    case "$key" in
      SHOW_*|BAR_WIDTH|THRESHOLD_*|COLOR_*|SEPARATOR|BRANCH_MAX_LEN|SUBAGENT_*) printf -v "$key" '%s' "$val" ;;
    esac
  done < "$cfg"
}
load_config

# -- Build ANSI colors from config --
RESET="\033[0m"
DIM="\033[2m"
BOLD="\033[1m"
C_BRANCH="\033[38;5;${COLOR_BRANCH}m"
C_GITSTATUS="\033[38;5;${COLOR_GIT_STATUS}m"
C_FOLDER="\033[38;5;${COLOR_FOLDER}m"
C_MODEL="\033[38;5;${COLOR_MODEL}m"
C_COST="\033[38;5;${COLOR_COST}m"
C_DURATION="\033[38;5;${COLOR_DURATION}m"
C_SPEED="\033[38;5;${COLOR_SPEED}m"
C_WORKTREE="\033[38;5;${COLOR_WORKTREE}m"
C_GITSYNC="\033[38;5;${COLOR_GIT_SYNC}m"
C_BAR_FILL="\033[38;5;${COLOR_BAR_FILL}m"
C_SUBAGENT="\033[38;5;${COLOR_SUBAGENT}m"
C_HEALTH_OK="\033[38;5;${COLOR_HEALTH_OK}m"
C_HEALTH_MID="\033[38;5;${COLOR_HEALTH_MID}m"
C_HEALTH_BAD="\033[38;5;${COLOR_HEALTH_BAD}m"
GRAY="\033[38;5;242m"

FILLED="█"
EMPTY="░"

# -- Read JSON from stdin --
JSON=""
if [[ ! -t 0 ]]; then
  JSON=$(cat)
fi

# -- JSON parser --
jv() { echo "$JSON" | jq -r "$1 // empty" 2>/dev/null || true; }

# -- Parse session data --
USED_PCT=$(jv '.context_window.used_percentage')
USED_PCT=${USED_PCT:-0}

# Model: can be object {id, display_name} or plain string
MODEL=$(jv '.model.display_name')
[[ -z "$MODEL" ]] && MODEL=$(jv '.model.id')
[[ -z "$MODEL" ]] && MODEL=$(jv '.model')
MODEL=${MODEL:-"—"}

# Cost
COST_RAW=$(jv '.cost.total_cost_usd')
if [[ -n "$COST_RAW" && "$COST_RAW" != "null" ]]; then
  COST=$(printf '$%.2f' "$COST_RAW")
else
  COST='$0.00'
fi

# Session duration (from cost.total_duration_ms)
DUR_MS=$(jv '.cost.total_duration_ms')
DURATION=""
if [[ -n "$DUR_MS" && "$DUR_MS" != "null" && "$DUR_MS" != "0" ]]; then
  DUR_S=$((DUR_MS / 1000))
  if [[ $DUR_S -ge 3600 ]]; then
    DUR_H=$((DUR_S / 3600))
    DUR_M=$(( (DUR_S % 3600) / 60 ))
    DURATION="${DUR_H}h${DUR_M}m"
  elif [[ $DUR_S -ge 60 ]]; then
    DUR_M=$((DUR_S / 60))
    DURATION="${DUR_M}m"
  else
    DURATION="${DUR_S}s"
  fi
fi

# Token speed (output tokens / total API duration)
API_MS=$(jv '.cost.total_api_duration_ms')
INPUT_TOK=$(jv '.context_window.total_input_tokens')
OUTPUT_TOK=$(jv '.context_window.total_output_tokens')
SPEED=""
if [[ -n "$API_MS" && "$API_MS" != "null" && "$API_MS" -gt 0 ]] 2>/dev/null; then
  OUT_TOK=${OUTPUT_TOK:-0}
  if [[ $OUT_TOK -gt 0 ]]; then
    TPS=$(( OUT_TOK * 1000 / API_MS ))
    SPEED="${TPS} t/s"
  fi
fi

# -- Subagent usage ------------------------------------------------------------
# Claude Code keeps each subagent's turns in a sidecar file and never folds them
# into the main transcript, so they have to be read separately:
#   <transcript>.jsonl              <- main thread
#   <transcript>/subagents/*.jsonl  <- one file per subagent
#
# Two correctness notes, both verified against real transcripts:
#  1. One API turn spans several lines (streaming snapshots). Within a
#     message.id the input/cache counts repeat verbatim while output_tokens
#     grows, so group by message.id, take input/cache once, take max output.
#     Summing raw lines overcounts by roughly 2x. requestId is null here, so it
#     cannot be the dedupe key.
#  2. Cache writes bill at two tiers: ephemeral_5m and ephemeral_1h.
#
# Cost is API-list value, not a bill. On a subscription the plan price applies.
SUB_PRICES='[
 {"id":"claude-opus-5-5","input":4,"output":20,"cacheRead":0.2,"cacheWrite":5,"cacheWriteLong":8},
 {"id":"claude-opus-5","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWriteLong":10},
 {"id":"claude-opus-4-8","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWriteLong":10},
 {"id":"claude-opus-4-7","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWriteLong":10},
 {"id":"claude-opus-4-6","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWriteLong":10},
 {"id":"claude-opus-4-5","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"cacheWriteLong":10},
 {"id":"claude-opus-4","input":15,"output":75,"cacheRead":1.5,"cacheWrite":18.75,"cacheWriteLong":30},
 {"id":"claude-fable-5-1","input":10,"output":50,"cacheRead":0.25,"cacheWrite":12.5,"cacheWriteLong":20},
 {"id":"claude-fable-5","input":10,"output":50,"cacheRead":1,"cacheWrite":12.5,"cacheWriteLong":20},
 {"id":"claude-sonnet-5","input":2,"output":10,"cacheRead":0.2,"cacheWrite":2.5,"cacheWriteLong":4},
 {"id":"claude-sonnet-4-6","input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75,"cacheWriteLong":6},
 {"id":"claude-sonnet-4-5","input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75,"cacheWriteLong":6},
 {"id":"claude-haiku-4-5","input":1,"output":5,"cacheRead":0.1,"cacheWrite":1.25,"cacheWriteLong":2}
]'
# Optional override: a JSON array in the same shape.
SUB_PRICES_FILE="${CCBAR_PRICES:-$HOME/.config/ccbar/prices.json}"
[[ -f "$SUB_PRICES_FILE" ]] && SUB_PRICES=$(cat "$SUB_PRICES_FILE" 2>/dev/null)

SUB_AGENTS=0; SUB_TOKENS=0; SUB_COST=0

sub_scan() { # $1 = subagents dir; emits "agents<TAB>tokens<TAB>cost"
  local dir="$1" files n
  files=$(find "$dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null)
  [[ -z "$files" ]] && return 1
  n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  jq -s -r --argjson prices "$SUB_PRICES" --arg n "$n" '
    [ .[] | select(.type == "assistant" and .message.usage != null) ]
    | group_by(.message.id)
    | map({
        model: (.[0].message.model // ""),
        inp:   (.[0].message.usage.input_tokens // 0),
        cw5:   (.[0].message.usage.cache_creation.ephemeral_5m_input_tokens
                  // .[0].message.usage.cache_creation_input_tokens // 0),
        cw1:   (.[0].message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
        cr:    (.[0].message.usage.cache_read_input_tokens // 0),
        out:   ([ .[].message.usage.output_tokens // 0 ] | max)
      })
    | map(.model as $m | . + { p: ([ $prices[]
        | select(.id as $i | $m | startswith($i)) ] | sort_by(.id | length) | last) })
    | { agents: ($n | tonumber),
        tokens: ([ .[] | .inp + .cw5 + .cw1 + .cr + .out ] | add // 0),
        cost:   ([ .[] | ( .inp * (.p.input          // 0)
                         + .cw5 * (.p.cacheWrite     // 0)
                         + .cw1 * (.p.cacheWriteLong // 0)
                         + .cr  * (.p.cacheRead      // 0)
                         + .out * (.p.output         // 0) ) / 1000000 ] | add // 0) }
    | "\(.agents)\t\(.tokens)\t\(.cost)"
  ' $files 2>/dev/null
}

if [[ "$SHOW_SUBAGENTS" == "true" ]]; then
  TRANSCRIPT=$(jv '.transcript_path')
  SUBDIR="${TRANSCRIPT%.jsonl}/subagents"
  if [[ -n "$TRANSCRIPT" && -d "$SUBDIR" ]]; then
    # Cache key: file count + cumulative size + newest mtime. Cheap to compute,
    # and changes whenever any subagent writes, so a quiet render costs one stat.
    # stat(1) differs between BSD/macOS and GNU/Linux, so pick the format once.
    if stat -f '%z' /dev/null >/dev/null 2>&1; then
      STAT_ARGS=(-f '%z %m')      # BSD
    else
      STAT_ARGS=(-c '%s %Y')      # GNU
    fi
    KEY=$(find "$SUBDIR" -maxdepth 1 -type f -name '*.jsonl' \
            -exec stat "${STAT_ARGS[@]}" {} + 2>/dev/null \
          | awk '{s+=$1; if ($2>m) m=$2; c++} END {print c"-"s"-"m}')
    BYTES=${KEY#*-}; BYTES=${BYTES%-*}
    CACHE_DIR="$HOME/.claude/cache"
    CACHE_F="$CACHE_DIR/ccbar-sub-$(jv '.session_id')"
    CACHED=""
    [[ -f "$CACHE_F" ]] && CACHED=$(cat "$CACHE_F" 2>/dev/null)

    if [[ -n "$CACHED" && "${CACHED%%|*}" == "$KEY" ]]; then
      IFS=$'\t' read -r SUB_AGENTS SUB_TOKENS SUB_COST <<< "${CACHED#*|}"
    elif [[ "${BYTES:-0}" -le "$SUBAGENT_MAX_BYTES" ]] 2>/dev/null; then
      # Watchdog: no timeout(1) on stock macOS, so run the parse in the
      # background and kill it if it overruns. A miss just skips the segment.
      # Explicit template: bare `mktemp -t prefix` is not portable to GNU.
      TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/ccbar-sub.XXXXXX" 2>/dev/null) || TMP_OUT=""
      if [[ -n "$TMP_OUT" ]]; then
        sub_scan "$SUBDIR" > "$TMP_OUT" 2>/dev/null &
        SCAN_PID=$!
        ( sleep "$SUBAGENT_TIMEOUT"; kill -9 "$SCAN_PID" 2>/dev/null ) 2>/dev/null &
        WATCH_PID=$!
        disown "$WATCH_PID" 2>/dev/null || true   # suppress the "Killed" job notice
        wait "$SCAN_PID" 2>/dev/null
        kill -9 "$WATCH_PID" 2>/dev/null
        RESULT=$(cat "$TMP_OUT" 2>/dev/null)
        rm -f "$TMP_OUT" 2>/dev/null
        if [[ -n "$RESULT" ]]; then
          IFS=$'\t' read -r SUB_AGENTS SUB_TOKENS SUB_COST <<< "$RESULT"
          mkdir -p "$CACHE_DIR" 2>/dev/null
          printf '%s|%s' "$KEY" "$RESULT" > "$CACHE_F" 2>/dev/null
          # Prune stale entries. Only runs on a cache miss, so it is not hot.
          find "$CACHE_DIR" -maxdepth 1 -name 'ccbar-sub-*' -mtime +7 -delete 2>/dev/null
        fi
      fi
    fi
  fi
fi

# Worktree — key is absent (not null) when not in a worktree
WORKTREE=$(jv '.worktree.name')

# Folder
CWD=$(jv '.cwd')
CWD=${CWD:-$(pwd)}
FOLDER=$(basename "$CWD")

# -- Git info --
BRANCH=""
GIT_STAT=""
if git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
  BRANCH=${BRANCH:-"detached"}
  if [[ ${#BRANCH} -gt $BRANCH_MAX_LEN ]]; then
    BRANCH="${BRANCH:0:$(( BRANCH_MAX_LEN - 1 ))}…"
  fi

  S=0; U=0; A=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    x="${line:0:1}"; y="${line:1:1}"
    if [[ "$x" == "?" ]]; then
      A=$((A + 1))
    else
      [[ "$x" != " " ]] && S=$((S + 1))
      [[ "$y" != " " ]] && U=$((U + 1))
    fi
  done < <(git -C "$CWD" status --porcelain 2>/dev/null)

  GIT_STAT=""
  [[ $S -gt 0 ]] && GIT_STAT+="S:$S "
  [[ $U -gt 0 ]] && GIT_STAT+="U:$U "
  [[ $A -gt 0 ]] && GIT_STAT+="A:$A "
  GIT_STAT="${GIT_STAT% }"

  # Ahead/behind tracking branch
  GIT_SYNC=""
  if upstream=$(git -C "$CWD" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    ahead=$(git -C "$CWD" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$CWD" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    [[ $ahead -gt 0 ]] && GIT_SYNC+="↑$ahead "
    [[ $behind -gt 0 ]] && GIT_SYNC+="↓$behind "
    GIT_SYNC="${GIT_SYNC% }"
  fi
fi

# -- Context bar --
CTX_SIZE=$(jv '.context_window.context_window_size')
CTX_SIZE=${CTX_SIZE:-200000}

# Format token counts as "44k" or "1.2M"
fmt_k() {
  local n=$1
  if [[ $n -ge 1000000 ]]; then
    printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif [[ $n -ge 1000 ]]; then
    printf "%.0fk" "$(echo "scale=1; $n/1000" | bc)"
  else
    printf "%d" "$n"
  fi
}

# Total used tokens (from percentage * window size)
USED_TOK=$(( USED_PCT * CTX_SIZE / 100 ))

# Health color for percentage
if [[ "$USED_PCT" -lt "$THRESHOLD_MID" ]]; then
  HC="$C_HEALTH_OK"
elif [[ "$USED_PCT" -lt "$THRESHOLD_HIGH" ]]; then
  HC="$C_HEALTH_MID"
else
  HC="$C_HEALTH_BAD"
fi

# Build bar
fc=$(( USED_PCT * BAR_WIDTH / 100 ))
ec=$(( BAR_WIDTH - fc ))
bar="${HC}["
for ((i=0; i<fc; i++)); do bar+="${C_BAR_FILL}${FILLED}"; done
bar+="${C_BAR_EMPTY:-\033[38;5;240m}"
for ((i=0; i<ec; i++)); do bar+="${EMPTY}"; done
bar+="${HC}] ${USED_PCT}%"
if [[ "$SHOW_TOKEN_COUNT" == "true" ]]; then
  bar+=" ${DIM}($(fmt_k $USED_TOK)/$(fmt_k $CTX_SIZE))"
fi
bar+="${RESET}"

# -- Assemble --
SEP=" ${GRAY}${SEPARATOR}${RESET} "
out=""

# Branch (purple)
if [[ "$SHOW_BRANCH" == "true" ]] && [[ -n "$BRANCH" ]]; then
  out+="${BOLD}${C_BRANCH}${BRANCH}${RESET}"
  # Git status (salmon)
  if [[ "$SHOW_GIT_STATUS" == "true" ]] && [[ -n "$GIT_STAT" ]]; then
    out+=" ${C_GITSTATUS}${GIT_STAT}${RESET}"
  fi
  # Git sync — ahead/behind (orange)
  if [[ "$SHOW_GIT_SYNC" == "true" ]] && [[ -n "$GIT_SYNC" ]]; then
    out+=" ${C_GITSYNC}${GIT_SYNC}${RESET}"
  fi
  out+="${SEP}"
fi

# Worktree (tan) — only when in a worktree
if [[ "$SHOW_WORKTREE" == "true" ]] && [[ -n "$WORKTREE" ]]; then
  out+="${C_WORKTREE}⌥ ${WORKTREE}${RESET}${SEP}"
fi

# Folder (cyan)
if [[ "$SHOW_FOLDER" == "true" ]]; then
  out+="${C_FOLDER}${FOLDER}${RESET}${SEP}"
fi

# Context bar (blue/white/orange)
if [[ "$SHOW_CONTEXT_BAR" == "true" ]]; then
  out+="${bar}${SEP}"
fi

# Model (gold)
if [[ "$SHOW_MODEL" == "true" ]]; then
  out+="${C_MODEL}${MODEL}${RESET}${SEP}"
fi

# Cost (green)
if [[ "$SHOW_COST" == "true" ]]; then
  out+="${C_COST}${COST}${RESET}"
fi

# Subagents (mauve) — omitted entirely when none have run this session
if [[ "$SHOW_SUBAGENTS" == "true" ]] && [[ "${SUB_AGENTS:-0}" -gt 0 ]] 2>/dev/null; then
  SUB_COST_FMT=$(printf '$%.2f' "${SUB_COST:-0}" 2>/dev/null || echo "\$0.00")
  out+="${SEP}${C_SUBAGENT}⊂${SUB_AGENTS} $(fmt_k "${SUB_TOKENS:-0}") ${SUB_COST_FMT}${RESET}"
fi

# Duration (light gray)
if [[ "$SHOW_DURATION" == "true" ]] && [[ -n "$DURATION" ]]; then
  out+="${SEP}${C_DURATION}${DURATION}${RESET}"
fi

# Speed (light blue)
if [[ "$SHOW_SPEED" == "true" ]] && [[ -n "$SPEED" ]]; then
  out+="${SEP}${C_SPEED}${SPEED}${RESET}"
fi

printf "%b" "$out"
