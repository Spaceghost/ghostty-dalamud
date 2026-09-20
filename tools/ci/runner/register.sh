#!/usr/bin/env bash
# Register (or remove) a self-hosted GitHub Actions runner for this repository
# as a systemd --user service. One script for both machines this project uses:
#
#   a build host        --labels ghostty-dalamud   (podman, ephemeral, no game)
#   the gaming PC       --labels ffxiv-live        (host mode, sees the game)
#
#   tools/ci/runner/register.sh install [options]
#   tools/ci/runner/register.sh uninstall [--name N] [--purge]
#   tools/ci/runner/register.sh status [--name N]
#   tools/ci/runner/register.sh token            print how to get a token, and get one
#
# Options for `install`:
#   --url URL        https://github.com/OWNER/REPO. Default: this checkout's
#                    `origin` remote, rewritten to an https URL.
#   --labels L,...   the runner's custom labels (required). It always also
#                    carries self-hosted, Linux and X64/ARM64.
#   --name N         runner name. Default <labels-head>-<hostname>.
#   --mode podman    run the job inside tools/ci/runner/Containerfile's image
#                    (the job cannot read the rest of your home directory).
#   --mode host      run the job directly as your user, in --dir. Needed when
#                    the job must reach the running game and write the dev
#                    plugin folder. Default: podman when podman is installed
#                    and no --bind was given, else host.
#   --ephemeral      one job per registration, then it deregisters itself
#                    (default). Needs a way to mint a fresh token for each
#                    job: --token-command, or gh on PATH.
#   --persistent     register once and keep serving jobs. Simpler; the runner
#                    stays registered (and visible as offline) until uninstall.
#   --dir DIR        where host mode unpacks the runner. Default
#                    ~/.local/share/ghostty-dalamud-runner/<name>
#   --bind PATH      (podman mode) bind PATH into the container at the same
#                    path. Repeatable. For the gaming PC: the dev plugin folder
#                    and the plugin config directory, nothing else.
#   --network host   (podman mode) share the host's network namespace, which is
#                    what reaching XivMcp on 127.0.0.1 needs.
#   --token-command CMD   a command printing a registration token, stored in the
#                    unit. A *command*, never a token.
#   --start / --no-start  start the service now (default --start).
#   --dry-run        print what it would write and do, change nothing.
#
# The registration token never comes from the repository and is never written
# to disk: it is read from RUNNER_TOKEN, or from --token-command/gh, or typed
# at a silent prompt. `uninstall` removes the unit, deregisters the runner and
# deletes the runner directory; --purge also drops the podman cache volume.
#
# Idempotent: `install` again with the same --name replaces the unit and
# re-registers (--replace), and never leaves two units for one runner.
#
# See docs/CI.md, "Self-hosted runners".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

log() { printf '== runner: %s\n' "$*"; }
warn() { printf 'runner: warning: %s\n' "$*" >&2; }
die() { printf 'runner: error: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRY=0
run() { if [[ $DRY == 1 ]]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- arguments
cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 2; }
shift || true

URL="" LABELS="" NAME="" MODE="" ELIFE=ephemeral DIR="" NETWORK="" TOKEN_CMD=""
START=1 PURGE=0
BINDS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:?--url needs a value}"; shift 2 ;;
    --labels) LABELS="${2:?--labels needs a value}"; shift 2 ;;
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs podman or host}"; shift 2 ;;
    --dir) DIR="${2:?--dir needs a path}"; shift 2 ;;
    --bind) BINDS+=("${2:?--bind needs a path}"); shift 2 ;;
    --network) NETWORK="${2:?--network needs a value}"; shift 2 ;;
    --token-command) TOKEN_CMD="${2:?--token-command needs a command}"; shift 2 ;;
    --ephemeral) ELIFE=ephemeral; shift ;;
    --persistent) ELIFE=persistent; shift ;;
    --start) START=1; shift ;;
    --no-start) START=0; shift ;;
    --purge) PURGE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# The repository: this checkout's origin, as an https URL, unless told otherwise.
default_url() {
  local u
  u="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  [[ -n "$u" ]] || return 1
  u="${u%.git}"
  case "$u" in
    git@*:*) u="https://${u#git@}"; u="${u/://}" ;;
    ssh://git@*) u="https://${u#ssh://git@}" ;;
  esac
  printf '%s\n' "$u"
}
[[ -n "$URL" ]] || URL="$(default_url || true)"

case "$cmd" in
  install | uninstall | status | token) ;;
  -h | --help) usage; exit 0 ;;
  *) die "unknown command: $cmd" ;;
esac

if [[ "$cmd" == install || "$cmd" == token ]]; then
  [[ -n "$URL" ]] || die "no --url and no origin remote to derive one from"
  [[ "$URL" =~ ^https://[^/]+/[^/]+/[^/]+$ ]] ||
    die "--url must look like https://github.com/OWNER/REPO, got: $URL"
fi
NWO="${URL#https://*/}"

# ---------------------------------------------------------------- the token
# Never stored. Printed nowhere. Read once, used once.
token_command_default() {
  command -v gh >/dev/null &&
    printf "gh api -X POST repos/%s/actions/runners/registration-token --jq .token\n" "$NWO"
}

get_token() {
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    printf '%s' "$RUNNER_TOKEN"
    return 0
  fi
  local c="${TOKEN_CMD:-${RUNNER_TOKEN_COMMAND:-$(token_command_default || true)}}"
  if [[ -n "$c" ]]; then
    bash -c "$c" | tr -d '\r\n'
    return 0
  fi
  if [[ -t 0 ]]; then
    local t
    printf 'runner: paste a registration token for %s\n' "$NWO" >&2
    printf '  get one at %s/settings/actions/runners/new, or with:\n' "$URL" >&2
    printf '  gh api -X POST repos/%s/actions/runners/registration-token --jq .token\n' "$NWO" >&2
    printf 'token (not echoed): ' >&2
    read -rs t
    printf '\n' >&2
    printf '%s' "$t"
    return 0
  fi
  die "no token: set RUNNER_TOKEN, pass --token-command, install gh, or run this on a terminal"
}

remove_token() { # a removal token, for deregistering
  if [[ -n "${RUNNER_REMOVE_TOKEN:-}" ]]; then
    printf '%s' "$RUNNER_REMOVE_TOKEN"
  elif command -v gh >/dev/null; then
    gh api -X POST "repos/$NWO/actions/runners/remove-token" --jq .token | tr -d '\r\n'
  else
    printf ''
  fi
}

if [[ "$cmd" == token ]]; then
  # deliberately does not print the token: it proves one can be obtained
  t="$(get_token)"
  [[ -n "$t" ]] || die "could not get a registration token"
  log "got a registration token for $NWO (${#t} characters; not printed)"
  exit 0
fi

# ---------------------------------------------------------------- defaults
if [[ "$cmd" == install ]]; then
  [[ -n "$LABELS" ]] || die "--labels is required (e.g. --labels ghostty-dalamud, or --labels ffxiv-live)"
  [[ "$LABELS" =~ ^[A-Za-z0-9][A-Za-z0-9._,-]*$ ]] || die "--labels must be comma separated label names"
fi
[[ -n "$NAME" ]] || NAME="${LABELS%%,*}-$(uname -n | tr '[:upper:]' '[:lower:]' | cut -d. -f1)"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "--name must be a short plain name, got: $NAME"
if [[ -z "$MODE" ]]; then
  if command -v podman >/dev/null && [[ ${#BINDS[@]} -eq 0 ]]; then MODE=podman; else MODE=host; fi
fi
[[ "$MODE" == podman || "$MODE" == host ]] || die "--mode must be podman or host"
[[ -n "$DIR" ]] || DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ghostty-dalamud-runner/$NAME"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="ghostty-dalamud-runner@$NAME"
UNIT_FILE="$UNIT_DIR/$UNIT.service"

# The actions/runner release, from the one place it is already pinned.
runner_pin() { # runner_pin VERSION|SHA_X64|SHA_ARM64
  local key="$1" cf="$HERE/Containerfile"
  case "$key" in
    VERSION) sed -n 's/^ARG RUNNER_VERSION=\(.*\)$/\1/p' "$cf" ;;
    SHA_X64) sed -n 's/^ARG RUNNER_SHA256_X64=\(.*\)$/\1/p' "$cf" ;;
    SHA_ARM64) sed -n 's/^ARG RUNNER_SHA256_ARM64=\(.*\)$/\1/p' "$cf" ;;
  esac
}

# ---------------------------------------------------------------- status
if [[ "$cmd" == status ]]; then
  printf 'unit      : %s\n' "$UNIT_FILE"
  if [[ -f "$UNIT_FILE" ]]; then
    printf 'installed : yes\n'
    printf 'enabled   : %s\n' "$(systemctl --user is-enabled "$UNIT" 2>&1 || true)"
    printf 'active    : %s\n' "$(systemctl --user is-active "$UNIT" 2>&1 || true)"
    sed -n 's/^# runner: //p' "$UNIT_FILE"
  else
    printf 'installed : no\n'
  fi
  printf 'directory : %s%s\n' "$DIR" "$([[ -d "$DIR" ]] && echo ' (present)' || echo ' (absent)')"
  printf 'linger    : %s\n' "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo '?')"
  exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ "$cmd" == uninstall ]]; then
  if [[ -f "$UNIT_FILE" ]]; then
    log "stopping and removing $UNIT"
    run systemctl --user disable --now "$UNIT" || true
    run rm -f "$UNIT_FILE"
    run systemctl --user daemon-reload
  else
    log "no unit at $UNIT_FILE"
  fi
  if [[ -x "$DIR/config.sh" ]]; then
    rt="$(remove_token)"
    if [[ -n "$rt" ]]; then
      log "deregistering $NAME"
      if [[ $DRY == 1 ]]; then
        printf '  would run: %s/config.sh remove --token <removal token>\n' "$DIR"
      else
        ( cd "$DIR" && ./config.sh remove --token "$rt" ) || warn "config.sh remove failed; remove the runner in the repository settings"
      fi
    else
      warn "no removal token (set RUNNER_REMOVE_TOKEN or install gh): remove the runner at $URL/settings/actions/runners"
    fi
  fi
  [[ -d "$DIR" ]] && { log "deleting $DIR"; run rm -rf "$DIR"; }
  if [[ $PURGE == 1 ]] && command -v podman >/dev/null; then
    log "removing the podman cache volume"
    run podman volume rm ghostty-dalamud-runner-cache || true
  fi
  log "uninstalled $NAME"
  exit 0
fi

# ---------------------------------------------------------------- install
log "repository : $URL"
log "runner     : $NAME"
log "labels     : self-hosted, Linux, $(uname -m | sed 's/x86_64/X64/; s/aarch64/ARM64/'), $LABELS"
log "mode       : $MODE, $ELIFE"
[[ ${#BINDS[@]} -gt 0 ]] && log "binds      : ${BINDS[*]}"

mkdir -p "$UNIT_DIR"

# Linger, so the runner keeps serving after you log out. Not fatal if refused.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != yes ]]; then
  log "enabling linger for $USER (so the service survives logout)"
  run loginctl enable-linger "$USER" 2>/dev/null ||
    warn "could not enable linger; the runner stops when you log out (loginctl enable-linger $USER as root)"
fi

TOKEN_CMD_EFF="${TOKEN_CMD:-${RUNNER_TOKEN_COMMAND:-$(token_command_default || true)}}"

if [[ "$MODE" == podman ]]; then
  command -v podman >/dev/null || die "--mode podman but podman is not installed"
  [[ "$ELIFE" == ephemeral ]] ||
    die "--mode podman is always ephemeral (each container serves one job); drop --persistent"
  [[ -n "$TOKEN_CMD_EFF" ]] ||
    die "--mode podman needs --token-command (or gh on PATH): every container needs a fresh token"
  log "building the runner image (tools/ci/runner/Containerfile)"
  run podman build -t localhost/ghostty-dalamud-runner -f "$HERE/Containerfile" "$HERE"
  podman_args=()
  [[ -n "$NETWORK" ]] && podman_args+=("--network" "$NETWORK")
  if [[ ${#BINDS[@]} -gt 0 ]]; then
    podman_args+=("--userns" "keep-id")
    for b in "${BINDS[@]}"; do
      [[ -d "$b" ]] || warn "--bind $b does not exist yet"
      podman_args+=("-v" "$b:$b")
    done
  fi
  exec_start="$ROOT/tools/ci/runner/start-runner.sh --loop"
  unit_env=(
    "Environment=RUNNER_URL=$URL"
    "Environment=RUNNER_LABELS=$LABELS"
    "Environment=RUNNER_NAME=$NAME"
    "Environment=RUNNER_TOKEN_COMMAND=$TOKEN_CMD_EFF"
  )
  [[ ${#podman_args[@]} -gt 0 ]] && unit_env+=("Environment=PODMAN_RUN_ARGS=${podman_args[*]}")
else
  # host mode: the runner itself, unpacked under $DIR, checked against the pin
  ver="$(runner_pin VERSION)" sha=""
  case "$(uname -m)" in
    x86_64) arch=x64; sha="$(runner_pin SHA_X64)" ;;
    aarch64 | arm64) arch=arm64; sha="$(runner_pin SHA_ARM64)" ;;
    *) die "no pinned actions/runner for $(uname -m)" ;;
  esac
  [[ -n "$ver" && -n "$sha" ]] || die "could not read the actions/runner pin from $HERE/Containerfile"
  if [[ -x "$DIR/run.sh" && "$(cat "$DIR/.version" 2>/dev/null || true)" == "$ver" ]]; then
    log "actions/runner $ver already unpacked in $DIR"
  else
    log "unpacking actions/runner $ver into $DIR"
    for c in curl tar sha256sum; do command -v "$c" >/dev/null || die "$c is required"; done
    run mkdir -p "$DIR"
    tarball="actions-runner-linux-$arch-$ver.tar.gz"
    if [[ $DRY == 1 ]]; then
      printf '  would fetch and verify %s\n' "$tarball"
    else
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      curl -fsSL --retry 3 -o "$tmp/$tarball" \
        "https://github.com/actions/runner/releases/download/v$ver/$tarball"
      echo "$sha  $tmp/$tarball" | sha256sum -c --status - ||
        die "checksum mismatch for $tarball; the pin in Containerfile does not match what was downloaded"
      tar -xzf "$tmp/$tarball" -C "$DIR"
      printf '%s\n' "$ver" >"$DIR/.version"
      rm -rf "$tmp"
      trap - EXIT
    fi
  fi

  if [[ "$ELIFE" == ephemeral ]]; then
    [[ -n "$TOKEN_CMD_EFF" ]] ||
      die "--ephemeral needs --token-command (or gh on PATH): every job needs a fresh token"
    # A loop that registers, serves one job, deregisters, and goes round again.
    # The token is fetched per iteration and stays in a shell variable.
    loop="$DIR/serve-one.sh"
    if [[ $DRY == 1 ]]; then
      printf '  would write %s\n' "$loop"
    else
      cat >"$loop" <<'LOOP'
#!/usr/bin/env bash
# Written by tools/ci/runner/register.sh. One ephemeral registration per job.
set -uo pipefail
cd "$(dirname "$0")"
: "${RUNNER_URL:?}" "${RUNNER_LABELS:?}" "${RUNNER_NAME:?}" "${RUNNER_TOKEN_COMMAND:?}"
t="$(bash -c "$RUNNER_TOKEN_COMMAND" | tr -d '\r\n')"
[[ -n "$t" ]] || { echo "no registration token" >&2; exit 1; }
./config.sh --unattended --ephemeral --disableupdate --replace \
  --url "$RUNNER_URL" --token "$t" --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" --work "${RUNNER_WORK:-_work}" || exit 1
unset t
exec ./run.sh
LOOP
      chmod +x "$loop"
    fi
    exec_start="$loop"
  else
    log "registering $NAME (once)"
    t="$(get_token)"
    [[ -n "$t" ]] || die "empty registration token"
    if [[ $DRY == 1 ]]; then
      printf '  would run: %s/config.sh --unattended --replace --url %s --token <token> --name %s --labels %s\n' \
        "$DIR" "$URL" "$NAME" "$LABELS"
    else
      ( cd "$DIR" && ./config.sh --unattended --disableupdate --replace \
        --url "$URL" --token "$t" --name "$NAME" --labels "$LABELS" --work _work )
    fi
    unset t
    exec_start="$DIR/run.sh"
  fi
  unit_env=(
    "Environment=RUNNER_URL=$URL"
    "Environment=RUNNER_LABELS=$LABELS"
    "Environment=RUNNER_NAME=$NAME"
  )
  [[ -n "$TOKEN_CMD_EFF" ]] && unit_env+=("Environment=RUNNER_TOKEN_COMMAND=$TOKEN_CMD_EFF")
fi

# The unit. `# runner:` lines are what `status` reads back.
unit_text="[Unit]
Description=GitHub Actions runner $NAME ($LABELS) for $NWO
Documentation=$URL/blob/HEAD/docs/CI.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
$(printf '%s\n' "${unit_env[@]}")
ExecStart=$exec_start
Restart=always
RestartSec=15
KillMode=process
TimeoutStopSec=5min

[Install]
WantedBy=default.target

# runner: mode      $MODE, $ELIFE
# runner: labels    $LABELS
# runner: directory $DIR
"

if [[ $DRY == 1 ]]; then
  printf -- '--- %s\n%s' "$UNIT_FILE" "$unit_text"
else
  printf '%s' "$unit_text" >"$UNIT_FILE"
  log "wrote $UNIT_FILE"
  systemctl --user daemon-reload
fi

if [[ $START == 1 ]]; then
  log "enabling and starting $UNIT"
  run systemctl --user enable --now "$UNIT"
  [[ $DRY == 1 ]] || { sleep 2; systemctl --user --no-pager --lines 10 status "$UNIT" || true; }
else
  log "not started; start it with: systemctl --user enable --now $UNIT"
fi

cat <<EOF

Installed. Useful from here:
  systemctl --user status $UNIT
  journalctl --user -u $UNIT -f
  tools/ci/runner/register.sh status --name $NAME
  tools/ci/runner/register.sh uninstall --name $NAME

The runner will pick up jobs whose runs-on asks for: $LABELS
No token was written to disk.
EOF
