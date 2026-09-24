#!/usr/bin/env bash
# Start the ghostty-agent container image and prove it answers the protocol:
# HELLO with its token gets OK "ghostty-agent <version> ...", LIST gets a
# listing, and netlab is really linked in: NLCTL `start relay=off` binds an iroh
# endpoint and `ticket` returns one. Speaks the wire format of
# core/protocol.nelua directly (u8 type, u32 LE length, payload) over bash's
# /dev/tcp, so it needs nothing but the container engine.
#
#   tools/ci/container-smoke.sh [IMAGE]      (default localhost/ghostty-agent:latest)
#
# Environment:
#   ENGINE        podman or docker (default: podman when there is one)
#   SMOKE_PORT    the host port to publish the agent on (default 17777)
#   SMOKE_NETLAB  0 to accept an image without netlab (default 1: required)
#
# Exit codes: 0 answered, 1 it did not, 2 bad argument, 127 no engine.
set -euo pipefail
IMAGE="${1:-localhost/ghostty-agent:latest}"
ENGINE="${ENGINE:-$(command -v podman || command -v docker || true)}"
[[ -n "$ENGINE" ]] || { echo 'container-smoke: podman or docker is required' >&2; exit 127; }
PORT="${SMOKE_PORT:-17777}"
NAME="ghostty-agent-smoke-$$"
log() { printf '== smoke: %s\n' "$*"; }
die() { printf 'container-smoke: error: %s\n' "$*" >&2; "$ENGINE" logs "$NAME" 2>&1 | tail -20 >&2 || true; exit 1; }
cleanup() { "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Published on the host's loopback only; inside, the agent listens on every
# interface of its own network namespace, which is the container's.
"$ENGINE" run -d --name "$NAME" -e HOME=/root -p "127.0.0.1:$PORT:7777" "$IMAGE" \
  --listen 0.0.0.0:7777 >/dev/null
TOKEN=""
for _ in $(seq 1 100); do
  TOKEN="$("$ENGINE" exec "$NAME" cat /root/.config/ghostty-agent/token 2>/dev/null || true)"
  [[ -n "$TOKEN" ]] && break
  sleep 0.2
done
[[ -n "$TOKEN" ]] || die 'the agent wrote no token'
log "token written ($("$ENGINE" exec "$NAME" stat -c %a /root/.config/ghostty-agent/token))"

# frame TYPE PAYLOAD-BYTES-AS-PRINTF-ESCAPES
u32le() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)); }
frame() { # type text [req]
  local body="$2" pre=""
  [[ $# -ge 3 ]] && pre="$(u32le "$3")"
  local len=$(( ${#body} + (${#pre} ? 4 : 0) ))
  # shellcheck disable=SC2059 # the escapes are the point
  printf "$(printf '\\x%02x' "$1")$(u32le "$len")$pre%s" "$body"
}

reply="$(mktemp)"
for _ in $(seq 1 50); do
  if exec 3<>"/dev/tcp/127.0.0.1/$PORT"; then break; fi 2>/dev/null
  sleep 0.2
done
{ frame 1 "$TOKEN"; frame 8 ""; } >&3
if [[ "${SMOKE_NETLAB:-1}" == 1 ]]; then
  frame 48 'start relay=off' 1 >&3
  frame 48 'ticket' 2 >&3
fi
timeout 8 cat <&3 >"$reply" || true
exec 3<&-

# Walk the frames: type, length, payload.
mapfile -t B < <(od -An -v -tu1 "$reply" | tr -s ' ' '\n' | sed '/^$/d')
i=0 hello="" list=0 nl_ok=0 nl_ticket=""
text() { local s="" k; for ((k = $1; k < $2; k++)); do s+="\\x$(printf '%02x' "${B[k]}")"; done; printf '%b' "$s"; }
while (( i + 5 <= ${#B[@]} )); do
  t=${B[i]} n=$(( B[i+1] | B[i+2] << 8 | B[i+3] << 16 | B[i+4] << 24 ))
  p=$((i + 5)) e=$((i + 5 + n))
  (( e <= ${#B[@]} )) || break
  case "$t" in
    16) [[ -z "$hello" ]] && hello="$(text "$p" "$e")" ;;
    17) log "ERR $(text "$p" "$e")" ;;
    21) list=1 ;;
    49) req=$(( B[p] | B[p+1] << 8 )) ok=${B[p+4]} msg="$(text $((p + 5)) "$e")"
        log "NLREPLY req $req ok $ok: ${msg:0:60}"
        [[ "$req" == 1 && "$ok" == 1 ]] && nl_ok=1
        [[ "$req" == 2 && "$ok" == 1 ]] && nl_ticket="$msg" ;;
  esac
  i=$e
done
rm -f "$reply"

[[ "$hello" == ghostty-agent\ * ]] || die "no OK \"ghostty-agent ...\" for HELLO (got '${hello}')"
log "HELLO -> OK \"$hello\""
[[ "$list" == 1 ]] || die 'no LIST answer'
log 'LIST -> answered'
if [[ "${SMOKE_NETLAB:-1}" == 1 ]]; then
  [[ "$nl_ok" == 1 ]] || die 'netlab did not start (is it built into this image?)'
  [[ -n "$nl_ticket" ]] || die 'netlab gave no ticket'
  log "netlab -> started, ticket ${nl_ticket:0:24}..."
fi
log "passed: $IMAGE"
