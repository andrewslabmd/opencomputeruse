/// Product identity shared by the stream connection and watcher row formatting.
public enum StreamWatchers {
    public static let appClient = "Open Computer Use"
    /// The helper leaves the app's own connection out of `watchers` (by process, not name),
    /// so every name it sends is another program and is shown.
    public static func rowText(_ names: [String]) -> String? {
        let others = Array(Set(names)).sorted()
        return others.isEmpty ? nil : "Watched by " + others.joined(separator: ", ")
    }
}
