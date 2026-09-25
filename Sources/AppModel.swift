import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoItem: Identifiable {
    enum Status: Equatable {
        case pending, running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let originalSize: Int64
    var status: Status = .pending
    var progress: Double = 0
    var outputURL: URL?
    var outputSize: Int64?
    var result: CompressionResult?
    var targetBytes: Int64?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var settings = CompressionSettings()
    @Published var isRunning = false

    private var current: VideoCompressor?
    private var stopRequested = false

    var hasPending: Bool { items.contains { $0.status != .done && $0.status != .running } }

    func add(_ urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.url == url }),
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) else { continue }
            items.append(VideoItem(url: url, originalSize: Self.fileSize(url)))
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func remove(_ item: VideoItem) {
        items.removeAll { $0.id == item.id && $0.status != .running }
    }

    func clear() {
        items.removeAll { $0.status != .running }
    }

    func reveal(_ item: VideoItem) {
        if let url = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func stop() {
        stopRequested = true
        current?.cancel()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        stopRequested = false
        let settings = settings
        Task {
            for id in items.filter({ $0.status != .done }).map(\.id) {
                if stopRequested { break }
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                let input = items[index].url
                let output = Self.outputURL(for: input)
                items[index].status = .running
                items[index].progress = 0

                let compressor = VideoCompressor()
                current = compressor
                do {
                    let result = try await compressor.compress(input: input, output: output,
                                                               settings: settings) { p in
                        Task { @MainActor in self.update(id) { $0.progress = p } }
                    }
                    update(id) {
                        $0.status = .done
                        $0.progress = 1
                        $0.outputURL = output
                        $0.outputSize = Self.fileSize(output)
                        $0.result = result
                        $0.targetBytes = settings.mode == .targetSize
                            ? Int64(settings.targetSizeMB * 1_000_000) : nil
                    }
                } catch CompressError.cancelled {
                    update(id) { $0.status = .cancelled; $0.progress = 0 }
                } catch {
                    update(id) { $0.status = .failed(error.localizedDescription) }
                }
            }
            current = nil
            isRunning = false
            if !stopRequested { NSSound(named: "Glass")?.play() }
        }
    }

    private func update(_ id: UUID, _ change: (inout VideoItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    static func outputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + "_compressed"
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(n)").appendingPathExtension("mp4")
            n += 1
        }
        return candidate
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
