import AppKit

/// The menu bar glyph: a slice of toast with a note cut out, drawn as a template image
/// so the system tints it for light, dark and highlighted menu bars.
enum StatusIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let unit = rect.width / 18
            // Bread slice: a straight-sided base under a crown of two rounded lobes.
            let slice = NSBezierPath()
            slice.move(to: NSPoint(x: 3.2 * unit, y: 2 * unit))
            slice.line(to: NSPoint(x: 14.8 * unit, y: 2 * unit))
            slice.curve(to: NSPoint(x: 15.6 * unit, y: 2.8 * unit),
                        controlPoint1: NSPoint(x: 15.3 * unit, y: 2 * unit),
                        controlPoint2: NSPoint(x: 15.6 * unit, y: 2.3 * unit))
            slice.line(to: NSPoint(x: 15.6 * unit, y: 10.6 * unit))
            slice.curve(to: NSPoint(x: 9 * unit, y: 16.2 * unit),
                        controlPoint1: NSPoint(x: 18.2 * unit, y: 12.6 * unit),
                        controlPoint2: NSPoint(x: 15.2 * unit, y: 16.2 * unit))
            slice.curve(to: NSPoint(x: 2.4 * unit, y: 10.6 * unit),
                        controlPoint1: NSPoint(x: 2.8 * unit, y: 16.2 * unit),
                        controlPoint2: NSPoint(x: -0.2 * unit, y: 12.6 * unit))
            slice.line(to: NSPoint(x: 2.4 * unit, y: 2.8 * unit))
            slice.curve(to: NSPoint(x: 3.2 * unit, y: 2 * unit),
                        controlPoint1: NSPoint(x: 2.4 * unit, y: 2.3 * unit),
                        controlPoint2: NSPoint(x: 2.7 * unit, y: 2 * unit))
            slice.close()
            NSColor.black.setFill()
            slice.fill()

            // Knock the note out of the slice.
            let config = NSImage.SymbolConfiguration(pointSize: 8.5 * unit, weight: .bold)
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let noteRect = NSRect(x: 9 * unit - note.size.width / 2, y: 8.2 * unit - note.size.height / 2,
                                      width: note.size.width, height: note.size.height)
                note.draw(in: noteRect, from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Toastune"
        return image
    }
}
