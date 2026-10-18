// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// Include the implementation to exercise the private delegate without exposing
// it as public API or opening a real Bluetooth pairing session.
#import "../WiimotePair/ViewController.m"
#include <assert.h>

@interface TestPeer : NSObject
@property (strong) NSUUID* identifier;
@end
@implementation TestPeer
@end

@interface OriginalDelegate : NSObject
@property NSUInteger calls;
@property NSInteger lastType;
@property (strong) id lastPasskey;
- (NSString*)unrelatedCallback;
@end
@implementation OriginalDelegate
- (void)pairingAgent:(id)agent peerDidRequestPairing:(id)peer type:(NSInteger)type passkey:(id)passkey {
    self.calls++;
    self.lastType = type;
    self.lastPasskey = passkey;
}
- (NSString*)unrelatedCallback { return @"forwarded"; }
@end

@interface TestPINDelegate : WiimoteLegacyPINDelegate
@property NSUInteger replies;
@property BOOL replySucceeds;
@end
@implementation TestPINDelegate
- (BOOL)replyWithLegacyPINToPeer:(id)peer {
    self.replies++;
    return self.replySucceeds;
}
@end

int main(void) {
    @autoreleasepool {
        TestPINDelegate* proxy = [TestPINDelegate new];
        OriginalDelegate* original = [OriginalDelegate new];
        TestPeer* target = [TestPeer new];
        target.identifier = [NSUUID UUID];
        TestPeer* other = [TestPeer new];
        other.identifier = [NSUUID UUID];
        proxy.originalDelegate = original;
        proxy.targetPeer = target;
        proxy.active = YES;
        proxy.replySucceeds = YES;

        // Never change another device's pairing request or its passkey.
        [proxy pairingAgent:nil peerDidRequestPairing:other type:0 passkey:@123456];
        assert(original.calls == 1 && proxy.replies == 0);
        assert(original.lastType == 0 && [original.lastPasskey isEqual:@123456]);

        // Rewrite only Just Works requests for the selected remote.
        [proxy pairingAgent:nil peerDidRequestPairing:target type:0 passkey:nil];
        assert(proxy.replies == 1 && original.calls == 1);
        TestPeer* equivalent = [TestPeer new];
        equivalent.identifier = target.identifier;
        [proxy pairingAgent:nil peerDidRequestPairing:equivalent type:0 passkey:nil];
        assert(proxy.replies == 2 && original.calls == 1);

        // Preserve the native legacy PIN flow and other pairing types.
        [proxy pairingAgent:nil peerDidRequestPairing:target type:6 passkey:nil];
        [proxy pairingAgent:nil peerDidRequestPairing:target type:4 passkey:@654321];
        assert(original.calls == 3 && original.lastType == 4 && proxy.replies == 2);
        assert([original.lastPasskey isEqual:@654321]);

        // Failed PIN preparation must fall back to the original delegate.
        proxy.replySucceeds = NO;
        [proxy pairingAgent:nil peerDidRequestPairing:target type:0 passkey:nil];
        assert(original.calls == 4 && proxy.replies == 3);

        // A callback already queued when the attempt ended must be forwarded.
        proxy.active = NO;
        [proxy pairingAgent:nil peerDidRequestPairing:target type:0 passkey:nil];
        assert(original.calls == 5 && proxy.replies == 3);

        // Missing identifiers must not accidentally match two unrelated peers.
        proxy.active = YES;
        target.identifier = nil;
        other.identifier = nil;
        [proxy pairingAgent:nil peerDidRequestPairing:other type:0 passkey:nil];
        assert(original.calls == 6 && proxy.replies == 3);
        assert([proxy respondsToSelector:@selector(unrelatedCallback)]);
        assert([[(id)proxy unrelatedCallback] isEqualToString:@"forwarded"]);

        // Bluetooth statuses must not become unrelated Mach kernel errors.
        assert([PairingErrorDescription(0x1f) isEqualToString:@"Unspecified Bluetooth error"]);
        assert([PairingErrorDescription(5) isEqualToString:@"Bluetooth authentication failed"]);
        puts("PASS: scoped PIN workaround, fallback, callback forwarding, and HCI errors");
    }
}
