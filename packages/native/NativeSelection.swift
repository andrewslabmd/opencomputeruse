import ApplicationServices
import Foundation

struct NativeSelectionPlan {
    let item: NativeInteractionNode
    let receiver: NativeInteractionNode
    let attribute: String
    let membershipOwner: NativeInteractionNode?
    let membershipAttribute: String?
}

enum NativeSelectionResolver {
    // AXSelectedChildren takes an item from AXChildren, not an arbitrary
    // descendant with an AXSelected flag. Collection sections expose their
    // item children while the enclosing collection owns the selection setter.
    static func member(owner: NativeInteractionNode, attribute: String,
        path: [NativeInteractionNode], access: any NativeInteractionAccess) throws -> NativeInteractionNode? {
        let relationship = attribute == "AXSelectedRows" ? "AXRows" : "AXChildren"
        func matches(_ parent: NativeInteractionNode, _ relationship: String) throws -> [NativeInteractionNode] {
            guard let raw = try access.read(parent.id, relationship) else { return [] }
            guard let elements = raw as? [CFTypeRef] else {
                throw NativeInteractionFailure(code: "selection_relationship_unavailable", message: "The selection container returned an invalid item relationship.")
            }
            return try path.filter { node in
                let element = try access.element(node.id)
                return elements.contains { CFEqual($0, element) }
            }
        }
        if relationship == "AXRows" {
            let items = try matches(owner, relationship)
            guard items.count <= 1 else {
                throw NativeInteractionFailure(code: "ambiguous_selection_item", message: "More than one row on the target path belongs to this selection container.")
            }
            return items.first
        }
        var parent = owner
        var visited = Set<String>()
        while visited.insert(parent.id).inserted {
            let items = try matches(parent, "AXChildren")
            guard items.count <= 1 else {
                throw NativeInteractionFailure(code: "ambiguous_selection_item", message: "The selection container has conflicting child relationships on the target path.")
            }
            guard let item = items.first else { return nil }
            if owner.role == "AXList", owner.subrole == "AXCollectionList",
               item.role == "AXList", item.subrole == "AXSectionList" {
                try access.validate(item)
                parent = item
                continue
            }
            return item
        }
        throw NativeInteractionFailure(code: "selection_relationship_unavailable", message: "The collection section relationship contains a cycle.")
    }

    static func resolve(chain: [NativeInteractionNode], access: any NativeInteractionAccess) throws -> NativeSelectionPlan? {
        // An image/label inside a real control must reach that control, never
        // select an outer collection instead. Custom AXPress declarations are
        // treated like standard buttons; this inspection is only at action time.
        var path: [NativeInteractionNode] = []
        for node in chain {
            if node.role == "AXWindow" { break }
            if NativeInteractionExecutor.pressable.contains(node.role) ||
               NativeInteractionExecutor.adjustable.contains(node.role) { return nil }
            if NativeInteractionExecutor.editable.contains(node.role),
               try access.canWrite(node.id, "AXSelectedTextRange") { return nil }
            let containers: Set<String> = ["AXList", "AXTable", "AXOutline", "AXGrid", "AXTabGroup", "AXBrowser"]
            // Disabled layout nodes cannot be press receivers. A collection's
            // explicit item relationship is inspected without enumerating its
            // unrelated actions. Some providers cannot enumerate layout actions.
            if !containers.contains(node.role),
               (try access.read(node.id, "AXEnabled") as? NSNumber)?.boolValue != false,
               try access.actionNames(node.id).contains("AXPress") { return nil }
            path.append(node)
            // The first actual selection receiver owns the item relationship.
            // Readable AXSelected=false is deliberately not eligibility evidence.
            for attribute in ["AXSelectedRows", "AXSelectedChildren"] {
                guard try access.canWrite(node.id, attribute),
                      let item = try member(owner: node, attribute: attribute,
                        path: Array(path.dropLast()), access: access) else { continue }
                return NativeSelectionPlan(item: item, receiver: node, attribute: attribute,
                    membershipOwner: node, membershipAttribute: attribute)
            }
        }
        // Standalone tabs/selection controls can expose only their own setter.
        for node in path where try access.canWrite(node.id, "AXSelected") {
            return NativeSelectionPlan(item: node, receiver: node, attribute: "AXSelected",
                membershipOwner: nil, membershipAttribute: nil)
        }
        return nil
    }
}
