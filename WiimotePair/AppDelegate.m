// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AppDelegate.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    //
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    //
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
    return true;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return true;
}

@end
