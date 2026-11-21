// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = BluetoothManager()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(manager: manager)

            Group {
                if let session = manager.session {
                    PairingSessionView(
                        session: session,
                        onCancel: { manager.cancelPairing() },
                        onRetry: { manager.dismissSession(); manager.startPairing() },
                        onDone: { manager.dismissSession() })
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if manager.remotes.isEmpty {
                    EmptyStateView()
                        .transition(.opacity)
                } else {
                    RemoteListView(manager: manager)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FooterView(manager: manager)
        }
        .animation(.easeInOut(duration: 0.25), value: manager.session)
        .animation(.easeInOut(duration: 0.25), value: manager.remotes.isEmpty)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Couldn't forget \(manager.forgetFailedName ?? "remote")",
               isPresented: Binding(get: { manager.forgetFailedName != nil },
                                    set: { if !$0 { manager.forgetFailedName = nil } })) {
            Button("Open Bluetooth Settings") {
                manager.openBluetoothSettings()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("macOS still lists it as paired. Remove it from Bluetooth settings instead.")
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var manager: BluetoothManager

    var body: some View {
        HStack(spacing: 12) {
            WiiRemoteIcon(tint: .accentColor)
                .frame(height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text("WiimotePair")
                    .font(.system(.title2, design: .rounded).bold())
                Text("Wii Remote pairing for macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            bluetoothPill
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var bluetoothPill: some View {
        if let problem = manager.bluetoothProblem {
            Button(action: { manager.openBluetoothSettings() }) {
                pill(
                    color: problem == .poweredOff ? .red : .orange,
                    text: problem == .poweredOff ? "Bluetooth Off" : "No Permission",
                    showChevron: true)
            }
            .buttonStyle(.plain)
            .help(problem == .poweredOff
                  ? "Bluetooth is turned off. Open Bluetooth settings."
                  : "WiimotePair needs Bluetooth permission. Open Privacy settings.")
        } else if manager.bluetoothReady {
            pill(color: .green, text: "Bluetooth On", showChevron: false)
        } else {
            pill(color: .gray, text: "Bluetooth…", showChevron: false)
        }
    }

    private func pill(color: Color, text: String, showChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Pairing session

private struct PairingSessionView: View {
    let session: BluetoothManager.PairingSession
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDone: () -> Void

    private static let steps = ["Searching for remotes", "Pairing", "Connecting"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            hero
                .frame(width: 120, height: 120)
                .padding(.bottom, 24)

            switch session {
            case .searching, .pairing, .connecting:
                stepList
            case .success(let name, let connected):
                VStack(spacing: 6) {
                    Text("Paired!")
                        .font(.system(.title3, design: .rounded).bold())
                    Text(connected
                         ? "\(name) is connected and ready."
                         : "\(name) is paired. Press any button on it to connect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("Pairing didn't work")
                        .font(.system(.title3, design: .rounded).bold())
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    HStack(spacing: 12) {
                        Button("Dismiss", action: onDone)
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 6)
                }
            }

            Spacer()

            if session.isInFlight {
                Button("Cancel", action: onCancel)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var hero: some View {
        switch session {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.orange)
                .transition(.scale.combined(with: .opacity))
        default:
            RadarView()
        }
    }

    private var currentStep: Int {
        switch session {
        case .searching: return 0
        case .pairing: return 1
        case .connecting: return 2
        case .success: return Self.steps.count
        case .failed: return -1
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 10) {
                    stepIcon(for: index)
                        .frame(width: 18, height: 18)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(index <= currentStep ? .primary : .tertiary)
                }
            }
            if case .pairing(let name) = session {
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            if case .connecting = session {
                Text("Not connecting? Press any button on the remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder private func stepIcon(for index: Int) -> some View {
        if index < currentStep {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if index == currentStep {
            ProgressView()
                .controlSize(.small)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
        }
    }
}

/// Concentric pulsing circles shown while searching.
private struct RadarView: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                    .scaleEffect(animating ? 1 : 0.15)
                    .opacity(animating ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.8)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.6),
                        value: animating)
            }
            WiiRemoteIcon(tint: .accentColor)
                .frame(height: 64)
        }
        .onAppear { animating = true }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            WiiRemoteIcon(tint: Color.secondary.opacity(0.6))
                .frame(height: 110)
                .padding(.bottom, 16)

            Text("No Wii Remotes yet")
                .font(.system(.title3, design: .rounded).bold())
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Click “Pair New Remote” below")
                step(2, "Press the red SYNC button inside the remote’s battery cover")
                step(3, "Release when paired — the remote connects automatically")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 22, height: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 270, alignment: .leading)
        }
    }
}

// MARK: - Remote list

private struct RemoteListView: View {
    @ObservedObject var manager: BluetoothManager

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(manager.remotes) { remote in
                    DeviceCardView(remote: remote, manager: manager)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

private struct DeviceCardView: View {
    let remote: RemoteDevice
    @ObservedObject var manager: BluetoothManager
    @State private var confirmingForget = false

    private var tint: Color { playerColor(remote.playerIndex) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                WiiRemoteIcon(tint: remote.isConnected ? tint : Color.secondary.opacity(0.5),
                              litLEDs: remote.isConnected ? remote.ledMask : 0)
                    .frame(height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(remote.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusPill

                Menu {
                    Button("Forget This Remote…", role: .destructive) {
                        confirmingForget = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
            }

            if remote.isConnected {
                connectedControls
            } else {
                disconnectedControls
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(remote.isConnected ? 0.35 : 0.12), lineWidth: 1))
        .confirmationDialog("Forget \(remote.name)?",
                            isPresented: $confirmingForget) {
            Button("Forget Remote", role: .destructive) {
                manager.forget(remote)
            }
        } message: {
            Text("It will be disconnected and removed from your Mac's Bluetooth devices. "
                 + "You'll need to pair it again to use it.")
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch remote.connection {
        case .connected: ("Connected", .green)
        case .connecting: ("Connecting…", .accentColor)
        case .disconnected: ("Paired", .secondary)
        }
        return HStack(spacing: 5) {
            if remote.connection == .connecting {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }

    private var statusReady: Bool { remote.statusAvailability == .available }

    private var connectedControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                liveStatus

                Spacer()

                if remote.extensionConnected {
                    Label("Extension", systemImage: "cable.connector")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if statusReady {
                    ledPicker
                }
            }

            HStack {
                Text(statusReady ? playerLabel : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rumble") { manager.rumbleTest(remote) }
                    .controlSize(.small)
                    .disabled(!statusReady)
                Button("Disconnect") { manager.disconnect(remote) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var liveStatus: some View {
        switch remote.statusAvailability {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading remote status…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .available:
            BatteryView(percent: remote.batteryPercent, low: remote.batteryLow)
            Button(action: { manager.requestBattery(remote) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh battery level")
        case .unavailable:
            Label("Status unavailable", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Couldn't read battery and LED status from this remote. "
                      + "Try disconnecting and reconnecting it.")
        }
    }

    private var disconnectedControls: some View {
        HStack {
            Text(remote.connection == .connecting
                 ? "Waiting for the remote to answer…"
                 : "Press any button on the remote, or")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { manager.connect(remote) }) {
                if remote.connection == .connecting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Connecting")
                    }
                } else {
                    Text("Connect")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(remote.connection == .connecting)
        }
    }

    private var playerLabel: String {
        if let index = remote.playerIndex {
            "Player \(index + 1)"
        } else {
            "Player LEDs off"
        }
    }

    private var ledPicker: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                let lit = (remote.ledMask & (1 << i)) != 0
                Circle()
                    .fill(lit ? playerColor(i) : Color.secondary.opacity(0.2))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    .onTapGesture { manager.setPlayer(remote, led: i) }
                    .help("Set as Player \(i + 1)")
            }
        }
    }
}

// MARK: - Battery gauge

private struct BatteryView: View {
    let percent: Int?
    let low: Bool

    private var fillColor: Color {
        if low || (percent ?? 100) <= 20 { return .red }
        if (percent ?? 100) <= 50 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: 40, height: 12)
                if let percent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fillColor)
                        .frame(width: max(3, 38 * CGFloat(percent) / 100), height: 9)
                        .padding(.leading, 1.5)
                }
            }
            Text(percent.map { "\($0)%" } ?? "——")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .help("Battery level")
    }
}

// MARK: - Footer

private struct FooterView: View {
    @ObservedObject var manager: BluetoothManager

    private var autoConnectBinding: Binding<Bool> {
        Binding(get: { manager.autoConnect }, set: { manager.autoConnect = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Toggle("Auto-connect", isOn: autoConnectBinding)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Automatically connect to bonded remotes when WiimotePair opens")

                Spacer()

                if manager.session == nil {
                    Button(action: { manager.startPairing() }) {
                        Label("Pair New Remote", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!manager.bluetoothReady)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

// MARK: - Player colors

/// Wii player colors: P1 blue, P2 red, P3 green, P4 yellow.
func playerColor(_ index: Int?) -> Color {
    switch index {
    case 0: return Color(red: 0.20, green: 0.55, blue: 1.00)
    case 1: return Color(red: 1.00, green: 0.28, blue: 0.28)
    case 2: return Color(red: 0.22, green: 0.78, blue: 0.35)
    case 3: return Color(red: 1.00, green: 0.80, blue: 0.15)
    default: return .accentColor
    }
}
