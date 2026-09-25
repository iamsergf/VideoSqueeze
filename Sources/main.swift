import AppKit
import SwiftUI

struct VideoSqueezeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("VideoSqueeze", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить видео…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Headless mode for scripting/testing: VideoSqueeze --cli <input> <output> [h264] [720] [size=<MB>]
func runCLI(_ args: [String]) -> Never {
    var settings = CompressionSettings()
    if args.contains("h264") { settings.codec = .h264 }
    if args.contains("720") { settings.resolution = .p720 }
    if let arg = args.first(where: { $0.hasPrefix("size=") }), let mb = Double(arg.dropFirst(5)) {
        settings.mode = .targetSize
        settings.targetSizeMB = mb
        settings.resolution = .original
    }
    let input = URL(fileURLWithPath: args[0])
    let output = URL(fileURLWithPath: args[1])
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached {
        do {
            let r = try await VideoCompressor().compress(input: input, output: output, settings: settings) { _ in }
            print("OK \(Int(r.size.width))x\(Int(r.size.height)) fps=\(Int(r.fps.rounded())) video=\(r.videoBitrate / 1000)kbps attempts=\(r.attempts)")
        } catch {
            print("\nERROR: \(error.localizedDescription)")
            code = 1
        }
        done.signal()
    }
    done.wait()
    exit(code)
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--cli"), arguments.count > i + 2 {
    runCLI(Array(arguments[(i + 1)...]))
} else {
    VideoSqueezeApp.main()
}
