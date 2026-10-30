import Foundation

// Shared by the opt-in Finder guard and its headless tests. No event contents
// are inspected. A nearby synthetic event never excuses a physical event.
struct LiveTestActivity {
    let helperPID: Int64
    private(set) var qualified = false
    private(set) var stopped = false

    mutating func sample(unlocked: Bool, idle: Double, background: Bool) {
        if qualified && (!unlocked || !background) { stopped = true }
        if !stopped && unlocked && background && idle >= 300 { qualified = true }
    }
    mutating func event(sourcePID: Int64, privateSource: Bool, tag: Int64) {
        let own = sourcePID == helperPID && privateSource && tag != 0
        if qualified && !own { stopped = true }
    }
    mutating func monitorLost() { stopped = true }
}
