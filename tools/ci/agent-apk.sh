#!/usr/bin/env sh
# Build the Alpine agent package from the agent source tarball, on Alpine.
# Run it on an Alpine host with abuild, normally inside a container: this
# machine's package set is not something a build should be installing into.
#
#   tools/ci/agent-apk.sh --out build/release
#   tools/ci/agent-apk.sh --check --out build/apk-check
#
# Output, in --out (default build/dist):
#   ghostty-agent-<version>-r0.apk   musl, with the Wayland compositor
#                                    (SKIP_WAYLAND=1 leaves it out)
#   and a byte copy under a name that never changes.
#
# Environment:
#   SOURCE_DATE_EPOCH   build time (default: the last commit's time)
#   SKIP_WAYLAND        1 to build without the compositor backend
#   HOST_UID, HOST_GID  who owns the output afterwards
#
# Exit codes: 0 done, 1 a build or an assertion failed, 2 bad argument, 127 abuild missing.
#
# POSIX sh, not bash: an Alpine container has no bash until something installs one.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
log() { printf '== agent-apk: %s\n' "$*"; }
die() { printf 'agent-apk: error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

OUT=build/dist
SRC=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "$1 needs a directory"; OUT="$2"; shift ;;
    --src) [ $# -ge 2 ] || die "$1 needs a tarball"; SRC="$2"; shift ;;
    --check) CHECK=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

command -v abuild >/dev/null || {
  printf 'agent-apk: error: abuild is required; run this inside an Alpine container\n' >&2
  exit 127
}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

if [ -z "$SRC" ]; then
  SRC=$(find build/dist -maxdepth 1 -name 'ghostty-agent-*-src.tar.gz' | sort | tail -n1)
  [ -n "$SRC" ] || die 'no agent source tarball; run tools/package-agent.sh first'
fi
[ -f "$SRC" ] || die "no such source tarball: $SRC"
VERSION=$(basename "$SRC"); VERSION=${VERSION#ghostty-agent-}; VERSION=${VERSION%-src.tar.gz}
log "source $SRC (version $VERSION)"

WORK="$ROOT/build/agent-apk"
rm -rf "$WORK"
mkdir -p "$WORK"
cp packaging/apk/APKBUILD "$WORK/APKBUILD"
cp "$SRC" "$WORK/"
# The APKBUILD carries the version the tree is on; keep them in step here too.
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$WORK/APKBUILD"

# abuild wants a packager key and refuses to run as root without -F. Newer
# abuild keeps it in $HOME/.config/abuild, older in $HOME/.abuild, and its own
# -i shells out to doas, which a root container has no rules for. So generate
# the key and install the public half here: the repository index abuild writes
# at the end is verified against it, and without it the package builds and the
# run then fails with "UNTRUSTED signature".
abuild_conf=""
for d in "$HOME/.config/abuild" "$HOME/.abuild"; do
  if [ -f "$d/abuild.conf" ]; then abuild_conf="$d/abuild.conf"; fi
done
if [ -z "$abuild_conf" ]; then
  abuild-keygen -a -n || die 'abuild-keygen failed: no packager key to sign with'
fi
if [ -d /etc/apk/keys ]; then
  for k in "$HOME"/.config/abuild/*.rsa.pub "$HOME"/.abuild/*.rsa.pub; do
    if [ -f "$k" ]; then cp -f "$k" /etc/apk/keys/; fi
  done
fi
export REPODEST="$WORK/repo"

log 'abuild'
( cd "$WORK" && abuild -F checksum && abuild -F -r ) || die 'abuild failed'

APK=$(find "$REPODEST" -name "ghostty-agent-$VERSION-r0.apk" | head -n1)
[ -n "$APK" ] || die "abuild produced no ghostty-agent-$VERSION-r0.apk"
cp "$APK" "$OUT/"
cp "$APK" "$OUT/ghostty-agent.apk"
# The man page and the READMEs live in the -doc subpackage, because abuild
# refuses a man page in the program package. Ship it beside the main one so an
# Alpine user can have `man ghostty-agent`; it is not required of a release, so
# its absence can never hold one up.
DOC=$(find "$REPODEST" -name "ghostty-agent-doc-$VERSION-r0.apk" | head -n1)
if [ -n "$DOC" ]; then
  cp "$DOC" "$OUT/"
  cp "$DOC" "$OUT/ghostty-agent-doc.apk"
else
  log 'note: no -doc subpackage was built'
fi

log 'what the package claims'
tar -tzf "$APK" 2>/dev/null | grep -q 'usr/bin/ghostty-agent' || die 'the package has no /usr/bin/ghostty-agent'
if [ "${SKIP_WAYLAND:-0}" != 1 ]; then
  apk adddep --help >/dev/null 2>&1 || true
  if ! tar -xzOf "$APK" .PKGINFO 2>/dev/null | grep -q 'so:libwlroots-0.20.so'; then
    die 'the package does not depend on so:libwlroots-0.20.so: the compositor did not link in'
  fi
fi
tar -xzOf "$APK" .PKGINFO 2>/dev/null | grep -E '^(pkgname|pkgver|license|depend)' | sed 's/^/    /'

if [ "$CHECK" = 1 ]; then
  log 'installing it and running it'
  apk add --allow-untrusted "$OUT/ghostty-agent-$VERSION-r0.apk" >/dev/null
  /usr/bin/ghostty-agent --help >/dev/null || die 'the installed agent does not answer --help'
  home=$(mktemp -d)
  port=$((20000 + $$ % 20000))
  HOME="$home" /usr/bin/ghostty-agent --listen "127.0.0.1:$port" &
  agent=$!
  i=0
  while [ $i -lt 60 ]; do [ -s "$home/.config/ghostty-agent/token" ] && break; sleep 0.1; i=$((i + 1)); done
  [ -s "$home/.config/ghostty-agent/token" ] || die 'the agent wrote no token'
  [ "$(stat -c %a "$home/.config/ghostty-agent/token")" = 600 ] || die 'the token is not 0600'
  kill -TERM "$agent" 2>/dev/null || true
  wait "$agent" 2>/dev/null || true
  rm -rf "$home"
  log 'check passed'
fi

chown -R "${HOST_UID:-$(id -u)}:${HOST_GID:-$(id -g)}" "$OUT" 2>/dev/null || true
log 'done:'
ls -la "$OUT"
