#!/bin/sh
# C compiler wrapper for sanitizer builds, handed to Nelua as --cc.
# tools/sanitize.sh exports SAN_CC (the compiler) and SAN_CFLAGS (the
# -fsanitize flags); everything else comes from Nelua's own command line.
# Word splitting of SAN_CFLAGS is deliberate.
# shellcheck disable=SC2086
exec ${SAN_CC:-gcc} ${SAN_CFLAGS} "$@"
