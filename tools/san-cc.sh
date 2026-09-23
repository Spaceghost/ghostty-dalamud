#!/bin/sh
# C compiler wrapper for sanitizer builds, handed to Nelua as --cc.
# tools/sanitize.sh exports SAN_CC (the compiler) and SAN_CFLAGS (the
# -fsanitize flags); everything else comes from Nelua's own command line.
# Nelua picks its flags by the compiler's name, and this script's name matches
# only its generic "cc" entry, whose shared-library flags are a bare -shared:
# a shared library (-H: the host module, the loader) is made position
# independent here instead, or the link fails on gcc's non-PIC objects.
pic=
for a in "$@"; do
  if [ "$a" = -shared ]; then pic=-fPIC; break; fi
done
# Word splitting of SAN_CFLAGS is deliberate; $pic is one word or none.
# shellcheck disable=SC2086
exec ${SAN_CC:-gcc} ${SAN_CFLAGS} $pic "$@"
