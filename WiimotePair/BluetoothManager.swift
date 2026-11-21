// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Owns all Bluetooth state for the app: the pairing session, the list of known
/// Wii Remotes, live connection monitoring, and (optionally) auto-connecting
/// bonded remotes. Everything runs on the main thread, which is also where
/// IOBluetooth delivers its delegate callbacks.
final class BluetoothManager: NSObject, ObservableObject {
    /// Progress of an explicit pairing session, shown as the pairing UI.
    enum PairingSession: Equatable {
        case searching
        case pairing(name: String)
        case connecting(name: String)
        case success(name: String, connected: Bool)
        case failed(message: String)

        var isInFlight: Bool {
            switch self {
            case .searching, .pairing, .connecting: return true
            case .success, .failed: return false
            }
        }
    }

    enum BluetoothProblem {
        case poweredOff
        case unauthorized
    }

    @Published private(set) var bluetoothReady = false
    @Published private(set) var bluetoothProblem: BluetoothProblem?
    @Published private(set) var remotes: [RemoteDevice] = []
    @Published var session: PairingSession?
    /// Set when macOS still lists a remote as paired after "Forget".
    @Published var forgetFailedName: String?
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }

    private static let autoConnectKey = "autoConnect"
    private static let maxPairAttempts = 3
    private static let sessionTimeout: TimeInterval = 45
    private static let batteryPollInterval: TimeInterval = 30
    private static let hidSetupTimeout: TimeInterval = 8
    private static let maxHIDRetries = 2
    private static let pairConnectTimeout: TimeInterval = 30

    private var central: CBCentralManager?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pair: IOBluetoothDevicePair?
    private var pairAttempts = 0
    /// Whether the current attempt got as far as exchanging the PIN.
    private var pinRequested = false

    private var devicesByAddress: [String: IOBluetoothDevice] = [:]
    private var statusByAddress: [String: RemoteStatus] = [:]
    private enum HIDState {
        case opening
        case ready
        case unavailable
    }

    private let hid = WiimoteHID()
    private var hidStateByAddress: [String: HIDState] = [:]
    private var hidTimeouts: [String: Timer] = [:]
    private var hidRetryAttempts: [String: Int] = [:]
    private var lastStatusRequest: [String: Date] = [:]
    /// Remotes with an outstanding async `openConnection(_:)`.
    private var connectingAddresses: Set<String> = []
    /// The just-paired remote whose connection result finishes the pairing session.
    private var pendingPairAddress: String?
    /// Remotes being unpaired; ignored by connect notifications until done.
    private var forgettingAddresses: Set<String> = []
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    private var sessionTimer: Timer?
    private var successDismissTimer: Timer?
    private var pairConnectTimer: Timer?
    private var batteryPollTimer: Timer?

    override init() {
        autoConnect = UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        setUpHID()
        registerForConnectNotifications()
        Log.info("BluetoothManager started")
    }

    // MARK: - Public API

    /// Begin an explicit pairing session ("Pair New Remote" button).
    func startPairing() {
        guard bluetoothReady, session?.isInFlight != true else { return }
        pairAttempts = 0
        session = .searching
        beginInquiry()
        scheduleSessionTimeout()
    }

    func cancelPairing() {
        stopInquiry()
        pair?.stop()
        pair = nil
        pendingPairAddress = nil
        pairConnectTimer?.invalidate()
        sessionTimer?.invalidate()
        session = nil
    }

    /// Dismiss a finished (success or failed) session card.
    func dismissSession() {
        if session?.isInFlight == false {
            session = nil
        }
    }

    func connect(_ remote: RemoteDevice) {
        guard let device = devicesByAddress[remote.id] else { return }
        hidRetryAttempts[remote.id] = nil
        connectAsync(device)
    }

    func disconnect(_ remote: RemoteDevice) {
        guard let device = devicesByAddress[remote.id], device.isConnected() else { return }
        hidRetryAttempts[remote.id] = nil
        detachHID(key: remote.id)
        device.closeConnection()
        rebuildList()
    }

    /// Unpairs the remote from macOS entirely, so it can be paired from scratch.
    func forget(_ remote: RemoteDevice) {
        guard let device = devicesByAddress[remote.id] else { return }
        let key = remote.id

        detachHID(key: key)
        if device.isConnected() {
            device.closeConnection()
        }
        disconnectNotifications.removeValue(forKey: key)?.unregister()
        connectingAddresses.remove(key)
        statusByAddress[key] = nil
        hidRetryAttempts[key] = nil
        devicesByAddress[key] = nil
        forgettingAddresses.insert(key)
        Log.info("[\(key)] forgetting")
        device.remove()
        rebuildList()
        verifyForgotten(key: key, name: remote.name, attemptsLeft: 16)
    }

    /// bluetoothd defers unpairing until the link is fully down (~3-4 s
    /// observed), so poll instead of checking once.
    private func verifyForgotten(key: String, name: String, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let stillPaired = paired.contains { Self.key(for: $0) == key && $0.isPaired() }
            if !stillPaired {
                Log.info("[\(key)] forgotten")
                self.forgettingAddresses.remove(key)
                return
            }
            if attemptsLeft > 0 {
                self.verifyForgotten(key: key, name: name, attemptsLeft: attemptsLeft - 1)
                return
            }
            Log.error("[\(key)] still paired 8s after forget")
            self.forgettingAddresses.remove(key)
            self.forgetFailedName = name
            self.refreshKnownRemotes()
        }
    }

    /// Assign a remote its player LED (0…3) and update the UI optimistically.
    func setPlayer(_ remote: RemoteDevice, led: Int) {
        let mask = 1 << led
        hid.setLEDs(remote.id, mask: mask)
        if var status = statusByAddress[remote.id] {
            status.ledMask = mask
            statusByAddress[remote.id] = status
        } else {
            statusByAddress[remote.id] = RemoteStatus(batteryPercent: remote.batteryPercent ?? 0,
                                                      batteryLow: remote.batteryLow,
                                                      ledMask: mask,
                                                      extensionConnected: remote.extensionConnected)
        }
        rebuildList()
    }

    func requestBattery(_ remote: RemoteDevice) {
        hid.requestStatus(remote.id)
    }

    /// Brief rumble pulse as a connection sanity check.
    func rumbleTest(_ remote: RemoteDevice) {
        let key = remote.id
        hid.setRumble(key, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.hid.setRumble(key, false)
        }
    }

    func openBluetoothSettings() {
        let urlString: String
        if bluetoothProblem == .unauthorized {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        } else {
            urlString = "x-apple.systempreferences:com.apple.Bluetooth"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Device bookkeeping

    static func isWiiRemote(_ device: IOBluetoothDevice) -> Bool {
        // Matches RVL-CNT-01, -TR (Wii Remote Plus) and -UC (Wii U bundle).
        (device.name ?? "").contains("Nintendo RVL-CNT-01")
    }

    private static func key(for device: IOBluetoothDevice) -> String {
        (device.addressString ?? "unknown")
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    /// Re-scan the bonded device list, then (optionally) nudge every bonded
    /// remote that isn't connected into connecting.
    private func refreshKnownRemotes() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        Log.info("pairedDevices: \(paired.count) total")
        for device in paired {
            Log.info("  paired: name=\(device.name ?? "nil") addr=\(device.addressString ?? "?") "
                     + "cod=0x\(String(device.classOfDevice, radix: 16)) "
                     + "connected=\(device.isConnected()) wii=\(Self.isWiiRemote(device))")
        }
        for device in paired where Self.isWiiRemote(device) {
            Log.info("[\(Self.key(for: device))] bonded remote \(device.name ?? "?"), "
                     + "isConnected=\(device.isConnected())")
            devicesByAddress[Self.key(for: device)] = device
            installNotifications(for: device)
        }
        rebuildList()

        for device in paired where Self.isWiiRemote(device) {
            if device.isConnected() {
                attachHID(to: device)
            } else if autoConnect {
                connectAsync(device)
            }
        }
        rebuildList()
    }

    /// Starts a baseband connection without blocking; the result arrives in
    /// `connectionComplete(_:status:)`. Remotes that are switched off take a
    /// full page timeout (~5 s) to fail, which is why this must never be sync.
    private func connectAsync(_ device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        guard !device.isConnected(), !connectingAddresses.contains(key) else { return }
        let result = device.openConnection(self)
        Log.info("[\(key)] openConnection(async) → \(Log.ioReturn(result))")
        if result == kIOReturnSuccess {
            connectingAddresses.insert(key)
        }
        rebuildList()
    }

    @objc(connectionComplete:status:)
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device else { return }
        let key = Self.key(for: device)
        connectingAddresses.remove(key)

        let connected = status == kIOReturnSuccess && device.isConnected()
        Log.info("[\(key)] connectionComplete: \(Log.ioReturn(status)), isConnected=\(device.isConnected())")
        if connected {
            attachHID(to: device)
        } else {
            retryPendingPairConnection(device)
        }
        rebuildList()
    }

    /// One registration covers connect notifications for every device; the
    /// specific remote is delivered as the selector's second argument.
    /// Registering synchronously invokes the selector for every device that is
    /// already connected, so this must never be reached from that callback.
    private func registerForConnectNotifications() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(remoteConnected(_:device:)))
    }

    private func installNotifications(for device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(
                forDisconnectNotification: self,
                selector: #selector(remoteDisconnected(_:device:)))
        }
    }

    @objc private func remoteConnected(_ notification: IOBluetoothUserNotification,
                                       device: IOBluetoothDevice) {
        guard Self.isWiiRemote(device) else { return }
        let key = Self.key(for: device)
        Log.info("[\(key)] connect notification (\(device.name ?? "?")), paired=\(device.isPaired())")
        // An unpaired remote connecting (e.g. right after Forget) never gets the
        // HID profile, so it isn't usable; only track it mid-pairing.
        guard !forgettingAddresses.contains(key),
              device.isPaired() || key == pendingPairAddress else { return }
        devicesByAddress[key] = device
        connectingAddresses.remove(key)
        installNotifications(for: device)
        attachHID(to: device)
        rebuildList()
    }

    @objc private func remoteDisconnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        Log.info("[\(Self.key(for: device))] disconnect notification")
        detachHID(key: Self.key(for: device))
        retryPendingPairConnection(device)
        rebuildList()
    }

    private func detachHID(key: String) {
        hidTimeouts.removeValue(forKey: key)?.invalidate()
        hidStateByAddress[key] = nil
    }

    /// Called once the baseband link is up. macOS publishes the remote's HID
    /// device shortly after; status is read as soon as it appears.
    private func attachHID(to device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        if hidStateByAddress[key] == nil {
            hidStateByAddress[key] = .opening
        }
        if hid.hasDevice(key) {
            requestStatus(key)
        }
        guard statusByAddress[key] == nil || hidStateByAddress[key] != .ready else { return }
        hidTimeouts[key]?.invalidate()
        hidTimeouts[key] = Timer.scheduledTimer(withTimeInterval: Self.hidSetupTimeout,
                                                repeats: false) { [weak self] _ in
            self?.hidSetupTimedOut(key: key)
        }
    }

    /// Sometimes bluetoothd brings up the baseband link but never starts its
    /// HID profile, so no HID device appears. Dropping and re-establishing the
    /// link reliably fixes that, so do it automatically a couple of times.
    private func hidSetupTimedOut(key: String) {
        guard hidStateByAddress[key] == .opening,
              let device = devicesByAddress[key], device.isConnected() else { return }
        let attempt = hidRetryAttempts[key, default: 0]
        let hasDevice = hid.hasDevice(key)
        Log.error("[\(key)] no status report within \(Int(Self.hidSetupTimeout))s "
                  + "(HID device present: \(hasDevice), retry \(attempt)/\(Self.maxHIDRetries))")

        guard attempt < Self.maxHIDRetries else {
            hidRetryAttempts[key] = nil
            hidStateByAddress[key] = .unavailable
            rebuildList()
            return
        }
        hidRetryAttempts[key] = attempt + 1

        if hasDevice {
            attachHID(to: device)
        } else {
            Log.info("[\(key)] no HID device; reconnecting")
            device.closeConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.devicesByAddress[key] === device else { return }
                self.connectAsync(device)
            }
        }
    }

    /// Several connect callbacks fire together; send one status request for them.
    private func requestStatus(_ key: String) {
        let now = Date()
        if let last = lastStatusRequest[key], now.timeIntervalSince(last) < 0.5 { return }
        lastStatusRequest[key] = now
        hid.requestStatus(key)
    }

    /// Lights the lowest player LED not already used by another connected remote.
    private func assignDefaultPlayer(_ key: String) {
        let taken = Set(remotes.filter { $0.id != key && $0.isConnected }.compactMap(\.playerIndex))
        guard let led = (0..<4).first(where: { !taken.contains($0) }) else { return }
        Log.info("[\(key)] assigning player \(led + 1)")
        hid.setLEDs(key, mask: 1 << led)
        statusByAddress[key]?.ledMask = 1 << led
    }

    private func setUpHID() {
        hid.onDeviceAdded = { [weak self] key in
            guard let self else { return }
            if self.hidStateByAddress[key] == nil {
                self.hidStateByAddress[key] = .opening
            }
            self.requestStatus(key)
            self.rebuildList()
        }
        hid.onDeviceRemoved = { [weak self] key in
            self?.detachHID(key: key)
            self?.rebuildList()
        }
        hid.onStatus = { [weak self] key, status in
            guard let self else { return }
            self.hidTimeouts.removeValue(forKey: key)?.invalidate()
            self.hidRetryAttempts[key] = nil
            self.statusByAddress[key] = status
            self.hidStateByAddress[key] = .ready
            if key == self.pendingPairAddress, let device = self.devicesByAddress[key] {
                self.finishPairingSession(device: device, connected: true)
            }
            // A freshly connected remote has all player LEDs off.
            if status.ledMask == 0 {
                self.assignDefaultPlayer(key)
            }
            self.rebuildList()
        }
        hid.start()
    }

    private func rebuildList() {
        remotes = devicesByAddress.values
            .filter { Self.isWiiRemote($0) && ($0.isPaired() || Self.key(for: $0) == pendingPairAddress) }
            .map { device in
                let key = Self.key(for: device)
                let status = statusByAddress[key]
                let connected = device.isConnected()
                let connection: RemoteDevice.Connection =
                    connected ? .connected
                    : connectingAddresses.contains(key) ? .connecting
                    : .disconnected
                let availability: RemoteDevice.StatusAvailability
                switch hidStateByAddress[key] {
                case .unavailable:
                    availability = .unavailable
                case .ready where status != nil:
                    availability = .available
                default:
                    availability = .loading
                }
                return RemoteDevice(
                    id: key,
                    name: device.name ?? "Wii Remote",
                    connection: connection,
                    statusAvailability: availability,
                    batteryPercent: connected ? status?.batteryPercent : nil,
                    batteryLow: status?.batteryLow ?? false,
                    ledMask: status?.ledMask ?? 0,
                    extensionConnected: connected && (status?.extensionConnected ?? false))
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Pairing session internals

    private func beginInquiry() {
        if inquiry == nil {
            inquiry = IOBluetoothDeviceInquiry(delegate: self)
            // kIOBluetoothDeviceSearchClassic — classic BR/EDR inquiry only.
            inquiry?.searchType = 1
            inquiry?.inquiryLength = 8
        }
        inquiry?.clearFoundDevices()
        inquiry?.stop()
        inquiry?.start()
    }

    private func stopInquiry() {
        inquiry?.stop()
    }

    private func scheduleSessionTimeout() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionTimeout,
                                            repeats: false) { [weak self] _ in
            guard let self, self.session?.isInFlight == true else { return }
            Log.error("pairing session timed out after \(Int(Self.sessionTimeout))s")
            self.stopInquiry()
            self.pair?.stop()
            self.pair = nil
            self.session = .failed(message: "No Wii Remote answered. Press the red SYNC button "
                                   + "inside the battery cover and try again.")
        }
    }

    /// `retry: false` for authentication rejections: each further attempt
    /// lengthens the remote's lockout of this Mac (Bluetooth "repeated attempts").
    private func pairingFailed(_ message: String, retry: Bool = true) {
        pairAttempts += 1
        Log.error("pairing attempt \(pairAttempts)/\(Self.maxPairAttempts) failed: \(message)")
        guard retry, pairAttempts < Self.maxPairAttempts else {
            stopInquiry()
            sessionTimer?.invalidate()
            session = .failed(message: retry
                              ? message + " (gave up after \(Self.maxPairAttempts) attempts)"
                              : message)
            return
        }
        // Back off briefly, then re-run discovery for another attempt.
        session = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.session?.isInFlight == true else { return }
            self.beginInquiry()
        }
    }

    private func pairingSucceeded(device: IOBluetoothDevice) {
        sessionTimer?.invalidate()
        session = .connecting(name: device.name ?? "Wii Remote")

        let key = Self.key(for: device)
        Log.info("[\(key)] paired; waiting for HID connection")
        devicesByAddress[key] = device
        installNotifications(for: device)
        pendingPairAddress = key

        // bluetoothd's first HID Host attempt races the pairing itself and often
        // fails, dropping the link ~200 ms later. Only call it done once the
        // remote has actually answered a status request.
        pairConnectTimer?.invalidate()
        pairConnectTimer = Timer.scheduledTimer(withTimeInterval: Self.pairConnectTimeout,
                                                repeats: false) { [weak self] _ in
            guard let self, self.pendingPairAddress == key else { return }
            Log.error("[\(key)] not connected \(Int(Self.pairConnectTimeout))s after pairing")
            self.finishPairingSession(device: device, connected: false)
        }

        if device.isConnected() {
            attachHID(to: device)
        } else {
            connectAsync(device)
        }
        rebuildList()
    }

    /// While a just-paired remote is still awake, keep trying to bring it up.
    private func retryPendingPairConnection(_ device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        guard key == pendingPairAddress, pairConnectTimer?.isValid == true else { return }
        Log.info("[\(key)] link dropped after pairing; reconnecting")
        connectAsync(device)
    }

    private func finishPairingSession(device: IOBluetoothDevice, connected: Bool) {
        pendingPairAddress = nil
        pairConnectTimer?.invalidate()
        guard case .connecting? = session else { return }
        session = .success(name: device.name ?? "Wii Remote", connected: connected)
        successDismissTimer?.invalidate()
        successDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0,
                                                   repeats: false) { [weak self] _ in
            self?.dismissSession()
        }
    }

    private func machDescription(_ error: IOReturn) -> String {
        String(cString: mach_error_string(error))
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.info("CBCentralManager state: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            bluetoothReady = true
            bluetoothProblem = nil
            refreshKnownRemotes()
            startBatteryPolling()
        case .poweredOff:
            bluetoothReady = false
            bluetoothProblem = .poweredOff
            tearDownBluetoothState()
        case .unauthorized:
            bluetoothReady = false
            bluetoothProblem = .unauthorized
            tearDownBluetoothState()
        default:
            bluetoothReady = false
            bluetoothProblem = nil
        }
    }

    private func tearDownBluetoothState() {
        cancelPairing()
        hidTimeouts.values.forEach { $0.invalidate() }
        hidTimeouts.removeAll()
        hidStateByAddress.removeAll()
        connectingAddresses.removeAll()
        batteryPollTimer?.invalidate()
        batteryPollTimer = nil
        rebuildList()
    }

    private func startBatteryPolling() {
        guard batteryPollTimer == nil else { return }
        batteryPollTimer = Timer.scheduledTimer(withTimeInterval: Self.batteryPollInterval,
                                                repeats: true) { [weak self] _ in
            // Only while the app is in front: status requests also reset rumble,
            // which would interfere with a game running in the background.
            guard let self, NSApp.isActive else { return }
            for remote in self.remotes where remote.isConnected {
                self.hid.requestStatus(remote.id)
            }
        }
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate

extension BluetoothManager: IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        guard Self.isWiiRemote(device) else {
            // Clear devices to enable rediscovery if the name changes.
            sender.clearFoundDevices()
            return
        }

        // Already bonded remotes can connect on their own; nothing to pair.
        if device.isPaired() {
            devicesByAddress[Self.key(for: device)] = device
            installNotifications(for: device)
            rebuildList()
            return
        }

        sender.stop()
        Log.info("[\(Self.key(for: device))] found unpaired remote; starting pairing "
                 + "(attempt \(pairAttempts + 1)/\(Self.maxPairAttempts))")

        session = .pairing(name: device.name ?? "Wii Remote")

        guard let newPair = IOBluetoothDevicePair(device: device) else {
            pairingFailed("Couldn't create a pairing session for this remote.")
            return
        }
        newPair.delegate = self
        pinRequested = false
        // Force the delegate to always be queried for the PIN (private API).
        newPair.setUserDefinedPincode(true)
        pair = newPair

        let result = newPair.start()
        if result != kIOReturnSuccess {
            pairingFailed("Couldn't start pairing: \(machDescription(result)).")
        }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        // Inquiry rounds are short; keep them rolling while we're still searching.
        if case .searching? = session, !aborted {
            sender.clearFoundDevices()
            sender.start()
        }
    }
}

// MARK: - IOBluetoothDevicePairDelegate

extension BluetoothManager: IOBluetoothDevicePairDelegate {
    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair,
              let device = pair.device(),
              let controller = IOBluetoothHostController.default(),
              let addressString = controller.addressAsString() else {
            Log.error("PIN requested but the host controller address is unavailable")
            return
        }
        Log.info("[\(Self.key(for: device))] PIN requested")
        pinRequested = true

        var controllerAddress = BluetoothDeviceAddress()
        IOBluetoothNSStringToDeviceAddress(addressString, &controllerAddress)

        // With the SYNC button, the PIN is the host controller's address, reversed.
        var pinCode = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pinCode) { pinBuffer in
            withUnsafeBytes(of: &controllerAddress) { addressBuffer in
                for i in 0..<6 {
                    pinBuffer[i] = addressBuffer[5 - i]
                }
            }
        }

        // Reply with the raw 6-byte key, skipping replyPINCode:'s NSString round-trip.
        var key: UInt64 = 0
        withUnsafeBytes(of: &pinCode) { buffer in
            if let baseAddress = buffer.baseAddress {
                memcpy(&key, baseAddress, MemoryLayout<UInt64>.size)
            }
        }

        guard let classicPeer = device.classicPeer() else {
            Log.error("[\(Self.key(for: device))] no classic peer to send the PIN to")
            return
        }
        IOBluetoothCoreBluetoothCoordinator.sharedInstance()
            .pairPeer(classicPeer, forType: pair.currentPairingType(), withKey: NSNumber(value: key))
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let finishedPair = sender as? IOBluetoothDevicePair,
              let device = finishedPair.device() else { return }

        pair?.stop()
        pair = nil
        Log.info("[\(Self.key(for: device))] pairing finished: \(Log.ioReturn(error))")

        if error != kIOReturnSuccess {
            // The error is a Bluetooth status, so mach_error_string would be misleading.
            if pinRequested {
                pairingFailed("The remote rejected the PIN. Make sure you press the red SYNC "
                              + "button, then try again.", retry: false)
            } else {
                pairingFailed("The remote refused to pair, usually after earlier failed "
                              + "attempts. Take its batteries out for a few seconds, put them "
                              + "back, then try again.", retry: false)
            }
            return
        }

        pairingSucceeded(device: device)
    }
}
