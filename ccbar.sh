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

BAR_WIDTH=20
THRESHOLD_MID=40
THRESHOLD_HIGH=80

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
      SHOW_*|BAR_WIDTH|THRESHOLD_*|COLOR_*|SEPARATOR|BRANCH_MAX_LEN) printf -v "$key" '%s' "$val" ;;
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
    # scale=3 so printf does the rounding; bc truncates, and at scale=1 that
    # turned 48.58M into 48.5M. The k branch below is unaffected because %.0f
    # already rounds bc's single decimal.
    printf "%.1fM" "$(echo "scale=3; $n/1000000" | bc)"
  elif [[ $n -ge 1000 ]]; then
    printf "%.0fk" "$(echo "scale=1; $n/1000" | bc)"
  else
    printf "%d" "$n"
  fi
}

# Total used tokens. Prefer the exact count Claude Code reports; fall back to
# deriving it from the integer percentage when the field is absent.
if [[ -n "$INPUT_TOK" && "$INPUT_TOK" != "null" && "$INPUT_TOK" -gt 0 ]] 2>/dev/null; then
  USED_TOK=$INPUT_TOK
else
  USED_TOK=$(( USED_PCT * CTX_SIZE / 100 ))
fi

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
  bar+=" ${DIM}($(fmt_k "$USED_TOK")/$(fmt_k "$CTX_SIZE"))"
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

# Duration (light gray)
if [[ "$SHOW_DURATION" == "true" ]] && [[ -n "$DURATION" ]]; then
  out+="${SEP}${C_DURATION}${DURATION}${RESET}"
fi

# Speed (light blue)
if [[ "$SHOW_SPEED" == "true" ]] && [[ -n "$SPEED" ]]; then
  out+="${SEP}${C_SPEED}${SPEED}${RESET}"
fi

printf "%b" "$out"
