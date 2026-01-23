import SwiftUI

/// A SwiftUI view that displays an animated MeshGradient glow border effect
struct GlowBorderView: View {
    /// The size of the target window (the glow border will surround this)
    let targetSize: CGSize

    /// Border thickness for the glow effect
    let borderWidth: CGFloat = 20

    /// Padding added around the target window for glow overflow
    let glowPadding: CGFloat = 30

    /// Controls the animation phase
    @State private var phase: CGFloat = 0

    /// Controls overall opacity for fade in/out
    @State private var opacity: Double = 0

    var body: some View {
        // The total size includes padding for glow overflow
        let totalWidth = targetSize.width + (glowPadding * 2)
        let totalHeight = targetSize.height + (glowPadding * 2)

        ZStack {
            // Animated MeshGradient as the glow
            animatedMeshGradient
                .frame(width: totalWidth, height: totalHeight)
                // Mask to only show the border area (hollow out the center)
                .mask(
                    borderMask(
                        totalSize: CGSize(width: totalWidth, height: totalHeight),
                        innerSize: targetSize,
                        cornerRadius: 12
                    )
                )
                // Add blur for soft glow effect
                .blur(radius: 8)

            // Sharper inner border for definition
            animatedMeshGradient
                .frame(width: totalWidth, height: totalHeight)
                .mask(
                    borderMask(
                        totalSize: CGSize(width: totalWidth, height: totalHeight),
                        innerSize: CGSize(
                            width: targetSize.width + 4,
                            height: targetSize.height + 4
                        ),
                        cornerRadius: 12
                    )
                )
                .blur(radius: 2)
                .opacity(0.8)
        }
        .opacity(opacity)
        .onAppear {
            startAnimation()
        }
    }

    /// The animated MeshGradient with flowing green colors
    private var animatedMeshGradient: some View {
        // Phase-based animation for organic movement
        let animatedPhase = phase

        return MeshGradient(
            width: 3,
            height: 3,
            points: meshPoints(phase: animatedPhase),
            colors: meshColors(phase: animatedPhase)
        )
    }

    /// Generate mesh points with subtle animation
    private func meshPoints(phase: CGFloat) -> [SIMD2<Float>] {
        // Small offsets for organic movement
        let wobble = Float(sin(phase * .pi * 2) * 0.05)
        let wobble2 = Float(cos(phase * .pi * 2) * 0.05)

        return [
            // Top row
            SIMD2(0.0, 0.0),
            SIMD2(0.5 + wobble, 0.0),
            SIMD2(1.0, 0.0),
            // Middle row
            SIMD2(0.0, 0.5 + wobble2),
            SIMD2(0.5 + wobble2, 0.5 + wobble),  // Center point moves
            SIMD2(1.0, 0.5 - wobble2),
            // Bottom row
            SIMD2(0.0, 1.0),
            SIMD2(0.5 - wobble, 1.0),
            SIMD2(1.0, 1.0)
        ]
    }

    /// Generate mesh colors with phase-based shifting
    private func meshColors(phase: CGFloat) -> [Color] {
        // Cycle through green hues based on phase
        let shift = phase

        return [
            // Top row - brighter greens
            Color(hue: 0.38 + shift * 0.05, saturation: 0.9, brightness: 0.9),
            Color(hue: 0.42 + shift * 0.03, saturation: 0.85, brightness: 0.95),
            Color(hue: 0.35 - shift * 0.05, saturation: 0.9, brightness: 0.85),
            // Middle row - mix of green and cyan
            Color(hue: 0.45 + shift * 0.04, saturation: 0.8, brightness: 0.9),
            Color(hue: 0.40, saturation: 0.7, brightness: 1.0),  // Bright center
            Color(hue: 0.33 - shift * 0.04, saturation: 0.85, brightness: 0.9),
            // Bottom row - deeper greens
            Color(hue: 0.36 - shift * 0.03, saturation: 0.9, brightness: 0.85),
            Color(hue: 0.40 + shift * 0.05, saturation: 0.85, brightness: 0.9),
            Color(hue: 0.44 + shift * 0.03, saturation: 0.9, brightness: 0.88)
        ]
    }

    /// Create a mask that shows only the border area
    private func borderMask(totalSize: CGSize, innerSize: CGSize, cornerRadius: CGFloat) -> some View {
        // Outer rounded rectangle (full size)
        // Minus inner rounded rectangle (window area)
        let outerRect = RoundedRectangle(cornerRadius: cornerRadius + glowPadding / 2)
        let innerRect = RoundedRectangle(cornerRadius: cornerRadius)

        return ZStack {
            outerRect
            innerRect
                .frame(width: innerSize.width, height: innerSize.height)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    /// Start the glow animation sequence
    private func startAnimation() {
        // Fade in
        withAnimation(.easeIn(duration: 0.3)) {
            opacity = 1.0
        }

        // Animate the mesh movement
        withAnimation(
            .easeInOut(duration: 1.5)
            .repeatCount(3, autoreverses: true)
        ) {
            phase = 1.0
        }

        // Schedule fade out after the animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.5)) {
                opacity = 0.0
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.3)
        GlowBorderView(targetSize: CGSize(width: 800, height: 600))
    }
    .frame(width: 900, height: 700)
}
