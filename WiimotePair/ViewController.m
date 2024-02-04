// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ViewController.h"

#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"

@implementation ViewController {
    CBCentralManager* _centralManager;
    IOBluetoothDeviceInquiry* _deviceInquiry;
    IOBluetoothDevicePair* _devicePair;
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

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
}

- (void)showAlertWithTitle:(NSString*)title text:(NSString*)text callback:(void (^)(void))callback {
    NSAlert* alert = [[NSAlert alloc] init];
    
    [alert setMessageText:title];
    [alert setInformativeText:text];
    [alert addButtonWithTitle:@"OK"];
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        callback();
    }];
}

- (void)showPairingResultAlertWithTitle:(NSString*)title text:(NSString*)text {
    [self showAlertWithTitle:title text:text callback:^{
        if (self->_deviceInquiry == nil) {
            [self->_deviceInquiry start];
        }
    }];
}

- (void)showFatalErrorAlertWithTitle:(NSString*)title text:(NSString*)text {
    [self showAlertWithTitle:title text:text callback:^{
        [NSApp terminate:self];
    }];
}

// CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(nonnull CBCentralManager*)centralManager {
    CBManagerState state = centralManager.state;
    
    if (state == CBManagerStateUnauthorized) {
        [self showFatalErrorAlertWithTitle:@"Bluetooth Permission Denied" text:@"WiimotePair is not allowed to access Bluetooth. Please allow WiimotePair to access Bluetooth in the \"Privacy & Security\" pane within the System Settings app."];
    } else if (state == CBManagerStatePoweredOff) {
        if (_deviceInquiry != nil) {
            [_deviceInquiry stop];
            _deviceInquiry = nil;
        }
        
        if (_devicePair != nil) {
            [_devicePair stop];
            _devicePair = nil;
        }
        
        [self showFatalErrorAlertWithTitle:@"Bluetooth Unavailable" text:@"Please turn Bluetooth on before running WiimotePair."];
    } else if (state == CBManagerStateUnsupported || state == CBManagerStateUnknown) {
        [self showFatalErrorAlertWithTitle:@"Unknown Bluetooth Error" text:@"CBCentralManager is in an invalid state. Relaunch WiimotePair and try again."];
    } else if (state == CBManagerStatePoweredOn) {
        if (_deviceInquiry == nil) {
            _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
            _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
            
            [_deviceInquiry start];
        }
    }
    
    // TODO: handle CBManagerStateResetting?
}

// IOBluetoothDeviceInquiryDelegate

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device {
    // Skip unsupported devices.
    if (![device.name containsString:@"Nintendo RVL-CNT-01"]) {
        return;
    }
    
    // Skip already paired devices.
    if (device.isPaired) {
        return;
    }
    
    [_deviceInquiry stop];
    
    _devicePair = [IOBluetoothDevicePair pairWithDevice:device];
    _devicePair.delegate = self;
    
    // We need to call this private API to ensure that the delegate is always queried for the PIN.
    [_devicePair setUserDefinedPincode:true];
    
    IOReturn pairResult = [_devicePair start];
    if (pairResult != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(pairResult);
        
        [self showPairingResultAlertWithTitle:@"Pairing Error" text:[NSString stringWithFormat:@"An error occurred while starting the pairing process: \"%s\".", pairResultString]];
        
        return;
    }
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry*)sender error:(IOReturn)error aborted:(BOOL)aborted {
    // Restart inquiries that have timed out.
    if (!aborted) {
        [sender clearFoundDevices];
        [sender start];
    }
}

// IOBluetoothDevicePairDelegate

- (void)devicePairingPINCodeRequest:(id)sender {
    IOBluetoothDevicePair* pair = (IOBluetoothDevicePair*)sender;
    IOBluetoothDevice* device = [sender device];

    IOBluetoothHostController* controller = [IOBluetoothHostController defaultController];
    
    NSString* controllerAddressStr = [controller addressAsString];
    
    BluetoothDeviceAddress controllerAddress;
    IOBluetoothNSStringToDeviceAddress(controllerAddressStr, &controllerAddress);

    BluetoothPINCode code;
    memset(&code, 0, sizeof(code));

    // When using the SYNC button, the PIN is the address of the Bluetooth controller in reverse.
    for (int i = 0; i < 6; i++) {
        code.data[i] = controllerAddress.data[5 - i];
    }

    uint64_t key;
    memcpy(&key, code.data, sizeof(key));
    
    // This is what [_devicePair replyPINCode:PINCode:] essentially does.
    // However, that method does a bunch of NSString-ification on the PIN code first.
    // We don't want this, so we replicate its behaviour here while skipping the NSString stuff.
    [[IOBluetoothCoreBluetoothCoordinator sharedInstance] pairPeer:[device classicPeer] forType:[pair currentPairingType] withKey:@(key)];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    [_devicePair stop];
    _devicePair = nil;
    
    if (error != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(error);
        
        [self showPairingResultAlertWithTitle:@"Pairing Error" text:[NSString stringWithFormat:@"An error occurred while attempting to pair: \"%s\".", pairResultString]];
    } else {
        [self showPairingResultAlertWithTitle:@"Paired" text:@"The Wii Remote has been paired with your Mac."];
    }
}

@end
