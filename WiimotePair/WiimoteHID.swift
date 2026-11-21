// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import IOKit.hid

/// Talks to Wii Remotes through the HID devices macOS creates for them.
///
/// Once a paired remote connects, bluetoothd's HID Host profile claims the
/// remote's L2CAP control (0x11) and interrupt (0x13) channels and publishes
/// an IOHIDUserDevice (VID 0x057E, PID 0x0306/0x0330, SerialNumber = address).
/// Opening our own L2CAP channels would conflict with that, so all traffic
/// goes through IOHIDManager instead, opened non-exclusively so games can
/// use the remote at the same time.
///
/// Reports here include the report ID as the first byte, without the
/// Bluetooth HID `a1`/`a2` header (macOS adds/strips it):
/// - Status request: `15 00`
/// - Status report:  `20 BB BB LF 00 00 VV` — `LF` holds battery-low (0x01),
///   extension (0x02) and LED bits (upper nibble); `VV` is battery, max ~0xC8.
final class WiimoteHID {
    private static let vendorID = 0x057E
    /// RVL-CNT-01 and RVL-CNT-01-TR (Wii Remote Plus).
    private static let productIDs = [0x0306, 0x0330]
    private static let reportBufferSize = 64

    /// Called with the remote's address when its HID device appears/disappears.
    var onDeviceAdded: ((String) -> Void)?
    var onDeviceRemoved: ((String) -> Void)?
    var onStatus: ((String, RemoteStatus) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices: [String: IOHIDDevice] = [:]
    private var reportBuffers: [String: UnsafeMutablePointer<UInt8>] = [:]
    /// IOHIDDeviceSetReport is synchronous; keep it off the main thread.
    private let writeQueue = DispatchQueue(label: "org.dolphin-emu.WiimotePair.hid-writes")

    /// Opening the device needs only the sandbox's com.apple.security.device.usb
    /// entitlement; the remote is a game controller, so Input Monitoring isn't required.
    func start() {
        let matching = Self.productIDs.map {
            [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: $0] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<WiimoteHID>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<WiimoteHID>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("IOHIDManagerOpen → \(Log.ioReturn(result))")
    }

    func hasDevice(_ address: String) -> Bool {
        devices[address] != nil
    }

    /// Ask the remote for a 0x20 status report (battery, LEDs, flags).
    func requestStatus(_ address: String) {
        write(address, [0x15, 0x00])
    }

    /// Set the four player LEDs. `mask` bit 0 = LED 1 … bit 3 = LED 4.
    func setLEDs(_ address: String, mask: Int) {
        write(address, [0x11, UInt8((mask & 0x0F) << 4)])
    }

    func setRumble(_ address: String, _ enabled: Bool) {
        write(address, [0x10, enabled ? 0x01 : 0x00])
    }

    // MARK: - Private

    private static func address(of device: IOHIDDevice) -> String? {
        guard let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
              !serial.isEmpty else { return nil }
        return serial.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard let address = Self.address(of: device) else {
            Log.error("HID Wii Remote matched without a serial number; ignoring")
            return
        }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("[\(address)] HID device matched, IOHIDDeviceOpen → \(Log.ioReturn(openResult))")
        guard openResult == kIOReturnSuccess else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
        reportBuffers[address] = buffer
        devices[address] = device

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportBufferSize, {
            context, _, sender, _, _, report, length in
            guard let context, let sender else { return }
            let me = Unmanaged<WiimoteHID>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            me.inputReport(from: device, report: UnsafeBufferPointer(start: report, count: length))
        }, context)

        onDeviceAdded?(address)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let address = devices.first(where: { $0.value === device })?.key else { return }
        Log.info("[\(address)] HID device removed")
        devices[address] = nil
        reportBuffers.removeValue(forKey: address)?.deallocate()
        onDeviceRemoved?(address)
    }

    private func inputReport(from device: IOHIDDevice, report bytes: UnsafeBufferPointer<UInt8>) {
        guard let address = devices.first(where: { $0.value === device })?.key,
              let reportID = bytes.first else { return }

        // Data reports (0x30+) stream continuously while a game is running.
        if reportID < 0x30 {
            Log.info("[\(address)] ← \(Log.hex(UnsafeRawBufferPointer(bytes)))")
        }

        guard reportID == 0x20, bytes.count >= 7 else { return }
        let flags = bytes[3]
        let rawBattery = Int(bytes[6])
        let status = RemoteStatus(
            batteryPercent: min(100, Int((Double(rawBattery) / 200.0 * 100.0).rounded())),
            batteryLow: (flags & 0x01) != 0,
            ledMask: Int(flags >> 4),
            extensionConnected: (flags & 0x02) != 0)
        Log.info("[\(address)] status: battery raw=\(rawBattery) (\(status.batteryPercent)%) "
                 + "low=\(status.batteryLow) ext=\(status.extensionConnected) "
                 + "leds=0b\(String(status.ledMask, radix: 2))")
        onStatus?(address, status)
    }

    private func write(_ address: String, _ bytes: [UInt8]) {
        guard let device = devices[address] else {
            Log.info("[\(address)] write dropped (no HID device): \(Log.hex(bytes))")
            return
        }
        writeQueue.async {
            let result = bytes.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]),
                                     buffer.baseAddress!, buffer.count)
            }
            Log.info("[\(address)] → \(Log.hex(bytes))  SetReport=\(Log.ioReturn(result))")
        }
    }
}
