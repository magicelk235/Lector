import AppKit
import CoreGraphics

/// A window as the window server lists it, its frame turned into global AppKit
/// coordinates.
struct WindowEntry: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    /// 0 for an app's ordinary windows; floating panels, the Dock and the menu bar sit higher.
    let layer: Int
    /// In global AppKit coordinates.
    let frame: CGRect
    let alpha: Double
    /// False while it's minimised, hidden or on another Space.
    let isOnScreen: Bool
}

extension WindowEntry {
    /// One of the window server's descriptions of a window. `primaryHeight` turns its
    /// bounds, measured down from the primary display's top-left corner, into AppKit's.
    init?(_ info: [String: Any], primaryHeight: CGFloat) {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary)
        else { return nil }
        self.init(id: id, pid: pid, layer: layer, frame: WindowList.flipped(bounds, primaryHeight: primaryHeight),
                  alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                  isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

/// The windows on screen as live translation needs them: the one an area was drawn in,
/// where that window is now, and what's in front of it.
enum WindowList {
    /// How much of an area a window must hold for the area to be watched in it. The rest,
    /// a careless edge of the drag, is left out.
    static let holds = 0.9
    /// How much of an area windows in front of its own may hide before it's out of sight.
    /// Less, like a corner under a small window, leaves the translation up.
    static let hides = 0.1
    /// Smaller windows of an app aren't where its text is: apps can keep small windows of
    /// their own in front of the main one, like a tooltip, a palette, or the title bar's
    /// buttons drawn in a window of their own.
    static let smallest = CGSize(width: 100, height: 100)

    /// Window-server bounds in AppKit coordinates, or AppKit's in the window server's: the
    /// one is the other turned upside down within the primary display.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `rect`, in AppKit coordinates, as measured from the top-left corner of the window at
    /// `frame`: the way ScreenCaptureKit takes a part of a window.
    static func offset(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The window an area drawn on screen is in: the frontmost ordinary window under it,
    /// as long as that holds nearly all of it and little of it is hidden by windows in
    /// front. Nil for an area across two windows or out on the desktop, which is watched
    /// on the display, where it was drawn. Windows are front to back; those of process
    /// `own`, Lector's, are looked through, as the watch looks through them.
    static func holding(_ area: CGRect, among windows: [WindowEntry], own: pid_t) -> WindowEntry? {
        var hidden = 0.0
        for window in windows where window.pid != own && canHide(window) {
            let held = share(of: area, under: window.frame)
            guard held > 0 else { continue }
            if window.layer == 0, held >= holds, hidden < hides { return window }
            hidden += held
            guard hidden < hides else { return nil }
        }
        return nil
    }

    /// How much of `area` the windows in front of its own hide, as a share of it.
    static func hidden(_ area: CGRect, by inFront: [WindowEntry], own: pid_t) -> Double {
        inFront.filter { $0.pid != own && canHide($0) }.reduce(0) { $0 + share(of: area, under: $1.frame) }
    }

    /// The front window of the app with process `pid`, front to back among `windows`:
    /// where an area remembered for the app is watched again.
    static func frontmost(of pid: pid_t, among windows: [WindowEntry]) -> WindowEntry? {
        windows.first {
            $0.pid == pid && $0.layer == 0 && canHide($0)
                && $0.frame.width >= smallest.width && $0.frame.height >= smallest.height
        }
    }

    /// Windows that can stand between the user and an area, and that the translation,
    /// floating above them, would be painted over: apps' windows and panels, not the Dock
    /// or the menu bar, nor anything that shows above the translation anyway.
    private static func canHide(_ window: WindowEntry) -> Bool {
        window.isOnScreen && window.alpha > 0 && (0..<dockLevel).contains(window.layer)
    }

    private static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    private static func share(of area: CGRect, under frame: CGRect) -> Double {
        let overlap = area.intersection(frame)
        guard !overlap.isNull, area.width > 0, area.height > 0 else { return 0 }
        return Double(overlap.width * overlap.height / (area.width * area.height))
    }

    // MARK: Reading

    /// The windows on screen, front to back.
    @MainActor
    static func onScreen() -> [WindowEntry] {
        entries(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
    }

    /// The windows on screen in front of window `id`, front to back.
    @MainActor
    static func inFront(of id: CGWindowID) -> [WindowEntry] {
        entries(CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id))
    }

    /// Window `id` as it is now, on screen or not; nil once it's closed.
    @MainActor
    static func entry(_ id: CGWindowID) -> WindowEntry? {
        // The window server takes an array of the numbers themselves, not of objects
        // holding them: an array of `NSNumber`s finds nothing.
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        return entries(CGWindowListCreateDescriptionFromArray(CFArrayCreate(nil, &ids, 1, nil))).first
    }

    @MainActor
    private static func entries(_ list: CFArray?) -> [WindowEntry] {
        guard let list = list as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { WindowEntry($0, primaryHeight: primaryHeight) }
    }
}

extension LiveArea {
    /// `rect` as shares of the window at `frame`, both in AppKit coordinates.
    init(_ rect: CGRect, in frame: CGRect) {
        self.init(x: Double((rect.minX - frame.minX) / frame.width),
                  y: Double((frame.maxY - rect.maxY) / frame.height),
                  width: Double(rect.width / frame.width),
                  height: Double(rect.height / frame.height))
    }

    /// Where the area is with its window at `frame`, in AppKit coordinates.
    func rect(in frame: CGRect) -> CGRect {
        let width = CGFloat(self.width) * frame.width, height = CGFloat(self.height) * frame.height
        return CGRect(x: frame.minX + CGFloat(x) * frame.width,
                      y: frame.maxY - CGFloat(y) * frame.height - height,
                      width: width, height: height)
    }
}
