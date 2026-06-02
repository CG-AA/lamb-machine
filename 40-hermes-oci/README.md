# 40-hermes-oci — Hermes agent in a hardened rootless sandbox

> ⚠️ **Different target machine.** Unlike layers `00`–`30` (which build *this*
> workstation, each assuming the one below), this component deploys to a
> **separate cloud VM**: an OCI Always-Free **Ampere A1 (arm64), Ubuntu 24.04**.
> It assumes **none** of layers 00–30. The `40-` number just sorts it last.
> The realistic install is `rsync -a 40-hermes-oci/ <vm>:` of *this directory*
> (it's self-contained — `lib/common.sh` is vendored, not shared).

Deploys [Hermes](https://github.com/NousResearch/hermes-agent) (Nous Research's
self-improving agent) so it can do its job — talk to **Discord** and **run
commands** — while being unable to harm the **other workloads on the same VM**.

## The problem this solves

Hermes runs arbitrary shell commands and code *as a feature*, and a Discord
message (or a prompt injection inside one) can drive it. On a shared VM that is
a structural risk, not a bug. So we make the agent's blast radius equal to **one
hardened container**: the agent keeps the Discord gateway and command execution,
but both are confined.

**Container-as-jail.** Hermes runs inside a single rootless Podman container with
its terminal tool pinned to the `local` backend — so agent-run commands execute
*inside that container*, which is the sandbox. Containment rests on three
independent layers:

1. **Namespaces** — the container sees only its own rootfs + one data volume,
   never host files or host processes.
2. **Rootless user-namespace mapping** — "root in the container" is an
   unprivileged host UID that owns nothing on the host.
3. **nftables egress** — the agent can't reach the cloud metadata service, the
   VCN, RFC1918 neighbors, or host loopback services (Discord + the LLM API on
   443, and DNS, still work).

Plus: drop-all-capabilities, `no-new-privileges`, the default seccomp profile,
read-only rootfs, and cgroup CPU/memory/PID limits.

### Two things we deliberately do NOT do

- **No `install.sh | bash` host install.** That would put the agent *and its
  `local` backend* directly on the host — no containment.
- **No docker/podman socket mounted** (so: not Hermes's `docker`/nested
  backends). A socket lets the agent launch a container with `-v /:/host`, which
  is host-root-equivalent and defeats every flag above. The agent keeps command
  execution via the `local` backend *inside* the jail instead.

## Files

| File | Role |
|------|------|
| [`config.sh`](config.sh) | **Declarative knobs** — image, user, CPU/mem/PID limits, LLM provider, DNS, ports. Edit to retune. |
| [`deploy.sh`](deploy.sh) | Orchestrator + step functions. Dry-run by default. |
| [`secrets.env.example`](secrets.env.example) | Template for the un-tracked `secrets.env` (Discord token, allowlist, one LLM key). |
| [`assets/hermes.container.tmpl`](assets/hermes.container.tmpl) | The hardened rootless Quadlet unit. |
| [`assets/nftables-hermes.tmpl`](assets/nftables-hermes.tmpl) | Egress firewall (output hook, scoped by the runtime UID). |
| [`assets/config.yaml.tmpl`](assets/config.yaml.tmpl) | `~/.hermes/config.yaml` — `terminal.backend: local`, no other-backend keys. |
| [`assets/hermesctl.tmpl`](assets/hermesctl.tmpl) | Generated `/usr/local/bin/hermesctl` — day-2 operator wrapper (see [Operating it](#operating-it)). |
| [`lib/common.sh`](lib/common.sh) | Logging, dry-run runner, file writer (vendored from `00-provision`). |

## Prerequisites (manual, one-time)

1. **The VM**: an OCI Always-Free Ampere A1 instance, Ubuntu 24.04 (arm64). In
   the VCN security list / NSG, allow **no inbound** except SSH (22) from your
   admin IP. The bot is outbound-only. Keep the instance's **IAM/instance-
   principal policy empty** so reachable metadata would grant nothing.
2. **A Discord bot**: create it in the Developer Portal, copy the bot token, and
   **enable the "Message Content" and "Server Members" privileged intents** (the
   bot reads empty messages without them).
3. **An LLM key**: a *dedicated, low-limit* key (OpenRouter / Anthropic / OpenAI
   / …). Remote API only — no local model on free-tier ARM.
4. **Secrets**: `cp secrets.env.example secrets.env && chmod 600 secrets.env`,
   then fill in `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_USERS` (your Discord user
   ID — **required**, an empty allowlist is refused), and one LLM key.

## Usage

```bash
# from the VM, inside this directory:
./deploy.sh all                 # DRY-RUN: prints every command, changes nothing
sudo ./deploy.sh all --yes      # execute the full deploy
sudo ./deploy.sh verify         # post-deploy checks (see Safety model)
sudo ./deploy.sh down           # stop + disable the service (REMOVE_NFT=1 also drops the firewall)
```

Single steps for inspection/manual use:
`preflight | user | podman | image | config | quadlet | nft | enable | hermesctl`.

Authoring-time validation (no VM, no root, no secrets needed):

```bash
./deploy.sh check               # local lint + template + secrets validator
CI=1 ./deploy.sh check          # hard-fail on missing tools (for pre-commit / CI)
```

`check` runs shellcheck on the scripts, syntax-checks the rendered nft / YAML
/ Quadlet (the last via regex assertions against
`test/fixtures/expected/quadlet-{required,forbidden}.txt`), and unit-tests
the secrets validator against fixtures in `test/fixtures/secrets/`. Missing
external tools (`shellcheck`, `nft`, `python3`) warn-and-skip by default;
`CI=1` makes them hard-fail.

After a successful `image` step, **pin the digest** it prints into
`config.sh`'s `HERMES_IMAGE` so restarts can't drift.

## Operating it

This is **not** a normal host install — Hermes runs as a rootless Podman container
owned by the system user `hermes` under `systemctl --user`, and the Hermes CLI lives
*inside* the container. `deploy.sh all` installs **`/usr/local/bin/hermesctl`** so you
don't have to type `sudo -u hermes env --chdir=/ XDG_RUNTIME_DIR=… podman exec …` by
hand. Run it as your normal admin user — it self-elevates via `sudo` (so every
privileged path is gated on sudo rights).

```bash
hermesctl status            # in-container Hermes CLI — and proof the container is up
hermesctl logs              # Hermes's own application log (the CLI's `logs`)
hermesctl model ...         # any Hermes CLI subcommand passes through
hermesctl restart           # restart | start | stop the systemd --user service
hermesctl journal -f        # the host systemd/container journal for the unit (sudo)
hermesctl help
```

**Contract:** `restart`, `start`, `stop`, `journal`, `help` are handled by the wrapper;
**everything else is forwarded** to the in-container `hermes` CLI, so it feels like a
local install. Two different "logs": `hermesctl logs` = Hermes's *app log*;
`hermesctl journal` = the *systemd journal* on the host.

**Change config** (model, etc.): edit `config.sh`/`secrets.env`, re-render, restart:

```bash
sudo DATA_DIR=<data-dir> ./deploy.sh config --yes   # re-renders config.yaml + .env (asserts backend=local)
hermesctl restart
```

**Lifecycle** stays in `deploy.sh`: `sudo ./deploy.sh verify --yes` (post-deploy checks),
`sudo ./deploy.sh down` (stop/disable; also removes the wrapper). To get a **shell inside
the jail** (debugging only — not a wrapper verb):

```bash
sudo -u hermes env --chdir=/ XDG_RUNTIME_DIR=/run/user/$(id -u hermes) podman exec -it hermes /bin/sh
```

| Thing | Where |
|------|------|
| service | `hermes.service` (user unit of `hermes`) |
| container | `hermes` (rootless podman) |
| data dir | host `DATA_DIR` → `/opt/data` in the container |
| config / secrets | `<data-dir>/config.yaml`, `<data-dir>/.env` (mode 600) |
| Quadlet unit | `~hermes/.config/containers/systemd/hermes.container` |
| egress firewall | `/etc/nftables.d/40-hermes.nft` |

## Safety model

- **Dry-run by default.** Every invocation prints the exact commands and changes
  nothing; add `--yes` to execute. A real run needs root.
- **Fails closed.** Preflight refuses an empty Discord allowlist, a missing LLM
  key, or any sandbox-weakening key (`SUDO_PASSWORD`, `*_DOCKER_*`, `*_SSH_*`,
  `GATEWAY_ALLOW_ALL_USERS=true`) in `secrets.env`. `config` asserts the rendered
  config has *only* the `local` backend.
- **`verify` actively proves the firewall.** From inside the container it checks
  that `http://169.254.169.254/...` (metadata) **fails** while `discord.com`
  and DNS **succeed** — proving the rootless egress rule matched. Then, from
  Discord as an allowlisted user, confirm command execution **works but is
  jailed**: `id` is an unprivileged user, host files aren't visible,
  `curl 169.254.169.254` fails, a neighbor's port fails, and `/tmp` writes
  vanish on `podman restart`.
- **Failure cleanup.** A mid-run failure unwinds only what *that* run created
  (service, Quadlet, nft table); your `~/.hermes` data is never touched.

## Functional caveats under hardening (and fixes)

The hardening you opted into touches a few Hermes features — verify-step 7 is the
gate, and these are the knobs:

- **In-task `pip/npm/apt install`** to system paths fail under read-only rootfs.
  Point caches/installs at the writable tmpfs (`PIP_CACHE_DIR`, `UV_CACHE_DIR`,
  `npm_config_cache`, install under `/workspace`). *Persistent* global installs
  won't survive a restart (ephemeral by design). Easiest relaxation if it bites:
  remove `ReadOnly=true` from the Quadlet (the container layer is still
  contained).
- **Browser tool (Chromium/Playwright)** needs `--no-sandbox` (set it via
  `AGENT_BROWSER_ARGS` in `secrets.env`) and a bigger `/dev/shm` — raise
  `SHM_SIZE` in `config.sh` to `1g`. It's heavy on free-tier ARM; treat as
  optional.
- **s6 on a read-only rootfs**: handled by `S6_READ_ONLY_ROOT=1` (set in the
  Quadlet). On the first `--yes` start, watch `journalctl --user -u hermes -f`;
  if the image's init still errors on a read-only path, add a *narrow* `Tmpfs=`
  for that path — don't drop `ReadOnly`.
- **Rootless `--memory`/`--cpus`** are ignored unless the cgroup-v2 controllers
  are delegated to the user — `deploy.sh` writes that delegation drop-in.

## Tuning knobs (`config.sh` / env)

| Var | Default | Purpose |
|-----|---------|---------|
| `HERMES_IMAGE` | `nousresearch/hermes-agent:latest` | **Pin by digest** in production. |
| `MEM_MAX` / `CPUS` / `PIDS_MAX` | `2g` / `2` / `512` | Container caps; size to your shape, leave headroom for neighbors. |
| `SHM_SIZE` | `256m` | Raise to `1g` for the browser tool. |
| `LLM_PROVIDER` / `LLM_MODEL` | `openrouter` / _unset_ | Provider + optional model id. |
| `DNS_RESOLVER` | _auto-detect_ | Resolver allowed on :53 (OCI: usually `169.254.169.254`). |
| `EXTRA_BLOCK_CIDRS` | _none_ | Extra egress blocks (only for a non-RFC1918 VCN). |
| `PUBLISH_API` | `0` | `1` exposes Hermes's API on **127.0.0.1** only (needs `API_SERVER_KEY`). |
| `HERMES_BUILD` / `HERMES_SRC` | `0` / _unset_ | Build the arm64 image locally if no published manifest. |

## Residual risks (read before trusting it)

- **Escape is still possible** (no gVisor, by choice). A breakout lands as the
  unprivileged runtime UID; nft + empty instance IAM blunt the radius.
  Containment is strong, not absolute — truly hostile use wants a dedicated VM.
- **Prompt injection → in-box command execution** is the accepted feature. The
  bot token + LLM key live in `/opt/data/.env` (the agent can read them) and 443
  egress is open, so an injected agent **can exfiltrate them**. Hence the
  *dedicated, low-limit* token/key — cheap to rotate, scoped. Egress is
  port-shaped, not destination-shaped: lateral/metadata access is blocked,
  generic 443 exfil is not.
- **arm64 / image trust**: the published arm64 image and its contents are
  trusted on faith; we pin by digest and offer a local build. Re-pin + re-verify
  per release.
