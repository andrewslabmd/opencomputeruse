import ApplicationServices
import Foundation

// AX ancestry expresses ownership, not visual clipping. Sheets and menus can
// extend past their owning window. Only scroll viewports clip their content;
// nested scroll viewports inherit the intersection, not a fresh larger region.
enum NativeSnapshotViewport {
    static let independent: Set<String> = ["AXWindow", "AXSheet", "AXMenu"]
    /// The clipping that applies to a node itself. Independent UI listed under
    /// a scroll viewport (Finder lists an icon's context menu inside its icon
    /// view) is not clipped by it.
    static func own(role: String, inherited: CGRect?) -> CGRect? {
        independent.contains(role) ? nil : inherited
    }
    static func children(role: String, frame: CGRect?, inherited: CGRect?) -> CGRect? {
        if independent.contains(role) { return nil }
        guard role == "AXScrollArea", let frame else { return inherited }
        return inherited.map { $0.intersection(frame) } ?? frame
    }
}

// Compare native handles, not just their hash. Distinct AX objects can collide.
struct NativeSnapshotElement: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

private struct SnapshotTraversalFrame<Element, Input, Output> {
    let element: Element
    let input: Input
    let depth: Int
    let children: [Element]
    var nextChild = 0
    var outputs: [Output] = []
}

// Iterative postorder avoids a traversal depth ceiling and native stack growth.
// Inventory every root before entering document content. Nothing is published
// if a read/cancellation fails; cycles/shared references are visited once.
struct NativeSnapshotTraversal<Element: Hashable, Input, Output> {
    let checkCancellation: () throws -> Void
    let read: (Element, Input?) throws -> Input
    let children: (Input) -> [Element]
    let encode: (Element, Input, Int, [Output]) throws -> Output?

    func collect(_ roots: [Element]) throws -> [Output?] {
        var seen = Set<Element>()
        var prepared: [SnapshotTraversalFrame<Element, Input, Output>] = []
        for root in roots {
            try checkCancellation()
            guard seen.insert(root).inserted else {
                throw NativeProcessIdentityFailure(message: "The snapshot contains duplicate window roots.")
            }
            let input = try read(root, nil)
            prepared.append(.init(element: root, input: input, depth: 0, children: children(input)))
        }
        var result: [Output?] = []
        for root in prepared {
            var stack = [root]
            while !stack.isEmpty {
                try checkCancellation()
                let i = stack.count - 1
                if stack[i].nextChild < stack[i].children.count {
                    let child = stack[i].children[stack[i].nextChild]
                    stack[i].nextChild += 1
                    guard seen.insert(child).inserted else { continue }
                    let input = try read(child, stack[i].input)
                    stack.append(.init(element: child, input: input, depth: stack[i].depth + 1, children: children(input)))
                } else {
                    let frame = stack.removeLast()
                    let output = try encode(frame.element, frame.input, frame.depth, frame.outputs)
                    if stack.isEmpty { result.append(output) }
                    else if let output { stack[stack.count - 1].outputs.append(output) }
                }
            }
        }
        return result
    }
}

// The request file is the existing caller's cancellation token. IPC timeout,
// disconnect or broker death removes it or changes the owner identity.
struct NativeRequestCancellation {
    let requestURL: URL
    let owner: NativeProcessIdentity
    let parentPID: pid_t

    func check() throws {
        guard FileManager.default.fileExists(atPath: requestURL.path),
              try NativeProcessIdentity.read(owner.pid) == owner,
              try NativeProcessIdentity.read(parentPID) != nil else {
            throw NativeProcessIdentityFailure(message: "The native request was cancelled or its owner exited.")
        }
    }
}
