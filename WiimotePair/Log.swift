// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import os

/// Unified-logging channel for Bluetooth diagnostics. Watch it live with:
/// `log stream --level debug --predicate 'subsystem == "org.dolphin-emu.WiimotePair"'`
enum Log {
    private static let logger = Logger(subsystem: "org.dolphin-emu.WiimotePair", category: "bluetooth")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func hex(_ bytes: UnsafeRawBufferPointer) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func ioReturn(_ code: IOReturn) -> String {
        String(format: "0x%08x (%@)", UInt32(bitPattern: code),
               String(cString: mach_error_string(code)))
    }
}
