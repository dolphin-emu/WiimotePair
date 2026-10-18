// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ViewController.h"

#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"

// Pair delegates return either an IOReturn or a Bluetooth HCI status. Passing an
// HCI status to mach_error_string produces unrelated kernel error descriptions.
static NSString* PairingErrorDescription(IOReturn error) {
    switch (error) {
        case kIOReturnSuccess: return @"Success";
        case kBluetoothHCIErrorNoConnection: return @"Bluetooth connection was lost";
        case kBluetoothHCIErrorPageTimeout: return @"Bluetooth device did not respond";
        case kBluetoothHCIErrorAuthenticationFailure: return @"Bluetooth authentication failed";
        case kBluetoothHCIErrorKeyMissing: return @"Bluetooth PIN or link key is missing";
        case kBluetoothHCIErrorConnectionTimeout: return @"Bluetooth connection timed out";
        case kBluetoothHCIErrorHostRejectedSecurityReasons: return @"Bluetooth connection rejected for security reasons";
        case kBluetoothHCIErrorPairingNotAllowed: return @"Bluetooth pairing is not allowed";
        case kBluetoothHCIErrorUnspecifiedError: return @"Unspecified Bluetooth error";
        default:
            if ((uint32_t)error <= 0xff) {
                return [NSString stringWithFormat:@"Bluetooth HCI status 0x%02X", error];
            }
            return [NSString stringWithUTF8String:mach_error_string(error)];
    }
}

// Private API declarations verified against the loaded macOS 26.5 framework.
@interface NSObject (WiiPairingAgentPrivate)
- (id)classicManager;
- (id)sharedPairingAgent;
- (id)identifier;
- (void)pairingAgent:(id)agent peerDidRequestPairing:(id)peer type:(NSInteger)type passkey:(id)passkey;
@end

@protocol WiiClassicPairingAgent <NSObject>
- (id)delegate;
- (void)setDelegate:(id)delegate;
@end

// An app-local delegate proxy: no framework patching, daemon changes, or changes
// to other devices. Restore the original delegate as soon as this attempt ends.
@interface WiimoteLegacyPINDelegate : NSObject
@property (strong) id originalDelegate;
@property (strong) id targetPeer;
@property (copy) void (^report)(NSString*);
@property (atomic) BOOL active;
@end

@implementation WiimoteLegacyPINDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return self.originalDelegate;
}
- (BOOL)replyWithLegacyPINToPeer:(id)peer {
    BluetoothDeviceAddress address = {0};
    NSString* addressString = [IOBluetoothHostController defaultController].addressAsString;
    if (!addressString || IOBluetoothNSStringToDeviceAddress(addressString, &address) != kIOReturnSuccess) {
        return NO;
    }
    uint8_t bytes[8] = {0};
    for (int i = 0; i < 6; i++) bytes[i] = address.data[5 - i];
    uint64_t key = 0;
    memcpy(&key, bytes, 6);
    // In macOS 26.5, type 0 is auto-accepted without a PIN. Type 6 is the
    // legacy binary PIN branch required by the Wii Remote.
    if (self.report) self.report(@"Responding to the Wii Remote with its legacy binary PIN.");
    [[IOBluetoothCoreBluetoothCoordinator sharedInstance] pairPeer:peer forType:6 withKey:@(key)];
    return YES;
}
- (void)pairingAgent:(id)agent peerDidRequestPairing:(id)peer type:(NSInteger)type passkey:(id)passkey {
    BOOL matches = peer == self.targetPeer;
    if (!matches && [peer respondsToSelector:@selector(identifier)] &&
        [self.targetPeer respondsToSelector:@selector(identifier)]) {
        id targetID = [self.targetPeer identifier];
        matches = targetID != nil && [targetID isEqual:[peer identifier]];
    }
    if (self.active && matches) {
        NSString* event = [NSString stringWithFormat:@"Classic pairing agent request: type %ld.", (long)type];
        if (self.report) self.report(event);
        if (type == 0 && [self replyWithLegacyPINToPeer:peer]) {
            return;
        }
    }
    if ([self.originalDelegate respondsToSelector:_cmd]) {
        [self.originalDelegate pairingAgent:agent peerDidRequestPairing:peer type:type passkey:passkey];
    }
}
@end

@implementation ViewController {
    CBCentralManager* _centralManager;
    IOBluetoothDeviceInquiry* _deviceInquiry;
    IOBluetoothDevicePair* _devicePair;
    IOBluetoothDevice* _pendingDevice;
    BOOL _inquiryRunning;
    BOOL _attemptActive;
    BOOL _showingResult;
    BOOL _pinRequested;
    NSMutableArray<NSString*>* _diagnostics;
    id<WiiClassicPairingAgent> _classicPairingAgent;
    IOBluetoothDevicePair* _successfulPair;
    WiimoteLegacyPINDelegate* _legacyPINProxy;
}

- (void)diagnostic:(NSString*)message {
    // Deliberately omit addresses, PIN bytes, and link keys.
    if (_diagnostics == nil) _diagnostics = [NSMutableArray array];
    [_diagnostics addObject:message];
    NSLog(@"[WiimotePair] %@", message);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.progressIndicator startAnimation:self];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (_centralManager == nil) {
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
}

- (void)showAlertWithTitle:(NSString*)title text:(NSString*)text callback:(void (^)(void))callback {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = text;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        callback();
    }];
}

- (void)startInquiryIfIdle {
    if (_centralManager.state != CBManagerStatePoweredOn || _attemptActive ||
        _showingResult || _inquiryRunning || _deviceInquiry == nil) return;
    [_deviceInquiry clearFoundDevices];
    _inquiryRunning = YES;
    IOReturn result = [_deviceInquiry start];
    if (result != kIOReturnSuccess) {
        _inquiryRunning = NO;
        [self diagnostic:[NSString stringWithFormat:@"Inquiry start: 0x%08X (%@)", result, PairingErrorDescription(result)]];
    }
}

- (void)showPairingResultAlertWithTitle:(NSString*)title text:(NSString*)text {
    _showingResult = YES;
    NSString* report = [_diagnostics componentsJoinedByString:@"\n"];
    NSString* fullText = [NSString stringWithFormat:@"%@\n\nDiagnostics:\n%@", text, report ?: @""];
    [self showAlertWithTitle:title text:fullText callback:^{
        self->_showingResult = NO;
        [self startInquiryIfIdle];
    }];
}

- (void)showFatalErrorAlertWithTitle:(NSString*)title text:(NSString*)text {
    _showingResult = YES;
    [self showAlertWithTitle:title text:text callback:^{ [NSApp terminate:self]; }];
}

- (void)centralManagerDidUpdateState:(CBCentralManager*)centralManager {
    switch (centralManager.state) {
        case CBManagerStateUnauthorized:
            [self showFatalErrorAlertWithTitle:@"Bluetooth Permission Denied" text:@"Allow WiimotePair to access Bluetooth in System Settings → Privacy & Security → Bluetooth."];
            break;
        case CBManagerStatePoweredOff:
        case CBManagerStateResetting: {
            [self restorePairingAgent];
            _pendingDevice = nil;
            _successfulPair = nil;
            _attemptActive = NO;
            IOBluetoothDevicePair* pair = _devicePair;
            _devicePair = nil;
            pair.delegate = nil;
            [pair stop];
            [_deviceInquiry stop];
            _inquiryRunning = NO;
            if (centralManager.state == CBManagerStatePoweredOff) {
                [self showFatalErrorAlertWithTitle:@"Bluetooth Unavailable" text:@"Turn Bluetooth on before running WiimotePair."];
            }
            break;
        }
        case CBManagerStateUnsupported:
            [self showFatalErrorAlertWithTitle:@"Bluetooth Unsupported" text:@"This Mac does not provide a supported Bluetooth controller."];
            break;
        case CBManagerStatePoweredOn:
            if (_deviceInquiry == nil) {
                _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
                _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
            }
            [self startInquiryIfIdle];
            break;
        case CBManagerStateUnknown: break; // Initial state; wait for an update.
    }
}

- (void)restorePairingAgent {
    _legacyPINProxy.active = NO;
    if (_classicPairingAgent && [_classicPairingAgent delegate] == _legacyPINProxy) {
        [_classicPairingAgent setDelegate:_legacyPINProxy.originalDelegate];
    }
    _legacyPINProxy = nil;
    _classicPairingAgent = nil;
}

- (void)installLegacyPINDelegateForDevice:(IOBluetoothDevice*)device {
    if (@available(macOS 26.0, *)) {
        // This workaround has been verified for the original Wii Remote only.
        if (![device.name isEqualToString:@"Nintendo RVL-CNT-01"]) return;
        id coordinator = [IOBluetoothCoreBluetoothCoordinator sharedInstance];
        if (![coordinator respondsToSelector:@selector(classicManager)] ||
            ![device respondsToSelector:@selector(classicPeer)]) return;
        id manager = [coordinator classicManager];
        if (![manager respondsToSelector:@selector(sharedPairingAgent)]) return;
        id<WiiClassicPairingAgent> agent = [manager sharedPairingAgent];
        if (![agent respondsToSelector:@selector(delegate)] ||
            ![agent respondsToSelector:@selector(setDelegate:)]) return;
        id original = [agent delegate];
        id peer = [device classicPeer];
        if (!original || !peer) return;
        _classicPairingAgent = agent;
        _legacyPINProxy = [WiimoteLegacyPINDelegate new];
        _legacyPINProxy.originalDelegate = original;
        _legacyPINProxy.targetPeer = peer;
        _legacyPINProxy.active = YES;
        __weak ViewController* weakSelf = self;
        _legacyPINProxy.report = ^(NSString* event) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf diagnostic:event]; });
        };
        [agent setDelegate:_legacyPINProxy];
        [self diagnostic:@"Installed the legacy PIN delegate for this Wii Remote."];
    }
}

- (void)beginPendingPairing {
    IOBluetoothDevice* device = _pendingDevice;
    _pendingDevice = nil;
    if (device == nil || !_attemptActive) return;
    _devicePair = [IOBluetoothDevicePair pairWithDevice:device];
    _devicePair.delegate = self;
    if ([_devicePair respondsToSelector:@selector(setUserDefinedPincode:)]) {
        [_devicePair setUserDefinedPincode:YES];
    }
    [self installLegacyPINDelegateForDevice:device];
    [self diagnostic:@"Inquiry stopped; starting one pairing attempt."];
    IOReturn result = [_devicePair start];
    [self diagnostic:[NSString stringWithFormat:@"Pair start: 0x%08X (%@)", result, PairingErrorDescription(result)]];
    if (result != kIOReturnSuccess && _devicePair != nil) {
        [self devicePairingFinished:_devicePair error:result];
    }
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device {
    // Discovery callbacks can already be queued when stop is called.
    if (_attemptActive || _showingResult) return;
    if (device.name == nil || ![device.name containsString:@"Nintendo RVL-CNT-01"]) {
        [sender clearFoundDevices];
        return;
    }
    if (device.isPaired) return;
    _attemptActive = YES;
    _pinRequested = NO;
    _diagnostics = [NSMutableArray array];
    [self diagnostic:[NSString stringWithFormat:@"macOS %@; device %@; class 0x%06X", NSProcessInfo.processInfo.operatingSystemVersionString, device.name, device.classOfDevice]];
    _pendingDevice = device;
    // Wait for the inquiry completion callback before opening the connection.
    // Keep discovery and pairing from competing for the Bluetooth adapter.
    IOReturn result = [sender stop];
    if (result != kIOReturnSuccess) {
        _pendingDevice = nil;
        _attemptActive = NO;
        [self showPairingResultAlertWithTitle:@"Inquiry Error" text:[NSString stringWithFormat:@"Cannot stop discovery: %@ (0x%08X).", PairingErrorDescription(result), result]];
    }
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry*)sender error:(IOReturn)error aborted:(BOOL)aborted {
    _inquiryRunning = NO;
    if (_pendingDevice != nil) {
        [self beginPendingPairing];
    } else if (!aborted && error == kIOReturnSuccess) {
        [self startInquiryIfIdle];
    }
}

- (void)devicePairingStarted:(id)sender {
    if (sender == _devicePair) [self diagnostic:@"Pairing started."];
}

- (void)devicePairingConnecting:(id)sender {
    if (sender == _devicePair) [self diagnostic:@"Connecting to the remote."];
}

- (void)devicePairingConnected:(id)sender {
    if (sender == _devicePair) [self diagnostic:@"Baseband connection established."];
}

- (void)devicePairingPINCodeRequest:(id)sender {
    if (sender != _devicePair) return;
    _pinRequested = YES;
    [self diagnostic:@"Binary PIN requested."];
    IOBluetoothDevicePair* pair = sender;
    IOBluetoothHostController* controller = [IOBluetoothHostController defaultController];
    BluetoothDeviceAddress address = {0};
    NSString* addressString = controller.addressAsString;
    IOReturn result = addressString ? IOBluetoothNSStringToDeviceAddress(addressString, &address) : kIOReturnNotFound;
    if (result != kIOReturnSuccess) {
        [self devicePairingFinished:sender error:result];
        return;
    }
    BluetoothPINCode code = {0};
    // SYNC mode uses the local adapter address, reversed, as a six-byte PIN.
    for (int i = 0; i < 6; i++) code.data[i] = address.data[5 - i];
    uint64_t key = 0;
    memcpy(&key, code.data, 6);

    if ([pair respondsToSelector:@selector(currentPairingType)] &&
        [pair.device respondsToSelector:@selector(classicPeer)]) {
        [self diagnostic:@"PIN reply through legacy coordinator."];
        [[IOBluetoothCoreBluetoothCoordinator sharedInstance] pairPeer:[pair.device classicPeer] forType:[pair currentPairingType] withKey:@(key)];
    } else {
        [self devicePairingFinished:sender error:kIOReturnUnsupported];
    }
}

- (void)deviceSimplePairingComplete:(id)sender status:(BluetoothHCIEventStatus)status {
    if (sender == _devicePair) {
        [self diagnostic:[NSString stringWithFormat:@"Simple pairing complete: 0x%02X (%@)", status, PairingErrorDescription(status)]];
    }
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    // Ignore stale callbacks and detach before stop to avoid reentrant results.
    if (sender != _devicePair) return;
    [self diagnostic:[NSString stringWithFormat:@"Pair finished: 0x%08X (%@); PIN requested: %@", error, PairingErrorDescription(error), _pinRequested ? @"yes" : @"no"]];
    IOBluetoothDevicePair* pair = _devicePair;
    _devicePair = nil;
    pair.delegate = nil;
    [self restorePairingAgent];
    // Keep a successful pairing alive so macOS can finish the HID handshake.
    if (error != kIOReturnSuccess) [pair stop];
    else _successfulPair = pair;
    _attemptActive = NO;
    if (error != kIOReturnSuccess) {
        NSString* hint = _pinRequested ? @"" : @"\nThe standard macOS callback did not request a PIN. Press the red SYNC button inside the battery compartment when pairing for the first time.";
        [self showPairingResultAlertWithTitle:@"Pairing Error" text:[NSString stringWithFormat:@"%@ (0x%08X).%@", PairingErrorDescription(error), error, hint]];
    } else {
        [self showPairingResultAlertWithTitle:@"Paired" text:@"The Wii Remote has been paired with your Mac. Quit WiimotePair, select Real Wii Remote in Dolphin, and press a normal button on the remote to reconnect."];
    }
}

@end
