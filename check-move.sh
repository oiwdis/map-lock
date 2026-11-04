#!/bin/bash
# Checks the "Move to Applications" path logic in Sources/MapLock/AppLocation.swift.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/move"
swiftc -O -o "$out" Sources/MapLock/AppLocation.swift Checks/move/main.swift
"$out" "$@"
