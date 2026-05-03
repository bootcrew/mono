#!/usr/bin/env bash

set -xeuo pipefail

# Pin to a stable upstream release — avoids breaking builds on unreviewed
# commits landing on main.  Bump deliberately when testing a new release.
git clone --depth 1 --branch v1.15.2 "https://github.com/bootc-dev/bootc.git" .

make bin install-all DESTDIR=/output
