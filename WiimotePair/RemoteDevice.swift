// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of a paired (or pairing) Wii Remote's state, as shown in the UI.
struct RemoteDevice: Identifiable, Equatable {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// Whether live HID status (battery, LEDs) can be read from the remote.
    enum StatusAvailability: Equatable {
        case loading
        case available
        case unavailable
    }

    /// Canonical address ("AA:BB:CC:DD:EE:FF"), used as the stable identity.
    let id: String
    var name: String
    var connection: Connection
    var statusAvailability: StatusAvailability
    /// 0...100, nil when unknown or not connected.
    var batteryPercent: Int?
    var batteryLow: Bool
    /// Player LED bitmask, bit 0 = LED 1 ... bit 3 = LED 4.
    var ledMask: Int
    var extensionConnected: Bool

    var isConnected: Bool { connection == .connected }

    /// Index (0-3) of the first lit player LED, if any.
    var playerIndex: Int? {
        for i in 0..<4 where (ledMask & (1 << i)) != 0 {
            return i
        }
        return nil
    }
}

/// Last-known live status reported by a remote over HID.
struct RemoteStatus: Equatable {
    var batteryPercent: Int
    var batteryLow: Bool
    var ledMask: Int
    var extensionConnected: Bool
}
