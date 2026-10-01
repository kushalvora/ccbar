# ccbar

Lightweight, configurable Claude Code statusline with a color-coded context bar.

![License](https://img.shields.io/github/license/dipenchovatiya/ccbar)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)
![Shell](https://img.shields.io/badge/shell-bash-green)

![ccbar demo](screenshots/demo.png)

## Install

```bash
curl -sSfL https://raw.githubusercontent.com/dipenchovatiya/ccbar/main/install.sh | bash
```

That's it. Start a new Claude Code session to see the statusline.

## What You Get

| Widget | Color | What it shows |
|--------|-------|---------------|
| Git branch | Purple | Current branch name (truncated at 20 chars) |
| Git status | Salmon | Staged (S:n), unstaged (U:n), untracked (A:n) file counts |
| Git sync | Orange | Commits ahead (↑n) or behind (↓n) tracking branch |
| Worktree | Tan | Active worktree name (hidden when not in a worktree) |
| Folder | Cyan | Current working directory basename |
| Context bar | Blue / Gray | Visual fill bar showing context window usage |
| Context % | Green / Yellow / Red | Percentage used; color shifts at configurable thresholds |
| Token count | Dim | Used and total tokens (e.g. 44k/200k) |
| Model | Gold | Model name from session data |
| Cost | Green | Cumulative session cost in USD |
| Subagents | Mauve | Count, combined tokens and API-list value of subagents (`⊂3 48.6M $52.50`); hidden when none have run |
| Duration | Light gray | Total session wall-clock time |
| Speed | Light blue | Output token throughput in tokens/second |

## Configuration

Config file: `~/.config/ccbar/config`

Created automatically on first install. Changes take effect on the next Claude Code turn — no restart needed.

**Disable widgets you don't want:**

```bash
SHOW_SPEED=false
SHOW_WORKTREE=false
SHOW_GIT_STATUS=false
```

**Adjust context threshold colors:**

```bash
THRESHOLD_MID=50    # green → yellow at 50% (default: 40)
THRESHOLD_HIGH=85   # yellow → red at 85% (default: 80)
```

**Change colors (ANSI 256 codes):**

```bash
COLOR_BRANCH=39     # bright blue instead of purple
COLOR_MODEL=208     # orange instead of gold
COLOR_COST=82       # brighter green
```

See [`config.default`](config.default) for all available options.
Color reference: [256colors.com](https://256colors.com)

## Uninstall

```bash
curl -sSfL https://raw.githubusercontent.com/dipenchovatiya/ccbar/main/install.sh | bash -s -- --uninstall
```

Your config at `~/.config/ccbar/config` is preserved. To remove it as well:

```bash
curl -sSfL https://raw.githubusercontent.com/dipenchovatiya/ccbar/main/install.sh | bash -s -- --uninstall --purge
```

## The Subagent Widget

Claude Code keeps each subagent's turns in a sidecar file and never folds them into the main transcript:

```
~/.claude/projects/<project>/<session-id>.jsonl              <- main thread
~/.claude/projects/<project>/<session-id>/subagents/*.jsonl  <- one per subagent
```

Subagents also get their own context windows, so their tokens never appear in the context bar. That is the point of delegating work to them, and it is why they need a separate readout.

ccbar parses those sidecar files and prices the usage at Anthropic's published API rates, split across input, output, cache read, and the two cache-write tiers.

**The dollar amount is API-list value, not a bill.** It is what that work would cost at list prices. On a subscription plan you pay the plan price instead.

Two details matter for correctness, both verified against real transcripts:

- A single API turn is written across several lines as streaming snapshots. Within one `message.id` the input and cache counts repeat verbatim while `output_tokens` grows, so the parse groups by `message.id`, takes input and cache once, and takes the maximum output. Summing raw lines overcounts by roughly 2x. `requestId` is `null` in these files, so it cannot serve as the key.
- Cache writes bill at two different rates, tracked separately as `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`.

Results are cached in `~/.claude/cache/`, keyed on file count, total size and newest mtime, so a turn with no new subagent activity costs a single `stat`. Model prices live in a table at the top of `ccbar.sh`; override it by pointing `CCBAR_PRICES` at a JSON file in the same shape, or by creating `~/.config/ccbar/prices.json`.

Turn the widget off entirely with `SHOW_SUBAGENTS=false`.

## How It Works

ccbar is a bash script registered as Claude Code's `statusCommand`. On each turn, Claude Code pipes a JSON blob to stdin containing session data — context window usage, model, cost, duration, and token counts. ccbar parses it with `jq`, runs a pair of `git` commands against the current working directory, and writes a single ANSI-colored line to stdout.

## Performance

Typical render time is ~60ms. There is no Node.js, no npm, no daemon, and no background process — ccbar exits completely after each turn.

Benchmark it yourself:

```bash
echo '{"context_window":{"used_percentage":42,"context_window_size":200000,"total_input_tokens":80000,"total_output_tokens":4000},"model":"claude-sonnet-4-5","cost":{"total_cost_usd":0.12,"total_duration_ms":180000,"total_api_duration_ms":9000}}' \
  | time bash ~/.claude/ccbar.sh
```

## Requirements

| Requirement | Notes |
|-------------|-------|
| macOS or Linux | Tested on macOS 13+ and Ubuntu 22.04+ |
| bash 3.2+ | Ships with macOS; available everywhere on Linux |
| jq | `brew install jq` / `apt install jq` / `dnf install jq` |
| bc | Ships with macOS and most Linux distributions |
| git | Required for branch and status widgets |

## License

MIT
