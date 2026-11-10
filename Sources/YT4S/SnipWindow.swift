import AVKit
import SwiftUI
import YT4SCore

/// The Snip window of one Done Queue row: a large player, the timeline under it, then Cut and
/// Save Snipped copy. One window per row (opening it again brings it forward); the main window
/// keeps working behind it. Save hands the Cut to the Queue and closes the window; the row shows
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
    private var timeObserver: Any?

    init(file: URL) {
        player = AVPlayer(url: file)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    /// The window closed (or saved): stop playing and following the playhead.
    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    /// The duration for the timeline, and an MP3's cover art for the player.
    func load(_ file: URL) async {
        let asset = AVURLAsset(url: file)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            editor.duration = duration.seconds
        }
        guard (try? await asset.loadTracks(withMediaType: .video))?.isEmpty ?? true,
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
                Text(spanText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        .task { await session.load(file) }
        .onDisappear { session.stop() }
    }

    /// What the timeline holds, in words: the selection being marked, or the Cut, or how to start.
    private var spanText: String {
        if let selection = editor.selection {
            return "Selected \(SnipEditor.timeText(selection.start)) - \(SnipEditor.timeText(selection.end)). Press Cut to leave it out."
        }
        if let cut = editor.cut {
            return "Cut \(SnipEditor.timeText(cut.start)) - \(SnipEditor.timeText(cut.end)) (\(SnipEditor.timeText(cut.length)))"
        }
        return "Drag across the timeline to select the part to cut."
    }

    private func save() {
        guard let plan = editor.plan else { return }
        session.stop()
        queue.snip(itemID, plan: plan)
        dismiss()
    }
}

/// The timeline under the player: the Cut in striped grey, the selection with its two edge
/// handles, and the playhead. Dragging across empty track selects a span; dragging a handle moves
/// that edge; a click moves the playhead. The picture follows every drag.
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
                if let cut = editor.cut {
                    StripedSpan()
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
        }
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

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let mode = session.timelineDrag ?? startingDrag(at: value.startLocation.x, width: width)
                session.timelineDrag = mode
                let time = self.time(value.location.x, width)
                let moved = abs(value.translation.width) >= 3
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
            .onEnded { _ in session.timelineDrag = nil }
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

/// A Cut on the timeline: grey with diagonal stripes.
private struct StripedSpan: View {
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
