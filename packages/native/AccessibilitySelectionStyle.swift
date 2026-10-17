import AppKit
import ApplicationServices

struct AccessibilitySelectionStyle: Encodable {
    let location: Int
    let length: Int
    let font: String?
    let bold: Bool?
    let italic: Bool?
    let underline: Bool?
    let strikethrough: Bool?

    static func runs(_ string: NSAttributedString, offset: Int) -> [Self]? {
        var styles: [Self] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, run, stop in
            if styles.count >= 32 { stop.pointee = true; return }
            let fontInfo = attributes[NSAttributedString.Key(rawValue: kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any]
            let name = fontInfo?[kAXFontNameKey.takeUnretainedValue() as String] as? String
            let size = (fontInfo?[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber)?.doubleValue ?? 12
            let font = name.flatMap { NSFont(name: $0, size: size) }
            func flag(_ key: CFString) -> Bool? {
                (attributes[NSAttributedString.Key(rawValue: key as String)] as? NSNumber).map { $0.intValue != 0 }
            }
            styles.append(.init(location: offset + run.location, length: run.length, font: name,
                bold: font.map { $0.fontDescriptor.symbolicTraits.contains(.bold) },
                italic: font.map { $0.fontDescriptor.symbolicTraits.contains(.italic) },
                underline: flag(kAXUnderlineTextAttribute.takeUnretainedValue()),
                strikethrough: flag(kAXStrikethroughTextAttribute.takeUnretainedValue())))
        }
        guard styles.reduce(0, { $0 + $1.length }) == string.length else { return nil }
        return styles
    }
}
