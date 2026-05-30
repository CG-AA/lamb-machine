#!/usr/bin/env bash
# Shared helpers for deploy.sh: logging, dry-run execution, file writing, and
# environment checks. Sourced, never run directly.
#
# Vendored & trimmed from ../../00-provision/lib/common.sh — intentionally
# self-contained so `rsync -a 40-hermes-oci/ vm:` ships a complete, runnable
# unit on the remote OCI VM (the rest of the repo is not cloned there). The
# disk/LUKS/btrfs helpers and the disk-specific failure cleanup were dropped;
# this component defines its own lighter cleanup in deploy.sh.

# --- logging -------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_DIM=$'\e[2m'
else
  C_RST=''; C_RED=''; C_YEL=''; C_BLU=''; C_DIM=''
fi
log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$@"; exit 1; }

# --- dry-run aware execution ---------------------------------------------
# DRY_RUN defaults to 1 (safe). deploy.sh sets it to 0 only on `--yes`.
run() {
  if [[ "${DRY_RUN:-1}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
  else
    printf '  %s+%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
    "$@"
  fi
}

# Like run(), but for a pipeline/redirection expressed as a single shell string.
# Use sparingly — only where `run cmd args` can't express it (pipes, redirects).
run_sh() {
  if [[ "${DRY_RUN:-1}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
  else
    printf '  %s+%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
    bash -c "$*"
  fi
}

# Write a file (creating parent dirs). Reads content from stdin. In dry-run it
# prints the content with a "| " gutter. If REDACT=1, lines matching a secret
# assignment (FOO_TOKEN=, FOO_KEY=, FOO_PASSWORD=, ..._SECRET=) are masked in
# the dry-run preview so secrets never reach the terminal/logs.
write_target_file() {
  local path="$1" mode="${2:-}" content; content="$(cat)"
  if [[ "${DRY_RUN:-1}" == "1" ]]; then
    printf '  %s[dry-run]%s would write %s%s:\n' "$C_DIM" "$C_RST" "$path" \
      "${mode:+ (mode $mode)}" >&2
    local _line
    while IFS= read -r _line; do
      if [[ "${REDACT:-0}" == "1" && "$_line" =~ ^[A-Za-z_][A-Za-z0-9_]*(TOKEN|KEY|PASSWORD|SECRET|PASSWD)=. ]]; then
        printf '        | %s=<redacted>\n' "${_line%%=*}" >&2
      else
        printf '        | %s\n' "$_line" >&2
      fi
    done <<<"$content"
  else
    printf '  %s+%s write %s%s\n' "$C_DIM" "$C_RST" "$path" "${mode:+ (mode $mode)}" >&2
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
    [[ -n "$mode" ]] && chmod "$mode" "$path"
  fi
}

# --- environment checks --------------------------------------------------
require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "must run as root for a real run (use sudo)"; }

# Return 0 if $1 is on $PATH. Otherwise: die under CI=1 (so CI is deterministic),
# warn-and-return-1 otherwise (so authoring on a machine missing some tool
# still runs the checks it can). $2 is a human-readable label for the message.
require_or_skip() {
  local cmd="$1" label="$2"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if [[ "${CI:-0}" == "1" ]]; then
    die "missing required tool: $cmd ($label)"
  fi
  warn "skipping $label: $cmd not installed (set CI=1 to hard-fail)"
  return 1
}

# True if $1 equals any later argument.
in_list() { local needle="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done; return 1; }

# --- secrets validation --------------------------------------------------
# Validate a secrets.env file: presence, perms, required non-empty vars. NEVER
# prints values. In dry-run, missing file is a warning (so the plan is
# reviewable). Positional-arg shape lets the test harness call it in isolation.
# Usage: check_secrets <secrets_file> <llm_provider>
# shellcheck disable=SC2154  # DRY_RUN is set by the caller (deploy.sh main)
check_secrets() {
  local secrets_file="$1" llm_provider="${2:-}"
  if [[ ! -f "$secrets_file" ]]; then
    [[ "${DRY_RUN:-1}" == "0" ]] && die "missing $secrets_file — copy secrets.env.example to secrets.env and fill it in"
    warn "no $secrets_file yet (cp secrets.env.example secrets.env; chmod 600) — required for a real run"
    return 0
  fi
  local perms; perms="$(stat -c '%a' "$secrets_file" 2>/dev/null || echo '?')"
  [[ "$perms" == "600" ]] || warn "$secrets_file mode is $perms; should be 600 (chmod 600 $secrets_file)"
  # presence/non-emptiness only — read without exposing
  local tok users key
  tok="$(awk -F= '/^DISCORD_BOT_TOKEN=/{print (length($2)>0)}' "$secrets_file")"
  users="$(awk -F= '/^DISCORD_ALLOWED_USERS=/{print (length($2)>0)}' "$secrets_file")"
  key="$(grep -cE '^(OPENROUTER_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY|GROQ_API_KEY)=.+' "$secrets_file" || true)"
  [[ "$tok" == "1" ]]   || die "DISCORD_BOT_TOKEN is empty in $secrets_file"
  [[ "$users" == "1" ]] || die "DISCORD_ALLOWED_USERS is empty — refusing to deploy an open bot (set your Discord user ID)"
  (( key >= 1 ))        || die "no LLM API key set in $secrets_file (need exactly one, e.g. OPENROUTER_API_KEY)"
  (( key == 1 ))        || warn "more than one LLM key set in $secrets_file; Hermes will pick by provider — make sure it matches LLM_PROVIDER=$llm_provider"
  # forbidden keys that would weaken the sandbox
  if grep -qE '^(SUDO_PASSWORD|HERMES_DOCKER_BINARY|TERMINAL_DOCKER_|TERMINAL_SSH_|GATEWAY_ALLOW_ALL_USERS=true)' "$secrets_file"; then
    die "$secrets_file sets a forbidden key (SUDO_PASSWORD / *_DOCKER_* / *_SSH_* / GATEWAY_ALLOW_ALL_USERS=true) — remove it; deploy.sh hard-locks the backend"
  fi
}
