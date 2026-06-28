import Foundation
import Speech
import AVFoundation
import CoreMedia

public typealias HermesSpeechCallback = @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Void

private var gAnalyzer: SpeechAnalyzer?
private var gTranscriber: SpeechTranscriber?
private var gInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
private var gAnalyzerTask: Task<Void, Never>?
private var gResultTask: Task<Void, Never>?
private var gCallback: HermesSpeechCallback?
private var gTargetFormat: AVAudioFormat?
private var gConverter: AVAudioConverter?
private var gConverterSrc: AVAudioFormat?
private let gAccumulator = SpeechAccumulator()

private actor SpeechAccumulator {
    private var finalized = AttributedString()
    private var volatile = AttributedString()
    private var lastFinalEnd = CMTime.zero

    func reset() {
        finalized = AttributedString()
        volatile = AttributedString()
        lastFinalEnd = .zero
    }

    func accumulate(_ result: SpeechTranscriber.Result) -> (text: String, isFinal: Bool) {
        let isFinal = CMTimeCompare(result.range.end, result.resultsFinalizationTime) <= 0
        if isFinal {
            if CMTimeCompare(result.range.end, lastFinalEnd) > 0 {
                finalized += result.text
                lastFinalEnd = result.range.end
            }
            volatile = AttributedString()
        } else {
            volatile = result.text
        }
        return (String((finalized + volatile).characters), isFinal)
    }
}

private func converterTo(_ dst: AVAudioFormat, from src: AVAudioFormat) -> AVAudioConverter? {
    if let c = gConverter, gConverterSrc == src { return c }
    let c = AVAudioConverter(from: src, to: dst)
    c?.sampleRateConverterQuality = .max
    gConverter = c
    gConverterSrc = src
    return c
}

private func logEngine(_ message: String) {
    fputs("[Hermes SpeechAnalyzer] \(message)\n", stderr)
}

@_cdecl("hermes_speech_analyzer_is_available")
public func hermes_speech_analyzer_is_available() -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    return SpeechTranscriber.isAvailable ? 1 : 0
}

@_cdecl("hermes_speech_analyzer_locale_supported")
public func hermes_speech_analyzer_locale_supported(_ localeCStr: UnsafePointer<CChar>?) -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    guard let localeCStr = localeCStr else { return 0 }
    let locale = Locale(identifier: String(cString: localeCStr))

    let sem = DispatchSemaphore(value: 0)
    var supported = false
    Task {
        if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            supported = true
        }
        sem.signal()
    }
    sem.wait()
    return supported ? 1 : 0
}

@_cdecl("hermes_speech_analyzer_start")
public func hermes_speech_analyzer_start(_ localeCStr: UnsafePointer<CChar>?, _ callback: HermesSpeechCallback?) -> Int32 {
    guard #available(macOS 26.0, *) else {
        logEngine("SpeechAnalyzer unavailable: macOS < 26")
        return -1
    }
    guard let localeCStr = localeCStr else { return -1 }
    guard let callback = callback else { return -2 }

    let locale = Locale(identifier: String(cString: localeCStr))
    gCallback = callback

    logEngine("starting locale=\(locale.identifier)")

    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    gTranscriber = transcriber

    let formatSem = DispatchSemaphore(value: 0)
    var targetFormat: AVAudioFormat?
    Task {
        targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        formatSem.signal()
    }
    formatSem.wait()
    guard let format = targetFormat else {
        logEngine("failed to determine audio format")
        return -3
    }
    gTargetFormat = format
    logEngine("audio format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

    notify(text: "preparing model", final: true)
    let assetSem = DispatchSemaphore(value: 0)
    var assetReady = false
    Task {
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .installed {
                assetReady = true
            } else {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                let newStatus = await AssetInventory.status(forModules: [transcriber])
                assetReady = (newStatus == .installed)
            }
        } catch {
            logEngine("asset installation error: \(error.localizedDescription)")
        }
        assetSem.signal()
    }
    assetSem.wait()
    guard assetReady else {
        logEngine("model asset not ready")
        return -4
    }
    logEngine("model asset ready")

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    gInputContinuation = continuation

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    gAnalyzer = analyzer

    Task { await gAccumulator.reset() }

    gAnalyzerTask = Task {
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            logEngine("analyzer error: \(error.localizedDescription)")
        }
    }

    gResultTask = Task {
        do {
            for try await result in transcriber.results {
                let (combined, isFinal) = await gAccumulator.accumulate(result)
                notify(text: combined, final: isFinal)
            }
        } catch {
            logEngine("result error: \(error.localizedDescription)")
        }
    }

    return 0
}

@_cdecl("hermes_speech_analyzer_feed_buffer")
public func hermes_speech_analyzer_feed_buffer(
    _ data: UnsafePointer<Float>?,
    _ frameCount: Int32,
    _ sampleRate: Double,
    _ channels: UInt32
) -> Int32 {
    guard #available(macOS 26.0, *) else { return -1 }
    guard let data = data, frameCount > 0 else { return 0 }
    guard let targetFormat = gTargetFormat else { return -2 }

    let frames = AVAudioFrameCount(frameCount)
    guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channels),
                                        interleaved: false),
          let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return -3 }
    srcBuffer.frameLength = frames
    memcpy(srcBuffer.floatChannelData![0], data, Int(frameCount) * MemoryLayout<Float>.size)

    if srcFormat == targetFormat {
        gInputContinuation?.yield(AnalyzerInput(buffer: srcBuffer))
        return 0
    }
    guard let converter = converterTo(targetFormat, from: srcFormat) else { return -5 }

    let ratio = targetFormat.sampleRate / srcFormat.sampleRate
    let outCap = AVAudioFrameCount(Double(frameCount) * ratio) + 16
    guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return -6 }

    var provided = false
    var convErr: NSError?
    _ = converter.convert(to: dstBuffer, error: &convErr) { _, outStatus in
        if provided { outStatus.pointee = .noDataNow; return nil }
        provided = true
        outStatus.pointee = .haveData
        return srcBuffer
    }
    if let err = convErr {
        logEngine("converter error: \(err.localizedDescription)")
        return -7
    }
    if dstBuffer.frameLength == 0 { return 0 }
    gInputContinuation?.yield(AnalyzerInput(buffer: dstBuffer))
    return 0
}

@_cdecl("hermes_speech_analyzer_reset")
public func hermes_speech_analyzer_reset() {
    Task { await gAccumulator.reset() }
}

@_cdecl("hermes_speech_analyzer_stop")
public func hermes_speech_analyzer_stop() {
    guard #available(macOS 26.0, *) else { return }
    logEngine("stopping")

    gInputContinuation?.finish()
    gInputContinuation = nil

    if let analyzer = gAnalyzer {
        Task {
            await analyzer.cancelAndFinishNow()
        }
    }
    gAnalyzer = nil
    gTranscriber = nil

    gAnalyzerTask?.cancel()
    gAnalyzerTask = nil
    gResultTask?.cancel()
    gResultTask = nil
    gCallback = nil
    gTargetFormat = nil
    gConverter = nil
    gConverterSrc = nil
    Task { await gAccumulator.reset() }
}

private func notify(text: String, final: Bool) {
    guard let callback = gCallback else { return }
    var bytes = Array(text.utf8CString)
    bytes.withUnsafeMutableBufferPointer { ptr in
        if let base = ptr.baseAddress {
            callback(base, final ? 1 : 0)
        }
    }
}
