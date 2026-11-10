import AVKit
import SwiftUI
import YT4SCore

/// The Snip window of one Done Queue row: a large player, the timeline under it, then Cut and
/// Save Snipped copy. One window per row (opening it again brings it forward); the main window
/// keeps working behind it. Save hands the Cuts to the Queue and closes the window; the row shows
/// the progress.
struct SnipWindow: View {
    static let id = "snip"

    let queue: Queue
    let itemID: QueueItem.ID?

    var body: some View {
        if let item = itemID.flatMap(queue.item), case .finished(let file) = item.state {
            Group {
                if item.isSnipping {
                    // Reopened while its Snip saves: one Snip at a time per row.
                    Text("Saving the Snipped copy. Its progress shows in the Queue.")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 400, minHeight: 200)
                } else {
                    SnipEditorView(queue: queue, itemID: item.id, file: file)
                }
            }
            .navigationTitle(item.title ?? file.deletingPathExtension().lastPathComponent)
        } else {
            Text("This video is no longer in the Queue.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 400, minHeight: 200)
                .navigationTitle("Snip")
        }
    }
}

/// The window's own state: the timeline model and the player, kept for the window's lifetime.
/// An `ObservableObject` held by `@StateObject`: `@State` is a SwiftUI macro whose plugin ships
/// only with Xcode, and this project builds with Command Line Tools (see `YT4SApp`).
///
/// Playback skips every Cut, so play previews the Snipped copy. The window's keys: Left / Right
/// step a frame (an MP3 a tenth of a second; with Shift, a second), I and O set the selection's
/// start and end at the playhead, Delete removes the picked Cut.
@MainActor
private final class SnipSession: ObservableObject {
    let editor = SnipEditor()
    let player: AVPlayer
    /// The playhead, in seconds.
    @Published var currentTime: Double = 0
    /// An MP3's cover art, shown in place of the picture it does not have.
    @Published var artwork: NSImage?
    /// What the drag in progress on the timeline does, from where it started.
    var timelineDrag: TimelineDrag?
    /// Set by Save: the Cuts went to the Queue, so closing asks nothing.
    var saved = false
    /// Whether the file has a picture, so the arrow keys step its frames.
    private var hasVideo = false
    private var timeObserver: Any?
    /// One per Cut, at its start: playback reaching it jumps over it (or stops).
    private var cutObservers: [Any] = []
    /// Play pressed at the end of the preview starts it again.
    private var rateObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private weak var window: NSWindow?
    private let closeGuard = CloseGuard()

    init(file: URL) {
        player = AVPlayer(url: file)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
                // Play started inside a Cut, or the playhead was dragged into one while playing.
                self?.jump(at: time.seconds)
            }
        }
        rateObservation = player.observe(\.rate, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue == 0, change.newValue != 0 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.restartIfAtEnd() } }
        }
        closeGuard.mustAsk = { [weak self] in
            guard let self else { return false }
            return !self.saved && !self.editor.cuts.isEmpty
        }
    }

    /// The window closed (or saved): stop playing, following the playhead and taking keys.
    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        cutObservers.forEach(player.removeTimeObserver)
        cutObservers = []
        rateObservation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The duration for the timeline, and an MP3's cover art for the player.
    func load(_ file: URL) async {
        let asset = AVURLAsset(url: file)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            editor.duration = duration.seconds
        }
        hasVideo = !((try? await asset.loadTracks(withMediaType: .video))?.isEmpty ?? true)
        guard !hasVideo,
              let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue) else { return }
        artwork = NSImage(data: data)
    }

    /// Frame-accurate, so the picture shows exactly where a span edge is.
    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The window the editor shows in: its keys come here, and closing it with Cuts asks first.
    func attach(to window: NSWindow) {
        closeGuard.install(on: window)
        guard self.window !== window else { return }
        self.window = window
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    /// The Cuts changed: playback now skips these.
    func cutsChanged() {
        cutObservers.forEach(player.removeTimeObserver)
        cutObservers = editor.cuts.map { cut in
            let start = NSValue(time: CMTime(seconds: cut.start, preferredTimescale: 600))
            return player.addBoundaryTimeObserver(forTimes: [start], queue: .main) { [weak self] in
                // Reported a moment before the start, sometimes: judged at the start itself.
                MainActor.assumeIsolated { self?.jump(at: cut.start) }
            }
        }
    }

    /// Playback at `time`, if it is in a Cut: on from the Cut's end, or stopped just before an
    /// end Cut.
    private func jump(at time: Double) {
        guard player.rate != 0, let jump = editor.playbackJump(at: time) else { return }
        switch jump {
        case .skip(let end):
            seek(to: end)
        case .stop(let last):
            player.pause()
            seek(to: last)
        }
    }

    private func restartIfAtEnd() {
        guard player.rate != 0, let start = editor.playbackRestart(at: player.currentTime().seconds) else { return }
        seek(to: start)
    }

    /// Whether the window's key was one of the editor's.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard editor.duration > 0, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.specialKey {
        case .leftArrow?: step(-1, bySecond: event.modifierFlags.contains(.shift)); return true
        case .rightArrow?: step(1, bySecond: event.modifierFlags.contains(.shift)); return true
        case .delete?, .deleteForward?:
            guard editor.pickedCut != nil else { return false }
            editor.removePickedCut()
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": editor.setSelectionStart(at: currentTime); return true
        case "o": editor.setSelectionEnd(at: currentTime); return true
        default: return false
        }
    }

    /// One frame (an MP3 a tenth of a second), or one second, either way; stepping pauses.
    private func step(_ direction: Int, bySecond: Bool) {
        player.pause()
        if hasVideo && !bySecond {
            player.currentItem?.step(byCount: direction)
            // The playhead line and I / O read this; the time observer may not fire while paused.
            currentTime = player.currentTime().seconds
        } else {
            seek(to: editor.step(from: currentTime, by: Double(direction) * (bySecond ? 1 : 0.1)))
        }
    }
}

/// Stands in as its window's delegate to ask "Discard Cuts?" before the window closes with
/// Cuts not saved; everything else goes on to SwiftUI's own delegate.
@MainActor
private final class CloseGuard: NSObject, NSWindowDelegate {
    var mustAsk: () -> Bool = { false }
    /// Read by the runtime off the main actor when it asks what the delegate implements; set once, on the main actor.
    nonisolated(unsafe) private weak var forwarded: NSWindowDelegate?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        forwarded = window.delegate
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwarded?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwarded?.responds(to: selector) == true ? forwarded : nil
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard !mustAsk() else {
            ask(in: window)
            return false
        }
        return forwarded?.windowShouldClose?(window) ?? true
    }

    private func ask(in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Discard Cuts?"
        alert.informativeText = "The Cuts you marked are not saved."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak window] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let window else { return }
                // Closes without asking again; after the sheet is fully gone, as a window with a
                // sheet does not close.
                DispatchQueue.main.async { window.close() }
            }
        }
    }
}

/// Reports the window it is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// The player, the timeline, and the Cut and Save Snipped copy buttons.
private struct SnipEditorView: View {
    let queue: Queue
    let itemID: QueueItem.ID
    let file: URL
    @StateObject private var session: SnipSession
    @Environment(\.dismiss) private var dismiss

    init(queue: Queue, itemID: QueueItem.ID, file: URL) {
        self.queue = queue
        self.itemID = itemID
        self.file = file
        _session = StateObject(wrappedValue: SnipSession(file: file))
    }

    private var editor: SnipEditor { session.editor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerView(player: session.player, artwork: session.artwork)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            SnipTimeline(session: session, currentTime: session.currentTime)
                .frame(height: 40)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("← → step  ·  I / O set start / end at the playhead  ·  Delete removes the picked Cut")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .monospacedDigit()
                .lineLimit(1)
                Spacer(minLength: 12)
                Button("Cut") { editor.cutSelection() }
                    .disabled(!editor.canCut)
                    .help("Leave the selected span out of the Snipped copy")
                Button("Save Snipped copy") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.plan == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .background(WindowReader { session.attach(to: $0) })
        .task { await session.load(file) }
        .onChange(of: editor.cuts) { session.cutsChanged() }
        .onDisappear { session.stop() }
    }

    private func save() {
        guard let plan = editor.plan else { return }
        session.saved = true
        session.stop()
        queue.snip(itemID, plan: plan)
        dismiss()
    }
}

/// The timeline under the player: the Cuts in striped grey, the selection with its two edge
/// handles, and the playhead. Dragging across empty track selects a span; dragging a handle moves
/// that edge; a click moves the playhead, and on a Cut picks it, showing an x that removes it.
/// The picture follows every drag.
private struct SnipTimeline: View {
    let session: SnipSession
    let currentTime: Double

    private var editor: SnipEditor { session.editor }

    /// How close to a handle (in points) a drag must start to move it.
    private static let handleReach: CGFloat = 8
    private static let handleWidth: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                ForEach(editor.cuts, id: \.start) { cut in
                    StripedSpan(picked: cut == editor.pickedCut)
                        .frame(width: max(x(cut.end, width) - x(cut.start, width), 1))
                        .offset(x: x(cut.start, width))
                }
                if let selection = editor.selection {
                    selectionView(selection, width: width)
                }
                if editor.duration > 0 {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: min(max(x(currentTime, width) - 1, 0), width - 2))
                        .allowsHitTesting(false)
                }
            }
            // A Cut or selection at either end follows the track's rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .gesture(gesture(width: width))
            .overlay {
                if let cut = editor.pickedCut {
                    removeButton
                        .position(x: min(max((x(cut.start, width) + x(cut.end, width)) / 2, 10), width - 10), y: geometry.size.height / 2)
                }
            }
        }
    }

    /// The picked Cut's x.
    private var removeButton: some View {
        Button { editor.removePickedCut() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Remove this Cut")
    }

    private func selectionView(_ selection: Cut, width: CGFloat) -> some View {
        let start = x(selection.start, width)
        let end = x(selection.end, width)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: max(end - start, 1))
                .offset(x: start)
            handle.offset(x: min(max(start - Self.handleWidth / 2, 0), width - Self.handleWidth))
            handle.offset(x: min(max(end - Self.handleWidth / 2, 0), width - Self.handleWidth))
        }
        .allowsHitTesting(false)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: Self.handleWidth)
    }

    /// A drag moves less than this (in points) to count as a click.
    private static let clickSlop: CGFloat = 3

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let mode = session.timelineDrag ?? startingDrag(at: value.startLocation.x, width: width)
                session.timelineDrag = mode
                let time = self.time(value.location.x, width)
                let moved = abs(value.translation.width) >= Self.clickSlop
                switch mode {
                case .newSpan(let anchor):
                    if moved { editor.select(from: anchor, to: time) }
                case .start:
                    editor.moveSelectionStart(to: time)
                case .end:
                    editor.moveSelectionEnd(to: time)
                }
                session.seek(to: min(max(time, 0), editor.duration))
            }
            .onEnded { value in
                if case .newSpan? = session.timelineDrag, abs(value.translation.width) < Self.clickSlop {
                    editor.pickCut(at: time(value.location.x, width))
                }
                session.timelineDrag = nil
            }
    }

    private func startingDrag(at location: CGFloat, width: CGFloat) -> TimelineDrag {
        let reach = width > 0 ? Double(Self.handleReach / width) * editor.duration : 0
        switch editor.handle(near: time(location, width), reach: reach) {
        case .start: return .start
        case .end: return .end
        case nil: return .newSpan(anchor: time(location, width))
        }
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        editor.duration > 0 ? CGFloat(time / editor.duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x, 0), width) / width) * editor.duration : 0
    }
}

/// What a drag on the timeline does, decided where it starts.
private enum TimelineDrag {
    /// Selects a new span from where it started.
    case newSpan(anchor: Double)
    /// Moves the selection's start handle.
    case start
    /// Moves the selection's end handle.
    case end
}

/// A Cut on the timeline: grey with diagonal stripes; outlined while picked.
private struct StripedSpan: View {
    var picked = false

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.55)))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(stripes, with: .color(.black.opacity(0.25)), lineWidth: 2)
            if picked {
                context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The AppKit player: its own controls (play, scrub, volume), no full screen. `artwork` (an
/// MP3's cover art) covers the player's audio-only placeholder, under the controls.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let artwork: NSImage?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        if let overlay = view.contentOverlayView {
            let artworkView = NSImageView()
            artworkView.imageScaling = .scaleProportionallyUpOrDown
            artworkView.wantsLayer = true
            artworkView.layer?.backgroundColor = NSColor.black.cgColor
            artworkView.isHidden = true
            artworkView.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(artworkView)
            NSLayoutConstraint.activate([
                artworkView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                artworkView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                artworkView.topAnchor.constraint(equalTo: overlay.topAnchor),
                artworkView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            context.coordinator.artworkView = artworkView
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.artworkView?.image = artwork
        context.coordinator.artworkView?.isHidden = artwork == nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var artworkView: NSImageView?
    }
}
