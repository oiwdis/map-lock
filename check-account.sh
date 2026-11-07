#!/bin/bash
# Checks username rules, seeded race order, and stats merge. No AppKit.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/account"
swiftc -O -o "$out" \
  Sources/MapLock/Countries.swift \
  Sources/MapLock/Settings.swift \
  Sources/MapLock/AccountName.swift \
  Sources/MapLock/Speedrun.swift \
  Sources/MapLock/Stats.swift \
  Checks/account/main.swift
"$out" "$@"
