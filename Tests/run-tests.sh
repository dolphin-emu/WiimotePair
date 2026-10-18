#!/bin/sh
# Copyright 2026 Dolphin Emulator Project
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -framework Cocoa -framework CoreBluetooth -framework IOBluetooth \
    LegacyPINDelegateTests.m -o "$test_dir/LegacyPINDelegateTests"
"$test_dir/LegacyPINDelegateTests"
