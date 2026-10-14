import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let set = root.appendingPathComponent("OmniDisplay.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let rect = NSRect(x: 38, y: 38, width: 948, height: 948)
        let rounded = NSBezierPath(roundedRect: rect, xRadius: 218, yRadius: 218)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.64, blue: 0.88, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.53, alpha: 1))!.draw(in: rounded, angle: -55)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: 178,y: 398,width: 470,height: 358),xRadius: 44,yRadius: 44).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let back = NSBezierPath(roundedRect: NSRect(x: 178,y: 398,width: 470,height: 358),xRadius: 44,yRadius: 44); back.lineWidth=18; back.stroke()
        NSColor(calibratedRed: 0.55,green: 0.86,blue: 1,alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 407,y: 274,width: 442,height: 328),xRadius: 42,yRadius: 42).fill()
        NSColor.white.setStroke(); let front = NSBezierPath(roundedRect: NSRect(x: 407,y: 274,width: 442,height: 328),xRadius: 42,yRadius: 42); front.lineWidth=20; front.stroke()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 582,y: 220,width: 88,height: 45),xRadius: 12,yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 513,y: 197,width: 224,height: 24),xRadius: 12,yRadius: 12).fill()
        image.unlockFocus()
        let output = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:output)
        image.draw(in:NSRect(x:0,y:0,width:pixels,height:pixels)); NSGraphicsContext.restoreGraphicsState()
        let suffix=scale==2 ? "@2x" : ""
        try output.representation(using:.png,properties:[:])!.write(to:set.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
