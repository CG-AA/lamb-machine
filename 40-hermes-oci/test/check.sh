#!/usr/bin/env bash
# check.sh — authoring-time validation pipeline for 40-hermes-oci. Sourced by
# deploy.sh; defines `step_check` (callable as `./deploy.sh check`).
#
# What it covers:
#   1. shell hygiene  — shellcheck + bash -n
#   2. template render — render each .tmpl with deterministic test values into
#      a tmp dir; syntax-check each rendered file with the right native tool
#      (nft -c, python yaml, regex assertions for the Quadlet)
#   3. secrets validator — fixture envs under test/fixtures/secrets/{good,bad-*}
#      assert check_secrets() returns the expected exit code
#   4. secrets.env.example purity — no live values committed
#
# Missing external tools (shellcheck, nft, python3) warn-and-skip by default;
# CI=1 hard-fails on any missing tool so CI runs are deterministic.

# shellcheck shell=bash
# shellcheck disable=SC2154  # vars from deploy.sh / lib/common.sh (HERE, ASSETS, ...)

# --- helpers used by step_check; private (underscore prefix) ---------------

# Render every template into $1/<basename without .tmpl>. Test values are
# inline (not a fixture file) because DNS_ALLOW_RULES is multi-line and a
# KEY=VAL line-oriented file would need fragile escaping.
_check_render_all() {
  local out="$1"
  local dns_rules
  dns_rules="        ip daddr 1.1.1.1 udp dport 53 accept"$'\n'
  dns_rules+="        ip daddr 1.1.1.1 tcp dport 53 accept"

  render "$ASSETS/nftables-hermes.tmpl" \
    "HERMES_UID=10001" \
    "DNS_ALLOW_RULES=$dns_rules" \
    "BLOCKED_ELEMENTS=" \
    > "$out/40-hermes.nft" || { err "render nftables-hermes.tmpl failed"; return 1; }

  render "$ASSETS/config.yaml.tmpl" \
    "LLM_PROVIDER=openrouter" \
    "MODEL_LINE=  # default: <Hermes default>" \
    "BASE_URL_LINE=  # base_url: <provider default>" \
    > "$out/config.yaml" || { err "render config.yaml.tmpl failed"; return 1; }

  render "$ASSETS/hermes.container.tmpl" \
    "IMAGE=docker.io/test/hermes@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    "RUN_CMD=gateway run" \
    "DATA_DIR=/opt/hermes-fixture" \
    "MEM_MAX=2g" "CPUS=2" "PIDS_MAX=512" "SHM_SIZE=256m" \
    "PUBLISH_PORT_LINE=# (API not published — fixture)" \
    > "$out/hermes.container" || { err "render hermes.container.tmpl failed"; return 1; }
}

# Grep the rendered Quadlet against required/forbidden pattern lists. Each
# line of the list is a (POSIX-ERE) regex; lines starting with # or blank are
# skipped. A required pattern that doesn't match fails; a forbidden pattern
# that DOES match fails.
_check_quadlet() {
  local rendered="$1" fail=0 pat
  local req="$HERE/test/fixtures/expected/quadlet-required.txt"
  local forb="$HERE/test/fixtures/expected/quadlet-forbidden.txt"
  # Strip #-comments and blank lines so the template's own documentation
  # ("we never set seccomp=unconfined", "PodmanArgs=--memory=...") doesn't
  # self-match the forbidden list. The Quadlet parser ignores #-lines too.
  local stripped; stripped="$(mktemp -t hermes-check-quadlet.XXXXXX)"
  grep -vE '^[[:space:]]*(#|$)' "$rendered" > "$stripped"

  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" =~ ^[[:space:]]*# ]] && continue
    # -e -- so patterns starting with '--' (e.g. --memory=) aren't read as flags.
    grep -qE -e "$pat" -- "$stripped" \
      || { err "quadlet missing required pattern: $pat"; fail=1; }
  done < "$req"
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" =~ ^[[:space:]]*# ]] && continue
    if grep -qE -e "$pat" -- "$stripped"; then
      err "quadlet contains forbidden pattern: $pat"; fail=1
    fi
  done < "$forb"
  rm -f "$stripped"
  return "$fail"
}

# Run check_secrets against every fixture and assert exit code matches the
# filename prefix (good.env → 0, bad-*.env → 1).
_check_secrets_fixtures() {
  local f rc want fail=0
  for f in "$HERE"/test/fixtures/secrets/*.env; do
    case "$(basename "$f")" in
      good.env) want=0 ;;
      bad-*)    want=1 ;;
      *) continue ;;
    esac
    # Parenthesized subshell isolates die's exit while sharing $HERE.
    # check_secrets takes (file, llm_provider).
    ( DRY_RUN=0; source "$HERE/lib/common.sh"; check_secrets "$f" openrouter ) \
      >/dev/null 2>&1
    rc=$?
    if [[ "$rc" != "$want" ]]; then
      err "check_secrets($(basename "$f")): want rc=$want got rc=$rc"
      fail=1
    fi
  done
  return "$fail"
}

# secrets.env.example must contain no uncommented assignments with a non-empty
# RHS — it's a fill-in template, real values should never land in git.
_check_secrets_example_pristine() {
  local f="$HERE/secrets.env.example" leak
  [[ -f "$f" ]] || { err "secrets.env.example missing"; return 1; }
  leak="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=.+' "$f" || true)"
  if [[ -n "$leak" ]]; then
    err "secrets.env.example has non-empty assignment(s) — never commit real values:"
    printf '%s\n' "$leak" >&2
    return 1
  fi
}

# --- public entry point ---------------------------------------------------

step_check() {
  log "check — pre-deploy validation (local, no VM)"
  local fail=0 tmp
  tmp="$(mktemp -d -t hermes-check.XXXXXX)"
  # NOTE: RETURN trap fires on function return; if `die` is called it bypasses
  # this. Acceptable wart — tmp dir is under /tmp (tmpfs) and named distinctly.
  # shellcheck disable=SC2064  # expand $tmp NOW, not at trap-fire time
  trap "rm -rf '$tmp'" RETURN

  # 1. Shell hygiene
  if require_or_skip shellcheck "shellcheck"; then
    # --severity=warning skips SC2015 (info) for existing intentional
    # `cmd && log_ok || { err_fail; }` patterns in step_verify.
    shellcheck -x --severity=warning \
        "$HERE/deploy.sh" "$HERE/lib/common.sh" "$HERE/config.sh" \
        "$HERE/test/check.sh" \
      || { err "shellcheck reported warnings or errors"; ((fail++)); }
  fi
  local f
  for f in "$HERE"/*.sh "$HERE"/lib/*.sh "$HERE"/test/*.sh; do
    [[ -f "$f" ]] || continue
    bash -n "$f" || { err "bash -n: $f"; ((fail++)); }
  done

  # 2. Render templates into $tmp (test values inline in _check_render_all)
  _check_render_all "$tmp" || ((fail++))

  # 3a. nftables — full syntax check.
  # `nft -c -f` needs CAP_NET_ADMIN to initialize the netfilter netlink cache,
  # even in check-only mode. Wrap in `unshare -rn` to get an isolated user+net
  # namespace where the current user is mapped to root — no privilege needed
  # on the host, no kernel state touched. Falls back to direct nft if unshare
  # fails (e.g. unprivileged userns disabled).
  if require_or_skip nft "nftables syntax check"; then
    if ! unshare -rn nft -c -f "$tmp/40-hermes.nft" 2>/dev/null; then
      if ! nft -c -f "$tmp/40-hermes.nft" 2>/dev/null; then
        err "nft -c -f $tmp/40-hermes.nft: failed (need unprivileged userns or root)"
        ((fail++))
      fi
    fi
  fi
  # 3b. YAML parse + backend-locked assertion
  if require_or_skip python3 "yaml parse"; then
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' \
        "$tmp/config.yaml" \
      || { err "yaml parse: $tmp/config.yaml"; ((fail++)); }
  fi
  assert_backend_locked "$tmp" || { err "assert_backend_locked: failed"; ((fail++)); }
  # 3c. Quadlet — regex assertions (no upstream standalone linter)
  _check_quadlet "$tmp/hermes.container" || ((fail++))

  # 4. Secrets validator behavior
  _check_secrets_fixtures || ((fail++))
  # 5. secrets.env.example purity
  _check_secrets_example_pristine || ((fail++))

  if (( fail == 0 )); then
    log "check: OK"
  else
    die "check: $fail failure(s)"
  fi
}
