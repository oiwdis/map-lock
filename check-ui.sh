#!/bin/bash
# Capture real native views on macOS without launching lock behavior or reading credentials.
set -euo pipefail
cd "$(dirname "$0")"
output="${1:-/tmp/map-lock-ui}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
sources=()
for source in Sources/MapLock/*.swift; do
  case "$source" in
    */MapLockApp.swift|*/AppDelegate.swift|*/KeychainStore.swift) ;;
    *) sources+=("$source") ;;
  esac
done
swiftc -parse-as-library -o "$build/preview" "${sources[@]}" Checks/ui/main.swift
"$build/preview" "$output" Sources/MapLock/Resources/countries.geojson
