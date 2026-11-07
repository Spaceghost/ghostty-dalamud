#!/usr/bin/env bash
# Separate external compositor, private socket, no host clipboard access.
set -euo pipefail
container="${GHOSTTY_WAYLAND_TEST_CONTAINER:-ghostty-vote-compositor-tests}"
podman exec "$container" bash /work/tools/build-clipboard-helper.sh
podman exec "$container" bash -c 'cc -std=c11 -Wall -Wextra -Werror -O2 -I/work/build/clipboard-helper /work/tests/fixtures/clipboard_source.c /work/build/clipboard-helper/ext-data-control-protocol.c $(pkg-config --cflags --libs wayland-client) -o /work/build/clipboard-helper/test-source'
podman exec -i --user 1000 \
  --env "GHOSTTY_CLIPBOARD_TEST_AGENT=${GHOSTTY_CLIPBOARD_TEST_AGENT:-/work/build/ghostty-agent-clipboard-helper}" \
  --env "GHOSTTY_CLIPBOARD_TEST_WAYLAND=${GHOSTTY_CLIPBOARD_TEST_WAYLAND:-0}" \
  --env "GHOSTTY_CLIPBOARD_TEST_INSTALLED=${GHOSTTY_CLIPBOARD_TEST_INSTALLED:-0}" \
  "$container" bash -s <<'INNER'
set -euo pipefail
runtime="$(mktemp -d /tmp/ghostty-clipboard-test.XXXXXX)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
cat > "$runtime/sway.conf" <<'CONFIG'
xwayland disable
output * resolution 800x600
CONFIG
sway --unsupported-gpu --config "$runtime/sway.conf" > "$runtime/sway.log" 2>&1 &
compositor=$!
trap 'kill "$compositor" 2>/dev/null || true; wait "$compositor" 2>/dev/null || true; rm -rf "$runtime"' EXIT
for attempt in {1..100}; do
  for socket in "$runtime"/wayland-*; do
    if [[ -S "$socket" ]]; then export WAYLAND_DISPLAY="${socket##*/}"; break 2; fi
  done
  if ! kill -0 "$compositor" 2>/dev/null; then cat "$runtime/sway.log"; exit 1; fi
  sleep 0.05
done
test -n "${WAYLAND_DISPLAY:-}"
for mode in safe empty oversized; do
  python3 - "$mode" <<'PY' | wl-copy --type 'text/plain;charset=utf-8'
import sys
mode = sys.argv[1]
sys.stdout.buffer.write(b'fixture external clipboard' if mode == 'safe' else b'x' * 65537 if mode == 'oversized' else b'')
PY
  if /work/build/dist/clipboard-snapshot > "$runtime/reply"; then result=0; else result=$?; fi
  python3 - "$mode" "$result" "$runtime/reply" <<'PY'
from pathlib import Path
import sys
mode, result, path = sys.argv[1:]
reply = Path(path).read_bytes()
if mode == 'oversized':
    assert int(result) != 0 and reply == b'', (mode, result, len(reply))
else:
    text = b'fixture external clipboard' if mode == 'safe' else b''
    assert result == '0' and reply == b'\x01' + text, (mode, result, reply)
print('external clipboard snapshot:', mode, 'OK')
PY
  python3 /work/tools/test-clipboard-agent.py "$mode"
done
/work/build/clipboard-helper/test-source > "$runtime/sensitive.log" 2> "$runtime/client.log" &
client=$!
for attempt in {1..100}; do
  if [[ -s "$runtime/sensitive.log" ]]; then break; fi
  if ! kill -0 "$client" 2>/dev/null; then cat "$runtime/client.log"; exit 1; fi
  sleep 0.05
done
if /work/build/dist/clipboard-snapshot > "$runtime/reply"; then result=0; else result=$?; fi
sleep 0.1
python3 - "$result" "$runtime/reply" "$runtime/sensitive.log" <<'PY'
from pathlib import Path
import sys
result, reply, log = sys.argv[1:]
assert result == '0' and Path(reply).read_bytes() == b'\x03', result
assert Path(log).read_text() == 'published:1\n', Path(log).read_text()
print('external clipboard snapshot: concealed source never requested OK')
PY
python3 /work/tools/test-clipboard-agent.py sensitive
python3 - "$runtime/sensitive.log" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text() == 'published:1\n', 'agent requested concealed data'
PY
kill "$client"
wait "$client" 2>/dev/null || true
if [[ "${GHOSTTY_CLIPBOARD_TEST_WAYLAND:-0}" == 1 ]]; then
  printf 'fixture external clipboard' | wl-copy --type 'text/plain;charset=utf-8'
  python3 /work/tools/test-clipboard-agent.py internal
fi
/work/build/clipboard-helper/test-source slow > "$runtime/slow.log" 2> "$runtime/client.log" &
client=$!
for attempt in {1..100}; do
  if [[ -s "$runtime/slow.log" ]]; then break; fi
  if ! kill -0 "$client" 2>/dev/null; then cat "$runtime/client.log"; exit 1; fi
  sleep 0.05
done
/work/build/dist/clipboard-snapshot > "$runtime/stale-reply" &
reader=$!
for attempt in {1..100}; do
  if python3 - "$runtime/slow.log" <<'PY'
from pathlib import Path
import sys
sys.exit(0 if 'requested:' in Path(sys.argv[1]).read_text() else 1)
PY
  then break; fi
  if ! kill -0 "$reader" 2>/dev/null; then echo 'reader exited before requesting the slow source'; exit 1; fi
  sleep 0.01
done
printf 'replacement clipboard' | wl-copy --type 'text/plain;charset=utf-8'
if wait "$reader"; then echo 'stale source was accepted'; exit 1; fi
test ! -s "$runtime/stale-reply"
echo 'external clipboard snapshot: replaced slow source discarded OK'
kill "$client" 2>/dev/null || true
wait "$client" 2>/dev/null || true
INNER
