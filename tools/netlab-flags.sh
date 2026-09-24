#!/usr/bin/env bash
# Sourced right after tools/wayland-flags.sh by the scripts that build the agent
# (tools/build.sh, tools/build-agent.sh, tests/run.sh). When vendor/moq-iroh is
# there (tools/fetch-vendor.sh builds it from the pinned moq fork),
# NETLAB_DEFINE is (-D NETLAB) and NETLAB_CFLAGS points the compiler and the
# linker at it; otherwise both are empty and the agent builds without netlab
# (docs/NETLAB.md), answering netlab commands with "netlab not built".
#
# AGENT_NELUA combines the Wayland compositor's and netlab's defines with one
# --cflags holding both, since Nelua keeps only the last --cflags it is given:
# the agent builds that pass no --cflags of their own use it in place of
# WAYLAND_NELUA.
# shellcheck disable=SC2034 # used by the scripts that source this
#
# Sanitizer runs (SAN, tests/run.sh) leave it out: the Rust library and its
# threads are not instrumented, and would be what TSan and valgrind report.
NETLAB_DEFINE=()
NETLAB_CFLAGS=""
if [[ "$(uname -s)" == Linux && "${SKIP_NETLAB:-0}" != 1 && -z "${SAN:-}" &&
      -f "$ROOT/vendor/moq-iroh/libmoq_iroh.a" ]]; then
  NETLAB_DEFINE=(-D NETLAB)
  # the library is a whole Rust program's worth of objects: keep what is used
  NETLAB_CFLAGS="-I\"$ROOT/vendor/moq-iroh\" -L\"$ROOT/vendor/moq-iroh\" -Wl,--gc-sections"
  echo "note: netlab (moq over iroh) from vendor/moq-iroh"
fi
AGENT_NELUA=("${WAYLAND_DEFINE[@]}" "${NETLAB_DEFINE[@]}")
if [[ -n "${WAYLAND_CFLAGS}${NETLAB_CFLAGS}" ]]; then
  AGENT_NELUA+=("--cflags=${WAYLAND_CFLAGS} ${NETLAB_CFLAGS}")
fi
