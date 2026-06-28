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
                let text = String(result.text.characters)
                let isFinal = CMTimeCompare(result.range.end, result.resultsFinalizationTime) <= 0
                notify(text: text, final: isFinal)
            }
        } catch {
            logEngine("result error: \(error.localizedDescription)")
        }
    }

    return 0
}

@_cdecl("hermes_speech_analyzer_feed_buffer")
public func hermes_speech_analyzer_feed_buffer(
    _ data: UnsafePointer<Int16>?,
    _ frameCount: Int32,
    _ sampleRate: Double,
    _ channels: UInt32
) -> Int32 {
    guard #available(macOS 26.0, *) else { return -1 }
    guard let data = data, frameCount > 0 else { return 0 }
    guard let targetFormat = gTargetFormat else { return -2 }

    let frames = AVAudioFrameCount(frameCount)
    guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: channels,
                                         interleaved: true) else { return -3 }
    guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return -4 }
    srcBuffer.frameLength = frames

    let bytes = Int(frameCount) * Int(channels) * MemoryLayout<Int16>.size
    memcpy(srcBuffer.audioBufferList.pointee.mBuffers.mData, data, bytes)

    guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return -5 }
    guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { return -6 }

    var error: NSError?
    converter.convert(to: dstBuffer, error: &error) { inNumPackets, outStatus in
        outStatus.pointee = .haveData
        return srcBuffer
    }

    if let err = error {
        logEngine("converter error: \(err.localizedDescription)")
        return -7
    }

    let input = AnalyzerInput(buffer: dstBuffer)
    gInputContinuation?.yield(input)
    return 0
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
