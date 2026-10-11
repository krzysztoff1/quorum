import SwiftUI
import AppKit
import CoreText

enum Fonts {
    static let uiFamily = "Instrument Sans"
    static let readFamily = "Source Serif 4"
    private static let opticalSizeAxis = 0x6F70737A

    @MainActor private static var registered = false

    @MainActor static func register() {
        guard !registered else { return }
        registered = true
        for url in Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: uiFamily, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func read(_ size: CGFloat, italic: Bool = false) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: readFamily,
            .variation: [opticalSizeAxis: min(max(size, 8), 60)],
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.regular],
        ])
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }
}
