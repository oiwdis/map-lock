#!/bin/bash
# Checks StatsStore records, breakdowns, and snapshot (no AppKit needed).
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/stats"
swiftc -O -o "$out" \
  Sources/MapLock/Countries.swift \
  Sources/MapLock/Settings.swift \
  Sources/MapLock/Stats.swift \
  Checks/stats/main.swift
"$out" "$@"
