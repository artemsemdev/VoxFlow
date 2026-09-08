import AVFoundation
import Foundation
import whisper

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let ratio = 16_000 / file.processingFormat.sampleRate
    let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 1024)!
    var consumed = false
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return inBuf
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

func peakRSS() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_maxrss) / 1_048_576
}

let processStart = Date()
func stamp(_ label: String) { print(String(format: "[t=%6.2f s] ", Date().timeIntervalSince(processStart)) + label) }
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: spike <model.bin> <audio.wav> [threads]"); exit(2) }
let threads = args.count > 3 ? Int32(args[3])! : Int32(ProcessInfo.processInfo.activeProcessorCount)
stamp("start"); let samples = try loadSamples(URL(fileURLWithPath: args[2])); stamp("audio decoded")
let audioSeconds = Double(samples.count) / 16_000
print("system: \(String(cString: whisper_print_system_info()))")
print("audio: \(String(format: "%.1f", audioSeconds)) s, threads: \(threads)")

var cparams = whisper_context_default_params()
cparams.use_gpu = true
cparams.flash_attn = true
let t0 = Date()
guard let ctx = whisper_init_from_file_with_params(args[1], cparams) else { print("model load failed"); exit(1) }
let loadSeconds = Date().timeIntervalSince(t0)
stamp("model loaded"); print("load: \(String(format: "%.2f", loadSeconds)) s, rss after load: \(String(format: "%.0f", peakRSS())) MB")

var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
params.n_threads = threads
params.language = nil          // auto-detect
params.detect_language = false
params.print_progress = false
params.print_realtime = false
params.print_special = false
params.no_timestamps = false

// language detection alone
let tl = Date()
var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
let langId = samples.withUnsafeBufferPointer { buf in
    whisper_pcm_to_mel(ctx, buf.baseAddress, Int32(buf.count), threads)
    return whisper_lang_auto_detect(ctx, 0, threads, &probs)
}
stamp("language detected"); print("language: \(String(cString: whisper_lang_str(langId))) p=\(String(format: "%.2f", probs[Int(langId)])) in \(String(format: "%.2f", Date().timeIntervalSince(tl))) s")

for run in 1...2 {
    let t1 = Date()
    let rc = samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
    let seconds = Date().timeIntervalSince(t1)
    guard rc == 0 else { print("whisper_full failed \(rc)"); exit(1) }
    let n = whisper_full_n_segments(ctx)
    print("run \(run): \(String(format: "%.2f", seconds)) s for \(String(format: "%.1f", audioSeconds)) s audio → RTF \(String(format: "%.3f", seconds / audioSeconds)) (\(String(format: "%.1f", audioSeconds / seconds))× realtime), \(n) segments, peak rss \(String(format: "%.0f", peakRSS())) MB")
    if run == 1 {
        for i in 0..<n {
            let t0s = Double(whisper_full_get_segment_t0(ctx, i)) / 100, t1s = Double(whisper_full_get_segment_t1(ctx, i)) / 100
            print(String(format: "  [%6.2f → %6.2f] ", t0s, t1s) + String(cString: whisper_full_get_segment_text(ctx, i)))
        }
    }
}
stamp("before free"); whisper_free(ctx); stamp("exit")
