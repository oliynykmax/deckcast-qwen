#!/bin/sh
# Build deckcast. Requires Odin (dev-2026-10 or later).
set -e
cd "$(dirname "$0")"
odin build src -out:deckcast -o:speed "$@"
