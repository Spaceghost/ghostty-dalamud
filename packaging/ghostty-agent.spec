# ghostty-agent, built from the agent's own source tarball.
#
#   rpmbuild -tb ghostty-agent-<version>-src.tar.gz
#
# One command, on whatever you are building for. The spec decides for itself
# whether the Wayland compositor goes in, because that depends on the
# distribution and not on the person typing:
#
#   Fedora 44+   wlroots 0.20  -> compositor in, remote desktop windows work
#   Fedora 43    wlroots 0.19  -> compositor out, terminals/jobs/clips
#   Fedora 42    wlroots 0.19  -> compositor out
#   anything else with rpm     -> compositor out
#
# Deciding here rather than at the command line is the point: the two builds
# are not "a normal one and a cut-down one" that a person picks between, they
# are what each distribution can actually support, and getting it wrong gives
# either a package that will not install or one quietly missing the feature the
# project is for. `--with wayland` and `--without wayland` still override, for
# a distribution this list has not learned about yet.
#
# tools/package-agent.sh writes that tarball and tools/ci/agent-rpm.sh builds it
# on each release in that release's own container, so the packaged path and the
# documented path are one path. The tarball carries the pinned Nelua compiler,
# so the build needs no network: it works in mock, and so in COPR.
#
# No %changelog section: the project's changelog is CHANGELOG.md, generated from
# lua/changelog.lua, and a second one would be a second thing to bump. rpmlint's
# no-changelogname-tag and empty-%postun are accepted
# for a package this pipeline builds rather than submits to Fedora.
%if 0%{?fedora} >= 44
%bcond_without wayland
%else
%bcond_with wayland
%endif
# Netlab (moq over iroh, docs/NETLAB.md) is in every build: its Rust library is
# built here from vendor/moq-iroh-src, the moq fork cut down to moq-iroh-c with
# every crate vendored (tools/moq-vendor.sh), with the distribution's own rust
# and cargo and no network. `--without netlab` leaves it out.
%bcond_without netlab

# Two builds of the same source agree: the build time comes from
# SOURCE_DATE_EPOCH and tools/ci/agent-rpm.sh pins _buildhost.
%global source_date_epoch_from_changelog 0
%global use_source_date_epoch_as_buildtime 1
%global clamp_mtime_to_source_date_epoch 1

Name:           ghostty-agent
Version:        0.3.1.13
Release:        1%{?dist}
%if %{with wayland}
Summary:        PTY server and desktop-window compositor for the Ghostty Dalamud plugin
%else
Summary:        PTY server for the Ghostty Dalamud plugin, without the compositor
%endif
# The agent is MIT; it compiles in Monocypher (CC0-1.0 or BSD-2-Clause), lwIP
# (BSD-3-Clause) and Nayuki's QR Code generator (MIT) for its WireGuard.
License:        MIT AND BSD-3-Clause AND (CC0-1.0 OR BSD-2-Clause)
URL:            https://github.com/Spaceghost/ghostty-dalamud
Source0:        %{name}-%{version}-src.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  systemd-rpm-macros
%if %{with netlab}
# moq-iroh-c's rust-version (RUST_MIN_VERSION in toolchain.env)
BuildRequires:  rust >= 1.91
BuildRequires:  cargo
%endif
%if %{with wayland}
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  wayland-protocols-devel
%endif

# No Requires on wlroots, wayland-server, xkbcommon or pixman: elfdeps generates
# those sonames from the binary it just linked, and that soname is exactly what
# keeps the Wayland build off a Fedora whose wlroots is older, with a better
# message than any version range could give. These two are not ELF dependencies
# and must be written out: the agent makes its config directory with
# os.execute('mkdir -p'), defaults a session to /bin/sh, and launches compositor
# apps with execl('/bin/sh', ...).
Requires:       /bin/sh
Requires:       coreutils

# Everything below is a child process the agent looks for on $PATH the first time
# it needs one, and does without politely when it is not there.
Recommends:     wl-clipboard
Recommends:     ffmpeg-free
Suggests:       xclip
Suggests:       tmux
%if %{with wayland}
Recommends:     xorg-x11-server-Xwayland
Recommends:     librsvg2-tools
Recommends:     xdg-utils
Suggests:       ImageMagick
%endif

%description
ghostty-agent hosts terminal sessions for the Ghostty plugin for Dalamud: the
game connects to it over 127.0.0.1 and the shells it opens outlive the game. It
runs as you, not as a system service. On first start it writes a token to
~/.config/ghostty-agent/token and listens on 127.0.0.1:7777.
%if %{with wayland}
This build carries the Wayland compositor backend, which links wlroots 0.20, so
it installs on Fedora 44 and newer. It is what remote desktop windows and the
browser integration need.
%else
This build has no Wayland compositor backend: terminals, jobs and clips work,
remote desktop windows are not in it. It depends on glibc alone.
%endif
%if %{with netlab}
It carries netlab: a window published as Media over QUIC over an iroh
connection, with the Rust library that does it linked in statically.
%endif

%prep
%autosetup -n %{name}-%{version}
# the licences of the vendored C the WireGuard compiles in, under names that do not collide
cp -p vendor/lwip/COPYING lwip-COPYING
cp -p vendor/monocypher/LICENCE.md monocypher-LICENCE.md
cp -p vendor/qrcodegen/LICENSE qrcodegen-LICENSE

%build
%set_build_flags
%if %{with netlab}
# Fedora's rust, offline, from the vendored crates (tools/build-moq-iroh.sh).
# %%set_build_flags' RUSTFLAGS keep full debug info, so it lands in -debuginfo
# with the rest of the agent's.
RUST_SYSTEM=1 JOBS=%{?_smp_build_ncpus} ./tools/build-moq-iroh.sh linux
%endif
# tools/build-agent.sh appends $CFLAGS and $LDFLAGS to the single --cflags that
# Nelua takes, so Fedora's hardening flags reach the generated C. The Nelua
# compiler itself is built without them.
CC=gcc JOBS=%{?_smp_build_ncpus} ./tools/build-agent.sh \
    %{?with_wayland:--wayland}%{!?with_wayland:--no-wayland} \
    %{?with_netlab:--netlab}%{!?with_netlab:--no-netlab} \
    -o build/dist/ghostty-agent
%if %{with wayland}
# A silently degraded package would carry none of the sonames that keep it off an
# older Fedora, so prove the backend really linked.
readelf -d build/dist/ghostty-agent | grep -q 'libwlroots-0.20\.so'
%endif
%if %{with netlab}
# and that netlab did (the binary is not stripped yet)
nm build/dist/ghostty-agent | grep -q ' T moqi_node_new$'
%endif

%install
install -Dpm0755 build/dist/ghostty-agent %{buildroot}%{_bindir}/ghostty-agent
install -Dpm0755 packaging/ghostty-voice %{buildroot}%{_bindir}/ghostty-voice
install -Dpm0644 packaging/ghostty-agent.service %{buildroot}%{_userunitdir}/ghostty-agent.service
install -Dpm0644 packaging/ghostty-agent.1 %{buildroot}%{_mandir}/man1/ghostty-agent.1

%check
# --help needs no network, no X and no game.
%{buildroot}%{_bindir}/ghostty-agent --help >/dev/null
# Then prove the listener and the token really work, without a second test
# suite: a private HOME, a port derived from this build's pid, SIGTERM for a
# clean stop. Note the doubled %% : this is a spec.
export HOME=%{_builddir}/agent-check-home
mkdir -p "$HOME"
port=$((20000 + $$ %% 20000))
%{buildroot}%{_bindir}/ghostty-agent --listen "127.0.0.1:$port" &
agent=$!
for _ in $(seq 1 60); do [ -s "$HOME/.config/ghostty-agent/token" ] && break; sleep 0.1; done
test -s "$HOME/.config/ghostty-agent/token"
test "$(stat -c %%a "$HOME/.config/ghostty-agent/token")" = 600
kill -TERM "$agent"
wait "$agent" || true

%post
%systemd_user_post ghostty-agent.service

%preun
%systemd_user_preun ghostty-agent.service

# No %postun scriptlet on purpose. %systemd_user_postun expands to nothing on
# Fedora 44 (rpmlint's empty-%postun), and the restart variant would kill every
# live terminal on upgrade, which is the one thing the agent exists to prevent.

%files
%license LICENSE lwip-COPYING monocypher-LICENCE.md qrcodegen-LICENSE
%doc README-agent.md
%{_bindir}/ghostty-agent
%{_bindir}/ghostty-voice
%{_userunitdir}/ghostty-agent.service
%{_mandir}/man1/ghostty-agent.1*
