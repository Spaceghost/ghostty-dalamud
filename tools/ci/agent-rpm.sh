#!/usr/bin/env bash
# Build the Linux agent packages from the agent source tarball, on Fedora.
# Run it on a Fedora host, normally through tools/ci/in-fedora.sh. It installs
# nothing itself: the container image provides the toolchain.
#
#   tools/ci/in-fedora.sh tools/ci/agent-rpm.sh --out build/release
#   tools/ci/in-fedora.sh tools/ci/agent-rpm.sh --check --out build/agent-check
#
# Output, in --out (default build/dist):
#   ghostty-agent-<version>-1.fc44.x86_64.rpm    with the Wayland compositor; Fedora 44 and newer
#   ghostty-agent-<version>-1.fc43.x86_64.rpm    glibc only; Fedora 43 and anything newer
#   ghostty-agent-<version>-linux-x86_64.tar.gz  the same binary as the .fc43 package,
#                                                the user unit, README-agent.md, BUILD-INFO.txt
#   and a byte copy of each under a name that never changes.
#
# Environment:
#   SOURCE_DATE_EPOCH   build time and file times (default: the last commit's time)
#   HOST_UID, HOST_GID  who owns the output afterwards (default: this user)
#   RELEASE_TAG         named in BUILD-INFO.txt (default: the commit)
#   AGENT_GLIBC_MAX     the highest glibc this binary may need (default 2.38)
#
# Exit codes: 0 done, 1 a build or an assertion failed, 2 bad argument, 127 rpmbuild missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
log() { printf '== agent-rpm: %s\n' "$*"; }
die() { printf 'agent-rpm: error: %s\n' "$*" >&2; exit 1; }
# "ID VERSION_ID" of this machine, read without sourcing os-release (it sets VERSION)
os_id() { local id ver; id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"; ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"; echo "$id $ver"; }
usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

OUT="build/dist"
SRC=""
CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || { echo "error: $1 needs a directory" >&2; exit 2; }; OUT="$2"; shift ;;
    --src) [[ $# -ge 2 ]] || { echo "error: $1 needs a tarball" >&2; exit 2; }; SRC="$2"; shift ;;
    --check) CHECK=1 ;;
    --publish) ;; # accepted and ignored: building and publishing are the same files now
    -h | --help) usage; exit 0 ;;
    *) usage >&2; echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v rpmbuild >/dev/null || {
  echo 'agent-rpm: error: rpmbuild is required; run this through tools/ci/in-fedora.sh' >&2
  exit 127
}
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}"
export SOURCE_DATE_EPOCH
# 2.38, not 2.36: netlab's aws-lc defines _GNU_SOURCE, so with glibc 2.38+
# headers its strtol and sscanf become __isoc23_strtol and __isoc23_sscanf.
AGENT_GLIBC_MAX="${AGENT_GLIBC_MAX:-2.38}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ -z "$SRC" ]]; then
  shopt -s nullglob
  cands=(build/dist/ghostty-agent-*-src.tar.gz)
  if [[ ${#cands[@]} -eq 0 ]]; then
    log 'no source tarball yet: tools/package-agent.sh'
    "$ROOT/tools/package-agent.sh" --out build/dist
    cands=(build/dist/ghostty-agent-*-src.tar.gz)
  fi
  shopt -u nullglob
  [[ ${#cands[@]} -gt 0 ]] || die 'no agent source tarball and none could be made'
  SRC="${cands[-1]}"
fi
[[ -f "$SRC" ]] || die "no such source tarball: $SRC"
VERSION="$(basename "$SRC")"
VERSION="${VERSION#ghostty-agent-}"
VERSION="${VERSION%-src.tar.gz}"
log "source $SRC (version $VERSION)"

# The rpmbuild tree lives under build/agent-rpm and is always removed, so no
# .src.rpm and no debug package survives under build/ where the release
# collector walks.
TOP="$ROOT/build/agent-rpm"
rm -rf "$TOP"
mkdir -p "$TOP/SOURCES"
trap 'rm -rf "$TOP"' EXIT
cp -p "$SRC" "$TOP/SOURCES/"
SRCBASE="$(basename "$SRC")"

build_flavour() { # dist without
  local dist="$1" without="$2" rpm
  log "rpmbuild -tb ${without:+--without wayland }($dist)"
  # shellcheck disable=SC2086 # $without is a deliberate word split or nothing
  rpmbuild -tb --define "_topdir $TOP" --define "dist $dist" \
    --define '_buildhost reproducible' $without "$TOP/SOURCES/$SRCBASE"
  rpm="$TOP/RPMS/x86_64/ghostty-agent-$VERSION-1$dist.x86_64.rpm"
  [[ -f "$rpm" ]] || die "rpmbuild made no $rpm"
  # exactly this filename, never a glob: -debuginfo and -debugsource stay behind
  cp -p "$rpm" "$OUT/"
  log "requires of $(basename "$rpm"):"
  rpm -qp --requires "$rpm" | sed 's/^/    /'
  log "files of $(basename "$rpm"):"
  rpm -qpl "$rpm" | sed 's/^/    /'
}

build_flavour .fc44 ''
build_flavour .fc43 '--without wayland'

FC44="$OUT/ghostty-agent-$VERSION-1.fc44.x86_64.rpm"
FC43="$OUT/ghostty-agent-$VERSION-1.fc43.x86_64.rpm"

log 'asserting what each package claims'
rpm -qp --requires "$FC44" | grep -q 'libwlroots-0.20\.so' ||
  die 'the .fc44 package does not require libwlroots-0.20.so: the compositor did not link in'
if rpm -qp --requires "$FC43" | grep -qE 'wlroots|wayland|xkbcommon|pixman'; then
  die 'the .fc43 package requires a Wayland library; it must depend on glibc alone'
fi
for r in "$FC44" "$FC43"; do
  rpm -qpl "$r" | grep -qx '/usr/bin/ghostty-agent' || die "$r does not carry /usr/bin/ghostty-agent"
  if [[ "${SKIP_NETLAB:-0}" != 1 ]]; then
    # the spec already checked the symbol before stripping; this is the shipped
    # bytes: moq-iroh-c's source paths are remapped to moq-iroh-src/ in its panics
    # (into a file first: grep -q stopping early would SIGPIPE cpio under pipefail)
    rpm2cpio "$r" | cpio -i --quiet --to-stdout ./usr/bin/ghostty-agent >"$TOP/netlab-check"
    grep -aq 'moq-iroh-src/' "$TOP/netlab-check" || die "$r carries no netlab (moq-iroh-c is not linked in)"
    rm -f "$TOP/netlab-check"
  fi
  rpm -qpl "$r" | grep -qx '/usr/lib/systemd/user/ghostty-agent.service' || die "$r does not carry the user unit"
done

# The portable tarball ships exactly the .fc43 package's stripped binary.
STAGE="$ROOT/build/agent-tar"
TARNAME="ghostty-agent-$VERSION-linux-x86_64"
rm -rf "$STAGE"
mkdir -p "$STAGE/$TARNAME" "$STAGE/x"
( cd "$STAGE/x" && rpm2cpio "$FC43" | cpio -idm --quiet )
cp -p "$STAGE/x/usr/bin/ghostty-agent" "$STAGE/$TARNAME/ghostty-agent"
cp -p "$STAGE/x/usr/bin/ghostty-voice" "$STAGE/$TARNAME/ghostty-voice"
chmod 0755 "$STAGE/$TARNAME/ghostty-agent"
sed 's|^ExecStart=/usr/bin/ghostty-agent |ExecStart=%h/.local/bin/ghostty-agent |' \
  "$STAGE/x/usr/lib/systemd/user/ghostty-agent.service" >"$STAGE/$TARNAME/ghostty-agent.service"
cp -p packaging/README-agent.md "$STAGE/$TARNAME/README-agent.md"
if [[ -f LICENSE ]]; then cp -p LICENSE "$STAGE/$TARNAME/LICENSE"; fi

if readelf -d "$STAGE/$TARNAME/ghostty-agent" | grep -q 'libwlroots'; then
  die 'the portable binary links wlroots; it must be the .fc43 build'
fi
# DT_RELR makes elfdeps emit GLIBC_ABI_DT_RELR, which only glibc 2.36 and newer
# provides, so the floor is at least 2.36 however low the symbol versions go.
# At least: a symbol version above it still wins (it used to replace it, which
# hid a binary needing more than the ceiling).
GLIBC_SYM="$(readelf -V "$STAGE/$TARNAME/ghostty-agent" 2>/dev/null |
  grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n1 || true)"
GLIBC_NEED="${GLIBC_SYM:-0}"
if readelf -d "$STAGE/$TARNAME/ghostty-agent" | grep -q 'RELR'; then
  GLIBC_NEED="$(printf '%s\n%s\n' "$GLIBC_NEED" 2.36 | sort -V | tail -n1)"
fi
log "glibc needed: $GLIBC_NEED (highest symbol version $GLIBC_SYM, ceiling $AGENT_GLIBC_MAX)"
[[ "$(printf '%s\n%s\n' "$GLIBC_NEED" "$AGENT_GLIBC_MAX" | sort -V | tail -n1)" == "$AGENT_GLIBC_MAX" ]] ||
  die "the binary needs glibc $GLIBC_NEED, above the $AGENT_GLIBC_MAX ceiling"

{
  echo "ghostty-agent $VERSION"
  echo "built on: $(os_id), $(uname -m), gcc $(gcc -dumpversion 2>/dev/null || echo unknown)"
  echo "glibc at build time: $(ldd --version 2>/dev/null | head -n1)"
  echo "glibc needed to run this: $GLIBC_NEED or newer (measured)"
  echo "wayland compositor backend: no"
  echo "netlab (moq over iroh): $(if grep -aq 'moq-iroh-src/' "$STAGE/$TARNAME/ghostty-agent"; then echo yes; else echo no; fi)"
  echo "sha256: $(sha256sum "$STAGE/$TARNAME/ghostty-agent" | cut -d' ' -f1)"
  echo "source: https://github.com/Spaceghost/ghostty-dalamud/tree/${RELEASE_TAG:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo master)}"
} >"$STAGE/$TARNAME/BUILD-INFO.txt"

log "$TARNAME.tar.gz"
find "$STAGE/$TARNAME" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
rm -f "$OUT/$TARNAME.tar.gz"
( cd "$STAGE" && find "$TARNAME" \( -type f -o -type l \) | LC_ALL=C sort |
  tar --format=gnu --numeric-owner --owner=0 --group=0 --mtime="@$SOURCE_DATE_EPOCH" \
    --no-recursion -T - -cf - ) | gzip -n -9 >"$OUT/$TARNAME.tar.gz"

# Names that never change, so a download URL never does either.
cp -p "$FC44" "$OUT/ghostty-agent.fc44.x86_64.rpm"
cp -p "$FC43" "$OUT/ghostty-agent.fc43.x86_64.rpm"
cp -p "$OUT/$TARNAME.tar.gz" "$OUT/ghostty-agent-linux-x86_64.tar.gz"
# both names for the source too: the versioned one is what the release notes
# name, the stable one is what a URL can point at forever.
[[ "$(cd "$(dirname "$SRC")" && pwd)" == "$OUT" ]] || cp -p "$SRC" "$OUT/"
cp -p "$SRC" "$OUT/ghostty-agent-src.tar.gz"

if [[ "$CHECK" == 1 ]]; then
  log 'installing the .fc43 package and running it'
  dnf -y install "$FC43" >/dev/null
  /usr/bin/ghostty-agent --help >/dev/null || die 'the installed agent does not answer --help'
  grep -q '^ExecStart=/usr/bin/ghostty-agent ' /usr/lib/systemd/user/ghostty-agent.service ||
    die 'the installed unit does not start /usr/bin/ghostty-agent'
  home="$(mktemp -d)"
  port=$((20000 + $$ % 20000))
  HOME="$home" /usr/bin/ghostty-agent --listen "127.0.0.1:$port" &
  agent=$!
  for _ in $(seq 1 60); do [[ -s "$home/.config/ghostty-agent/token" ]] && break; sleep 0.1; done
  [[ -s "$home/.config/ghostty-agent/token" ]] || die 'the agent wrote no token'
  [[ "$(stat -c %a "$home/.config/ghostty-agent/token")" == 600 ]] || die 'the token is not 0600'
  kill -TERM "$agent"
  wait "$agent" || true
  rm -rf "$home"
  cmp "$STAGE/$TARNAME/ghostty-agent" /usr/bin/ghostty-agent ||
    die 'the tarball binary and the packaged binary differ'
  # Only where the checkout is: tools/package-agent.sh packs out of git, and a
  # container that was handed a finished tarball has no index to pack from.
  if [[ -d "$ROOT/.git" && -d "$ROOT/vendor/nelua-lang/.git" ]]; then
    log 'packing the source tarball twice to prove it is deterministic'
    "$ROOT/tools/package-agent.sh" --version "$VERSION" --out "$ROOT/build/agent-det" >/dev/null
    cmp "$SRC" "$ROOT/build/agent-det/ghostty-agent-$VERSION-src.tar.gz" ||
      die 'two packs of the same source differ'
    rm -rf "$ROOT/build/agent-det"
  else
    log 'skipping the determinism re-pack: no checkout here, only the tarball'
  fi
  log 'check passed'
fi

rm -rf "$STAGE"
chown -R "${HOST_UID:-$(id -u)}:${HOST_GID:-$(id -g)}" "$OUT" "$ROOT/build" 2>/dev/null || true
log "done:"
ls -la "$OUT"
