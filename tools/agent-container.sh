#!/usr/bin/env bash
# Stand up ghostty-agent in a container on another machine, so the shells, the
# compositor and any browser you pull into the game use that machine's memory
# and not the one running the game.
#
#   tools/agent-container.sh create [NAME]     make it and start the agent
#   tools/agent-container.sh token [NAME]      print its token, for lua/init.lua
#   tools/agent-container.sh app NAME CMD...   run a program inside its compositor
#   tools/agent-container.sh log [NAME]        what the agent has been saying
#   tools/agent-container.sh remove [NAME]     delete it
#
# NAME is an Incus instance, remote prefix and all: `ghostty-agent` on this
# machine's daemon, `builder:ghostty-agent` on the remote called `builder`.
# Default: $GHOSTTY_AGENT_CONTAINER, else `ghostty-agent`.
#
# What create does, and why each step is there — every one of these was needed
# to make it actually work, and the ones marked (!) fail quietly without it:
#   * a Fedora container, because the agent's packages are built for Fedora
#   * the .rpm from build/release, or the published one when there is none here
#   * (!) HOME in the unit, or the token lands in /.config instead of ~/.config
#   * (!) a `gpu` device, or /dev/dri does not exist in the container at all and
#     the compositor falls back to software however you configure it
#   * (!) mesa drivers, or an Intel/AMD card has no EGL and the same happens
#   * a proxy device, so the agent answers on the host's own address
#
# Environment:
#   GHOSTTY_AGENT_PORT   the port to listen on and forward (default 7777)
#   GHOSTTY_AGENT_PROXY_ADDR  the host address the proxy listens on (default
#                        0.0.0.0). The agent itself listens on loopback inside
#                        the container (it refuses the network in the clear,
#                        docs/WIREGUARD.md); the proxy is what reaches the host,
#                        so give it the host's tailnet address where you can.
#   GHOSTTY_AGENT_IMAGE  the image (default images:fedora/44)
#   GHOSTTY_AGENT_RPM    a .rpm to install instead of the one in build/release
#   INCUS                the incus binary (default: incus on PATH)
#
# Exit codes: 0 done, 1 a step failed, 2 bad argument, 127 incus missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCUS="${INCUS:-incus}"
PORT="${GHOSTTY_AGENT_PORT:-7777}"
IMAGE="${GHOSTTY_AGENT_IMAGE:-images:fedora/44}"
NAME_DEFAULT="${GHOSTTY_AGENT_CONTAINER:-ghostty-agent}"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log() { printf '== agent-container: %s\n' "$*"; }
die() { printf 'agent-container: error: %s\n' "$*" >&2; exit 1; }
command -v "$INCUS" >/dev/null || { echo 'agent-container: error: incus is required' >&2; exit 127; }

exec_in() { "$INCUS" exec "$1" -- "${@:2}"; }

cmd_create() {
  local c="$1"
  if "$INCUS" info "$c" >/dev/null 2>&1; then
    log "$c exists already"
  else
    log "launching $c from $IMAGE"
    "$INCUS" launch "$IMAGE" "$c"
    local tries=0
    while [[ $tries -lt 40 ]]; do
      exec_in "$c" sh -c 'command -v dnf >/dev/null' 2>/dev/null && break
      tries=$((tries + 1))
      sleep 2
    done
  fi

  # The GPU has to be handed in explicitly. Without it /dev/dri is absent and
  # the compositor renders in software no matter what you ask for; sysfs still
  # shows the cards, so the agent's own log looks like it found one.
  if ! "$INCUS" config device get "$c" gpu type >/dev/null 2>&1; then
    log 'adding a gpu device'
    "$INCUS" config device add "$c" gpu gpu >/dev/null || log 'no gpu could be added: software rendering'
  fi

  local rpm="${GHOSTTY_AGENT_RPM:-}"
  if [[ -z "$rpm" ]]; then
    shopt -s nullglob
    local found=("$ROOT"/build/release/ghostty-agent-*-1.fc44.x86_64.rpm)
    shopt -u nullglob
    [[ ${#found[@]} -gt 0 ]] && rpm="${found[-1]}"
  fi
  if [[ -n "$rpm" && -f "$rpm" ]]; then
    log "installing $(basename "$rpm")"
    exec_in "$c" mkdir -p /root/pkg
    "$INCUS" file push "$rpm" "$c/root/pkg/" >/dev/null
    exec_in "$c" dnf -y install "/root/pkg/$(basename "$rpm")"
  else
    log 'installing the published package'
    exec_in "$c" dnf -y install \
      'https://github.com/Spaceghost/ghostty-dalamud/releases/latest/download/ghostty-agent.fc44.x86_64.rpm'
  fi

  # mesa, or an Intel/AMD render node has no EGL and the GLES2 renderer refuses
  log 'mesa drivers, for the GPU path'
  exec_in "$c" dnf -y install mesa-dri-drivers mesa-libEGL mesa-libgbm >/dev/null 2>&1 ||
    log 'mesa could not be installed: software rendering'

  # A system unit, because a container has no logged-in user session to hang a
  # --user one on. HOME matters: without it the token goes to /.config.
  log 'installing the service'
  exec_in "$c" sh -c "cat > /etc/systemd/system/ghostty-agent.service <<'UNIT'
[Unit]
Description=ghostty-agent for the Ghostty Dalamud plugin
After=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/usr/bin/mkdir -p /run/user/0
ExecStart=/usr/bin/ghostty-agent --listen 127.0.0.1:$PORT --wayland-render-node gpu
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ghostty-agent"

  log "forwarding the host's :$PORT into the container"
  "$INCUS" config device remove "$c" agentport >/dev/null 2>&1 || true
  "$INCUS" config device add "$c" agentport proxy \
    "listen=tcp:${GHOSTTY_AGENT_PROXY_ADDR:-0.0.0.0}:$PORT" "connect=tcp:127.0.0.1:$PORT" >/dev/null

  sleep 3
  exec_in "$c" sh -c 'systemctl is-active ghostty-agent >/dev/null' ||
    die "the agent did not start; tools/agent-container.sh log $c"
  log 'the agent is up:'
  exec_in "$c" sh -c "journalctl -u ghostty-agent -n 8 --no-pager | sed 's|^.*ghostty-agent\[[0-9]*\]: ||'"
  echo
  log 'put this in lua/init.lua on the machine running the game:'
  printf '\n  agent = {\n    host = %s,\n    port = %s,\n    token = %s,\n  },\n\n' \
    "'<this machine on your private network>'" "$PORT" "'$(cmd_token "$c")'"
  log 'then /term reload in game. The stream is authenticated but not encrypted, and the'
  log "proxy listens on ${GHOSTTY_AGENT_PROXY_ADDR:-0.0.0.0}:$PORT of this host: keep that on a private network"
  log '(GHOSTTY_AGENT_PROXY_ADDR=<tailnet address>), or use the agent'"'"'s own WireGuard (ghostty-agent wg).'
}

cmd_token() { exec_in "$1" cat /root/.config/ghostty-agent/token; }
cmd_log() { exec_in "$1" sh -c "journalctl -u ghostty-agent -n 40 --no-pager | sed 's|^.*ghostty-agent\[[0-9]*\]: ||'"; }
cmd_remove() { "$INCUS" delete --force "$1"; log "removed $1"; }

# Run a program inside the agent's compositor. Its window then shows up in the
# game's window picker (/term window, or the plugin's own list).
cmd_app() {
  local c="$1"; shift
  [[ $# -gt 0 ]] || die 'app needs a command to run'
  log "starting: $*"
  exec_in "$c" sh -c "export XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=ffxiv-0 \
      MOZ_ENABLE_WAYLAND=1 GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland SDL_VIDEODRIVER=wayland
    setsid $* >/tmp/app.log 2>&1 < /dev/null &
    sleep 2; echo started"
}

case "${1:-}" in
  create) cmd_create "${2:-$NAME_DEFAULT}" ;;
  token)  cmd_token "${2:-$NAME_DEFAULT}" ;;
  log)    cmd_log "${2:-$NAME_DEFAULT}" ;;
  remove) cmd_remove "${2:-$NAME_DEFAULT}" ;;
  app)    shift; c="${1:-}"; [[ -n "$c" ]] || die 'app needs a container name'; shift; cmd_app "$c" "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
