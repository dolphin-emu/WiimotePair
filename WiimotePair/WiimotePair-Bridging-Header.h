// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef WiimotePair_Bridging_Header_h
#define WiimotePair_Bridging_Header_h

#import <Cocoa/Cocoa.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <mach/mach_error.h>

// Private IOBluetooth interfaces required for PIN-based Wii Remote pairing.
#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"

#endif /* WiimotePair_Bridging_Header_h */
