#!/usr/bin/env swift
import AppKit
import Foundation

let symbolName = "camera.viewfinder"
let iconSize = 1024
let iconRect = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)

// Match the command bar's dark background and the active type button's amber.
let bgColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
let amber = NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.0, alpha: 1.0)

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

func render(size: Int, filename: String) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = CGFloat(size) * 0.2237 // macOS app-icon corner radius ratio

    let image = NSImage(size: rect.size)
    image.lockFocus()

    // Rounded dark background.
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    bgColor.setFill()
    path.fill()

    // Load and tint the symbol at a size that fills most of the icon.
    let symbolSize = CGFloat(size) * 0.55
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [amber]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) else {
        fatalError("Could not load system symbol '\(symbolName)'")
    }

    let symbolRect = NSRect(
        x: (CGFloat(size) - symbol.size.width) / 2.0,
        y: (CGFloat(size) - symbol.size.height) / 2.0,
        width: symbol.size.width,
        height: symbol.size.height
    )
    symbol.draw(in: symbolRect, from: NSRect(origin: .zero, size: symbol.size), operation: .sourceOver, fraction: 1.0)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(filename)")
    }

    let url = URL(fileURLWithPath: "\(outputDir)/\(filename)")
    do {
        try png.write(to: url)
        print("wrote \(filename)")
    } catch {
        fatalError("Failed to write \(filename): \(error)")
    }
}

let pairs = [(16, 16), (32, 32), (128, 128), (256, 256), (512, 512)]
for (base, px) in pairs {
    render(size: px, filename: "icon_\(base)x\(base).png")
    render(size: px * 2, filename: "icon_\(base)x\(base)@2x.png")
}

print("App icon set rendered in \(outputDir)")
