import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

private struct HelperArguments {
    let parentPID: pid_t
    let commandDirectory: URL

    init?(_ arguments: [String]) {
        func value(after name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let rawParentPID = value(after: "--parent-pid"),
              let parentPID = pid_t(rawParentPID),
              let commandDirectory = value(after: "--command-directory")
        else { return nil }

        self.parentPID = parentPID
        self.commandDirectory = URL(fileURLWithPath: commandDirectory, isDirectory: true)
    }
}

private struct PreviewRequest: Decodable {
    let kind: String
    let value: String
    let path: String
    let windowIDs: [CGWindowID]?
}

private struct AppLaunchRequest: Decodable {
    let name: String?
    let bundleIdentifier: String?
    let waitUntilReady: Bool?
}

private struct AccessibilitySnapshotRequest: Decodable {
    let appTarget: String
    let windowTitle: String?
    let windowID: CGWindowID?
}

private struct AccessibilityPointRequest: Decodable {
    let processID: pid_t
    let capturedAt: UInt64
    let windowID: CGWindowID
    let x: Double
    let y: Double
}

private struct AccessibilityInteractionRequest: Decodable {
    let point: AccessibilityPointRequest
    let kind: String
    let elementID: String?
    let text: String?
    let replace: Bool?
    let submit: Bool?
    let inputMethod: String?
    let toX: Double?
    let toY: Double?
    let direction: String?
    let amount: Int?
    let durationMs: Int?
    let clickCount: Int?
    let modifiers: [String]?
    let actionName: String?
}

private struct AccessibilitySnapshotFrame: Encodable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

private struct AccessibilitySnapshotNode: Encodable {
    let id: String
    let role: String
    let subrole: String?
    let name: String?
    let value: AccessibilityControlValue?
    let identifier: String?
    let url: String?
    let document: String?
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let selection_range: AccessibilityTextRange?
    let selection_style: [AccessibilitySelectionStyle]?
    let frame: AccessibilitySnapshotFrame?
    let offscreen: Bool?
    let children: [AccessibilitySnapshotNode]?
}

private struct AccessibilitySnapshotApp: Encodable {
    let name: String
    let bundleIdentifier: String?
    let pid: pid_t
}

private struct AccessibilitySnapshotWindow: Encodable {
    let windowID: CGWindowID
    let title: String?
    let frame: AccessibilitySnapshotFrame
    let zIndex: Int
    let tree: AccessibilitySnapshotNode
}

private struct AccessibilitySnapshotSurface: Encodable {
    let frame: AccessibilitySnapshotFrame
    let windows: [AccessibilitySnapshotWindow]
    let captureWindowIDs: [CGWindowID]
    let anchorWindowID: CGWindowID?
    let closedWindowID: CGWindowID?
    let unavailableWindowID: CGWindowID?
    var processExited: Bool? = nil
    var unavailable: Bool? = nil
}

private struct AccessibilitySnapshotPreservation: Encodable {
    let frontmostApplicationUnchanged: Bool
    let physicalPointerUnchanged: Bool
}

private struct TargetedAccessibilitySnapshot: Encodable {
    let app: AccessibilitySnapshotApp
    let surface: AccessibilitySnapshotSurface
    let capturedAt: UInt64
    let nodeCount: Int
    let preservation: AccessibilitySnapshotPreservation?
}

private struct ApplicationSurfaceWindow {
    let element: AXUIElement
    let windowID: CGWindowID
    let title: String?
    let frame: CGRect
    let zIndex: Int
}

private struct ApplicationSurfaceCaptureWindow {
    let windowID: CGWindowID
    let frame: CGRect
    let zIndex: Int
}

private struct ApplicationSurface {
    let accessibilityWindows: [ApplicationSurfaceWindow]
    let captureWindows: [ApplicationSurfaceCaptureWindow]
    let frame: CGRect
}

private struct ComputerUsePermissionStatus: Encodable {
    let name: String
    let isGranted: Bool
    let isRequired: Bool
    let grantInstructions: String
}

private struct HelperRequest: Decodable {
    let id: String
    let action: String
    let preview: PreviewRequest?
    let appLaunch: AppLaunchRequest?
    let accessibilitySnapshot: AccessibilitySnapshotRequest?
    let accessibilityInteraction: AccessibilityInteractionRequest?
    let processID: pid_t?
    let capturedAt: UInt64?
    let ownerProcessID: pid_t?
    let focusToken: String?
    let keys: [String]?
    let inputTraceIDs: [String]?
    let keyboardElementID: String?
    let sinceMs: UInt64?
    let appTarget: String?
}

private struct HelperResponse: Encodable {
    let id: String
    let granted: Bool?
    let success: Bool?
    let stdout: String?
    let stderr: String?
    let error: String?
    var retrySnapshotIdentity: NativeProcessIdentity? = nil
    enum CodingKeys: String, CodingKey { case id, granted, success, stdout, stderr, error }
}

private final class ComputerUseHelper {
    private let arguments: HelperArguments
    private let fileManager = FileManager.default
    private var stopping = false
    private let nativeQueue = DispatchQueue(label: "OpenComputerUse.native-commands")
    private var queuedNativeRequests = Set<URL>() // main-thread scheduling only
    private var nativeCancellation: NativeRequestCancellation? // native queue only
    private var nextElementIdentity: UInt64 = 0
    private var identityReuseBuckets: [CFHashCode: [(String, AXUIElement)]] = [:]
    private var snapshotElements: [String: AXUIElement] = [:]
    private var snapshotProcessID: pid_t?
    private var snapshotCapturedAt: UInt64?
    private var snapshotWindows: [CGWindowID: NativeInteractionNode] = [:]
    private var snapshotKeyboardWindowIDs = Set<CGWindowID>()
    private var snapshotKeyboardReceiver: NativeKeyboardReceiver<AXUIElement>?
    private var snapshotProcessIdentity: NativeProcessIdentity?
    // Each agent (owner process) has its own latest observation: the handles,
    // windows and keyboard scope its actions are validated against. Native
    // requests run one at a time on nativeQueue; the owner's state is loaded
    // before its request and parked when another owner's request runs.
    private struct SnapshotState {
        var elements: [String: AXUIElement] = [:]
        var processID: pid_t?
        var capturedAt: UInt64?
        var windows: [CGWindowID: NativeInteractionNode] = [:]
        var keyboardWindowIDs = Set<CGWindowID>()
        var keyboardReceiver: NativeKeyboardReceiver<AXUIElement>?
        var processIdentity: NativeProcessIdentity?
    }
    private var snapshotOwner: NativeProcessIdentity? // native queue only
    private var parkedSnapshots: [pid_t: (owner: NativeProcessIdentity, state: SnapshotState)] = [:] // native queue only
    private let backgroundFocus = BackgroundAppFocus(access: AXBackgroundAppFocusAccess())
    private let webAccessibility = WebAccessibilityMode(access: AXWebAccessibilityAccess()) // native queue only
    private let foregroundGuard = ForegroundGuard(access: SystemForegroundGuardAccess())

    init(arguments: HelperArguments) {
        self.arguments = arguments
    }

    func run() throws {
        try self.prepareDirectories()
        NativeKeyboardInput.shared.configureJournal(self.arguments.commandDirectory.deletingLastPathComponent().appendingPathComponent("input-audit.jsonl"))
        self.backgroundFocus.monitorUserActivation()
        ForegroundGuard.shared = self.foregroundGuard

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { [weak self] in self?.stopping = true }
        signalSource.resume()

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler { [weak self] in self?.stopping = true }
        interruptSource.resume()

        while !self.stopping, self.parentIsRunning() {
            self.processPermissionRequests()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        _ = try? self.backgroundFocus.release()
        nativeQueue.sync { NativeKeyboardInput.shared.stopObservers() }
    }

    private func prepareDirectories() throws {
        try self.fileManager.createDirectory(
            at: self.arguments.commandDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func parentIsRunning() -> Bool {
        if kill(self.arguments.parentPID, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func processPermissionRequests() {
        guard let entries = try? self.fileManager.contentsOfDirectory(
            at: self.arguments.commandDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for requestURL in entries where requestURL.pathExtension == "json" && requestURL.lastPathComponent.hasPrefix("request-") {
            self.processPermissionRequest(at: requestURL)
        }
    }

    private func processPermissionRequest(at requestURL: URL) {
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        else {
            try? self.fileManager.removeItem(at: requestURL)
            return
        }

        let controlActions = ["permissionStatus", "screenRecording", "accessibility", "eventSynthesizing", "releaseActionFocus", "listApplications", "resolveApplication"]
        if !controlActions.contains(request.action) {
            guard queuedNativeRequests.insert(requestURL).inserted else { return }
            let owner: NativeProcessIdentity?
            do { owner = try request.ownerProcessID.flatMap { try NativeProcessIdentity.read($0) } }
            catch { self.writeResponse(self.captureResponse(id: request.id, error: error.localizedDescription), at: requestURL); queuedNativeRequests.remove(requestURL); return }
            guard let owner else {
                self.writeResponse(self.captureResponse(id: request.id, error: "The native request owner exited."), at: requestURL)
                queuedNativeRequests.remove(requestURL); return
            }
            nativeQueue.async { [self] in
                let cancellation = NativeRequestCancellation(requestURL: requestURL, owner: owner, parentPID: arguments.parentPID)
                nativeCancellation = cancellation
                defer {
                    nativeCancellation = nil
                    DispatchQueue.main.async { self.queuedNativeRequests.remove(requestURL) }
                }
                do {
                    try cancellation.check()
                    self.loadSnapshot(for: owner)
                    let response = self.nativeResponse(request)
                    try cancellation.check()
                    self.writeResponse(response, at: requestURL)
                } catch {
                    // No late cache can survive a cancelled collector. The owner
                    // cannot act with a partial or previously retained snapshot.
                    self.invalidateSnapshot()
                    if FileManager.default.fileExists(atPath: requestURL.path) {
                        self.writeResponse(self.captureResponse(id: request.id, error: error.localizedDescription), at: requestURL)
                    }
                }
            }
            return
        }
        self.writeResponse(self.nativeResponse(request), at: requestURL)
    }

    private func nativeResponse(_ request: HelperRequest) -> HelperResponse {
        // App launches can bring a launched app forward; posted input is armed in the dispatcher.
        let launching = request.action == "launchApplication"
        if launching { foregroundGuard.arm(target: nil) }
        defer { if launching { foregroundGuard.settle() } }
        let response: HelperResponse
        switch request.action {
        case "permissionStatus":
            response = self.permissionStatus(id: request.id)
        case "listApplications":
            if let data = try? JSONEncoder().encode(NativeAppList.current()) {
                response = HelperResponse(id: request.id, granted: nil, success: true, stdout: String(data: data, encoding: .utf8), stderr: nil, error: nil)
            } else { response = self.captureResponse(id: request.id, error: "Could not encode the application list") }
        case "resolveApplication":
            // Read-only: which running process an app target names, if any.
            let pid = request.appTarget.flatMap { NativeAppTarget.resolve($0) }
            response = HelperResponse(id: request.id, granted: nil, success: true, stdout: "{\"pid\":\(pid.map { String($0) } ?? "null")}", stderr: nil, error: nil)
        case "screenRecording":
            response = HelperResponse(
                id: request.id,
                granted: CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess(),
                success: nil,
                stdout: nil,
                stderr: nil,
                error: nil
            )
        case "accessibility":
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            response = HelperResponse(
                id: request.id,
                granted: AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options),
                success: nil,
                stdout: nil,
                stderr: nil,
                error: nil
            )
        case "eventSynthesizing":
            response = HelperResponse(
                id: request.id,
                granted: CGPreflightPostEventAccess() || CGRequestPostEventAccess(),
                success: nil,
                stdout: nil,
                stderr: nil,
                error: nil
            )
        case "captureApplicationSurface":
            response = self.captureApplicationSurface(request)
        case "launchApplication":
            response = self.launchApplication(request)
        case "accessibilitySnapshot":
            response = self.accessibilitySnapshot(request)
            if response.success != true { self.invalidateSnapshot() }
        case "accessibilityInteraction":
            response = self.accessibilityInteraction(request)
        case "keyboardTarget":
            response = self.keyboardTarget(request)
        case "sendHotkey":
            response = self.sendHotkey(request)
        case "inputDelivery":
            do {
                let data=try JSONEncoder().encode(NativeKeyboardInput.shared.receipts(request.inputTraceIDs ?? []))
                response=HelperResponse(id:request.id,granted:nil,success:true,stdout:String(data:data,encoding:.utf8),stderr:nil,error:nil)
            }catch{response=self.captureResponse(id:request.id,error:error.localizedDescription)}
        case "foregroundGuardEvents":
            let data = try? JSONEncoder().encode(foregroundGuard.events(since: request.sinceMs ?? 0))
            response = HelperResponse(id: request.id, granted: nil, success: data != nil, stdout: data.flatMap { String(data: $0, encoding: .utf8) }, stderr: nil, error: nil)
        case "inputAuditStatus":
            var state:[String:Any]=["input_posted":false,"accessibility_granted":AXIsProcessTrusted(),"listen_event_access":CGPreflightListenEventAccess()]
            do{state.merge(try NativeKeyboardInput.shared.probe(pid:request.processID ?? getpid())){_,new in new}}
            catch{state["observer_available"]=false;state["error"]=error.localizedDescription}
            let data=try? JSONSerialization.data(withJSONObject:state)
            response=HelperResponse(id:request.id,granted:nil,success:true,stdout:data.flatMap{String(data:$0,encoding:.utf8)},stderr:nil,error:nil)
        case "beginActionFocus":
            response = self.actionFocus(request, begin: true)
        case "endActionFocus":
            response = self.actionFocus(request, begin: false)
        case "releaseActionFocus":
            do {
                guard let owner = request.ownerProcessID else { throw BackgroundAppFocusFailure(message: "Missing action owner.") }
                _ = try self.backgroundFocus.release(owner: owner)
                // Input observers serve every agent's dispatch; they start again on demand.
                nativeQueue.async { if !self.backgroundFocus.hasLeases { NativeKeyboardInput.shared.stopObservers() } }
                response = HelperResponse(id: request.id, granted: nil, success: true, stdout: "{}", stderr: nil, error: nil)
            } catch { response = self.captureResponse(id: request.id, error: error.localizedDescription) }
        default:
            response = HelperResponse(
                id: request.id,
                granted: nil,
                success: nil,
                stdout: nil,
                stderr: nil,
                error: "Unsupported Computer Use permission"
            )
        }

        return response
    }

    private func writeResponse(_ response: HelperResponse, at requestURL: URL) {
        let responseURL = self.arguments.commandDirectory.appendingPathComponent("response-\(response.id).json")
        let temporaryURL = responseURL.appendingPathExtension("tmp")
        if let encoded = try? JSONEncoder().encode(response) {
            try? encoded.write(to: temporaryURL, options: .atomic)
            try? self.fileManager.moveItem(at: temporaryURL, to: responseURL)
        }
        try? self.fileManager.removeItem(at: requestURL)
    }

    private func permissionStatus(id: String) -> HelperResponse {
        // The helper runs as the app's child, so macOS lists its grants under the app.
        let helperName = "Open Computer Use"
        let permissions = [
            ComputerUsePermissionStatus(
                name: "Screen Recording",
                isGranted: CGPreflightScreenCaptureAccess(),
                isRequired: true,
                grantInstructions: "Allow \(helperName) in Privacy & Security > Screen & System Audio Recording."
            ),
            ComputerUsePermissionStatus(
                name: "Accessibility",
                isGranted: AXIsProcessTrusted(),
                isRequired: true,
                grantInstructions: "Allow \(helperName) in Privacy & Security > Accessibility."
            ),
            ComputerUsePermissionStatus(
                name: "Event Synthesizing",
                isGranted: CGPreflightPostEventAccess(),
                isRequired: false,
                grantInstructions: "Allow \(helperName) in Privacy & Security > Accessibility when foreground input is requested."
            ),
        ]
        guard let encoded = try? JSONEncoder().encode(permissions),
              let output = String(data: encoded, encoding: .utf8)
        else {
            return self.captureResponse(id: id, error: "Could not encode Computer Use permission status")
        }
        return HelperResponse(
            id: id,
            granted: nil,
            success: true,
            stdout: output,
            stderr: nil,
            error: nil
        )
    }

    private func captureApplicationSurface(_ request: HelperRequest) -> HelperResponse {
        guard CGPreflightScreenCaptureAccess() else {
            return self.captureResponse(id: request.id, error: "Screen Recording permission is required")
        }
        guard let preview = request.preview,
              let processID = self.resolvePreviewProcessID(preview),
              kill(processID, 0) == 0
        else {
            return self.captureResponse(id: request.id, error: "Invalid application-surface target")
        }
        let cacheDirectory = self.arguments.commandDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("observations", isDirectory: true)
            .standardizedFileURL
        let destination = URL(fileURLWithPath: preview.path).standardizedFileURL
        guard destination.deletingLastPathComponent() == cacheDirectory else {
            return self.captureResponse(id: request.id, error: "Invalid application-surface destination")
        }
        let discovered: ApplicationSurface?
        do { discovered = try self.applicationSurface(processID: processID, requestedTitle: nil) }
        catch { return self.captureResponse(id: request.id, error: error.localizedDescription) }
        guard let discoveredSurface = discovered else {
            return self.captureResponse(id: request.id, error: "The application has no observable on-screen windows")
        }
        let discoveredWindows = discoveredSurface.captureWindows
        let requestedWindowIDs = Set(preview.windowIDs ?? [])
        let windows = requestedWindowIDs.isEmpty
            ? discoveredWindows
            : discoveredWindows.filter { requestedWindowIDs.contains($0.windowID) }
        guard !windows.isEmpty else {
            return self.captureResponse(id: request.id, error: "The application has no observable on-screen windows")
        }
        let surfaceFrame = windows
            .map(\.frame)
            .dropFirst()
            .reduce(windows[0].frame) { $0.union($1) }
        let width = max(Int(surfaceFrame.width.rounded(.up)), 1)
        let height = max(Int(surfaceFrame.height.rounded(.up)), 1)
        guard width <= 16_384, height <= 16_384,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return self.captureResponse(id: request.id, error: "Could not allocate the application-surface image")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        guard let shareableContent = self.shareableContent(),
              !shareableContent.windows.isEmpty
        else {
            NSGraphicsContext.restoreGraphicsState()
            return self.captureResponse(id: request.id, error: "ScreenCaptureKit could not enumerate shareable windows")
        }
        let captureWindowIDs = Set(windows.map(\.windowID))
        let shareableWindows = shareableContent.windows.filter {
            captureWindowIDs.contains($0.windowID)
        }
        guard !shareableWindows.isEmpty else {
            NSGraphicsContext.restoreGraphicsState()
            return self.captureResponse(id: request.id, error: "ScreenCaptureKit could not resolve the application-surface windows")
        }
        var capturedDisplayCount = 0
        for display in shareableContent.displays {
            let intersection = display.frame.intersection(surfaceFrame)
            let displayWindows = shareableWindows.filter { $0.frame.intersects(display.frame) }
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0,
                  !displayWindows.isEmpty,
                  let image = self.captureImage(
                      on: display,
                      windows: displayWindows,
                      sourceRect: CGRect(
                          x: intersection.minX - display.frame.minX,
                          y: intersection.minY - display.frame.minY,
                          width: intersection.width,
                          height: intersection.height
                      )
                  )
            else { continue }
            let destinationRect = NSRect(
                x: intersection.minX - surfaceFrame.minX,
                y: surfaceFrame.maxY - intersection.maxY,
                width: intersection.width,
                height: intersection.height
            )
            let displayImage = NSImage(cgImage: image, size: destinationRect.size)
            displayImage.draw(
                in: destinationRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            capturedDisplayCount += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        guard capturedDisplayCount > 0 else {
            return self.captureResponse(id: request.id, error: "Could not capture any application-surface windows")
        }

        let isPNG = destination.pathExtension.compare("png", options: .caseInsensitive) == .orderedSame
        let imageData = bitmap.representation(
            using: isPNG ? .png : .jpeg,
            properties: isPNG ? [:] : [.compressionFactor: 0.86]
        )
        guard let imageData else {
            return self.captureResponse(id: request.id, error: "Could not encode the application-surface image")
        }
        do {
            try self.fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try imageData.write(to: destination, options: .atomic)
        } catch {
            return self.captureResponse(id: request.id, error: error.localizedDescription)
        }
        // Capture does not activate an app or generate input. Concurrent human
        // cursor/focus changes are expected during background operation and do
        // not invalidate the captured app-window image.
        let metadata: [String: Any] = [
            "success": true,
            "data": [
                "observations": [[
                    "coordinates": [
                        "image_size_pixels": ["width": width, "height": height],
                        "logical_bounds": [
                            [surfaceFrame.minX, surfaceFrame.minY],
                            [surfaceFrame.width, surfaceFrame.height],
                        ],
                    ],
                    "window_count": shareableWindows.count,
                ]],
            ],
        ]
        guard let metadataData = try? JSONSerialization.data(withJSONObject: metadata),
              let stdout = String(data: metadataData, encoding: .utf8)
        else {
            try? self.fileManager.removeItem(at: destination)
            return self.captureResponse(id: request.id, error: "Could not encode application-surface metadata")
        }
        return HelperResponse(
            id: request.id,
            granted: nil,
            success: true,
            stdout: stdout,
            stderr: nil,
            error: nil
        )
    }

    private func shareableContent() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) { content, _ in
            result = content
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return nil }
        return result
    }

    private func captureImage(
        on display: SCDisplay,
        windows: [SCWindow],
        sourceRect: CGRect
    ) -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(Int(sourceRect.width.rounded(.up)), 1)
        configuration.height = max(Int(sourceRect.height.rounded(.up)), 1)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, including: windows)
        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { image, _ in
            result = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return nil }
        return result
    }

    private func resolvePreviewProcessID(_ preview: PreviewRequest) -> pid_t? {
        switch preview.kind {
        case "pid":
            return pid_t(preview.value)
        case "app":
            return self.resolveProcessID(preview.value)
        case "window":
            guard let windowID = CGWindowID(preview.value),
                  let windows = CGWindowListCopyWindowInfo(
                      [.optionIncludingWindow],
                      windowID
                  ) as? [[String: Any]],
                  let processID = (windows.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { return nil }
            return processID
        default:
            return nil
        }
    }

    private func loadSnapshot(for owner: NativeProcessIdentity) {
        guard snapshotOwner != owner else { return }
        if let current = snapshotOwner {
            parkedSnapshots[current.pid] = (current, SnapshotState(elements: snapshotElements, processID: snapshotProcessID,
                capturedAt: snapshotCapturedAt, windows: snapshotWindows, keyboardWindowIDs: snapshotKeyboardWindowIDs,
                keyboardReceiver: snapshotKeyboardReceiver, processIdentity: snapshotProcessIdentity))
        }
        let parked = parkedSnapshots.removeValue(forKey: owner.pid)
        // A later process reusing an exited agent's PID never inherits its handles.
        let state = parked.flatMap { $0.owner == owner ? $0.state : nil } ?? SnapshotState()
        snapshotElements = state.elements; snapshotProcessID = state.processID; snapshotCapturedAt = state.capturedAt
        snapshotWindows = state.windows; snapshotKeyboardWindowIDs = state.keyboardWindowIDs
        snapshotKeyboardReceiver = state.keyboardReceiver; snapshotProcessIdentity = state.processIdentity
        snapshotOwner = owner
        parkedSnapshots = parkedSnapshots.filter { (try? NativeProcessIdentity.read($0.key)) == $0.value.owner }
    }

    private func invalidateSnapshot() {
        snapshotElements.removeAll(); snapshotWindows.removeAll(); snapshotKeyboardWindowIDs.removeAll()
        snapshotKeyboardReceiver = nil
        snapshotProcessID = nil; snapshotCapturedAt = nil; snapshotProcessIdentity = nil
    }

    private func exitedSnapshot(_ request: HelperRequest, processID: pid_t) -> HelperResponse {
        self.invalidateSnapshot()
        let result = TargetedAccessibilitySnapshot(
            app: .init(name: request.accessibilitySnapshot?.appTarget ?? "Exited application", bundleIdentifier: nil, pid: processID),
            surface: .init(frame: .init(x: 0, y: 0, w: 0, h: 0), windows: [], captureWindowIDs: [],
                anchorWindowID: nil, closedWindowID: nil, unavailableWindowID: nil, processExited: true),
            capturedAt: UInt64(Date().timeIntervalSince1970 * 1000), nodeCount: 0,
            preservation: nil)
        guard let data = try? JSONEncoder().encode(result), let output = String(data: data, encoding: .utf8) else {
            return self.captureResponse(id: request.id, error: "Could not encode the process exit observation.")
        }
        return HelperResponse(id: request.id, granted: nil, success: true, stdout: output, stderr: nil, error: nil)
    }

    private func accessibilitySnapshot(_ request: HelperRequest) -> HelperResponse {
        var pinned: NativeProcessIdentity?
        var restarts = 0
        while true {
            var response = self.accessibilitySnapshotAttempt(request, retryIdentity: pinned)
            guard let retry = response.retrySnapshotIdentity else {
                if restarts > 0, response.success == true, let text = response.stdout,
                   var result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    result["collectionRestarts"] = restarts
                    if let bytes = try? JSONSerialization.data(withJSONObject: result) {
                        response = HelperResponse(id: response.id, granted: response.granted, success: response.success,
                            stdout: String(data: bytes, encoding: .utf8), stderr: response.stderr, error: response.error)
                    }
                }
                return response
            }
            pinned = retry; restarts += 1
            do { try nativeCancellation?.check() }
            catch { return captureResponse(id: request.id, error: error.localizedDescription) }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    private func accessibilitySnapshotAttempt(_ request: HelperRequest, retryIdentity: NativeProcessIdentity?) -> HelperResponse {
        guard AXIsProcessTrusted() else {
            return self.captureResponse(
                id: request.id,
                error: "Accessibility permission is required for a targeted accessibility snapshot"
            )
        }
        guard let snapshot = request.accessibilitySnapshot,
              !snapshot.appTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let processID = self.resolveProcessID(snapshot.appTarget)
        else {
            return self.captureResponse(id: request.id, error: "Invalid accessibility snapshot target")
        }
        let expectedIdentity: NativeProcessIdentity?
        if let retryIdentity { expectedIdentity = retryIdentity }
        else if let stamp = request.capturedAt {
            guard stamp == snapshotCapturedAt, processID == snapshotProcessID, let identity = snapshotProcessIdentity else {
                return self.captureResponse(id: request.id, error: "The post-action observation generation expired.")
            }
            expectedIdentity = identity
        } else { expectedIdentity = nil }
        let processIdentity: NativeProcessIdentity
        do {
            guard let identity = try NativeProcessIdentity.read(processID) else {
                if expectedIdentity != nil { return self.exitedSnapshot(request, processID: processID) }
                return self.captureResponse(id: request.id, error: "The accessibility target process exited.")
            }
            guard expectedIdentity == nil || expectedIdentity == identity else {
                self.invalidateSnapshot()
                return self.captureResponse(id: request.id, error: "The observed process was replaced. Observe the new process explicitly.")
            }
            processIdentity = identity
        } catch { self.invalidateSnapshot(); return self.captureResponse(id: request.id, error: error.localizedDescription) }
        if let owner = request.ownerProcessID {
            do { try backgroundFocus.releaseIfTargetChanged(identity: processIdentity, owner: owner) }
            catch { return self.captureResponse(id: request.id, error: error.localizedDescription) }
        }

        // Electron web content drops AXPress until complete mode is applied.
        // Wait out the provider's own debounce once per process, cancellably,
        // so the first published tree's presses can reach the page.
        do {
            if let remaining = try webAccessibility.prepare(processIdentity), remaining > 0 {
                let ready = Date(timeIntervalSinceNow: remaining)
                while Date() < ready {
                    try nativeCancellation?.check()
                    Thread.sleep(forTimeInterval: min(0.025, max(0, ready.timeIntervalSinceNow)))
                }
            }
        } catch { return self.captureResponse(id: request.id, error: error.localizedDescription) }

        let requestedWindowTitle = snapshot.windowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let frontmostBefore = NativeAppTarget.frontmostPID()
        let pointerBefore = NSEvent.mouseLocation
        let surface: ApplicationSurface?
        do {
            surface = try self.applicationSurface(processID: processID, requestedTitle: requestedWindowTitle, requestedWindowID: snapshot.windowID)
        } catch { return self.snapshotReadFailure(request, error: error, identity: processIdentity) }
        if surface == nil, snapshot.windowID != nil || requestedWindowTitle?.isEmpty != false {
            // This pinned window currently has no observable surface. Hidden,
            // cached and animating windows can disagree across AX/Window Server;
            // unavailable does not assert absence. Claim destruction only when
            // a successful Window Server inventory confirms the ID is gone.
            let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
            let id = snapshot.windowID
            let closed = id.map { id in windows.map { list in !list.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) } ?? false } ?? false
            self.snapshotElements.removeAll(); self.snapshotWindows.removeAll(); self.snapshotKeyboardWindowIDs.removeAll()
            self.snapshotKeyboardReceiver = nil
            let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
            self.snapshotProcessID = processID; self.snapshotCapturedAt = stamp
            self.snapshotProcessIdentity = processIdentity
            let result = TargetedAccessibilitySnapshot(
                app: .init(name: NSRunningApplication(processIdentifier: processID)?.localizedName ?? snapshot.appTarget,
                    bundleIdentifier: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier, pid: processID),
                surface: .init(frame: .init(x: 0, y: 0, w: 0, h: 0), windows: [], captureWindowIDs: [], anchorWindowID: nil, closedWindowID: closed ? id : nil, unavailableWindowID: closed ? nil : id, unavailable: true),
                capturedAt: stamp, nodeCount: 0, preservation: .init(
                    frontmostApplicationUnchanged: frontmostBefore == NativeAppTarget.frontmostPID(),
                    physicalPointerUnchanged: pointerBefore == NSEvent.mouseLocation))
            let encoded = try? JSONEncoder().encode(result)
            return HelperResponse(id: request.id, granted: nil, success: encoded != nil, stdout: encoded.flatMap { String(data: $0, encoding: .utf8) }, stderr: nil, error: nil)
        }
        if surface == nil, requestedWindowTitle?.isEmpty == false {
            return self.captureResponse(
                id: request.id,
                error: "The requested accessibility window was not found"
            )
        }
        guard let surface, !surface.accessibilityWindows.isEmpty else {
            return self.captureResponse(
                id: request.id,
                error: "The application has no observable on-screen windows"
            )
        }
        let surfaceWindows = surface.accessibilityWindows
        let keyboardWindows = Dictionary(uniqueKeysWithValues: surfaceWindows.map { ($0.windowID, $0.element) })
        let observedKeyboardReceiver = try? readKeyboardReceiver(processID, windows: keyboardWindows)

        let priorElements = self.snapshotProcessIdentity == processIdentity ? self.snapshotElements : [:]
        self.invalidateSnapshot()
        if retryIdentity == nil || !priorElements.isEmpty {
            self.identityReuseBuckets = Dictionary(grouping: priorElements.map { ($0.key, $0.value) }, by: { CFHash($0.1) })
        }
        var nodeCount = 0
        var encodedWindows: [AccessibilitySnapshotWindow] = []
        do {
            let traversal = NativeSnapshotTraversal<NativeSnapshotElement, SnapshotNodeInput, AccessibilitySnapshotNode>(
                checkCancellation: { try self.nativeCancellation?.check() },
                read: { handle, parent in
                    nodeCount += 1
                    _ = AXUIElementSetMessagingTimeout(handle.element, 2)
                    let attributes = try AccessibilitySnapshotAttributes(element: handle.element)
                    return SnapshotNodeInput(id: nodeCount, attributes: attributes,
                        clipRect: parent?.childClipRect)
                },
                children: { $0.attributes.children.map { NativeSnapshotElement(element: $0) } },
                encode: { handle, input, depth, children in
                    self.encodeAccessibilitySnapshotNode(handle.element, input: input, depth: depth, children: children)
                })
            let trees = try traversal.collect(surfaceWindows.map { NativeSnapshotElement(element: $0.element) })
            for (window, tree) in zip(surfaceWindows, trees) {
                guard let tree else { throw NativeProcessIdentityFailure(message: "A requested window produced no usable tree.") }
                encodedWindows.append(.init(windowID: window.windowID, title: window.title,
                    frame: self.snapshotFrame(window.frame), zIndex: window.zIndex, tree: tree))
            }
        } catch {
            // A provider read may lose the app mid-collection. Only a definite
            // kernel exit makes this a terminal observation; lookup failures
            // and process replacement remain observation errors.
            do {
                try self.nativeCancellation?.check()
                if try NativeProcessIdentity.read(processID) == nil { return self.exitedSnapshot(request, processID: processID) }
            } catch { /* no terminal state inferred from failed identity/cancellation */ }
            return self.snapshotReadFailure(request, error: error, identity: processIdentity)
        }
        guard !encodedWindows.isEmpty else {
            return self.captureResponse(id: request.id, error: "The application surface produced no usable nodes")
        }
        do {
            guard let current = try NativeProcessIdentity.read(processID) else {
                return self.exitedSnapshot(request, processID: processID)
            }
            guard current == processIdentity else {
                self.invalidateSnapshot()
                return self.captureResponse(id: request.id, error: "The accessibility target process changed during collection.")
            }
            try self.nativeCancellation?.check()
        } catch {
            self.snapshotElements.removeAll()
            return self.captureResponse(id: request.id, error: error.localizedDescription)
        }
        let runningApplication = NSRunningApplication(processIdentifier: processID)
        var retainedIDs = Set<String>()
        func retainIDs(_ node: AccessibilitySnapshotNode) {
            retainedIDs.insert(node.id)
            for child in node.children ?? [] { retainIDs(child) }
        }
        for window in encodedWindows { retainIDs(window.tree) }
        self.snapshotElements = self.snapshotElements.filter { retainedIDs.contains($0.key) }
        let capturedAt = UInt64(Date().timeIntervalSince1970 * 1_000)
        let result = TargetedAccessibilitySnapshot(
            app: AccessibilitySnapshotApp(
                name: runningApplication?.localizedName ?? snapshot.appTarget,
                bundleIdentifier: runningApplication?.bundleIdentifier,
                pid: processID
            ),
            surface: AccessibilitySnapshotSurface(
                frame: self.snapshotFrame(surface.frame),
                windows: encodedWindows,
                captureWindowIDs: surface.captureWindows.map(\.windowID),
                anchorWindowID: snapshot.windowID ?? requestedWindowTitle.flatMap { title in
                    encodedWindows.filter { $0.title?.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                        .max(by: { $0.frame.w * $0.frame.h < $1.frame.w * $1.frame.h })?.windowID
                }, closedWindowID: nil, unavailableWindowID: nil
            ),
            capturedAt: capturedAt,
            nodeCount: nodeCount,
            preservation: AccessibilitySnapshotPreservation(
                frontmostApplicationUnchanged: frontmostBefore
                    == NativeAppTarget.frontmostPID(),
                physicalPointerUnchanged: pointerBefore == NSEvent.mouseLocation
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(result),
              let output = String(data: encoded, encoding: .utf8)
        else {
            return self.captureResponse(id: request.id, error: "Could not encode the accessibility snapshot")
        }
        self.snapshotProcessID = processID
        self.snapshotCapturedAt = capturedAt
        func interactionNode(_ node: AccessibilitySnapshotNode) -> NativeInteractionNode {
            NativeInteractionNode(id: node.id, role: node.role, subrole: node.subrole,
                frame: node.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) },
                children: (node.children ?? []).map(interactionNode), offscreen: node.offscreen ?? false, name: node.name)
        }
        self.snapshotWindows = Dictionary(uniqueKeysWithValues: encodedWindows.map { ($0.windowID, interactionNode($0.tree)) })
        self.snapshotKeyboardWindowIDs = result.surface.anchorWindowID.map { Set([$0]) } ?? Set(encodedWindows.map(\.windowID))
        if let anchorID = result.surface.anchorWindowID,
           let anchor = surfaceWindows.first(where: { $0.windowID == anchorID }) {
            let application = AXUIElementCreateApplication(processID)
            let mainID = self.accessibilityElementAttribute(application, "AXMainWindow" as CFString).flatMap(NativeWindowIdentity.read)
            let focused = self.accessibilityElementAttribute(application, "AXFocusedUIElement" as CFString)
            for window in surfaceWindows {
                let role = self.stringAttribute(window.element, kAXRoleAttribute as CFString) ?? ""
                if NativeWindowIdentity.read(window.element) == window.windowID,
                   NativeWindowIdentity.allowsFocusedEditorOverlay(role: role, frame: window.frame, anchorFrame: anchor.frame,
                       anchorID: anchorID, mainID: mainID, focused: focused.map { CFEqual($0, window.element) } ?? false) {
                    self.snapshotKeyboardWindowIDs.insert(window.windowID)
                }
            }
        }
        self.snapshotProcessIdentity = processIdentity
        // A focus transition during collection does not invalidate the AX tree,
        // but it cannot authorize a shortcut to an unobserved receiver.
        let currentKeyboardReceiver = try? readKeyboardReceiver(processID, windows: keyboardWindows)
        if let observedKeyboardReceiver,
           snapshotKeyboardWindowIDs.contains(observedKeyboardReceiver.windowID),
           observedKeyboardReceiver.matches(currentKeyboardReceiver, equal: { CFEqual($0, $1) }) {
            snapshotKeyboardReceiver = observedKeyboardReceiver
        } else { snapshotKeyboardReceiver = nil }
        return HelperResponse(
            id: request.id,
            granted: nil,
            success: true,
            stdout: output,
            stderr: nil,
            error: nil
        )
    }

    private func snapshotReadFailure(_ request: HelperRequest, error: Error, identity: NativeProcessIdentity) -> HelperResponse {
        self.invalidateSnapshot()
        var failure = self.captureResponse(id: request.id, error: error.localizedDescription)
        if (error as? AccessibilitySnapshotAttributes.ReadFailure)?.nativeError == .invalidUIElement,
           (try? NativeProcessIdentity.read(identity.pid)) == identity {
            do {
                try nativeCancellation?.check()
                failure.retrySnapshotIdentity = identity
            } catch { return self.captureResponse(id: request.id, error: error.localizedDescription) }
        }
        return failure
    }

    private func accessibilityInteraction(_ request: HelperRequest) -> HelperResponse {
        do {
            guard AXIsProcessTrusted(), let action = request.accessibilityInteraction else {
                throw NativeInteractionFailure(code: "permission_required", message: "Accessibility permission and a spatial action are required.")
            }
            let point = action.point
            let location = CGPoint(x: point.x, y: point.y)
            guard point.x.isFinite, point.y.isFinite,
                  point.processID == self.snapshotProcessID, point.capturedAt == self.snapshotCapturedAt,
                  let identity = self.snapshotProcessIdentity,
                  try NativeProcessIdentity.read(point.processID) == identity,
                  let root = self.snapshotWindows[point.windowID],
                  let surface = try self.applicationSurface(processID: point.processID, requestedTitle: nil),
                  let window = surface.accessibilityWindows.first(where: { $0.windowID == point.windowID }),
                  window.windowID == point.windowID else {
                throw NativeInteractionFailure(code: "native_target_changed", message: "Native window/process changed or observation expired. Observe again.")
            }
            let application = AXUIElementCreateApplication(point.processID)
            _ = AXUIElementSetMessagingTimeout(application, 2)
            let hit: AXUIElement
            let elementChain = try action.elementID.map {
                try NativePointResolver.elementChain(root: root, elementID: $0, allowOffscreen: action.kind == "scroll_to_visible")
            }
            if let elementID = action.elementID, let observed = elementChain {
                if !observed.allSatisfy({ self.isLive($0, in: window) }),
                   let rebound = self.rebind(observed, in: window, application: application) {
                    for (id, element) in rebound { self.snapshotElements[id] = element }
                }
                guard let exact = self.snapshotElements[elementID], self.element(exact, belongsTo: window) else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "The retained control no longer belongs to the observed window.")
                }
                hit = exact
            } else {
                var found: AXUIElement?
                guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &found) == .success,
                      let found, self.element(found, belongsTo: window) else {
                    throw NativeInteractionFailure(code: "native_target_unavailable", message: "The application cannot resolve this point in the observed window. Use its exact observed element reference.")
                }
                hit = found
            }
            var ids: [String] = []
            var current: AXUIElement? = hit
            var seen: [AXUIElement] = []
            while let element = current {
                try self.nativeCancellation?.check()
                guard !seen.contains(where: { CFEqual($0, element) }) else { break }
                seen.append(element)
                if let id = self.snapshotElements.first(where: { CFEqual($0.value, element) })?.key { ids.append(id) }
                if CFEqual(element, window.element) { break }
                current = self.parent(of: element)
            }
            let pointerAtPoint = action.elementID == nil &&
                (action.kind == "long_press" || (["click", "drag"].contains(action.kind) && action.inputMethod == "pointer"))
            let chain: [NativeInteractionNode]
            if let elementChain {
                chain = elementChain
            } else if pointerAtPoint {
                // Pointer input at a point goes to this window at that point. An
                // element there that the observation cannot name only leaves the
                // result labelled with the window.
                let resolved = (try? NativePointResolver.chain(root: root, nativeHitIDs: ids, point: location)) ?? []
                chain = resolved.isEmpty ? [root] : resolved
            } else {
                chain = try NativePointResolver.chain(root: root, nativeHitIDs: ids, point: location)
            }
            // Window-bound input goes to the native window hosting the receiver. UI
            // observed inside this window but hosted in its own (Chrome's profile
            // bubble) receives it there, not in the window beneath it.
            let inputWindow = self.accessibilityWindowAncestor(of: hit)
                .flatMap { host in surface.accessibilityWindows.first { CFEqual($0.element, host) } } ?? window
            let access = AXNativeInteractionAccess(elements: self.snapshotElements, validateNode: { node, linkedOwner, phase in
                try self.nativeCancellation?.check()
                guard let element = self.snapshotElements[node.id] else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "The native target expired. Observe again.")
                }
                _ = AXUIElementSetMessagingTimeout(element, 2)
                var pid: pid_t = 0
                guard try NativeProcessIdentity.read(point.processID) == identity,
                      AXUIElementGetPid(element, &pid) == .success, pid == point.processID else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "The target process changed. Observe again.")
                }
                guard let role = self.stringAttribute(element, "AXRole" as CFString) else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "\(node.id) (\(node.role)) no longer exists: the app closed or rebuilt it, and no single live control with its role, name and frame was found. Observe again.")
                }
                guard role == node.role else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "\(node.id) changed role from \(node.role) to \(role). Observe again.")
                }
                guard self.element(element, belongsTo: window) else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "\(node.id) is no longer in the observed window. Observe again.")
                }
                // Validate live ancestry, including coarse-hit refinement. Never
                // route a fallback to a sibling or a descendant outside the point.
                var ancestor: AXUIElement? = element
                var related = false
                if let owner = linkedOwner, let ownerElement = self.snapshotElements[owner.id] {
                    for attribute in ["AXVerticalScrollBar", "AXHorizontalScrollBar"] {
                        if let linked = self.accessibilityElementAttribute(ownerElement, attribute as CFString), CFEqual(linked, element) { related = true }
                    }
                    guard related, node.role == "AXScrollBar" else {
                        throw NativeInteractionFailure(code: "native_target_changed", message: "The scrollbar no longer belongs to the requested scroll container.")
                    }
                    // The scroll operation is at the owner's point. Its linked
                    // scrollbar need not contain that point, but must retain its
                    // own live identity, window and geometry.
                }
                for _ in 0..<80 {
                    guard let a = ancestor else { break }
                    if CFEqual(a, hit) { related = true; break }
                    ancestor = self.parent(of: a)
                }
                if !related {
                    ancestor = hit
                    var seen: [AXUIElement] = []
                    while let a = ancestor {
                        try self.nativeCancellation?.check()
                        guard !seen.contains(where: { CFEqual($0, a) }) else { break }; seen.append(a)
                        if CFEqual(a, element) { related = true; break }
                        ancestor = self.parent(of: a)
                    }
                }
                if !related, node.role == "AXMenu" {
                    // Finder's menu children can report a different AXParent menu
                    // handle. Prove membership with the retained menu's live children.
                    related = NativeRelatedUI.menuContains(ancestry: self.liveAncestry(of: hit),
                        children: self.elementsAttribute(element, kAXChildrenAttribute as CFString),
                        equal: { CFEqual($0, $1) })
                }
                if !related, self.accessibilityWindowAncestor(of: hit).map({ !CFEqual($0, window.element) }) ?? true {
                    // UI hosted in its own native window (a context menu, Chrome's
                    // toolbar bubble) has a parent chain that does not reach the
                    // containers it is observed under (see NativeRelatedUI). They
                    // are related only through the exact retained handle observed
                    // inside this window's tree on the hit's live ancestry.
                    if let entry = NativeRelatedUI.observedEntry(liveAncestry: self.retainedAncestry(of: hit), root: root),
                       let path = try? NativePointResolver.elementChain(root: root, elementID: entry, allowOffscreen: true),
                       path.contains(where: { $0.id == node.id }) { related = true }
                }
                guard related else { throw NativeInteractionFailure(code: "native_target_changed", message: "The live native ancestry changed. Observe again.") }
                if phase != .identity, let expected = node.frame {
                    guard let actual = self.frame(of: element),
                          (action.elementID != nil && phase == .point ? NativeValidationPhase.receiver : phase).matches(actual: actual, expected: expected, point: location, linked: linkedOwner != nil) else {
                        throw NativeInteractionFailure(code: "native_target_changed", message: "The target geometry changed. Observe again.")
                    }
                }
            }, refreshNode: { node in
                guard let handle = self.snapshotElements[node.id], let frame = self.frame(of: handle) else {
                    throw NativeInteractionFailure(code: "native_target_changed", message: "The edited control no longer exposes its geometry. Observe again.")
                }
                return NativeInteractionNode(id: node.id, role: node.role, subrole: node.subrole,
                    frame: frame, children: node.children, offscreen: node.offscreen)
            }, checkInput: {
                try self.nativeCancellation?.check()
            }, inputWindowID: inputWindow.windowID, inputWindowFrame: inputWindow.frame)
            var input = NativeInteractionAction(kind: action.kind == "type" && action.inputMethod != "accessibility" ? "input_text" : action.kind, point: location)
            if let x = action.toX, let y = action.toY {
                guard x.isFinite, y.isFinite else { throw NativeInteractionFailure(code: "invalid_drag", message: "Drag destination must be finite.") }
                input.destination = CGPoint(x: x, y: y)
            }
            input.text = action.text ?? ""; input.replace = action.replace ?? false; input.submit = action.submit ?? false
            input.direction = action.direction ?? "down"; input.amount = min(20, max(1, action.amount ?? 3))
            input.pointer = ["click", "drag"].contains(action.kind) && action.inputMethod == "pointer"
            input.clickCount = action.clickCount ?? 1
            input.modifiers = try NativeInputPlan.modifierFlags(action.modifiers ?? [])
            input.actionName = action.actionName
            input.atPoint = action.elementID == nil
            if let ms = action.durationMs {
                guard ms >= 0, Double(ms) / 1000 <= NativePointerGesture.maximumDuration else {
                    throw NativeInteractionFailure(code: "invalid_pointer_duration", message: "Pointer durations must be between 0 and 5000 ms.")
                }
                input.duration = Double(ms) / 1000
            }
            var result: NativeInteractionResult
            do {result = try NativeInteractionExecutor(access: access).execute(input, chain: chain)}
            catch let error as NativeKeyboardDispatchFailure {
                result=NativeInteractionResult(status:"failed",behavior:"keyboard",code:"keyboard_dispatch_failed",error:error.localizedDescription,effect:"change_possible")
                result.input_trace_ids=[error.traceID]
            }
            if result.submit_ready, let id = result.element_id, let element = self.snapshotElements[id] {
                // Return is sent through the existing process-directed keyboard
                // backend only after this exact editable element owns app focus.
                var focused: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(application, "AXFocusedUIElement" as CFString, &focused)
                guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
                      CFEqual(focused, element) else {
                    result.status = "failed"; result.code = "submit_focus_unavailable"
                    result.error = "Text changed, but the exact field could not be confirmed for Return."; result.submit_ready = false
                    return self.interactionResponse(id: request.id, result: result)
                }
            }
            return self.interactionResponse(id: request.id, result: result)
        } catch let failure as NativeInteractionFailure {
            return self.interactionResponse(id: request.id, result: NativeInteractionResult(status: "failed", behavior: "none", code: failure.code, error: failure.message, effect: "unknown"))
        } catch {
            return self.captureResponse(id: request.id, error: error.localizedDescription)
        }
    }

    private func actionFocus(_ request: HelperRequest, begin: Bool) -> HelperResponse {
        do {
            let result: BackgroundAppFocusResult
            if begin {
                guard let pid = request.processID, pid == snapshotProcessID,
                      request.capturedAt == snapshotCapturedAt,
                      let identity = snapshotProcessIdentity,
                      try NativeProcessIdentity.read(pid) == identity,
                      !snapshotWindows.isEmpty, let owner = request.ownerProcessID else {
                    throw BackgroundAppFocusFailure(message: "The background action observation or owner expired.")
                }
                result = try backgroundFocus.begin(pid: pid, owner: owner)
            } else {
                guard let token = request.focusToken, let owner = request.ownerProcessID else { throw BackgroundAppFocusFailure(message: "Missing action focus token or owner.") }
                result = try backgroundFocus.end(token: token, owner: owner)
            }
            let data = try JSONEncoder().encode(result)
            return HelperResponse(id: request.id, granted: nil, success: true,
                stdout: String(data: data, encoding: .utf8), stderr: nil, error: nil)
        } catch { return self.captureResponse(id: request.id, error: error.localizedDescription) }
    }

    private func readKeyboardReceiver(_ pid: pid_t, windows: [CGWindowID: AXUIElement]) throws -> NativeKeyboardReceiver<AXUIElement>? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 2)
        func read(_ name: String) throws -> AXUIElement? {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, name as CFString, &raw)
            if error == .noValue { return nil }
            guard error == .success else {
                throw NativeInteractionFailure(code: "keyboard_receiver_unavailable", message: "Reading \(name) failed (AXError \(error.rawValue)).")
            }
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        let focused = try read("AXFocusedUIElement")
        if let focused, let windowID = NativeWindowIdentity.read(focused) {
            if windows[windowID] != nil {
                return NativeKeyboardReceiver(windowID: windowID, focusedElement: focused)
            }
        }
        let focusWindow: AXUIElement?
        if let ancestor = focused.flatMap({ accessibilityWindowAncestor(of: $0) }) {
            focusWindow = ancestor
        } else { focusWindow = try read("AXFocusedWindow") }
        let windowID = focused.flatMap(NativeWindowIdentity.read)
            ?? focusWindow.flatMap(NativeWindowIdentity.read)
            ?? focusWindow.flatMap { window in windows.first { CFEqual($0.value, window) }?.key }
        if let windowID {
            if windows[windowID] != nil {
                return NativeKeyboardReceiver(windowID: windowID, focusedElement: focused)
            }
        }
        // Finder clears AXFocusedWindow and focuses AXApplication while tracking
        // a context menu. Retain the one live menu inside the allowed window
        // tree, including its exact handle; never fall back to an arbitrary window.
        var menus: [NativeKeyboardMenu<AXUIElement>] = []
        for (id, root) in windows {
            var pending = [root], seen: [CFHashCode: [AXUIElement]] = [:], count = 0
            while let candidate = pending.popLast() {
                try nativeCancellation?.check()
                let hash = CFHash(candidate)
                guard !(seen[hash]?.contains(where: { CFEqual($0, candidate) }) ?? false) else { continue }
                seen[hash, default: []].append(candidate); count += 1
                guard count <= 10_000 else { return nil }
                guard let role = stringAttribute(candidate, kAXRoleAttribute as CFString) else { return nil }
                var rawChildren: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(candidate, kAXChildrenAttribute as CFString, &rawChildren)
                guard [.success, .noValue, .attributeUnsupported, .notImplemented].contains(error) else {
                    throw NativeInteractionFailure(code: "keyboard_receiver_unavailable",
                        message: "Reading live menu children failed (AXError \(error.rawValue)).")
                }
                // An incomplete scan cannot prove that this is the only menu.
                if error == .success, rawChildren != nil, !(rawChildren is [AXUIElement]) { return nil }
                let children = rawChildren as? [AXUIElement] ?? []
                if role == "AXMenu" {
                    // Hidden submenus are excluded, and the top menu owns their keys.
                    var visible = false
                    for child in children {
                        guard let frame = self.frame(of: child) else { return nil }
                        if frame.width > 0 && frame.height > 0 { visible = true }
                    }
                    if visible { menus.append(NativeKeyboardMenu(windowID: id, element: candidate, children: children)) }
                } else { pending.append(contentsOf: children) }
            }
        }
        return NativeKeyboardReceiver.trackingMenu(menus, focused: focused, application: app,
            focusedWindow: focusWindow, ancestry: { self.liveAncestry(of: $0) },
            equal: { CFEqual($0, $1) })
    }

    private func checkedKeyboardReceiver(_ request: HelperRequest) throws -> NativeKeyboardReceiver<AXUIElement> {
        try nativeCancellation?.check()
        guard let pid = request.processID, pid == snapshotProcessID, request.capturedAt == snapshotCapturedAt,
              let identity = snapshotProcessIdentity, try NativeProcessIdentity.read(pid) == identity else {
            throw NativeInteractionFailure(code: "keyboard_target_expired", message: "The retained keyboard observation or process expired. Observe again.")
        }
        let windows = Dictionary(uniqueKeysWithValues: snapshotWindows.compactMap { id, node -> (CGWindowID, AXUIElement)? in
            guard snapshotKeyboardWindowIDs.contains(id), let root = snapshotElements[node.id] else { return nil }
            return (id, root)
        })
        let expected: NativeKeyboardReceiver<AXUIElement>
        if let elementID = request.keyboardElementID {
            // Submit binds the edited control explicitly. Its deliberate focus
            // change need not reuse the snapshot's earlier focused control.
            guard let element = snapshotElements[elementID] else {
                throw NativeInteractionFailure(code: "keyboard_target_expired", message: "The retained submit control expired.")
            }
            let ancestor = accessibilityWindowAncestor(of: element)
            let windowID = NativeWindowIdentity.read(element)
                ?? ancestor.flatMap { window in windows.first { CFEqual($0.value, window) }?.key }
            guard let windowID, windows[windowID] != nil else {
                throw NativeInteractionFailure(code: "keyboard_target_unavailable", message: "The submit control is outside the observed keyboard window.")
            }
            expected = NativeKeyboardReceiver(windowID: windowID, focusedElement: element)
        } else {
            guard let captured = snapshotKeyboardReceiver else {
                throw NativeInteractionFailure(code: "keyboard_target_unavailable", message: "No stable keyboard receiver was retained in the observed scope. Direct Accessibility operations remain available.")
            }
            expected = captured
        }
        try expected.validate(readKeyboardReceiver(pid, windows: windows), equal: { CFEqual($0, $1) })
        return expected
    }

    private func keyboardContext(_ receiver: NativeKeyboardReceiver<AXUIElement>) -> [String: Any] {
        var context: [String: Any] = ["window_id": receiver.windowID]
        if let focused = receiver.focusedElement {
            context["role"] = stringAttribute(focused, "AXRole" as CFString)
            context["element_id"] = snapshotElements.first { CFEqual($0.value, focused) }?.key
        }
        return context
    }

    private func keyboardTarget(_ request: HelperRequest) -> HelperResponse {
        do {
            let context = keyboardContext(try checkedKeyboardReceiver(request))
            let data = try JSONSerialization.data(withJSONObject: context)
            return HelperResponse(id: request.id, granted: nil, success: true, stdout: String(data: data, encoding: .utf8), stderr: nil, error: nil)
        } catch { return captureResponse(id: request.id, error: error.localizedDescription) }
    }

    private func sendHotkey(_ request: HelperRequest) -> HelperResponse {
        do {
            guard let pid = request.processID, let keys = request.keys else {
                throw NativeInteractionFailure(code: "invalid_hotkey", message: "A target process and keys are required.")
            }
            let expected = try checkedKeyboardReceiver(request)
            var context = keyboardContext(expected)
            let id = try NativeKeyboardInput.shared.send(.shortcut(keys), pid: pid, window: expected.windowID,
                receiver: context["element_id"] as? String) {
                let current = try self.checkedKeyboardReceiver(request)
                try expected.validate(current, equal: { CFEqual($0, $1) })
            }
            context["input_trace_ids"] = [id]
            let data = try JSONSerialization.data(withJSONObject: context)
            return HelperResponse(id: request.id, granted: nil, success: true, stdout: String(data: data, encoding: .utf8), stderr: nil, error: nil)
        } catch let error as NativeKeyboardDispatchFailure {
            let payload: [String: Any] = ["input_trace_ids": [error.traceID], "dispatch_error": error.localizedDescription,
                "code": (error.cause as? NativeInteractionFailure)?.code ?? "keyboard_dispatch_failed"]
            let data = try? JSONSerialization.data(withJSONObject: payload)
            return HelperResponse(id: request.id, granted: nil, success: true, stdout: data.flatMap { String(data: $0, encoding: .utf8) }, stderr: nil, error: nil)
        } catch let error as NativeInteractionFailure {
            let data = try? JSONSerialization.data(withJSONObject: ["dispatch_error": error.message, "code": error.code, "input_trace_ids": []] as [String: Any])
            return HelperResponse(id: request.id, granted: nil, success: true, stdout: data.flatMap { String(data: $0, encoding: .utf8) }, stderr: nil, error: nil)
        } catch { return captureResponse(id: request.id, error: error.localizedDescription) }
    }

    private func interactionResponse(id: String, result: NativeInteractionResult) -> HelperResponse {
        guard let encoded = try? JSONEncoder().encode(result), let output = String(data: encoded, encoding: .utf8) else {
            return self.captureResponse(id: id, error: "Could not encode the native action result")
        }
        return HelperResponse(id: id, granted: nil, success: true, stdout: output, stderr: nil, error: nil)
    }

    private func snapshotFrame(_ frame: CGRect) -> AccessibilitySnapshotFrame {
        AccessibilitySnapshotFrame(
            x: Int(frame.origin.x.rounded()),
            y: Int(frame.origin.y.rounded()),
            w: Int(frame.size.width.rounded()),
            h: Int(frame.size.height.rounded())
        )
    }

    private func applicationSurface(
        processID: pid_t,
        requestedTitle: String?,
        requestedWindowID: CGWindowID? = nil
    ) throws -> ApplicationSurface? {
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(application, 2)
        defer { _ = AXUIElementSetMessagingTimeout(application, 0) }
        var rawAXWindows: CFTypeRef?
        let axWindowsCode = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawAXWindows)
        guard [.success, .attributeUnsupported, .noValue, .notImplemented].contains(axWindowsCode) else {
            throw AccessibilitySnapshotAttributes.ReadFailure.windowInventory(axWindowsCode)
        }
        let inventoriedAXWindows = rawAXWindows as? [AXUIElement] ?? []
        let accessibilityWindows = inventoriedAXWindows
            .filter { element in
                self.hasAccessibilityContent(element)
                    && self.frame(of: element).map { $0.width > 1 && $0.height > 1 } == true
            }
        guard let rawWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw NativeInteractionFailure(code: "window_server_inventory_failed", message: "Window Server inventory was unavailable; visibility could not be established.")
        }
        let cgWindows = rawWindowList.enumerated().compactMap { index, window -> (id: CGWindowID, title: String?, frame: CGRect, zIndex: Int)? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber,
                  let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber,
                  width.doubleValue > 1,
                  height.doubleValue > 1
            else { return nil }
            return (
                id,
                self.meaningfulAccessibilityText(window[kCGWindowName as String] as? String),
                CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue),
                index
            )
        }

        // A successful AX inventory can lose a closed/hidden window before
        // Window Server removes its cached surface. For an exact pinned ID,
        // that is unavailability, not failure to map some other CG candidate.
        // Unknown AX identities cannot establish this condition.
        if let requestedWindowID, axWindowsCode == .success {
            let identities = inventoriedAXWindows.map(NativeWindowIdentity.read)
            if identities.allSatisfy({ $0 != nil && $0 != requestedWindowID }) { return nil }
        }

        var availableAccessibilityWindows = accessibilityWindows
        var matched: [ApplicationSurfaceWindow] = []
        for match in cgWindows {
            var element: AXUIElement?
            let candidates = availableAccessibilityWindows.map { root in
                NativeWindowIdentity.Candidate(id: NativeWindowIdentity.read(root), frame: self.frame(of: root) ?? .null,
                    fallbackAllowed: self.stringAttribute(root, kAXRoleAttribute as CFString) == kAXWindowRole as String)
            }
            if let index = NativeWindowIdentity.index(id: match.id, frame: match.frame, candidates: candidates) {
                element = availableAccessibilityWindows.remove(at: index)
            }
            if element == nil, accessibilityWindows.isEmpty {
                element = self.accessibilityWindow(
                    in: application,
                    matching: match.frame,
                    excluding: Set(matched.map { CFHash($0.element) })
                )
            }
            guard let element, self.hasAccessibilityContent(element) else { continue }
            let axTitle = self.meaningfulAccessibilityText(
                self.stringAttribute(element, kAXTitleAttribute as CFString)
            )
            matched.append(ApplicationSurfaceWindow(
                element: element,
                windowID: match.id,
                title: axTitle ?? match.title,
                frame: match.frame,
                zIndex: match.zIndex
            ))
        }
        matched.sort { $0.zIndex < $1.zIndex }
        guard !matched.isEmpty else {
            if axWindowsCode == .success && inventoriedAXWindows.isEmpty { return nil }
            if !cgWindows.isEmpty {
                throw NativeInteractionFailure(code: "window_mapping_failed", message: "Window mapping failed: \(cgWindows.count) visible Window Server candidates, \(accessibilityWindows.count) AX roots, no validated matches (AXWindows code \(axWindowsCode.rawValue)).")
            }
            return nil
        }
        let selectedAccessibilityWindows: [ApplicationSurfaceWindow]
        if requestedWindowID != nil || requestedTitle?.isEmpty == false {
            let anchors = matched.filter({ window in
                    if let requestedWindowID { return window.windowID == requestedWindowID }
                    return window.title?.range(
                        of: requestedTitle!,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                })
            guard anchors.count == 1, let anchor = anchors.first else {
                if requestedWindowID != nil { return nil }
                throw NativeInteractionFailure(code: "window_scope_unresolved", message: "Window title matched \(anchors.count) of \(matched.count) validated windows. Observe without a title and choose an exact window_id.")
            }
            let mainID = self.accessibilityElementAttribute(application, "AXMainWindow" as CFString).flatMap(NativeWindowIdentity.read)
            let focused = self.accessibilityElementAttribute(application, "AXFocusedUIElement" as CFString)
            selectedAccessibilityWindows = matched.filter { window in
                window.windowID == anchor.windowID || self.element(window.element, belongsTo: anchor) ||
                    NativeWindowIdentity.allowsFocusedEditorOverlay(
                        role: self.stringAttribute(window.element, kAXRoleAttribute as CFString) ?? "", frame: window.frame,
                        anchorFrame: anchor.frame, anchorID: anchor.windowID, mainID: mainID,
                        focused: focused.map { CFEqual($0, window.element) } ?? false)
            }
        } else {
            selectedAccessibilityWindows = matched
        }

        let accessibilityFrame = selectedAccessibilityWindows
            .map(\.frame)
            .dropFirst()
            .reduce(selectedAccessibilityWindows[0].frame) { $0.union($1) }
        let matchedWindowIDs = Set(selectedAccessibilityWindows.map(\.windowID))
        let backmostAccessibilityIndex = selectedAccessibilityWindows.map(\.zIndex).max() ?? 0
        let captureWindows = cgWindows.compactMap { window -> ApplicationSurfaceCaptureWindow? in
            if matchedWindowIDs.contains(window.id) {
                return ApplicationSurfaceCaptureWindow(
                    windowID: window.id,
                    frame: window.frame,
                    zIndex: window.zIndex
                )
            }
            guard requestedWindowID == nil, requestedTitle?.isEmpty != false,
                  window.zIndex < backmostAccessibilityIndex,
                  window.frame.width >= 30,
                  window.frame.height >= 30
            else { return nil }
            let intersection = window.frame.intersection(accessibilityFrame)
            guard !intersection.isNull,
                  intersection.width * intersection.height
                    >= window.frame.width * window.frame.height * 0.2
            else { return nil }
            return ApplicationSurfaceCaptureWindow(
                windowID: window.id,
                frame: window.frame,
                zIndex: window.zIndex
            )
        }
        guard !captureWindows.isEmpty else { return nil }
        let surfaceFrame = captureWindows
            .map(\.frame)
            .dropFirst()
            .reduce(captureWindows[0].frame) { $0.union($1) }
        return ApplicationSurface(
            accessibilityWindows: selectedAccessibilityWindows,
            captureWindows: captureWindows.sorted { $0.zIndex < $1.zIndex },
            frame: surfaceFrame
        )
    }

    private func accessibilityWindow(
        in application: AXUIElement,
        matching frame: CGRect,
        excluding excluded: Set<CFHashCode>
    ) -> AXUIElement? {
        let insetX = min(max(frame.width * 0.08, 8), 40)
        let insetY = min(max(frame.height * 0.08, 8), 40)
        let xs = [frame.midX, frame.minX + insetX, frame.maxX - insetX]
        let ys = [frame.midY, frame.minY + insetY, frame.maxY - insetY]
        for y in ys {
            for x in xs {
                var hitElement: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    application,
                    Float(x),
                    Float(y),
                    &hitElement
                ) == .success,
                    let hitElement,
                    let window = self.accessibilityWindowAncestor(of: hitElement),
                    !excluded.contains(CFHash(window)),
                    let accessibilityFrame = self.frame(of: window),
                    self.windowMatchDistance(accessibilityFrame, frame, nil, nil) < 80
                else { continue }
                return window
            }
        }
        return nil
    }

    private func windowMatchDistance(
        _ accessibilityFrame: CGRect,
        _ windowFrame: CGRect,
        _ accessibilityTitle: String?,
        _ windowTitle: String?
    ) -> Double {
        let geometry = abs(accessibilityFrame.minX - windowFrame.minX)
            + abs(accessibilityFrame.minY - windowFrame.minY)
            + abs(accessibilityFrame.width - windowFrame.width)
            + abs(accessibilityFrame.height - windowFrame.height)
        guard let accessibilityTitle, let windowTitle else { return geometry }
        return accessibilityTitle.compare(
            windowTitle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame ? geometry : geometry + 40
    }

    private func accessibilityWindowAncestor(of element: AXUIElement) -> AXUIElement? {
        for attribute in ["AXWindow", "AXTopLevelUIElement"] {
            if let window = self.accessibilityElementAttribute(element, attribute as CFString),
               self.stringAttribute(window, kAXRoleAttribute as CFString) == kAXWindowRole as String
            {
                return window
            }
        }
        var candidate: AXUIElement? = element
        var seen: [AXUIElement] = []
        while let current = candidate {
            if (try? self.nativeCancellation?.check()) == nil, self.nativeCancellation != nil { return nil }
            guard !seen.contains(where: { CFEqual($0, current) }) else { return nil }; seen.append(current)
            if self.stringAttribute(current, kAXRoleAttribute as CFString) == kAXWindowRole as String {
                return current
            }
            candidate = self.parent(of: current)
        }
        return nil
    }

    private func isLive(_ node: NativeInteractionNode, in window: ApplicationSurfaceWindow) -> Bool {
        guard let element = self.snapshotElements[node.id] else { return false }
        return self.stringAttribute(element, kAXRoleAttribute as CFString) == node.role && self.element(element, belongsTo: window)
    }

    /// The name the snapshot gives a node, read from a live element.
    private func liveName(_ element: AXUIElement, role: String?) -> String? {
        let editable = role.map { NativeInteractionExecutor.editable.contains($0) } == true ||
            self.stringAttribute(element, kAXSubroleAttribute as CFString) == "AXSearchField"
        return (editable ? ["AXTitle", "AXDescription", "AXLabel"] : ["AXTitle", "AXDescription", "AXLabel", "AXValue"])
            .lazy.compactMap { self.meaningfulAccessibilityText(self.stringAttribute(element, $0 as CFString)) }.first
    }

    /// Finds the observed control again after the app replaced its element: first
    /// on the hit path at its observed centre, then anywhere in its window.
    private func rebind(_ chain: [NativeInteractionNode], in window: ApplicationSurfaceWindow,
                        application: AXUIElement) -> [String: AXUIElement]? {
        guard let target = chain.first else { return nil }
        func describe(_ element: AXUIElement) -> NativeLiveElementDescription {
            let role = self.stringAttribute(element, kAXRoleAttribute as CFString)
            return NativeLiveElementDescription(role: role, name: self.liveName(element, role: role), frame: self.frame(of: element))
        }
        func attempt(_ candidates: [AXUIElement]) -> [String: AXUIElement]? {
            NativeTargetRebinder.rebind(chain: chain, window: window.element, candidates: candidates, describe: describe,
                parent: { self.parent(of: $0) }, same: { CFEqual($0, $1) })
        }
        if let frame = target.frame {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(application, Float(frame.midX), Float(frame.midY), &hit) == .success, let hit {
                var path: [AXUIElement] = []
                var current: AXUIElement? = hit
                while let element = current, path.count < 80, !CFEqual(element, window.element) { path.append(element); current = self.parent(of: element) }
                if let bound = attempt(path) { return bound }
            }
        }
        var all: [AXUIElement] = []
        var pending = [window.element]
        while let element = pending.popLast(), all.count < 10_000 {
            if (try? self.nativeCancellation?.check()) == nil, self.nativeCancellation != nil { return nil }
            all.append(element)
            pending.append(contentsOf: self.elementsAttribute(element, kAXChildrenAttribute as CFString))
        }
        // Only elements with the target's role can be it; the rest are not described.
        return attempt(all.filter { self.stringAttribute($0, kAXRoleAttribute as CFString) == target.role })
    }

    private func element(_ element: AXUIElement, belongsTo window: ApplicationSurfaceWindow) -> Bool {
        if let ancestor = self.accessibilityWindowAncestor(of: element), CFEqual(ancestor, window.element) { return true }
        if NativeWindowIdentity.read(element) == window.windowID && NativeWindowIdentity.read(window.element) == window.windowID { return true }
        // UI hosted in its own Window Server window but listed inside this one (a
        // context menu, Chrome's profile bubble) belongs to it only through an
        // exact retained handle observed in this window's tree (NativeRelatedUI).
        guard let root = self.snapshotWindows[window.windowID] else { return false }
        return NativeRelatedUI.observedEntry(liveAncestry: self.retainedAncestry(of: element), root: root) != nil
    }

    /// Snapshot ids of an element and its live ancestors, nearest first (nil
    /// where a handle is not retained). Retained handles match by CFEqual.
    private func retainedAncestry(of element: AXUIElement) -> [String?] {
        let retained = Dictionary(grouping: self.snapshotElements.map { ($0.key, $0.value) }, by: { CFHash($0.1) })
        return liveAncestry(of: element).map { candidate in
            retained[CFHash(candidate)]?.first(where: { CFEqual($0.1, candidate) })?.0
        }
    }

    private func liveAncestry(of element: AXUIElement) -> [AXUIElement] {
        var seen: [AXUIElement] = []
        var current: AXUIElement? = element
        while let candidate = current, seen.count < 80, !seen.contains(where: { CFEqual($0, candidate) }) {
            seen.append(candidate)
            current = self.parent(of: candidate)
        }
        return seen
    }

    private func accessibilityElementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private struct SnapshotNodeInput {
        let id: Int
        let attributes: AccessibilitySnapshotAttributes
        let clipRect: CGRect?
        var childClipRect: CGRect? {
            let role = attributes.string("AXRole") ?? ""
            return NativeSnapshotViewport.children(role: role, frame: attributes.frame, inherited: clipRect)
        }
    }

    private func encodeAccessibilitySnapshotNode(
        _ element: AXUIElement, input: SnapshotNodeInput, depth: Int,
        children: [AccessibilitySnapshotNode]
    ) -> AccessibilitySnapshotNode? {
        let attributes = input.attributes
        let role = attributes.string("AXRole") ?? "AXUnknown"
        let subrole = self.meaningfulAccessibilityText(
            attributes.string("AXSubrole")
        )
        let editable = NativeInteractionExecutor.editable.contains(role) || subrole == "AXSearchField"
        let name = (editable ? ["AXTitle", "AXDescription", "AXLabel"] : ["AXTitle", "AXDescription", "AXLabel", "AXValue"])
            .lazy.compactMap { self.meaningfulAccessibilityText(attributes.string($0)) }.first
        let value: AccessibilityControlValue? = {
            if let text = attributes.string("AXValue") {
                let presented = editable ? text : self.meaningfulAccessibilityText(text)
                guard let presented, presented != name else { return nil }
                return .text(presented)
            }
            return AccessibilityControlValue(attributes.values["AXValue"])
        }()
        let identifier = self.meaningfulAccessibilityText(
            attributes.string("AXIdentifier")
        )
        let rawFrame = attributes.frame
        let isOffscreen = rawFrame.map { frame in NativeSnapshotViewport.own(role: role, inherited: input.clipRect).map { !$0.intersects(frame) } ?? false } ?? false

        if role == kAXStaticTextRole as String, name == nil {
            return nil
        }
        // An unnamed group can own native actions (for example AXOpen). Its
        // role/name do not establish that it is inert. Preserve its identity and
        // hierarchy without enumerating actions on every observed object.

        let identity: String
        if let prior = identityReuseBuckets[CFHash(element)]?.first(where: { CFEqual($0.1, element) }) {
            identity = prior.0
        } else {
            nextElementIdentity += 1
            identity = "ax_\(nextElementIdentity)"
        }
        self.snapshotElements[identity] = element
        return AccessibilitySnapshotNode(
            id: identity,
            role: role,
            subrole: subrole,
            name: name,
            value: value,
            identifier: identifier,
            url: attributes.url("AXURL"),
            document: attributes.url("AXDocument"),
            enabled: attributes.boolean("AXEnabled"),
            focused: attributes.boolean("AXFocused"),
            selected: attributes.boolean("AXSelected"),
            selection_range: attributes.selectedRange,
            selection_style: editable ? self.selectionStyle(element, range: attributes.selectedRange) : nil,
            frame: rawFrame.map {
                AccessibilitySnapshotFrame(
                    x: Int($0.origin.x.rounded()),
                    y: Int($0.origin.y.rounded()),
                    w: Int($0.size.width.rounded()),
                    h: Int($0.size.height.rounded())
                )
            },
            offscreen: isOffscreen ? true : nil,
            children: children.isEmpty ? nil : children
        )
    }

    private func selectionStyle(_ element: AXUIElement, range: AccessibilityTextRange?) -> [AccessibilitySelectionStyle]? {
        // Formatting is inspected only for a bounded active selection. No
        // per-node capability enumeration or attributed document dump.
        guard let range, range.length > 0, range.length <= 4096 else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &requested) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForRange" as CFString, parameter, &raw) == .success,
              let string = raw as? NSAttributedString, string.length == range.length else { return nil }
        return AccessibilitySelectionStyle.runs(string, offset: range.location)
    }

    private func meaningfulAccessibilityText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        let scalars = trimmed.unicodeScalars
        let privateUseOnly = scalars.allSatisfy { scalar in
            switch scalar.value {
            case 0xE000 ... 0xF8FF, 0xF0000 ... 0xFFFFD, 0x100000 ... 0x10FFFD:
                true
            default:
                false
            }
        }
        return privateUseOnly ? nil : trimmed
    }

    private func isAccessibilityLayoutRole(_ role: String) -> Bool {
        ["AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown"]
            .contains(role)
    }

    private func isAccessibilityScrollContainer(_ role: String) -> Bool {
        ["AXScrollArea", "AXList", "AXTable", "AXOutline"].contains(role)
    }

    private func launchApplication(_ request: HelperRequest) -> HelperResponse {
        guard let launch = request.appLaunch else {
            return self.captureResponse(id: request.id, error: "Missing application launch request")
        }
        let name = launch.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = launch.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleIdentifier?.isEmpty == false || name?.isEmpty == false else {
            return self.captureResponse(
                id: request.id,
                error: "Missing installed application name or bundle identifier"
            )
        }
        let resolvedBundleIdentifier = self.resolvedBundleIdentifier(
            name: name,
            bundleIdentifier: bundleIdentifier
        )
        let frontmostBefore = NativeAppTarget.frontmostPID()
        let openProcess = Process()
        let standardError = Pipe()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let resolvedBundleIdentifier, !resolvedBundleIdentifier.isEmpty {
            openProcess.arguments = ["-g", "-b", resolvedBundleIdentifier]
        } else if let name, !name.isEmpty {
            openProcess.arguments = ["-g", "-a", name]
        }
        openProcess.standardOutput = FileHandle.nullDevice
        openProcess.standardError = standardError
        do {
            try openProcess.run()
        } catch {
            return self.captureResponse(id: request.id, error: error.localizedDescription)
        }
        let openDeadline = Date(timeIntervalSinceNow: 5)
        while openProcess.isRunning, Date() < openDeadline, self.parentIsRunning(), !self.stopping {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        if openProcess.isRunning {
            openProcess.terminate()
            return self.captureResponse(id: request.id, error: "Timed out opening the native application")
        }
        openProcess.waitUntilExit()
        if openProcess.terminationStatus != 0 {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return self.captureResponse(
                id: request.id,
                error: errorText?.isEmpty == false ? errorText! : "The requested native application is not installed"
            )
        }

        let applicationDeadline = Date(timeIntervalSinceNow: 15)
        var launchedApplication: NSRunningApplication?
        while launchedApplication == nil, Date() < applicationDeadline {
            launchedApplication = self.runningApplication(
                name: name,
                bundleIdentifier: resolvedBundleIdentifier
            )
            if launchedApplication == nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        guard let launchedApplication else {
            return self.captureResponse(id: request.id, error: "The native application did not start")
        }

        if launch.waitUntilReady != false {
            let readyDeadline = Date(timeIntervalSinceNow: 15)
            var windowReadyAt: Date?
            while Date() < readyDeadline,
                  windowReadyAt.map({ Date().timeIntervalSince($0) < 0.75 }) ?? true
            {
                if launchedApplication.isFinishedLaunching,
                   self.hasUsableWindow(launchedApplication)
                {
                    windowReadyAt = windowReadyAt ?? Date()
                } else {
                    windowReadyAt = nil
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let frontmostUnchanged = frontmostBefore == NativeAppTarget.frontmostPID()
        let targetRemainedInBackground = NativeAppTarget.frontmostPID()
            != launchedApplication.processIdentifier
        let launchedName = launchedApplication.localizedName ?? name ?? resolvedBundleIdentifier ?? "application"
        let detail = [
            "Opened \(launchedName) (PID: \(launchedApplication.processIdentifier)) in the background.",
            "Foreground app unchanged: \(frontmostUnchanged).",
            "Target app remained in background: \(targetRemainedInBackground).",
            "Physical pointer input: none.",
            self.hasUsableWindow(launchedApplication)
                ? "Accessibility interface ready: true."
                : "Accessibility interface ready: false; retry a background observation while it finishes loading.",
        ].joined(separator: " ")
        return HelperResponse(
            id: request.id,
            granted: nil,
            success: true,
            stdout: detail,
            stderr: nil,
            error: nil
        )
    }

    private func hasUsableWindow(_ application: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return application.isFinishedLaunching }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
            let windows = rawWindows as? [AXUIElement]
        else { return false }
        let accessibleWindows = windows.filter { window in
            var rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &rawSize
            ) == .success,
                let rawSize,
                CFGetTypeID(rawSize) == AXValueGetTypeID()
            else { return false }
            var size = CGSize.zero
            return AXValueGetValue(
                unsafeBitCast(rawSize, to: AXValue.self),
                .cgSize,
                &size
            ) && size.width > 1 && size.height > 1
        }
        guard accessibleWindows.contains(where: self.hasAccessibilityContent) else { return false }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windowList.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == application.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber
            else { return false }
            return width.doubleValue > 1 && height.doubleValue > 1
        }
    }

    private func hasAccessibilityContent(_ window: AXUIElement) -> Bool {
        // AXWindows can contain a directly editable root, not an AXWindow
        // wrapper. A real native window ID ties that single node to its surface.
        if let role = self.stringAttribute(window, kAXRoleAttribute as CFString),
           role != kAXWindowRole as String, !role.isEmpty, NativeWindowIdentity.read(window) != nil { return true }
        var queue = self.elementsAttribute(window, kAXChildrenAttribute as CFString)
        queue.append(contentsOf: self.elementsAttribute(window, kAXRowsAttribute as CFString))
        var index = 0
        var seen = Set<CFHashCode>()
        while index < queue.count, index < 512 {
            let element = queue[index]
            index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            if let role = self.stringAttribute(element, kAXRoleAttribute as CFString),
               !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
            queue.append(contentsOf: self.elementsAttribute(element, kAXChildrenAttribute as CFString))
            queue.append(contentsOf: self.elementsAttribute(element, kAXRowsAttribute as CFString))
        }
        return false
    }

    private func runningApplication(name: String?, bundleIdentifier: String?) -> NSRunningApplication? {
        let runningApplications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let bundleIdentifier, !bundleIdentifier.isEmpty,
           let application = runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier })
        {
            return application
        }
        if let name, !name.isEmpty {
            return runningApplications.first(where: {
                $0.localizedName?.compare(
                    name.replacingOccurrences(of: ".app", with: ""),
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            })
        }
        return nil
    }

    private func resolvedBundleIdentifier(name: String?, bundleIdentifier: String?) -> String? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        guard let name, !name.isEmpty,
              let path = NSWorkspace.shared.fullPath(forApplication: name),
              let resolved = Bundle(path: path)?.bundleIdentifier,
              !resolved.isEmpty
        else { return nil }
        return resolved
    }

    private func resolveProcessID(_ rawTarget: String) -> pid_t? {
        NativeAppTarget.resolve(rawTarget)
    }

    private func elementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        var elements: [AXUIElement] = []
        elements.reserveCapacity(CFArrayGetCount(array))
        for index in 0 ..< CFArrayGetCount(array) {
            guard let rawElement = CFArrayGetValueAtIndex(array, index) else { continue }
            let candidate = Unmanaged<AXUIElement>.fromOpaque(rawElement).takeUnretainedValue()
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { continue }
            elements.append(candidate)
        }
        return elements
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &rawSize
            ) == .success,
            let rawPosition,
            let rawSize,
            CFGetTypeID(rawPosition) == AXValueGetTypeID(),
            CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(rawPosition, to: AXValue.self),
            .cgPoint,
            &position
        ),
            AXValueGetValue(
                unsafeBitCast(rawSize, to: AXValue.self),
                .cgSize,
                &size
            )
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func captureResponse(id: String, error: String) -> HelperResponse {
        HelperResponse(
            id: id,
            granted: nil,
            success: false,
            stdout: nil,
            stderr: nil,
            error: error
        )
    }


}

@main
private enum ComputerUseHelperMain {
    static func main() {
        guard let arguments = HelperArguments(Array(CommandLine.arguments.dropFirst())) else {
            // Started on its own, as macOS does for "Quit & Reopen" after a
            // permission is granted: open the app that owns this helper so it
            // comes back, instead of exiting with nothing on screen.
            if CommandLine.arguments.count == 1, openOwningApp() { exit(0) }
            fputs("Open Computer Use Helper received invalid launch arguments.\n", stderr)
            exit(64)
        }

        do {
            let helper = ComputerUseHelper(arguments: arguments)
            try helper.run()
        } catch {
            fputs("Open Computer Use Helper failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// The helper ships at <App>.app/Contents/Resources/<Helper>.app.
    static func owningApp(of helper: URL) -> URL? {
        let resources = helper.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard resources.lastPathComponent == "Resources", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    private static func openOwningApp() -> Bool {
        guard let app = owningApp(of: Bundle.main.bundleURL) else { return false }
        let done = DispatchSemaphore(value: 0); var opened = false
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { running, _ in
            opened = running != nil; done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success && opened
    }
}
