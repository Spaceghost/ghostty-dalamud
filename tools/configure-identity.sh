#!/bin/sh
# Maintainer-only setup. Change this repository, never the global Git identity.
set -eu
git config --local user.name Spaceghost
git config --local user.email 251370+Spaceghost@users.noreply.github.com
git config --local core.hooksPath .githooks
printf '%s\n' 'Repository identity and local pre-commit hook configured.'
