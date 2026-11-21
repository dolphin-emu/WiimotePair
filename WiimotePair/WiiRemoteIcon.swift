// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A minimal Wii Remote: slim body, D-pad, A button, the 1/2 buttons and,
/// at larger sizes, the four player LEDs.
struct WiiRemoteIcon: View {
    var tint: Color = .accentColor
    /// Player LED bitmask, bit 0 = LED 1 … bit 3 = LED 4.
    var litLEDs: Int = 0

    private static let aspectRatio: CGFloat = 0.3

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let lineWidth = max(1, w * 0.07)

            let bodyRect = CGRect(x: lineWidth / 2, y: lineWidth / 2,
                                  width: w - lineWidth, height: h - lineWidth)
            let bodyPath = RoundedRectangle(cornerRadius: w * 0.4, style: .continuous)
                .path(in: bodyRect)
            context.fill(bodyPath, with: .color(tint.opacity(0.12)))
            context.stroke(bodyPath, with: .color(tint), lineWidth: lineWidth)

            func circle(y: CGFloat, radius: CGFloat, opacity: Double = 1, x: CGFloat? = nil) {
                let rect = CGRect(x: (x ?? cx) - radius, y: y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Circle().path(in: rect), with: .color(tint.opacity(opacity)))
            }

            // D-pad
            let armLength = w * 0.44
            let armThickness = w * 0.14
            let dpadY = h * 0.17
            for rect in [
                CGRect(x: cx - armThickness / 2, y: dpadY - armLength / 2,
                       width: armThickness, height: armLength),
                CGRect(x: cx - armLength / 2, y: dpadY - armThickness / 2,
                       width: armLength, height: armThickness),
            ] {
                let arm = RoundedRectangle(cornerRadius: armThickness * 0.25).path(in: rect)
                context.fill(arm, with: .color(tint))
            }

            // A button
            circle(y: h * 0.36, radius: w * 0.17)

            // 1 and 2
            circle(y: h * 0.69, radius: w * 0.095)
            circle(y: h * 0.79, radius: w * 0.095)

            // Player LEDs, skipped when too small to read
            if w >= 14 {
                for i in 0..<4 {
                    let lit = (litLEDs & (1 << i)) != 0
                    circle(y: h * 0.905, radius: w * 0.045,
                           opacity: lit ? 1 : 0.25,
                           x: cx + (CGFloat(i) - 1.5) * w * 0.16)
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityLabel("Wii Remote")
    }
}

#Preview {
    HStack(alignment: .bottom, spacing: 24) {
        WiiRemoteIcon(tint: .blue, litLEDs: 0b0001).frame(height: 160)
        WiiRemoteIcon(tint: .red, litLEDs: 0b0010).frame(height: 100)
        WiiRemoteIcon(tint: .secondary).frame(height: 44)
    }
    .padding()
}
