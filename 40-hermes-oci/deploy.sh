#!/usr/bin/env bash
#
# deploy.sh — deploy the Hermes agent into a hardened rootless Podman sandbox
# on a SHARED OCI ARM64 VM (Ubuntu 24.04). The container is the security
# boundary: Hermes keeps its Discord gateway and command-execution feature, but
# both are contained. See ./README.md for the threat model.
#
#   all         run the whole deploy (preflight -> ... -> enable -> verify hint)
#   verify      run the post-deploy checks (also a Discord runbook)
#   down        stop/disable the service (and optionally remove the nft ruleset)
#   check       authoring-time lint + template render validation (no VM needed)
#
#   preflight | user | podman | image | config | quadlet | nft | enable | hermesctl
#               run a single step (advanced; assumes earlier steps ran)
#
# Default mode is --dry-run (prints exact commands, changes nothing).
# Add --yes to execute. A real run needs root (sudo).
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/assets"
SECRETS_FILE="${SECRETS_FILE:-$HERE/secrets.env}"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=config.sh
source "${CONFIG:-$HERE/config.sh}"
# shellcheck source=test/check.sh
[[ -f "$HERE/test/check.sh" ]] && source "$HERE/test/check.sh"

# --- runtime state (also referenced by cleanup_on_failure) ---------------
DRY_RUN=1
HERMES_UID=""
HERMES_HOME=""
QUADLET_PATH=""
NFT_PATH="/etc/nftables.d/40-hermes.nft"
HERMESCTL_PATH="/usr/local/bin/hermesctl"
SERVICE_NAME="hermes.service"
RESOLVED_IMAGE=""           # digest-pinned ref filled by step_image
CREATED_QUADLET=0
CREATED_NFT=0
CREATED_HERMESCTL=0
STARTED_SERVICE=0

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'; }

# ========================================================================
# Helpers
# ========================================================================

# Resolve the hermes user's uid / home / data dir. Tolerant in dry-run so the
# plan can be reviewed on a box where the user doesn't exist yet.
resolve_user() {
  HERMES_UID="$(id -u "$HERMES_USER" 2>/dev/null || echo '<hermes-uid>')"
  # The user may not exist yet (first deploy) — guard against set -e/pipefail.
  HERMES_HOME="$(getent passwd "$HERMES_USER" 2>/dev/null | cut -d: -f6)" || true
  HERMES_HOME="${HERMES_HOME:-/home/$HERMES_USER}"
  [[ -n "$DATA_DIR" ]] || DATA_DIR="$HERMES_HOME/.hermes"
  QUADLET_PATH="$HERMES_HOME/.config/containers/systemd/hermes.container"
}

# Run a command as the hermes user with its user-systemd / dbus session env
# (works once linger has created /run/user/<uid>). Honors dry-run via run().
run_as_hermes() {
  # --chdir=/ : deploy.sh runs from the operator's home (e.g. ~ubuntu/..., mode
  # 750), which the hermes uid can't enter; without this the inherited cwd makes
  # the dropped-privilege command fail "cannot chdir ... Permission denied".
  run sudo -u "$HERMES_USER" \
    env --chdir=/ \
        "XDG_RUNTIME_DIR=/run/user/$HERMES_UID" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$HERMES_UID/bus" \
        "$@"
}

# Capture stdout of a hermes-user command (used where we need the value, e.g.
# the image digest). Returns empty in dry-run.
capture_as_hermes() {
  [[ "$DRY_RUN" == "0" ]] || { echo ""; return 0; }
  # --chdir=/ : see run_as_hermes (the dropped-privilege cwd would be unreadable).
  sudo -u "$HERMES_USER" \
    env --chdir=/ \
        "XDG_RUNTIME_DIR=/run/user/$HERMES_UID" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$HERMES_UID/bus" \
        "$@" 2>/dev/null || true
}

# Substitute @@TOKEN@@ markers. Remaining args are TOKEN=VALUE (values may be
# multi-line). Prints the rendered text to stdout.
render() {
  local tmpl="$1"; shift
  local content; content="$(cat "$tmpl")"
  local pair token value
  for pair in "$@"; do
    token="${pair%%=*}"; value="${pair#*=}"
    content="${content//@@${token}@@/$value}"
  done
  printf '%s\n' "$content"
}

# Detect the host's effective DNS resolver IP(s). We allow :53 to ALL of them
# (resolv.conf nameservers + resolvectl upstreams) because, depending on the
# rootless network backend, the container's egress :53 may land on the stub
# (127.0.0.53) or the real upstream (on OCI: 169.254.169.254). Allowing only
# :53 to these specific IPs keeps DNS working without opening general traffic.
detect_resolvers() {
  local out=() ip
  if have_cmd resolvectl; then
    while read -r ip; do [[ -n "$ip" ]] && out+=("$ip"); done < <(
      resolvectl status 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
  fi
  while read -r ip; do [[ -n "$ip" ]] && out+=("$ip"); done < <(
    awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  printf '%s\n' "${out[@]}" | awk 'NF' | sort -u
}

# ========================================================================
# Steps
# ========================================================================

step_preflight() {
  log "Preflight"
  # Architecture: this component is arm64-only. Hard-fail only on a real run so
  # the plan stays reviewable (dry-run) from any machine.
  if [[ "$(uname -m)" != "aarch64" ]]; then
    [[ "$DRY_RUN" == "0" ]] && die "targets arm64 (aarch64); got $(uname -m)"
    warn "not aarch64 ($(uname -m)) — fine for dry-run; a real run would refuse"
  fi
  # OS: warn-only (works on 24.04 derivatives too).
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "24.04" ]] || warn "expected Ubuntu 24.04; found ${PRETTY_NAME:-unknown}"
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    require_root
    # Only tools that must PRE-EXIST on the base image (systemd, iproute2,
    # coreutils, shadow). podman / nft / newuidmap / newgidmap are delivered by
    # step_base_packages (which runs next) and verified there — requiring them
    # here would fail on a fresh VM before we ever get a chance to install them.
    require_cmds systemctl loginctl ss id useradd usermod getent
    # Unprivileged user namespaces (rootless needs them). Ubuntu 24.04 ships
    # the AppArmor userns restriction — warn so it can be addressed if podman
    # can't create namespaces.
    local r
    r="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
    [[ "$r" == "1" ]] && warn "kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 24.04 default); rootless may need the podman AppArmor profile or relaxing this sysctl if 'podman info' fails"
    r="$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)"
    [[ "$r" == "0" ]] && die "kernel.unprivileged_userns_clone=0 — rootless Podman cannot create user namespaces"
  fi

  check_secrets "$SECRETS_FILE" "$LLM_PROVIDER"
  check_ports
  log "preflight OK"
}

# Warn if the API/dashboard ports are already taken by a co-resident workload.
check_ports() {
  have_cmd ss || return 0
  local p
  for p in "$API_PORT" 9119; do
    if ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .; then
      warn "port $p is already bound on this host — a neighbor uses it (we publish nothing by default)"
    fi
  done
}

step_base_packages() {
  log "Installing host packages (root)"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    podman uidmap slirp4netns fuse-overlayfs nftables dbus-user-session
  # Verify the install delivered the binaries the later steps depend on:
  # podman, the nft CLI, and the uidmap setuid helpers for the rootless
  # user-namespace mapping. (Real run only — in dry-run nothing was installed.)
  if [[ "$DRY_RUN" == "0" ]]; then
    require_cmds podman nft newuidmap newgidmap
  fi
}

step_user() {
  log "Creating unprivileged system user '$HERMES_USER' (root)"
  if id "$HERMES_USER" >/dev/null 2>&1; then
    log "  user exists — leaving it"
  else
    run useradd --system --create-home --home-dir "/home/$HERMES_USER" \
      --shell /usr/sbin/nologin "$HERMES_USER"
  fi
  # Subordinate uid/gid ranges for the rootless user namespace.
  if ! grep -q "^$HERMES_USER:" /etc/subuid 2>/dev/null; then
    run usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$HERMES_USER"
  fi
  # Delegate the cgroup-v2 controllers to user slices, or rootless --memory /
  # --cpus are silently ignored.
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | \
    write_target_file /etc/systemd/system/user@.service.d/delegate.conf
  run systemctl daemon-reload
  # Start (and keep, across logouts/reboots) the user manager so the Quadlet
  # service runs unattended and /run/user/<uid> exists for run_as_hermes.
  run loginctl enable-linger "$HERMES_USER"
  resolve_user   # uid now exists on a real run
  run systemctl start "user@$HERMES_UID.service"
}

step_podman() {
  log "Initializing rootless Podman storage (as $HERMES_USER)"
  run_as_hermes podman info >/dev/null
  if [[ "$DRY_RUN" == "0" ]]; then
    capture_as_hermes podman info --format '{{.Host.Security.Rootless}}' | grep -q true \
      || warn "podman does not report rootless:true — check user namespaces"
  fi
}

step_image() {
  log "Fetching image $HERMES_IMAGE (as $HERMES_USER)"
  if [[ "${HERMES_BUILD:-0}" == "1" ]]; then
    : "${HERMES_SRC:?set HERMES_SRC to a checkout of the hermes-agent repo to build}"
    run_as_hermes podman build --platform linux/arm64 -t localhost/hermes-agent:built "$HERMES_SRC"
    RESOLVED_IMAGE="localhost/hermes-agent:built"
    return 0
  fi
  # Best-effort arm64 manifest check; fall back to a build hint.
  if [[ "$DRY_RUN" == "0" ]] && ! capture_as_hermes podman manifest inspect "$HERMES_IMAGE" | grep -q arm64; then
    warn "no arm64 in the manifest for $HERMES_IMAGE — re-run with HERMES_BUILD=1 HERMES_SRC=<repo> to build locally"
  fi
  run_as_hermes podman pull --platform linux/arm64 "$HERMES_IMAGE"
  # Pin by digest for reproducible restarts.
  RESOLVED_IMAGE="$(capture_as_hermes podman inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$HERMES_IMAGE")"
  if [[ -n "$RESOLVED_IMAGE" ]]; then
    log "  resolved digest: $RESOLVED_IMAGE"
    log "  -> pin it in config.sh: HERMES_IMAGE=\"$RESOLVED_IMAGE\""
  else
    RESOLVED_IMAGE="$HERMES_IMAGE"
  fi
}

step_config() {
  log "Writing ~$HERMES_USER/.hermes/{config.yaml,.env} (as $HERMES_USER)"
  [[ -n "$RESOLVED_IMAGE" ]] || RESOLVED_IMAGE="$HERMES_IMAGE"

  # --- .env : pass through the operator's secret lines, then append the
  #     hard-locked safety settings. Strips any forbidden keys defensively.
  local env_body
  if [[ -f "$SECRETS_FILE" ]]; then
    env_body="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE" \
      | grep -vE '^(TERMINAL_ENV|GATEWAY_ALLOW_ALL_USERS|HERMES_DASHBOARD|HERMES_DOCKER_BINARY|TERMINAL_DOCKER_|TERMINAL_SSH_|SUDO_PASSWORD)=')"
  else
    env_body="# (no secrets.env present — fill it in before a real run)"
  fi
  {
    printf '%s\n' "$env_body"
    echo "TERMINAL_ENV=local"
    echo "GATEWAY_ALLOW_ALL_USERS=false"
    echo "HERMES_DASHBOARD=0"
    if [[ "$PUBLISH_API" == "1" ]]; then
      echo "API_SERVER_ENABLED=true"
      echo "API_SERVER_HOST=127.0.0.1"
    fi
  } | REDACT=1 write_target_file "$DATA_DIR/.env" 600

  # --- config.yaml : optional model/base_url lines only when set.
  local model_line base_line
  if [[ -n "$LLM_MODEL" ]]; then model_line="  default: \"$LLM_MODEL\""; else model_line="  # default: <Hermes default>"; fi
  if [[ -n "$LLM_BASE_URL" ]]; then base_line="  base_url: \"$LLM_BASE_URL\""; else base_line="  # base_url: <provider default>"; fi
  render "$ASSETS/config.yaml.tmpl" \
    "LLM_PROVIDER=$LLM_PROVIDER" "MODEL_LINE=$model_line" "BASE_URL_LINE=$base_line" \
    | write_target_file "$DATA_DIR/config.yaml" 644

  run chown -R "$HERMES_USER:$HERMES_USER" "$DATA_DIR"

  # Assert the backend lockdown actually held (no other-backend keys leaked).
  # Only on a real run — in dry-run the files we'd grep don't exist yet.
  if [[ "$DRY_RUN" == "0" ]]; then
    assert_backend_locked "$DATA_DIR"
  fi
}

# Assert that the rendered config in <config_dir> pins terminal.backend=local
# and contains no keys from any other backend. Greps only files that exist so
# the same function works both after step_config (config.yaml + .env) and from
# step_check (just config.yaml). Caller decides when to invoke (was previously
# DRY_RUN-gated internally).
assert_backend_locked() {
  local config_dir="$1"
  local -a targets=()
  [[ -f "$config_dir/config.yaml" ]] && targets+=("$config_dir/config.yaml")
  [[ -f "$config_dir/.env" ]] && targets+=("$config_dir/.env")
  (( ${#targets[@]} > 0 )) || die "assert_backend_locked: no config.yaml or .env in $config_dir"
  # Strip comment lines first — the template's own documentation describes the
  # forbidden keys (e.g. "NO docker_image / container_* / ssh_* keys") and
  # would otherwise self-match.
  local bad
  bad="$(grep -hEv '^[[:space:]]*#' "${targets[@]}" 2>/dev/null \
    | grep -Ei '(docker_image|container_(cpu|memory|disk|persistent|image)|ssh_host|TERMINAL_DOCKER_|HERMES_DOCKER_BINARY)' \
    || true)"
  [[ -z "$bad" ]] || die "backend lockdown failed — found non-local backend keys:\n$bad"
  if [[ -f "$config_dir/config.yaml" ]]; then
    grep -qE '^[[:space:]]*backend:[[:space:]]*local' "$config_dir/config.yaml" \
      || die "config.yaml terminal.backend is not 'local'"
  fi
}

step_quadlet() {
  log "Installing the hardened Quadlet unit (as $HERMES_USER)"
  [[ -n "$RESOLVED_IMAGE" ]] || RESOLVED_IMAGE="$HERMES_IMAGE"
  local publish_line
  if [[ "$PUBLISH_API" == "1" ]]; then
    publish_line="PublishPort=127.0.0.1:${API_PORT}:${API_PORT}"
  else
    publish_line="# (API not published — the Discord bot is outbound-only)"
  fi
  CREATED_QUADLET=1
  render "$ASSETS/hermes.container.tmpl" \
    "IMAGE=$RESOLVED_IMAGE" "RUN_CMD=$HERMES_RUN_CMD" "DATA_DIR=$DATA_DIR" \
    "MEM_MAX=$MEM_MAX" "CPUS=$CPUS" "PIDS_MAX=$PIDS_MAX" "SHM_SIZE=$SHM_SIZE" \
    "PUBLISH_PORT_LINE=$publish_line" \
    | write_target_file "$QUADLET_PATH" 644
  run chown -R "$HERMES_USER:$HERMES_USER" "$HERMES_HOME/.config"
  run_as_hermes systemctl --user daemon-reload
}

step_nft() {
  log "Installing the egress firewall (root)"
  local resolvers=()
  if [[ -n "$DNS_RESOLVER" ]]; then
    resolvers=("$DNS_RESOLVER")
  else
    mapfile -t resolvers < <(detect_resolvers)
  fi
  if ((${#resolvers[@]} == 0)); then
    [[ "$DRY_RUN" == "0" ]] && die "could not detect a DNS resolver — set DNS_RESOLVER in config.sh (OCI: usually 169.254.169.254)"
    resolvers=("169.254.169.254")   # OCI default, for a readable dry-run
    warn "DNS resolver not detected; showing OCI default 169.254.169.254 for dry-run"
  fi
  log "  allowing DNS :53 to: ${resolvers[*]}"

  local dns="" ip
  for ip in "${resolvers[@]}"; do
    dns+="        ip daddr ${ip} udp dport 53 accept"$'\n'
    dns+="        ip daddr ${ip} tcp dport 53 accept"$'\n'
  done
  dns="${dns%$'\n'}"

  local extra="" c
  for c in "${EXTRA_BLOCK_CIDRS[@]:-}"; do
    [[ -n "$c" ]] && extra+=", ${c}"
  done

  CREATED_NFT=1
  render "$ASSETS/nftables-hermes.tmpl" \
    "HERMES_UID=$HERMES_UID" "DNS_ALLOW_RULES=$dns" "BLOCKED_ELEMENTS=$extra" \
    | write_target_file "$NFT_PATH" 644

  # Make sure the boot-time loader pulls in /etc/nftables.d/*.nft.
  if [[ -f /etc/nftables.conf ]] && ! grep -q 'include "/etc/nftables.d/\*\.nft"' /etc/nftables.conf; then
    run_sh 'printf '\''\ninclude "/etc/nftables.d/*.nft"\n'\'' >> /etc/nftables.conf'
  fi
  # Syntax-check, then load now, then enable for boot.
  run nft -c -f "$NFT_PATH"
  run nft -f "$NFT_PATH"
  run systemctl enable nftables.service
}

step_enable() {
  log "Starting $SERVICE_NAME (as $HERMES_USER)"
  STARTED_SERVICE=1
  # Quadlet units are GENERATED by the podman-system-generator from the
  # .container file, so `systemctl enable` rejects them ("transient or
  # generated"). Boot-time autostart comes from the unit's
  # [Install] WantedBy=default.target plus linger (set in step_user); here we
  # only need to start it now.
  run_as_hermes systemctl --user start "$SERVICE_NAME"
}

# Install /usr/local/bin/hermesctl — the day-2 operator wrapper (rootless container
# + in-container CLI behind one command). Generated from the template with this
# install's real values; removed by step_down / cleanup_on_failure.
step_hermesctl() {
  log "Installing $HERMESCTL_PATH (operator wrapper, root)"
  CREATED_HERMESCTL=1
  render "$ASSETS/hermesctl.tmpl" \
    "HERMES_USER=$HERMES_USER" "HERMES_UID=$HERMES_UID" \
    "SERVICE_NAME=$SERVICE_NAME" "CONTAINER=hermes" \
    | write_target_file "$HERMESCTL_PATH" 755
}

# ========================================================================
# Verify / teardown
# ========================================================================

step_verify() {
  log "Verify"
  if [[ "$DRY_RUN" == "1" ]]; then
    cat >&2 <<EOF
  [dry-run] On the deployed VM, 'verify' will check:
    1. service settles to active/running with NO new restarts over ~18s (catches a
       crash-loop a single is-active would miss); Restart=always; survives podman kill
    2. podman inspect: ReadonlyRootfs=true, all caps dropped, PidsLimit/Memory set,
       NoNewPrivileges=true, non-identity userns mapping
    3. no docker/podman socket in Mounts; config has no non-local backend keys
    4. ACTIVE egress test from inside the container:
         curl -m5 http://169.254.169.254/opc/v2/instance/   -> must FAIL
         curl -m5 https://discord.com/api/v10/gateway        -> must SUCCEED
         a DNS lookup                                         -> must SUCCEED
    5. 'hermes doctor' inside the container -> no failed (✗) provider/env/config
       checks (catches a bad model slug / missing key the egress test can't)
  Then, from Discord as an allowlisted user (manual):
    6. bot replies; logs show a clean gateway login (Message Content + Server
       Members intents enabled in the Dev Portal)
    7. ask it to run: id; cat /etc/shadow; curl 169.254.169.254; hit a neighbor port
       -> command runs but is jailed (unprivileged, no host files, egress blocked)
    8. ffmpeg / browser tool still work (regression). If not: narrow Tmpfs or
       install-cache redirect, NOT weaker caps.
EOF
    return 0
  fi
  local fail=0
  # Service health: settle, then require active/running AND no NEW restarts over a
  # short window — a single is-active right after start can't tell a healthy service
  # from one in a crash-loop (it reports active between restarts).
  local n1 n2 astate sstate
  log "  waiting ~18s for the service to settle (crash-loop check)…"
  n1="$(capture_as_hermes systemctl --user show "$SERVICE_NAME" -p NRestarts --value)"
  sleep 10
  astate="$(capture_as_hermes systemctl --user show "$SERVICE_NAME" -p ActiveState --value)"
  sstate="$(capture_as_hermes systemctl --user show "$SERVICE_NAME" -p SubState --value)"
  sleep 8
  n2="$(capture_as_hermes systemctl --user show "$SERVICE_NAME" -p NRestarts --value)"
  if [[ "$astate" == "active" && "$sstate" == "running" && "$n2" == "$n1" ]]; then
    log "  service stable (active/running, no restarts in ~18s)"
  else
    err "  service NOT stable (ActiveState=$astate SubState=$sstate NRestarts ${n1:-?}->${n2:-?}) — likely crash-looping"
    journalctl "_SYSTEMD_USER_UNIT=$SERVICE_NAME" -n 30 --no-pager >&2 || true
    fail=1
  fi
  if capture_as_hermes podman inspect hermes --format '{{.HostConfig.ReadonlyRootfs}}' | grep -q true; then
    log "  rootfs read-only: yes"; else err "  rootfs NOT read-only"; fail=1; fi
  if capture_as_hermes podman inspect hermes --format '{{.Mounts}}' | grep -q 'docker.sock\|podman.sock'; then
    err "  a container socket is mounted — REMOVE IT"; fail=1; else log "  no container socket mounted"; fi
  log "  active egress test (metadata must fail, discord must pass):"
  if capture_as_hermes podman exec hermes curl -m5 -s -o /dev/null -w '%{http_code}' http://169.254.169.254/opc/v2/instance/ | grep -q 200; then
    err "    metadata REACHABLE (169.254.169.254) — firewall not effective"; fail=1
  else log "    metadata blocked"; fi
  # Capture the HTTP code (don't trust the exit status — capture_as_hermes swallows
  # it via `|| true`, which would make any result read as "reachable").
  local dcode
  dcode="$(capture_as_hermes podman exec hermes curl -m8 -s -o /dev/null -w '%{http_code}' https://discord.com/api/v10/gateway)"
  if [[ "$dcode" =~ ^[1-5][0-9][0-9]$ ]]; then
    log "    discord reachable (HTTP $dcode)"
  else err "    discord NOT reachable (code=${dcode:-none}) — check DNS/egress"; fail=1; fi
  # Config/provider health. The checks above can't tell a misconfigured LLM (wrong
  # model slug / missing key) from a healthy one — the container is active/running
  # either way (conmon marks it running at container start, not app-readiness), so a
  # bad config would deploy green and only surface as a silent Discord failure.
  # `hermes doctor` validates provider/env/paths INSIDE the container. NOTE: doctor
  # exits 0 even when checks fail (it only sys.exits on its --ack path) — it marks
  # results with ✓/✗ — so we parse the markers, not $?. Soft by design (warn + surface,
  # non-fatal) to avoid spurious hard-fails on advisory ✗ items; tighten to fail=1 once
  # the ✗ taxonomy is confirmed to be blockers-only on a real deploy.
  local doctor_out
  doctor_out="$(capture_as_hermes timeout 20 podman exec hermes hermes doctor)"
  if printf '%s\n' "$doctor_out" | grep -q '✗'; then
    warn "  hermes doctor flagged config/provider issues (verify still proceeds) — review:"
    printf '%s\n' "$doctor_out" | grep -E '✓|✗' >&2
  elif [[ -n "$doctor_out" ]]; then
    log "  hermes doctor: no failed checks"
  else
    warn "  hermes doctor produced no output (skipped check)"
  fi
  (( fail == 0 )) && log "verify: host-side checks passed" || die "verify: $fail check(s) failed"
}

step_down() {
  log "Tearing down (as $HERMES_USER + root)"
  run_as_hermes systemctl --user disable --now "$SERVICE_NAME" || true
  run rm -f "$QUADLET_PATH"
  run rm -f "$HERMESCTL_PATH"
  run_as_hermes systemctl --user daemon-reload || true
  if [[ "${REMOVE_NFT:-0}" == "1" ]]; then
    run_sh "nft delete table inet hermes_egress 2>/dev/null || true"
    run rm -f "$NFT_PATH"
  else
    log "  left the nft ruleset in place (set REMOVE_NFT=1 to remove it)"
  fi
}

# ========================================================================
# Failure cleanup
# ========================================================================
cleanup_on_failure() {
  local rc=$?
  trap - ERR INT TERM EXIT
  [[ $rc -eq 0 ]] && exit 0
  err "failed (exit $rc)"
  [[ "$DRY_RUN" == "1" ]] && exit "$rc"
  warn "unwinding what THIS run created"
  if [[ "$STARTED_SERVICE" == "1" ]]; then
    sudo -u "$HERMES_USER" env --chdir=/ "XDG_RUNTIME_DIR=/run/user/$HERMES_UID" \
      systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  if [[ "$CREATED_QUADLET" == "1" && -n "$QUADLET_PATH" ]]; then
    rm -f "$QUADLET_PATH" 2>/dev/null || warn "could not remove $QUADLET_PATH"
  fi
  if [[ "$CREATED_NFT" == "1" ]]; then
    nft delete table inet hermes_egress 2>/dev/null || true
    rm -f "$NFT_PATH" 2>/dev/null || true
  fi
  if [[ "$CREATED_HERMESCTL" == "1" ]]; then
    rm -f "$HERMESCTL_PATH" 2>/dev/null || true
  fi
  warn "left ~$HERMES_USER/.hermes data untouched"
  exit "$rc"
}

# ========================================================================
# Workflows
# ========================================================================
finish_ok() {
  trap - ERR INT TERM EXIT
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run complete — nothing changed. Re-run with --yes to execute."
  else
    log "done."
  fi
}

do_all() {
  log "WORKFLOW all — deploy Hermes into the hardened sandbox"
  step_preflight
  step_base_packages
  step_user
  step_podman
  step_image
  step_config
  step_quadlet
  step_nft
  step_enable
  step_hermesctl
  [[ "$DRY_RUN" == "0" ]] && step_verify || true
  [[ "$DRY_RUN" == "0" ]] && log "operate it: hermesctl status | logs | restart | journal -f  (README → Operating it)" || true
  finish_ok
}

# ========================================================================
# Entry point
# ========================================================================
main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all|preflight|user|podman|image|config|quadlet|nft|enable|hermesctl|verify|down|check) cmd="$1"; shift ;;
      --yes)     DRY_RUN=0; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  [[ -n "$cmd" ]] || { usage; exit 1; }

  resolve_user
  trap cleanup_on_failure ERR INT TERM EXIT
  case "$cmd" in
    all)       do_all ;;
    preflight) step_preflight; finish_ok ;;
    user)      step_user; finish_ok ;;
    podman)    step_podman; finish_ok ;;
    image)     step_image; finish_ok ;;
    config)    step_config; finish_ok ;;
    quadlet)   step_quadlet; finish_ok ;;
    nft)       step_nft; finish_ok ;;
    enable)    step_enable; finish_ok ;;
    hermesctl) step_hermesctl; finish_ok ;;
    verify)    step_verify; finish_ok ;;
    down)      step_down; finish_ok ;;
    check)     step_check; finish_ok ;;
  esac
}

main "$@"
