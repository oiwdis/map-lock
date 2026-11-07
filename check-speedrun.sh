#!/bin/bash
# Checks speedrun order, clicks, the clock, and saved bests (no AppKit needed).
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/speedrun"
swiftc -O -o "$out" \
  Sources/MapLock/Countries.swift \
  Sources/MapLock/Settings.swift \
  Sources/MapLock/Speedrun.swift \
  Sources/MapLock/Stats.swift \
  Checks/speedrun/main.swift
"$out" "$@"
