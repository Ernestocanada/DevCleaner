import SwiftUI
import AppKit

public enum AppIconBranding {
    /// Renders the native macOS utility icon for DevCleaner using CoreGraphics vector geometry.
    public static func makeAppIconImage(pixelSize: Int = 1024) -> NSImage {
        let size = NSSize(width: pixelSize, height: pixelSize)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            drawIcon(in: CGRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    public static func pngData(pixelSize: Int) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            drawIcon(in: CGRect(origin: .zero, size: rep.size))
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    public static func exportIconAssets(projectRoot: URL) throws {
        let fm = FileManager.default
        let resourcesDir = projectRoot.appendingPathComponent("Sources/DevCleaner/Resources", isDirectory: true)
        let appIconsetDir = resourcesDir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        let tempIconsetDir = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)

        try fm.createDirectory(at: appIconsetDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempIconsetDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempIconsetDir) }

        let specs: [(filename: String, ptSize: Int, scale: Int, pixels: Int)] = [
            ("icon_16x16.png", 16, 1, 16),
            ("icon_16x16@2x.png", 16, 2, 32),
            ("icon_32x32.png", 32, 1, 32),
            ("icon_32x32@2x.png", 32, 2, 64),
            ("icon_128x128.png", 128, 1, 128),
            ("icon_128x128@2x.png", 128, 2, 256),
            ("icon_256x256.png", 256, 1, 256),
            ("icon_256x256@2x.png", 256, 2, 512),
            ("icon_512x512.png", 512, 1, 512),
            ("icon_512x512@2x.png", 512, 2, 1024)
        ]

        for spec in specs {
            guard let data = pngData(pixelSize: spec.pixels) else { continue }
            try data.write(to: appIconsetDir.appendingPathComponent(spec.filename))
            try data.write(to: tempIconsetDir.appendingPathComponent(spec.filename))
        }

        if let masterData = pngData(pixelSize: 1024) {
            try masterData.write(to: resourcesDir.appendingPathComponent("AppIcon-1024.png"))
        }

        let contentsJSON = """
        {
          "images" : [
            { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
            { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
            { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
            { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
            { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
            { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
            { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
            { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
            { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
            { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        try contentsJSON.write(to: appIconsetDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        let rootCatalogJSON = """
        {
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        try rootCatalogJSON.write(
            to: resourcesDir.appendingPathComponent("Assets.xcassets/Contents.json"),
            atomically: true,
            encoding: .utf8
        )

        let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", tempIconsetDir.path, "-o", icnsPath]
        try proc.run()
        proc.waitUntilExit()
    }

    public static func drawIcon(in rect: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let s = rect.width / 1024.0
        cg.saveGState()
        cg.scaleBy(x: s, y: s)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. Apple HIG macOS squircle (824x824 centered in 1024x1024)
        let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircleRadius: CGFloat = 186
        let squirclePath = CGPath(
            roundedRect: squircleRect,
            cornerWidth: squircleRadius,
            cornerHeight: squircleRadius,
            transform: nil
        )

        // Drop shadow behind squircle
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -20),
            blur: 36,
            color: NSColor(calibratedWhite: 0.0, alpha: 0.42).cgColor
        )
        cg.addPath(squirclePath)
        cg.setFillColor(NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.18, alpha: 1.0).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // Clip to squircle for background gradient & ambient glow
        cg.saveGState()
        cg.addPath(squirclePath)
        cg.clip()

        let bgColors = [
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.17, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.29, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.42, alpha: 1.0).cgColor
        ] as CFArray
        let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
        cg.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: 512, y: 100),
            end: CGPoint(x: 512, y: 924),
            options: []
        )

        // Subtle cyan/emerald radial glow in top-right of squircle
        let glowColors = [
            NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.83, alpha: 0.28).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.83, alpha: 0.0).cgColor
        ] as CFArray
        let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
        cg.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: 720, y: 740),
            startRadius: 0,
            endCenter: CGPoint(x: 720, y: 740),
            endRadius: 420,
            options: [.drawsBeforeStartLocation]
        )

        // 2. Metallic SSD / Developer Drive Enclosure
        let driveRect = CGRect(x: 210, y: 270, width: 520, height: 480)
        let drivePath = CGPath(roundedRect: driveRect, cornerWidth: 68, cornerHeight: 68, transform: nil)

        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -18),
            blur: 32,
            color: NSColor(calibratedWhite: 0.0, alpha: 0.45).cgColor
        )
        cg.addPath(drivePath)
        cg.setFillColor(NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.92, alpha: 1.0).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // Drive metallic gradient fill
        cg.saveGState()
        cg.addPath(drivePath)
        cg.clip()
        let metalColors = [
            NSColor(calibratedRed: 0.75, green: 0.80, blue: 0.87, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.97, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.00, alpha: 1.0).cgColor
        ] as CFArray
        let metalGrad = CGGradient(colorsSpace: colorSpace, colors: metalColors, locations: [0.0, 0.65, 1.0])!
        cg.drawLinearGradient(
            metalGrad,
            start: CGPoint(x: 470, y: 270),
            end: CGPoint(x: 470, y: 750),
            options: []
        )

        // Drive lower front bay panel (dark slate recess)
        let bayRect = CGRect(x: 248, y: 306, width: 444, height: 112)
        let bayPath = CGPath(roundedRect: bayRect, cornerWidth: 34, cornerHeight: 34, transform: nil)
        cg.addPath(bayPath)
        cg.setFillColor(NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.24, alpha: 1.0).cgColor)
        cg.fillPath()

        // Safe emerald LED indicator inside drive bay
        let ledRect = CGRect(x: 288, y: 346, width: 32, height: 32)
        cg.saveGState()
        cg.setShadow(
            offset: .zero,
            blur: 14,
            color: NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.55, alpha: 0.9).cgColor
        )
        cg.fillEllipse(in: ledRect)
        cg.setFillColor(NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.55, alpha: 1.0).cgColor)
        cg.fillEllipse(in: ledRect)
        cg.restoreGState()

        // Storage capacity bar inside drive bay
        let barTrackRect = CGRect(x: 346, y: 350, width: 290, height: 24)
        let barTrackPath = CGPath(roundedRect: barTrackRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        cg.addPath(barTrackPath)
        cg.setFillColor(NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.38, alpha: 1.0).cgColor)
        cg.fillPath()

        let barFillRect = CGRect(x: 346, y: 350, width: 172, height: 24)
        let barFillPath = CGPath(roundedRect: barFillRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        cg.saveGState()
        cg.addPath(barFillPath)
        cg.clip()
        let barColors = [
            NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.14, green: 0.63, blue: 0.94, alpha: 1.0).cgColor
        ] as CFArray
        let barGrad = CGGradient(colorsSpace: colorSpace, colors: barColors, locations: [0.0, 1.0])!
        cg.drawLinearGradient(
            barGrad,
            start: CGPoint(x: 346, y: 362),
            end: CGPoint(x: 518, y: 362),
            options: []
        )
        cg.restoreGState()

        // Corner mounting screws on top plate
        let screwColor = NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.72, alpha: 0.85).cgColor
        cg.setFillColor(screwColor)
        for pt in [
            CGPoint(x: 256, y: 696),
            CGPoint(x: 672, y: 696),
            CGPoint(x: 256, y: 454),
            CGPoint(x: 672, y: 454)
        ] {
            cg.fillEllipse(in: CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18))
        }

        // Developer code glyph `< / >` engraved on top plate of SSD
        cg.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.36, alpha: 0.92).cgColor)
        cg.setLineWidth(26)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        // Left chevron `<`
        cg.beginPath()
        cg.move(to: CGPoint(x: 400, y: 632))
        cg.addLine(to: CGPoint(x: 338, y: 576))
        cg.addLine(to: CGPoint(x: 400, y: 520))
        cg.strokePath()

        // Right chevron `>`
        cg.beginPath()
        cg.move(to: CGPoint(x: 540, y: 632))
        cg.addLine(to: CGPoint(x: 602, y: 576))
        cg.addLine(to: CGPoint(x: 540, y: 520))
        cg.strokePath()

        // Center slash `/`
        cg.setStrokeColor(NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.82, alpha: 0.95).cgColor)
        cg.beginPath()
        cg.move(to: CGPoint(x: 446, y: 506))
        cg.addLine(to: CGPoint(x: 494, y: 646))
        cg.strokePath()

        cg.restoreGState() // End drive clip

        // Drive subtle border highlight
        cg.addPath(drivePath)
        cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.65).cgColor)
        cg.setLineWidth(3)
        cg.strokePath()

        // 3. Clean Cyan/Teal Utility Badge with Sparkle (bottom-right overlap)
        let badgeCenter = CGPoint(x: 706, y: 334)
        let badgeRadius: CGFloat = 148
        let badgeRect = CGRect(
            x: badgeCenter.x - badgeRadius,
            y: badgeCenter.y - badgeRadius,
            width: badgeRadius * 2,
            height: badgeRadius * 2
        )

        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -14),
            blur: 26,
            color: NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.18, alpha: 0.55).cgColor
        )
        cg.fillEllipse(in: badgeRect)
        cg.restoreGState()

        cg.saveGState()
        cg.addEllipse(in: badgeRect)
        cg.clip()
        let badgeColors = [
            NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.88, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.76, blue: 0.72, alpha: 1.0).cgColor
        ] as CFArray
        let badgeGrad = CGGradient(colorsSpace: colorSpace, colors: badgeColors, locations: [0.0, 1.0])!
        cg.drawLinearGradient(
            badgeGrad,
            start: CGPoint(x: badgeRect.minX, y: badgeRect.minY),
            end: CGPoint(x: badgeRect.maxX, y: badgeRect.maxY),
            options: []
        )
        cg.restoreGState()

        // Badge white ring
        cg.strokeEllipse(in: badgeRect.insetBy(dx: 3, dy: 3))
        cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.45).cgColor)
        cg.setLineWidth(5)
        cg.strokeEllipse(in: badgeRect.insetBy(dx: 3, dy: 3))

        // Crisp 4-point cleanup sparkle star inside badge + accent sparkle
        drawSparkle(in: cg, center: CGPoint(x: 696, y: 326), radius: 84, color: .white)
        drawSparkle(in: cg, center: CGPoint(x: 766, y: 400), radius: 32, color: NSColor(calibratedWhite: 1.0, alpha: 0.92))
        drawSparkle(
            in: cg,
            center: CGPoint(x: 760, y: 690),
            radius: 38,
            color: NSColor(calibratedRed: 0.38, green: 0.90, blue: 0.88, alpha: 0.90)
        )

        // Squircle inner specular border
        cg.addPath(squirclePath)
        cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor)
        cg.setLineWidth(4)
        cg.strokePath()

        cg.restoreGState() // End squircle clip
        cg.restoreGState() // End scale
    }

    private static func drawSparkle(in cg: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
        let inner = radius * 0.24
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        path.addQuadCurve(
            to: CGPoint(x: center.x + radius, y: center.y),
            control: CGPoint(x: center.x + inner, y: center.y + inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius),
            control: CGPoint(x: center.x + inner, y: center.y - inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x - radius, y: center.y),
            control: CGPoint(x: center.x - inner, y: center.y - inner)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control: CGPoint(x: center.x - inner, y: center.y + inner)
        )
        path.closeSubpath()

        cg.saveGState()
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }
}

public struct DevCleanerBrandIconView: View {
    let size: CGFloat

    public init(size: CGFloat = 38) {
        self.size = size
    }

    public var body: some View {
        Image(nsImage: AppIconBranding.makeAppIconImage(pixelSize: Int(size * 2)))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
    }
}
