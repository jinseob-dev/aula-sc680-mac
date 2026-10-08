#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TEST_BUILD="$(mktemp -d)"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library \
  macos/SC680Config/HID/*.swift \
  macos/SC680Config/Protocol/*.swift \
  macos/SC680Config/Models/*.swift \
  macos/tests/RegressionTests.swift \
  -o "$TEST_BUILD/regression-tests"
"$TEST_BUILD/regression-tests"
