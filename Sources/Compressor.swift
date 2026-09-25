import AVFoundation
import VideoToolbox

enum Codec: String, CaseIterable, Identifiable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
    var id: Self { self }

    /// Minimum bits per pixel per frame before we'd rather drop resolution.
    var minBitsPerPixel: Double { self == .hevc ? 0.035 : 0.055 }
}

enum Quality: String, CaseIterable, Identifiable {
    case high = "Высокое"
    case medium = "Среднее"
    case low = "Низкое"
    var id: Self { self }

    /// Bits per pixel per frame for HEVC; H.264 gets a multiplier on top.
    var bitsPerPixel: Double {
        switch self {
        case .high: return 0.08
        case .medium: return 0.05
        case .low: return 0.03
        }
    }
}

enum MaxResolution: String, CaseIterable, Identifiable {
    case original = "Как в оригинале"
    case p2160 = "4K (2160p)"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    var id: Self { self }

    var shortSide: CGFloat? {
        switch self {
        case .original: return nil
        case .p2160: return 2160
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

enum CompressionMode: String, CaseIterable, Identifiable {
    case quality = "По качеству"
    case targetSize = "По размеру"
    var id: Self { self }
}

struct CompressionSettings {
    var mode: CompressionMode = .quality
    var codec: Codec = .hevc
    var quality: Quality = .medium
    var resolution: MaxResolution = .p1080
    var targetSizeMB: Double = 5
    var keepAudio = true
}

struct CompressionResult {
    var size: CGSize
    var fps: Double
    var videoBitrate: Int
    var attempts: Int
}

enum CompressError: LocalizedError {
    case noVideoTrack
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "В файле нет видеодорожки"
        case .cancelled: return "Отменено"
        case .failed(let msg): return msg
        }
    }
}

private struct AudioPlan {
    var bitrate: Int
    var channels: Int
    var sampleRate: Int

    /// Scales audio down as the overall budget gets tighter.
    static func forTotalBitrate(_ total: Double) -> AudioPlan {
        switch total {
        case 1_000_000...: return AudioPlan(bitrate: 128_000, channels: 2, sampleRate: 48_000)
        case 400_000...: return AudioPlan(bitrate: 96_000, channels: 2, sampleRate: 48_000)
        case 150_000...: return AudioPlan(bitrate: 64_000, channels: 2, sampleRate: 48_000)
        case 100_000...: return AudioPlan(bitrate: 32_000, channels: 1, sampleRate: 24_000)
        default: return AudioPlan(bitrate: 16_000, channels: 1, sampleRate: 16_000)
        }
    }
}

private struct EncodePlan {
    var codec: Codec
    var isHDR: Bool
    var size: CGSize
    /// Output frame rate; frames are dropped when it's below the source rate.
    var fps: Double
    var sourceFps: Double
    var videoBitrate: Double
    var audio: AudioPlan?

    var minFrameInterval: Double { fps < sourceFps * 0.95 ? 1 / fps : 0 }
}

final class VideoCompressor {
    private var reader: AVAssetReader?
    private var isCancelled = false

    /// Roughly where Apple Silicon's encoder stops honoring lower bitrates at 30 fps (measured at 144p).
    static let hardwareFloorBitrate: Double = 60_000

    func cancel() {
        isCancelled = true
        reader?.cancelReading()
    }

    @discardableResult
    func compress(input: URL, output: URL, settings: CompressionSettings,
                  progress: @escaping (Double) -> Void) async throws -> CompressionResult {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let (naturalSize, nominalFps, dataRate, characteristics) =
            try await videoTrack.load(.naturalSize, .nominalFrameRate, .estimatedDataRate, .mediaCharacteristics)
        let audioTrack = settings.keepAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil

        // HDR (e.g. iPhone Dolby Vision/HLG) is kept as 10-bit HEVC; H.264 can't carry it.
        let isHDR = characteristics.contains(.containsHDRVideo)
        let codec: Codec = isHDR ? .hevc : settings.codec
        let fps = nominalFps > 0 ? Double(nominalFps) : 30
        let sourceRate = dataRate > 0 ? Double(dataRate) : .infinity

        var plan = EncodePlan(codec: codec, isHDR: isHDR, size: .zero, fps: fps, sourceFps: fps,
                              videoBitrate: 0, audio: nil)

        switch settings.mode {
        case .quality:
            plan.size = Self.targetSize(naturalSize, limit: settings.resolution.shortSide)
            var bitrate = Double(plan.size.width * plan.size.height) * fps * settings.quality.bitsPerPixel
            if codec == .h264 { bitrate *= 1.6 }
            plan.videoBitrate = max(min(bitrate, sourceRate * 0.9), 250_000)
            if audioTrack != nil { plan.audio = AudioPlan(bitrate: 128_000, channels: 2, sampleRate: 48_000) }

            try await encode(asset: asset, videoTrack: videoTrack, audioTrack: audioTrack,
                             output: output, plan: plan, progress: progress)
            return CompressionResult(size: plan.size, fps: plan.fps,
                                     videoBitrate: Int(plan.videoBitrate), attempts: 1)

        case .targetSize:
            let targetBytes = settings.targetSizeMB * 1_000_000
            let seconds = max(duration.seconds, 0.1)
            // ~3% goes to mp4 container overhead (moov, sample tables).
            let totalRate = targetBytes * 8 * 0.97 / seconds
            if audioTrack != nil { plan.audio = AudioPlan.forTotalBitrate(totalRate) }
            plan.videoBitrate = max(min(totalRate - Double(plan.audio?.bitrate ?? 0), sourceRate * 0.9), 40_000)
            plan.size = Self.fittingSize(naturalSize, bitrate: plan.videoBitrate, fps: fps, codec: codec,
                                         limit: settings.resolution.shortSide)
            // The hardware encoder can't go much below this at 30 fps, so spend the budget on fewer frames.
            if plan.videoBitrate < Self.hardwareFloorBitrate {
                plan.fps = max(5, min(fps, fps * plan.videoBitrate / Self.hardwareFloorBitrate))
            }

            // The hardware encoder's rate control isn't exact, so verify and retry if we overshoot.
            let maxAttempts = 4
            for attempt in 1...maxAttempts {
                try await encode(asset: asset, videoTrack: videoTrack, audioTrack: audioTrack,
                                 output: output, plan: plan, progress: progress)
                let actual = Double(AppModel.fileSize(output))
                if actual <= targetBytes || attempt == maxAttempts {
                    return CompressionResult(size: plan.size, fps: plan.fps,
                                             videoBitrate: Int(plan.videoBitrate), attempts: attempt)
                }
                let audioBytes = Double(plan.audio?.bitrate ?? 0) / 8 * seconds
                let videoBytes = max(actual - audioBytes, 1)
                let allowedVideoBytes = max(targetBytes * 0.97 - audioBytes, targetBytes * 0.1)
                let ratio = allowedVideoBytes / videoBytes * 0.95
                if plan.videoBitrate * ratio < Self.hardwareFloorBitrate {
                    plan.fps = max(5, plan.fps * ratio)
                }
                plan.videoBitrate = max(plan.videoBitrate * ratio, 10_000)
                progress(0)
            }
            fatalError("unreachable")
        }
    }

    private func encode(asset: AVAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?,
                        output: URL, plan: EncodePlan, progress: @escaping (Double) -> Void) async throws {
        let (transform, formatDescriptions) = try await videoTrack.load(.preferredTransform, .formatDescriptions)
        let duration = try await asset.load(.duration)

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        self.reader = reader
        if isCancelled { throw CompressError.cancelled }

        // Video
        let pixelFormat = plan.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let roundedFps = Int(plan.fps.rounded())
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(plan.videoBitrate),
            AVVideoExpectedSourceFrameRateKey: max(roundedFps, 1),
            AVVideoMaxKeyFrameIntervalKey: max(roundedFps * 2, 2),
        ]
        if plan.codec == .hevc {
            compression[AVVideoProfileLevelKey] = (plan.isHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                                              : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(plan.size.width),
            AVVideoHeightKey: Int(plan.size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let fd = formatDescriptions.first, let color = Self.colorProperties(fd) {
            videoSettings[AVVideoColorPropertiesKey] = color
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Audio
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack, let audio = plan.audio {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
            ])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: audio.bitrate,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
            }
        }

        guard writer.startWriting() else {
            throw CompressError.failed(writer.error?.localizedDescription ?? "Не удалось начать запись")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw CompressError.failed(reader.error?.localizedDescription ?? "Не удалось прочитать файл")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration.seconds, 0.001)
        var lastReported = -1.0
        async let videoDone: Void = Self.pump(videoOutput, into: videoInput, queue: DispatchQueue(label: "video"),
                                              minFrameInterval: plan.minFrameInterval) { time in
            let p = min(max(time.seconds / total, 0), 1)
            if p - lastReported >= 0.005 {
                lastReported = p
                progress(p)
            }
        }
        async let audioDone: Void = {
            if let (out, inp) = audioPair {
                await Self.pump(out, into: inp, queue: DispatchQueue(label: "audio"), onSample: nil)
            }
        }()
        _ = await (videoDone, audioDone)

        if isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CompressError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CompressError.failed(reader.error?.localizedDescription ?? "Ошибка чтения")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw CompressError.failed(writer.error?.localizedDescription ?? "Ошибка записи")
        }
        progress(1)
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                             queue: DispatchQueue, minFrameInterval: Double = 0,
                             onSample: ((CMTime) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var nextFrameTime = -Double.infinity
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    if minFrameInterval > 0 {
                        // Decimate the frame rate: keep a frame only once enough time has passed.
                        if time.seconds < nextFrameTime { continue }
                        nextFrameTime = nextFrameTime.isFinite
                            ? max(nextFrameTime + minFrameInterval, time.seconds + minFrameInterval * 0.5)
                            : time.seconds + minFrameInterval
                    }
                    guard input.append(sample) else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    onSample?(time)
                }
            }
        }
    }

    /// Scales so the short side fits `limit`, keeping aspect ratio and even dimensions.
    static func targetSize(_ natural: CGSize, limit: CGFloat?) -> CGSize {
        var w = abs(natural.width), h = abs(natural.height)
        if let limit, min(w, h) > limit {
            let scale = limit / min(w, h)
            w *= scale
            h *= scale
        }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    /// Largest standard resolution whose bits-per-pixel stays watchable at the given bitrate.
    static func fittingSize(_ natural: CGSize, bitrate: Double, fps: Double, codec: Codec,
                            limit: CGFloat?) -> CGSize {
        let shortSide = min(abs(natural.width), abs(natural.height))
        let cap = min(limit ?? shortSide, shortSide)
        let candidates: [CGFloat] = [2160, 1440, 1080, 720, 540, 480, 360, 240, 144]
        for side in candidates where side <= cap || side == candidates.last {
            let size = targetSize(natural, limit: min(side, cap))
            if Double(size.width * size.height) * fps * codec.minBitsPerPixel <= bitrate {
                return size
            }
        }
        return targetSize(natural, limit: min(candidates.last!, cap))
    }

    private static func colorProperties(_ fd: CMFormatDescription) -> [String: Any]? {
        func ext(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(fd, extensionKey: key) as? String
        }
        guard let primaries = ext(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = ext(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = ext(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }
}
