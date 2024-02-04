// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

@interface IOBluetoothDevicePair()

- (void)setUserDefinedPincode:(BOOL)enabled;
- (NSUInteger)currentPairingType;

@end
