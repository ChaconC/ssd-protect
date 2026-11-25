import AppKit

enum MenuBarIcon {
    static func image(protectedCount: Int) -> NSImage {
        protectedCount > 0 ? closedCradle : openCradle
    }

    private static let openCradle = makeImage(enclosed: false)
    private static let closedCradle = makeImage(enclosed: true)

    private static func makeImage(enclosed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: true) { _ in
            let drive = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 16, height: 10),
                                     xRadius: 2.5, yRadius: 2.5)
            let port = NSRect(x: 9, y: 10, width: 6, height: 2)
            drive.append(NSBezierPath(roundedRect: port, xRadius: 1, yRadius: 1))
            drive.windingRule = .evenOdd
            NSColor.black.setFill()
            drive.fill()

            NSGraphicsContext.saveGraphicsState()
            if !enclosed {
                NSBezierPath(rect: NSRect(x: 0, y: 9, width: 24, height: 9)).addClip()
            }
            let cradle = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1, width: 21, height: 16),
                                      xRadius: 5, yRadius: 5)
            NSColor.black.setStroke()
            cradle.lineWidth = 2
            cradle.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
