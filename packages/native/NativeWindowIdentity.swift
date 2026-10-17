import ApplicationServices
import Foundation

// Same AX-to-Window-Server bridge used by the bundled AXorcist resolver.
@_silgen_name("_AXUIElementGetWindow")
private func nativeAXWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

enum NativeWindowIdentity {
    static func read(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return nativeAXWindowID(element, &id) == .success && id != 0 ? id : nil
    }

    struct Candidate {
        let id: CGWindowID?
        let frame: CGRect
        let fallbackAllowed: Bool
    }

    static func index(id: CGWindowID, frame: CGRect, candidates: [Candidate]) -> Int? {
        let exact = candidates.indices.filter { candidates[$0].id == id }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        // Some providers cannot expose a window number. A unique matching
        // window frame can retain their old AX-window path; never break ties
        // with stale titles, ordering or the nearest unrelated window.
        let fallback = candidates.indices.filter { i in
            let c = candidates[i]
            return c.id == nil && c.fallbackAllowed &&
                abs(c.frame.minX - frame.minX) <= 1 && abs(c.frame.minY - frame.minY) <= 1 &&
                abs(c.frame.width - frame.width) <= 1 && abs(c.frame.height - frame.height) <= 1
        }
        return fallback.count == 1 ? fallback[0] : nil
    }

    static func allowsFocusedEditorOverlay(role: String, frame: CGRect, anchorFrame: CGRect,
        anchorID: CGWindowID, mainID: CGWindowID?, focused: Bool) -> Bool {
        focused && mainID == anchorID && NativeInteractionExecutor.editable.contains(role) && frame.intersects(anchorFrame)
    }
}
