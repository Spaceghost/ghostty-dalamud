#!/usr/bin/env bash
# Netlab between machines, headless (docs/NETLAB.md): two ghostty-agents in two
# Incus containers and `iroh-relay --dev` in a third. Agent A publishes its
# test window (--windows test); agent B subscribes to it over iroh, dialing
# with A's endpoint id and relay only; tests/netlab_probe.nelua, run in B's
# container, checks the stats the panel reads from both: the connection
# starts on the relay and goes direct, B rebuilds A's pictures exactly, the
# slow subscription loses groups, A serves both.
#
#   tools/netlab-containers.sh build   where the agent builds (the build
#                                      container): the agent with netlab and
#                                      without Wayland, the probe, and
#                                      iroh-relay, into build/netlab/
#   tools/netlab-containers.sh run     on a host with Incus: three ephemeral
#                                      containers from build/netlab/, the
#                                      probe's PASS or FAIL line, cleanup
#
# Environment: INCUS_REMOTE (default local; the build host's remote works),
# NETLAB_IMAGE (default images:$BUILD_IMAGE_ALIAS from toolchain.env), KEEP=1
# to leave the containers running for a look.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
cd "$ROOT"
OUT=build/netlab
die() { printf 'netlab-containers: %s\n' "$*" >&2; exit 1; }

build() {
  [[ -f vendor/moq-iroh/libmoq_iroh.a ]] || die 'no vendor/moq-iroh: run tools/fetch-vendor.sh (cargo needed)'
  local NELUA="$ROOT/vendor/nelua-lang/nelua"
  export ZIG="${ZIG:-zig}"
  local CC="$ROOT/tools/zig-cc.sh"
  WAYLAND_DEFINE=() WAYLAND_CFLAGS=""
  # shellcheck source=tools/netlab-flags.sh
  source "$ROOT/tools/netlab-flags.sh"
  [[ ${#NETLAB_DEFINE[@]} -gt 0 ]] || die 'netlab-flags.sh found no netlab'
  mkdir -p "$OUT/bin"
  echo "== $OUT/ghostty-agent (netlab, no Wayland)"
  "$NELUA" --cc "$CC" -P nogc "${AGENT_NELUA[@]}" --cache-dir "$OUT/cache" -L . -o "$OUT/ghostty-agent" -b agent/agent.nelua
  echo "== $OUT/netlab_probe"
  "$NELUA" --cc "$CC" -P nogc --cache-dir "$OUT/cache" -L . -o "$OUT/netlab_probe" -b tests/netlab_probe.nelua
  if [[ ! -x "$OUT/bin/iroh-relay" ]]; then
    echo "== iroh-relay $IROH_RELAY_VERSION (cargo install)"
    cargo install --quiet --locked iroh-relay --version "$IROH_RELAY_VERSION" --features server --root "$OUT"
  fi
  echo "== ready: tools/netlab-containers.sh run"
}

run() {
  for f in ghostty-agent netlab_probe bin/iroh-relay; do
    [[ -x "$OUT/$f" ]] || die "no $OUT/$f: run tools/netlab-containers.sh build first"
  done
  local remote="${INCUS_REMOTE:-local}"
  p=""
  [[ "$remote" != local ]] && p="$remote:"
  local image="${NETLAB_IMAGE:-images:$BUILD_IMAGE_ALIAS}"
  relay="netlab-$$-relay" a="netlab-$$-a" b="netlab-$$-b"
  cleanup() {
    [[ "${KEEP:-0}" == 1 ]] && { echo "kept: $relay $a $b"; return; }
    incus delete -f "$p$relay" "$p$a" "$p$b" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  for n in "$relay" "$a" "$b"; do incus launch -q --ephemeral "$image" "$p$n"; done
  # a fresh container's address, once systemd-networkd has one (asked inside:
  # incus list can lag behind)
  ip_of() {
    local ip=""
    for _ in $(seq 1 240); do
      ip="$(incus exec "$p$1" -- ip -4 -o addr show dev eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -c6- | head -1 || true)"
      [[ -n "$ip" ]] && { echo "$ip"; return 0; }
      sleep 0.5
    done
    return 1
  }
  local relay_ip a_ip
  relay_ip="$(ip_of "$relay")" || die "$relay has no IPv4 address"
  a_ip="$(ip_of "$a")" || die "$a has no IPv4 address"
  ip_of "$b" >/dev/null || die "$b has no IPv4 address"
  incus file push -q --mode 0755 "$OUT/bin/iroh-relay" "$p$relay/usr/local/bin/iroh-relay"
  incus exec "$p$relay" -- sh -c 'setsid nohup iroh-relay --dev >/var/log/iroh-relay.log 2>&1 &'
  for n in "$a" "$b"; do
    incus file push -q --mode 0755 "$OUT/ghostty-agent" "$p$n/usr/local/bin/ghostty-agent"
    incus exec "$p$n" -- sh -c 'echo netlabtoken >/root/token && setsid nohup ghostty-agent --listen 0.0.0.0:7788 --token-file /root/token --windows test >/var/log/ghostty-agent.log 2>&1 &'
  done
  incus file push -q --mode 0755 "$OUT/netlab_probe" "$p$b/usr/local/bin/netlab_probe"
  # the relay and the agents listening
  for _ in $(seq 1 100); do
    incus exec "$p$b" -- sh -c "exec 3<>/dev/tcp/$relay_ip/3340 && exec 4<>/dev/tcp/$a_ip/7788 && exec 5<>/dev/tcp/127.0.0.1/7788" 2>/dev/null && break
    sleep 0.2
  done
  echo "== relay http://$relay_ip:3340, A $a_ip:7788, B its own"
  if incus exec "$p$b" -- netlab_probe "$a_ip" 7788 127.0.0.1 7788 netlabtoken "http://$relay_ip:3340"; then
    return 0
  fi
  echo '-- A:'; incus exec "$p$a" -- tail -n 20 /var/log/ghostty-agent.log || true
  echo '-- B:'; incus exec "$p$b" -- tail -n 20 /var/log/ghostty-agent.log || true
  echo '-- relay:'; incus exec "$p$relay" -- tail -n 20 /var/log/iroh-relay.log || true
  return 1
}

case "${1:-}" in
  build) build ;;
  run) run ;;
  *) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
