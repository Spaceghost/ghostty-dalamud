#!/usr/bin/env bash
# The agent's WireGuard against kernel WireGuard (docs/WIREGUARD.md "Tests").
#
#   tools/wg-interop.sh
#
# Two Incus containers on the build host: the build container runs our side
# (tests/wg_interop.nelua: a WireGuard device on a UDP socket that answers
# ping inside the tunnel), and a peer container (created on first use, Fedora
# with wireguard-tools) runs the Linux kernel's WireGuard, configured with
# keys that wg(8) itself generated. Checked, in order:
#
#   handshake  ping through the tunnel; both sides report a session
#   roaming    the kernel peer changes its UDP port mid-session; our side
#              follows it and the pings keep coming back
#   rekey      pings for 130 s: the kernel initiates a new handshake after
#              REKEY_AFTER_TIME (120 s) and nothing is lost across it
#
# The checkout in the build container must be current: run
# `tools/build-remote.sh push` first (or set WG_INTEROP_DIR to a directory
# that is). Exit 0 when every check passed; the logs are printed either way.
#
# Environment: INCUS_REMOTE (default BUILD_REMOTE_NAME from build.env or
# toolchain.env), WG_INTEROP_DIR (default BUILD_CONTAINER_DIR),
# WG_PEER_CONTAINER (default ghostty-wgpeer), WG_REKEY_SECONDS (default 130).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=toolchain.env
source "$ROOT/toolchain.env"
# shellcheck disable=SC1091
[[ -f "$ROOT/build.env" ]] && source "$ROOT/build.env"
REMOTE="${INCUS_REMOTE:-${BUILD_REMOTE_NAME:-local}}"
AGENT="$REMOTE:${BUILD_CONTAINER_NAME:-$BUILD_CONTAINER}"
PEER="$REMOTE:${WG_PEER_CONTAINER:-ghostty-wgpeer}"
DIR="${WG_INTEROP_DIR:-$BUILD_CONTAINER_DIR}"
REKEY="${WG_REKEY_SECONDS:-130}"
PORT=51820
fails=0
log() { printf '== wg-interop: %s\n' "$*"; }
check() { # name, then a command whose success is the check
  local name="$1"; shift
  if "$@"; then log "PASS $name"; else log "FAIL $name"; fails=$((fails + 1)); fi
}
peer() { incus exec "$PEER" -- bash -c "$1"; }
agent() { incus exec "$AGENT" -- bash -lc "$1"; }

if ! incus info "$PEER" >/dev/null 2>&1; then
  log "creating $PEER (Fedora 44, wireguard-tools)"
  incus launch "images:${BUILD_IMAGE_ALIAS}" "$PEER" >/dev/null
  for _ in $(seq 1 30); do peer 'getent hosts fedoraproject.org' >/dev/null 2>&1 && break; sleep 1; done
  peer 'dnf -y -q install wireguard-tools iproute iputils >/dev/null'
fi
peer 'ip link del wg0 2>/dev/null || true'

log "building tests/wg_interop.nelua in $AGENT:$DIR"
agent "cd $DIR && vendor/nelua-lang/nelua --cc tools/zig-cc.sh -P nogc --cache-dir build/nelua-cache -L . -o build/wg_interop -b tests/wg_interop.nelua >/dev/null"

# keys from the real tool, so our base64 and clamping meet wg(8)'s
agent_key="$(peer 'wg genkey')"
agent_pub="$(peer "echo $agent_key | wg pubkey")"
peer_key="$(peer 'wg genkey')"
peer_pub="$(peer "echo $peer_key | wg pubkey")"
psk="$(peer 'wg genpsk')"
agent_ip="$(agent "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
[[ -n "$agent_ip" ]] || { log "no IPv4 address for $AGENT"; exit 1; }

log "our side listens on $agent_ip:$PORT"
# shellcheck disable=SC2016 # expanded in the container, not here
stop_ours() { agent '[ -f /tmp/wg-interop.pid ] && kill "$(cat /tmp/wg-interop.pid)" 2>/dev/null; rm -f /tmp/wg-interop.pid; true'; }
stop_ours
agent "cd $DIR && { setsid nohup build/wg_interop $PORT '$agent_key' '$peer_pub' '$psk' 10.77.0.2/32 $((REKEY + 90)) >/tmp/wg-interop.log 2>&1 & echo \$! >/tmp/wg-interop.pid; }"
sleep 1

peer "set -e
  ip link add wg0 type wireguard
  wg set wg0 private-key <(echo $peer_key) listen-port 51000 \
    peer $agent_pub preshared-key <(echo $psk) endpoint $agent_ip:$PORT allowed-ips 10.77.0.1/32
  ip addr add 10.77.0.2/32 dev wg0
  ip link set wg0 up
  ip route add 10.77.0.1/32 dev wg0"

ours() { agent 'cat /tmp/wg-interop.log'; }
has() { ours | grep -q "$1"; }

check 'handshake: ping through the tunnel' peer 'ping -c 3 -W 2 10.77.0.1 >/dev/null'
# shellcheck disable=SC2016 # expanded in the peer container, not here
check 'handshake: the kernel has a session' peer '[ "$(wg show wg0 latest-handshakes | cut -f2)" -gt 0 ]'
check 'handshake: our side has a session' has 'handshake 1'

peer 'wg set wg0 listen-port 51001'
check 'roaming: pings after the port change' peer 'ping -c 3 -W 2 10.77.0.1 >/dev/null'
check 'roaming: our side followed to :51001' has 'endpoint .*:51001'

if [[ "$REKEY" -gt 0 ]]; then
  log "rekey: pinging for ${REKEY}s"
  first="$(peer 'wg show wg0 latest-handshakes | cut -f2')"
  loss="$(peer "ping -i 1 -w $REKEY 10.77.0.1 | grep -o '[0-9.]*% packet loss'")"
  second="$(peer 'wg show wg0 latest-handshakes | cut -f2')"
  log "kernel handshakes at $first and $second; $loss"
  check 'rekey: the kernel made a new handshake' test "$second" -gt "$first"
  check 'rekey: our side saw a second session' has 'handshake 2'
  check 'rekey: no ping lost across it' test "${loss%%%*}" = 0
else
  log 'rekey: skipped (WG_REKEY_SECONDS=0)'
fi

log 'kernel peer:'
peer 'wg show wg0' | sed 's/^/   /'
log 'our side:'
ours | sed 's/^/   /'
stop_ours

# The agent itself: its WireGuard, its netstack, its own port forwarded
# through the tunnel, and the plugin's agent client (core/agent_client.nelua,
# driven by tests/test_agent.nelua) talking to it from the kernel peer's side.
APORT=17777
log "agent: building ghostty-agent and tests/test_agent.nelua"
agent "cd $DIR && vendor/nelua-lang/nelua --cc tools/zig-cc.sh -P nogc --cache-dir build/nelua-cache -L . -o build/wg-agent -b agent/agent.nelua >/dev/null &&
  vendor/nelua-lang/nelua --cc tools/zig-cc.sh -P nogc --cache-dir build/nelua-cache -L . -o build/wg-test-agent -b tests/test_agent.nelua >/dev/null"
agent_key2="$(peer 'wg genkey')"
agent_pub2="$(peer "echo $agent_key2 | wg pubkey")"
agent "printf '%s\n' '[Interface]' 'PrivateKey = $agent_key2' 'ListenPort = $((PORT + 1))' 'Address = 10.77.0.1/24' \
  '' '[Peer]' 'Name = interop' 'PublicKey = $peer_pub' 'PresharedKey = $psk' 'AllowedIPs = 10.77.0.2/32' >/tmp/wg-agent.conf
  echo interoptoken >/tmp/wg-agent-token"
# shellcheck disable=SC2016 # expanded in the container, not here
stop_agent() { agent '[ -f /tmp/wg-agent.pid ] && kill "$(cat /tmp/wg-agent.pid)" 2>/dev/null; rm -f /tmp/wg-agent.pid; true'; }
stop_agent
agent "cd $DIR && { setsid nohup build/wg-agent --listen 127.0.0.1:$APORT --token-file /tmp/wg-agent-token --windows off \
  --clipboard-file /tmp/wg-agent-clipboard \
  --wireguard-config /tmp/wg-agent.conf >/tmp/wg-agent.log 2>&1 & echo \$! >/tmp/wg-agent.pid; }"
sleep 1
peer "wg set wg0 peer $agent_pub remove
  wg set wg0 peer $agent_pub2 preshared-key <(echo $psk) endpoint $agent_ip:$((PORT + 1)) allowed-ips 10.77.0.1/32"
incus exec "$AGENT" -- cat "$DIR/build/wg-test-agent" | incus exec "$PEER" -- sh -c 'cat >/tmp/test_agent && chmod +x /tmp/test_agent'
agentlog() { agent 'cat /tmp/wg-agent.log'; }
check 'agent: its netstack answers ping in the tunnel' peer 'ping -c 3 -W 2 10.77.0.1 >/dev/null'
check "agent: the plugin's client over the tunnel (test_agent, 10.77.0.1:$APORT)" \
  peer "/tmp/test_agent $APORT interoptoken - 10.77.0.1 >/tmp/test_agent.log 2>&1"
check 'agent: a 1 MB paste through the tunnel reached the shell whole' \
  agent "[ \"\$(wc -c <$DIR/build/agent-paste)\" = 1048576 ]"
agent_has() { agentlog | grep -q "$1"; }
check 'agent: its log names the peer' agent_has 'interop connected from'
check 'agent: the tunnel connections were forwarded to its listener' agent_has 'tunnel connection from 10.77.0.2 port'
log 'test_agent over the tunnel:'
peer 'tail -n 5 /tmp/test_agent.log' | sed 's/^/   /'
log 'the agent:'
agentlog | grep -i 'wireguard\|listening\|tunnel' | head -n 12 | sed 's/^/   /'
stop_agent
peer 'ip link del wg0'
if [[ $fails -gt 0 ]]; then log "$fails check(s) failed"; exit 1; fi
log 'all checks passed'
