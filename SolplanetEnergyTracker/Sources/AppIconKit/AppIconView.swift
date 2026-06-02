import SwiftUI
import AppKit

/// SwiftUI rendering of the application icon: a sun above a charged battery, on a
/// warm sky gradient. Lives in its own target so both the running app (assigning
/// it to `NSApplication.shared.applicationIconImage`) and the packaging tooling
/// (exporting an `.iconset`) share one source of truth instead of a static `.icns`
/// that drifts from the design.
public struct AppIconView: View {
    private static let canvasSize: CGFloat = 1024
    private static let squircleRadius: CGFloat = 228

    // Sun geometry.
    private static let sunCenterY: CGFloat = 372
    private static let sunRadius: CGFloat = 132
    private static let rayInner: CGFloat = 168
    private static let rayOuter: CGFloat = 236
    private static let rayWidth: CGFloat = 26
    private static let rayCount = 8

    // Battery geometry.
    private static let batteryWidth: CGFloat = 540
    private static let batteryHeight: CGFloat = 268
    private static let batteryCenterY: CGFloat = 700
    private static let batteryCornerRadius: CGFloat = 64
    private static let batteryStroke: CGFloat = 28
    private static let batteryInset: CGFloat = 54
    private static let batteryFillRatio: CGFloat = 0.72
    private static let terminalWidth: CGFloat = 34
    private static let terminalHeight: CGFloat = 120

    // Warm dawn sky: amber top → soft peach bottom.
    private let skyTop = Color(red: 0.992, green: 0.808, blue: 0.380)
    private let skyBottom = Color(red: 0.976, green: 0.659, blue: 0.380)

    // Deep navy ink: battery outline + terminal.
    private let ink = Color(red: 0.102, green: 0.161, blue: 0.259)
    // Sun + battery charge share a single warm white-gold so they read as "energy".
    private let sun = Color(red: 1.0, green: 0.973, blue: 0.910)
    private let charge = Color(red: 0.353, green: 0.792, blue: 0.467)

    public init() {}

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.squircleRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [skyTop, skyBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))

            sunMark
            batteryMark
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
    }

    private var sunMark: some View {
        ZStack {
            ForEach(0..<Self.rayCount, id: \.self) { index in
                Capsule()
                    .fill(sun)
                    .frame(width: Self.rayWidth, height: Self.rayOuter - Self.rayInner)
                    .offset(y: -(Self.rayInner + Self.rayOuter) / 2)
                    .rotationEffect(.degrees(Double(index) / Double(Self.rayCount) * 360))
            }
            Circle()
                .fill(sun)
                .frame(width: Self.sunRadius * 2, height: Self.sunRadius * 2)
        }
        .position(x: Self.canvasSize / 2, y: Self.sunCenterY)
    }

    private var batteryMark: some View {
        ZStack {
            // Body outline.
            RoundedRectangle(cornerRadius: Self.batteryCornerRadius, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.batteryCornerRadius, style: .continuous)
                        .strokeBorder(ink, lineWidth: Self.batteryStroke)
                )
                .frame(width: Self.batteryWidth, height: Self.batteryHeight)

            // Charge fill, left-aligned inside the body.
            HStack {
                RoundedRectangle(cornerRadius: Self.batteryCornerRadius - Self.batteryInset, style: .continuous)
                    .fill(charge)
                    .frame(
                        width: (Self.batteryWidth - 2 * Self.batteryInset) * Self.batteryFillRatio,
                        height: Self.batteryHeight - 2 * Self.batteryInset
                    )
                Spacer(minLength: 0)
            }
            .frame(width: Self.batteryWidth - 2 * Self.batteryInset, height: Self.batteryHeight)

            // Positive terminal on the right edge.
            RoundedRectangle(cornerRadius: Self.terminalWidth / 2, style: .continuous)
                .fill(ink)
                .frame(width: Self.terminalWidth, height: Self.terminalHeight)
                .offset(x: Self.batteryWidth / 2 + Self.terminalWidth / 2)
        }
        .position(x: Self.canvasSize / 2, y: Self.batteryCenterY)
    }
}

@MainActor
public enum AppIconRenderer {
    /// Rasterises `AppIconView` to an `NSImage` at the requested pixel size.
    /// The view's intrinsic size is 1024 points, so the scale factor is the ratio
    /// between target pixels and 1024.
    public static func makeImage(pixelSize: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = pixelSize / 1024
        return renderer.nsImage
    }

    /// CGImage variant — needed by packaging tooling that writes PNG files through
    /// `CGImageDestination`.
    public static func makeCGImage(pixelSize: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = pixelSize / 1024
        return renderer.cgImage
    }
}

#Preview {
    AppIconView()
        .frame(width: 256, height: 256)
        .padding()
}
