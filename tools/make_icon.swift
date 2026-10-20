// Renders the 该隐 / Cain app icon: black square, a white arch outline (a tunnel mouth), and the
// red status square bottom-right, as on Bridge's icon. Adapted from Bridge's tools/make_icon.swift.
// usage: swift tools/make_icon.swift <out.png> [--tinted] [size=1024]
// --tinted: the Tinted home-screen variant. iOS tints by luminance, so it is greyscale and the red
// square becomes light grey (a red there would turn into a muddy mid-tone).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var args = Array(CommandLine.arguments.dropFirst())
let tinted = args.contains("--tinted")
args.removeAll { $0 == "--tinted" }
guard let out = args.first else { print("usage: make_icon.swift <out.png> [--tinted] [size]"); exit(2) }
let size = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
let s = CGFloat(size)

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }

ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

// The arch: two uprights and a half circle, one heavy white stroke, flat ends on the ground line.
let line = s * 0.075
let width = s * 0.46
let left = (s - width) / 2, right = left + width
let ground = s * 0.27                     // CoreGraphics y grows upwards
let shoulder = s * 0.52
let arch = CGMutablePath()
arch.move(to: CGPoint(x: left, y: ground))
arch.addLine(to: CGPoint(x: left, y: shoulder))
arch.addArc(center: CGPoint(x: s / 2, y: shoulder), radius: width / 2, startAngle: .pi, endAngle: 0, clockwise: true)
arch.addLine(to: CGPoint(x: right, y: ground))
ctx.addPath(arch)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(line)
ctx.setLineCap(.butt)
ctx.setLineJoin(.miter)
ctx.strokePath()

// Ground line under the arch, 1px-style but at icon scale.
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: s * 0.18, y: ground - line / 2, width: s * 0.64, height: line / 2))

// Status square, the theme's 8pt square at home-screen scale.
let square = s * 0.12
if tinted {
    ctx.setFillColor(CGColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1))
} else {
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0x2d / 255, blue: 0x20 / 255, alpha: 1))   // Theme.red
}
ctx.fill(CGRect(x: s * 0.82 - square, y: s * 0.08, width: square, height: square))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(out)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(out)") }
print("wrote \(out)")
