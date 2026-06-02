#!/usr/bin/env bash
# Declarative config for ./deploy.sh — the layout.sh analogue.
# Bash-sourced; every value is env-overridable. NO SECRETS HERE (those live in
# the un-tracked secrets.env — see secrets.env.example).
#
# shellcheck disable=SC2034  # vars are consumed by deploy.sh after sourcing

# --- runtime user --------------------------------------------------------
# Dedicated, unprivileged *system* user that owns the rootless Podman runtime.
# Not a login account; it just runs the container under `systemctl --user`.
HERMES_USER="${HERMES_USER:-hermes}"

# Host data dir (bind-mounted to /opt/data in the container: config, .env,
# sessions DB, skills, memories). Empty => deploy.sh derives ~<user>/.hermes.
DATA_DIR="${DATA_DIR:-}"

# --- image ---------------------------------------------------------------
# PIN BY DIGEST in production: deploy.sh's `image` step pulls, then rewrites
# this to nousresearch/hermes-agent@sha256:... so restarts can't drift.
HERMES_IMAGE="${HERMES_IMAGE:-docker.io/nousresearch/hermes-agent@sha256:3380770368adc29c4af681f6a55e2de19439ccc1e59fb3e742588729910f6671}"
# Container subcommand. `gateway run` = the persistent messaging gateway.
HERMES_RUN_CMD="${HERMES_RUN_CMD:-gateway run}"

# --- LLM (remote API only — see README; no local model on free-tier ARM) -
# provider: auto | openrouter | nous | anthropic | openai | gemini | custom ...
LLM_PROVIDER="${LLM_PROVIDER:-openrouter}"
LLM_MODEL="${LLM_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"  # OpenRouter slug; override in env, or set to a different model
LLM_BASE_URL="${LLM_BASE_URL:-}"  # optional; only for custom/self-hosted endpoints

# --- resource limits (sized for a SHARED VM: leave headroom for neighbors) -
# Tune to your shape. On a 1-OCPU/6GB free-tier instance, CPUS=1 / MEM_MAX=2g
# is conservative; raise on a 4-OCPU/24GB shape. Remote-API operation is light
# (~hundreds of MB); the browser tool needs more (see SHM_SIZE + README).
MEM_MAX="${MEM_MAX:-2g}"
CPUS="${CPUS:-2}"
PIDS_MAX="${PIDS_MAX:-512}"
SHM_SIZE="${SHM_SIZE:-256m}"      # bump to 1g if you enable the browser tool

# --- networking / egress firewall ---------------------------------------
# Resolver the container is allowed to reach on :53. Empty => deploy.sh
# auto-detects from the host (handles systemd-resolved 127.0.0.53 specially).
DNS_RESOLVER="${DNS_RESOLVER:-}"
# Extra CIDRs to block on egress, on top of metadata + RFC1918 + CGNAT.
# Only needed if your VCN uses a NON-RFC1918 range (e.g. BYOIP). Space-separated
# in the environment, e.g. EXTRA_BLOCK_CIDRS="203.0.113.0/24 198.51.100.0/24".
read -ra EXTRA_BLOCK_CIDRS <<< "${EXTRA_BLOCK_CIDRS:-}"

# --- API / dashboard exposure --------------------------------------------
# Default OFF + unpublished: the Discord bot is OUTBOUND-only and needs no port.
# Set PUBLISH_API=1 to also enable Hermes's OpenAI-compatible API on LOOPBACK
# only (127.0.0.1:$API_PORT). Requires API_SERVER_ENABLED=true + API_SERVER_KEY
# in secrets.env; never bind it to 0.0.0.0 on a shared/public VM.
PUBLISH_API="${PUBLISH_API:-0}"
API_PORT="${API_PORT:-8642}"
