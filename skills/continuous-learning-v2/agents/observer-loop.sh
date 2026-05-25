#!/usr/bin/env bash
# Continuous Learning v2 - Observer background loop
#
# Fix for #521: Added re-entrancy guard, cooldown throttle, and
# tail-based sampling to prevent memory explosion from runaway
# parallel Claude analysis processes.

set +e
unset CLAUDECODE

SLEEP_PID=""
USR1_FIRED=0
ANALYZING=0
LAST_ANALYSIS_EPOCH=0
CONSECUTIVE_FAILURES=0
MAX_FAILURES=3
BACKOFF_BASE=60
# Minimum seconds between analyses (prevents rapid re-triggering)
ANALYSIS_COOLDOWN="${ECC_OBSERVER_ANALYSIS_COOLDOWN:-60}"
# Idle self-termination: exit after this many consecutive cycles with no new
# observations, so the loop does not survive as an orphan past its session.
# observe.sh lazy-restarts the observer when tool activity resumes.
MAX_IDLE_CYCLES="${ECC_OBSERVER_MAX_IDLE_CYCLES:-4}"
IDLE_CYCLES=0
LAST_OBS_COUNT=-1

cleanup() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE"
  fi
  exit 0
}
trap cleanup TERM INT

analyze_observations() {
  if [ ! -f "$OBSERVATIONS_FILE" ]; then
    return
  fi

  obs_count=$(wc -l < "$OBSERVATIONS_FILE" 2>/dev/null || echo 0)
  last_analyzed=$(cat "${PROJECT_DIR}/.last-analyzed-line" 2>/dev/null || echo 0)
  new_count=$((obs_count - last_analyzed))
  if [ "$new_count" -lt "$MIN_OBSERVATIONS" ]; then
    return
  fi

  echo "[$(date)] Analyzing $obs_count observations for project ${PROJECT_NAME}..." >> "$LOG_FILE"

  if [ "${CLV2_IS_WINDOWS:-false}" = "true" ] && [ "${ECC_OBSERVER_ALLOW_WINDOWS:-false}" != "true" ]; then
    echo "[$(date)] Skipping claude analysis on Windows due to known non-interactive hang issue (#295). Set ECC_OBSERVER_ALLOW_WINDOWS=true to override." >> "$LOG_FILE"
    return
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "[$(date)] claude CLI not found, skipping analysis" >> "$LOG_FILE"
    return
  fi

  # session-guardian: gate observer cycle (active hours, cooldown, idle detection)
  if ! bash "$(dirname "$0")/session-guardian.sh"; then
    echo "[$(date)] Observer cycle skipped by session-guardian" >> "$LOG_FILE"
    return
  fi

  # Sample new (unanalyzed) observations, capped to prevent multi-MB payloads (#521).
  MAX_ANALYSIS_LINES="${ECC_OBSERVER_MAX_ANALYSIS_LINES:-40}"
  analysis_file="$(mktemp "${TMPDIR:-/tmp}/ecc-observer-analysis.XXXXXX.jsonl")"
  tail -n "$new_count" "$OBSERVATIONS_FILE" | tail -n "$MAX_ANALYSIS_LINES" > "$analysis_file"
  analysis_count=$(wc -l < "$analysis_file" 2>/dev/null || echo 0)
  echo "[$(date)] Analyzing $analysis_count new observations ($new_count since last run, $obs_count total)" >> "$LOG_FILE"

  prompt_file="$(mktemp "${TMPDIR:-/tmp}/ecc-observer-prompt.XXXXXX")"
  cat > "$prompt_file" <<PROMPT
Read ${analysis_file} and identify patterns for the project ${PROJECT_NAME} (user corrections, error resolutions, repeated workflows, tool preferences).
If you find 3+ occurrences of the same pattern, create an instinct file in ${INSTINCTS_DIR}/<id>.md.

CRITICAL EXECUTION RULES:
- You are a non-interactive background agent. There is NO user to grant permission.
- Write is in your allowedTools — call the Write tool directly to create instinct files.
- DO NOT ask for permission, DO NOT describe what you would write, DO NOT propose changes.
- Just call Write for each instinct file. The directory ${INSTINCTS_DIR} already exists.
- If you finish writing all instincts before max_turns, output one line: "DONE: <N> instincts written" and stop.

CRITICAL: Every instinct file MUST use this exact format:

---
id: kebab-case-name
trigger: when <specific condition>
confidence: <0.3-0.85 based on frequency: 3-5 times=0.5, 6-10=0.7, 11+=0.85>
domain: <one of: code-style, testing, git, debugging, workflow, file-patterns>
source: session-observation
scope: project
project_id: ${PROJECT_ID}
project_name: ${PROJECT_NAME}
---

# Title

## Action
<what to do, one clear sentence>

## Evidence
- Observed N times in session <id>
- Pattern: <description>
- Last observed: <date>

Rules:
- Be conservative, only clear patterns with 3+ observations
- Use narrow, specific triggers
- Never include actual code snippets, only describe patterns
- If a similar instinct already exists in ${INSTINCTS_DIR}/, update it instead of creating a duplicate
- The YAML frontmatter (between --- markers) with id field is MANDATORY
- If a pattern seems universal (not project-specific), set scope to global instead of project
- Examples of global patterns: always validate user input, prefer explicit error handling
- Examples of project patterns: use React functional components, follow Django REST framework conventions
PROMPT

  # Daily cost guard: cap analyses per day
  MAX_DAILY_ANALYSES="${ECC_OBSERVER_MAX_DAILY:-60}"
  today=$(date +%Y-%m-%d)
  counter_file="${PROJECT_DIR}/.observer-daily-count"
  daily_count=0
  if [ -f "$counter_file" ] && [ "$(head -1 "$counter_file" 2>/dev/null)" = "$today" ]; then
    daily_count=$(tail -1 "$counter_file" 2>/dev/null || echo 0)
  fi
  if [ "$daily_count" -ge "$MAX_DAILY_ANALYSES" ]; then
    echo "[$(date)] Daily analysis limit ($MAX_DAILY_ANALYSES) reached, skipping" >> "$LOG_FILE"
    rm -f "$prompt_file" "$analysis_file"
    return
  fi

  # Run error detector for pre-analysis (if available)
  error_report=""
  error_detector="${SKILL_ROOT}/scripts/error-detector.py"
  if [ -f "$error_detector" ]; then
    error_report=$("${PYTHON_CMD:-python3}" "$error_detector" "$analysis_file" 2>/dev/null || true)
  fi
  if [ -n "$error_report" ]; then
    cat >> "$prompt_file" <<ERROR_SECTION

## Pre-detected Repeat Error Patterns (HIGH PRIORITY)
These errors appeared 3+ times. Create instincts for them FIRST:

$error_report
ERROR_SECTION
  fi

  timeout_seconds="${ECC_OBSERVER_TIMEOUT_SECONDS:-120}"
  max_turns="${ECC_OBSERVER_MAX_TURNS:-20}"
  exit_code=0

  case "$max_turns" in
    ''|*[!0-9]*)
      max_turns=20
      ;;
  esac

  if [ "$max_turns" -lt 4 ]; then
    max_turns=20
  fi

  # Prevent observe.sh from recording this automated Haiku session as observations
  ECC_SKIP_OBSERVE=1 ECC_HOOK_PROFILE=minimal claude --model haiku --max-turns "$max_turns" --print \
    --allowedTools "Read,Write" \
    < "$prompt_file" >> "$LOG_FILE" 2>&1 &
  claude_pid=$!

  (
    sleep "$timeout_seconds"
    if kill -0 "$claude_pid" 2>/dev/null; then
      echo "[$(date)] Claude analysis timed out after ${timeout_seconds}s; terminating process" >> "$LOG_FILE"
      kill "$claude_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  wait "$claude_pid"
  exit_code=$?
  kill "$watchdog_pid" 2>/dev/null || true
  rm -f "$prompt_file" "$analysis_file"

  if [ "$exit_code" -ne 0 ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    echo "[$(date)] Analysis failed (exit $exit_code, $CONSECUTIVE_FAILURES/$MAX_FAILURES)" >> "$LOG_FILE"
    if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
      echo "[$(date)] FATAL: $MAX_FAILURES consecutive failures, observer stopping" >> "$LOG_FILE"
      cleanup
      exit 1
    fi
    backoff=$((BACKOFF_BASE * (2 ** (CONSECUTIVE_FAILURES - 1))))
    echo "[$(date)] Backing off ${backoff}s before next attempt" >> "$LOG_FILE"
    sleep "$backoff" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
    return
  else
    CONSECUTIVE_FAILURES=0
  fi

  # Mark how far we've analyzed (don't delete observations — they accumulate for richer analysis)
  echo "$obs_count" > "${PROJECT_DIR}/.last-analyzed-line"

  # Update daily analysis counter
  printf '%s\n%s\n' "$today" "$((daily_count + 1))" > "$counter_file"
}

on_usr1() {
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
  USR1_FIRED=1

  # Re-entrancy guard: skip if analysis is already running (#521)
  if [ "$ANALYZING" -eq 1 ]; then
    echo "[$(date)] Analysis already in progress, skipping signal" >> "$LOG_FILE"
    return
  fi

  # Cooldown: skip if last analysis was too recent (#521)
  now_epoch=$(date +%s)
  elapsed=$(( now_epoch - LAST_ANALYSIS_EPOCH ))
  if [ "$elapsed" -lt "$ANALYSIS_COOLDOWN" ]; then
    echo "[$(date)] Analysis cooldown active (${elapsed}s < ${ANALYSIS_COOLDOWN}s), skipping" >> "$LOG_FILE"
    return
  fi

  ANALYZING=1
  analyze_observations
  LAST_ANALYSIS_EPOCH=$(date +%s)
  ANALYZING=0
}
trap on_usr1 USR1

echo "$$" > "$PID_FILE"
echo "[$(date)] Observer started for ${PROJECT_NAME} (PID: $$)" >> "$LOG_FILE"

while true; do
  sleep "${OBSERVER_INTERVAL_SECONDS:-900}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""

  if [ "$USR1_FIRED" -eq 1 ]; then
    USR1_FIRED=0
  else
    analyze_observations
  fi

  # Idle self-termination: if the observation count has not moved for
  # MAX_IDLE_CYCLES cycles, the session is over — exit cleanly instead of
  # lingering as an orphan. observe.sh re-spawns us on the next tool call.
  cur_obs_count=$(wc -l < "$OBSERVATIONS_FILE" 2>/dev/null || echo 0)
  if [ "$cur_obs_count" = "$LAST_OBS_COUNT" ]; then
    IDLE_CYCLES=$((IDLE_CYCLES + 1))
    if [ "$IDLE_CYCLES" -ge "$MAX_IDLE_CYCLES" ]; then
      echo "[$(date)] Observer idle ${IDLE_CYCLES} cycles, exiting (lazy-restart on next activity)" >> "$LOG_FILE"
      cleanup
    fi
  else
    IDLE_CYCLES=0
  fi
  LAST_OBS_COUNT="$cur_obs_count"
done
