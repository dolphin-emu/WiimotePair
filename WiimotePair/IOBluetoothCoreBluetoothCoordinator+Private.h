// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

@interface IOBluetoothCoreBluetoothCoordinator : NSObject

+ (IOBluetoothCoreBluetoothCoordinator*)sharedInstance;

- (void)pairPeer:(id)peer forType:(NSUInteger)type withKey:(NSNumber*)key;

@end
