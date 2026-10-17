import ApplicationServices
import Foundation

/// One read of the presentation/state fields used by the snapshot traversal.
/// Action names and writable attributes remain separate native APIs.
struct AccessibilitySnapshotAttributes {
    static let names = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXLabel", "AXValue",
        "AXIdentifier", "AXPosition", "AXSize", "AXChildren", "AXContents", "AXURL", "AXDocument",
        "AXEnabled", "AXFocused", "AXSelected", "AXSelectedTextRange",
    ]

    enum ReadFailure: Error, LocalizedError {
        case native(AXError)
        case windowInventory(AXError)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .native(let error):
                return "Accessibility read failed (AX error \(error.rawValue))."
            case .windowInventory(let error):
                return "AX window inventory failed (AX error \(error.rawValue)); this is not window absence."
            case .malformedResponse:
                return "Accessibility attribute batch returned an invalid result count."
            }
        }
        var nativeError: AXError? {
            switch self {
            case .native(let error), .windowInventory(let error): return error
            case .malformedResponse: return nil
            }
        }
    }

    private(set) var values: [String: CFTypeRef] = [:]
    private(set) var errors: [String: AXError] = [:]

    init(element: AXUIElement) throws {
        var result: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, Self.names as CFArray, [], &result
        )
        if error == .notImplemented {
            // Generic compatibility for providers without the batch API.
            // Do not retry a stalled/invalid element with thirteen more messages.
            for name in Self.names {
                var value: CFTypeRef?
                let fieldError = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                if fieldError == .success, let value {
                    self.values[name] = value
                } else {
                    self.errors[name] = fieldError == .success ? .noValue : fieldError
                }
            }
            try self.validateFailures()
            return
        }
        guard error == .success else { throw ReadFailure.native(error) }
        guard let result else { throw ReadFailure.malformedResponse }
        self = try Self(results: result)
    }

    init(results: CFArray) throws {
        guard CFArrayGetCount(results) == Self.names.count else {
            throw ReadFailure.malformedResponse
        }
        for (index, name) in Self.names.enumerated() {
            guard let raw = CFArrayGetValueAtIndex(results, index) else {
                self.errors[name] = .noValue
                continue
            }
            let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            if CFGetTypeID(value) == CFNullGetTypeID() {
                self.errors[name] = .noValue
            } else if CFGetTypeID(value) == AXValueGetTypeID(),
                      AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError {
                var error = AXError.failure
                _ = AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .axError, &error)
                self.errors[name] = error
            } else {
                self.values[name] = value
            }
        }
        try self.validateFailures()
    }

    private func validateFailures() throws {
        if let code = self.errors.values.first(where: { [.invalidUIElement, .cannotComplete, .apiDisabled].contains($0) }) {
            throw ReadFailure.native(code)
        }
    }

    func string(_ name: String) -> String? { self.values[name] as? String }
    func url(_ name: String) -> String? {
        guard let raw = self.values[name] else { return nil }
        if CFGetTypeID(raw) == CFURLGetTypeID() {
            return CFURLGetString(unsafeBitCast(raw, to: CFURL.self)) as String
        }
        // AXDocument providers can expose a URL string instead of CFURL.
        return raw as? String
    }
    func boolean(_ name: String) -> Bool? { (self.values[name] as? NSNumber)?.boolValue }
    var hasControlState: Bool {
        values["AXSelected"] != nil || values["AXValue"] != nil || selectedRange != nil || boolean("AXFocused") == true
    }

    var selectedRange: AccessibilityTextRange? {
        guard let raw = values["AXSelectedTextRange"], CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return .init(location: range.location, length: range.length)
    }

    var children: [AXUIElement] {
        var seen = Set<NativeSnapshotElement>()
        return ["AXChildren", "AXContents"].flatMap { name in
            elements(name).filter { seen.insert(NativeSnapshotElement(element: $0)).inserted }
        }
    }

    private func elements(_ name: String) -> [AXUIElement] {
        guard let value = self.values[name], CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0 ..< CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    var frame: CGRect? {
        guard let rawPosition = self.values["AXPosition"],
              let rawSize = self.values["AXSize"],
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

struct AccessibilityTextRange: Encodable {
    let location: Int
    let length: Int
}

enum AccessibilityControlValue: Encodable {
    case text(String), number(Double), boolean(Bool)
    init?(_ raw: CFTypeRef?) {
        if let text = raw as? String { self = .text(text) }
        else if let raw, CFGetTypeID(raw) == CFBooleanGetTypeID(), let n = raw as? NSNumber { self = .boolean(n.boolValue) }
        else if let n = raw as? NSNumber, n.doubleValue.isFinite { self = .number(n.doubleValue) }
        else { return nil }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let n): try container.encode(n)
        case .boolean(let b): try container.encode(b)
        }
    }
}
