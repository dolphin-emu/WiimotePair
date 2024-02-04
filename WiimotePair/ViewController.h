// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Cocoa/Cocoa.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>

@interface ViewController : NSViewController <CBCentralManagerDelegate, IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate>

@property (weak) IBOutlet NSProgressIndicator* progressIndicator;

@end

