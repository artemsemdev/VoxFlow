import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowTestSupport

enum RussianSpeechCase: String, CaseIterable, Sendable {
    case reminder, conditions, incident, planning, explanation, handover, proposal, retrospective
    var automatic: Bool { [.conditions, .planning, .handover, .retrospective].contains(self) }
    var minimumDuration: Double {
        switch self {
        case .reminder: 10
        case .conditions: 20
        case .incident: 45
        case .planning: 60
        case .explanation: 90
        case .handover: 120
        case .proposal: 150
        case .retrospective: 180
        }
    }
    var anchors: [String] {
        switch self {
        case .reminder: ["не отправляй ответ автоматически", "только после этого", "напоминание закончено"]
        case .conditions: ["не публикуй его", "хотя бы один", "не меняй срок встречи", "пояснение для руководителя"]
        case .incident: ["не означает что проблема решена", "не удаляй первую запись", "не заменяй", "не называй", "описание события завершено"]
        case .planning: ["не объединяйте разные ошибки", "не будем требовать", "лучше честно записать", "следующий конкретный шаг", "план недели закончен"]
        case .explanation: ["не следует выполнять без согласования", "потеря одного короткого слова", "сохранилось ли отрицание", "не нужно требовать", "объяснение завершено"]
        case .handover: ["не смешивайте эти группы", "не удаляйте эти материалы", "не следует обещать", "не называйте задачу завершённой", "передача работы завершена"]
        case .proposal: ["не переносите сразу все", "если улучшения не будет", "не объявлять участников", "не отправляйте окончательный вариант", "предыдущие версии", "предложение закончено"]
        case .retrospective: ["на первом этапе", "полные последовательности действий", "не заменяйте такое описание", "выбору небольших исправлений", "не закрывайте вопрос", "не должна превращаться", "другой участник", "не обещайте безошибочную работу", "подведение итогов завершено"]
        }
    }
}

private struct RussianSpeechFixture: Decodable {
    let id: String
    let frames: Int
    let parts: [String]
    static let directory = "Fixtures/RussianLongForm"

    static func load(_ scenario: RussianSpeechCase) throws -> Self {
        let url = try resource("manifest.json")
        let entries = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        return try #require(entries.first { $0.id == scenario.rawValue })
    }
    static func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: directory))
    }
    func reference() throws -> String {
        try String(contentsOf: Self.resource("\(id).txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func audio() throws -> AudioSamples {
        // Parts are storage chunks only. Restore the exact continuous recording before windowing.
        let samples = try parts.flatMap { try AudioDecoder().decode(Self.resource($0)).samples }
        try #require(samples.count == frames, "Missing, truncated or duplicated fixture parts")
        return AudioSamples(samples)
    }
    static func missingAnchors(_ anchors: [String], in text: String) -> [String] {
        let words = WordErrorRate.words(text)
        var cursor = 0
        return anchors.filter { anchor in
            let tokens = WordErrorRate.words(anchor)
            guard cursor <= words.count - tokens.count,
                  let start = (cursor...(words.count - tokens.count)).first(where: {
                      Array(words[$0..<($0 + tokens.count)]) == tokens
                  }) else { return true }
            cursor = start + tokens.count
            return false
        }
    }
}

extension TranscriptionE2ETests {
    @Test("Russian connected speech of increasing duration preserves content, negations and ending",
          .timeLimit(.minutes(10)), arguments: RussianSpeechCase.allCases)
    func russianLongForm(_ scenario: RussianSpeechCase) async throws {
        let fixture = try RussianSpeechFixture.load(scenario)
        let audio = try fixture.audio()
        #expect(audio.duration >= scenario.minimumDuration)
        let reference = try fixture.reference()
        let directory = TemporaryDirectory()
        let input = directory.file("\(scenario.rawValue).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)))
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.samples.count) }
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: buffer)
        }
        try await withEngine { engine, model in
            let options = TranscriptionOptions(language: scenario.automatic ? nil : "ru")
            let progress = Mutex<[Double]>([])
            let document = try await FileTranscriber(decoder: AudioDecoder(), engine: engine.fileEngine, modelID: model)
                .transcribe(input, options: options) { event in
                    if case .progress(let value) = event { progress.withLock { $0.append(value) } }
                }
            try checkRussian(document.transcript.plainText, reference: reference, scenario: scenario,
                             duration: audio.duration, route: "file", model: model)
            checkTimeline(document.transcript.segments, duration: audio.duration)
            #expect(abs(document.audioDuration - audio.duration) < 0.05)
            #expect(document.transcript.language == "ru")
            let values = progress.withLock { $0 }
            #expect(values.last == 1 && values.allSatisfy { (0...1).contains($0) })
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            try checkExports(document, in: directory)

            let previews = Mutex<[String]>([])
            let result = try await WindowedTranscriber(engine: engine).transcribe(chunks(audio), options: options) { event in
                if case .partialText(let text) = event { previews.withLock { $0.append(text) } }
            }
            try checkRussian(result.text, reference: reference, scenario: scenario,
                             duration: audio.duration, route: "dictation", model: model)
            checkTimeline(result.segments, duration: audio.duration)
            #expect(abs(result.duration - audio.duration) < 0.05)
            #expect(result.rawText == result.text)
            if scenario.automatic { #expect(result.language?.code == "ru") }
            let emitted = previews.withLock { $0 }
            #expect(emitted.last == result.text)
            #expect(emitted.count > 1, "Long dictation must deliver previews before the final result")
            #expect(zip(emitted, emitted.dropFirst()).allSatisfy { $1.hasPrefix($0) })
        }
    }

    private func checkRussian(_ text: String, reference: String, scenario: RussianSpeechCase,
                              duration: Double, route: String, model: String) throws {
        let wer = WordErrorRate.measure(reference: reference, hypothesis: text)
        let missing = RussianSpeechFixture.missingAnchors(scenario.anchors, in: text)
        var record: [String: Any] = ["scenario": scenario.rawValue, "model": model, "route": route,
                                   "duration": duration, "wer": wer, "missingAnchors": missing,
                                   "referenceWords": WordErrorRate.words(reference).count]
        let summary = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("RUSSIAN_E2E " + String(decoding: summary, as: UTF8.self))
        // Separate files avoid interleaving multi-page transcripts with native stderr logging.
        if let path = ProcessInfo.processInfo.environment["VOXFLOW_E2E_REPORT_DIR"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            record["reference"] = reference; record["actual"] = text
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("\(model)-\(scenario.rawValue)-\(route).json"), options: .atomic)
        }
        #expect(wer <= 0.15, "\(scenario.rawValue)/\(route) WER=\(wer); actual: \(text)")
        #expect(missing.isEmpty, "\(scenario.rawValue)/\(route) missing or reordered anchors: \(missing); actual: \(text)")
    }
}

@Suite("Russian long-form corpus")
struct RussianSpeechCorpusTests {
    @Test("all eight cases have continuous audio, ordered anchors and increasing durations")
    func integrity() throws {
        var previousDuration = 0.0
        for scenario in RussianSpeechCase.allCases {
            let fixture = try RussianSpeechFixture.load(scenario)
            let audio = try fixture.audio()
            #expect(audio.duration >= scenario.minimumDuration && audio.duration > previousDuration)
            previousDuration = audio.duration
            #expect(!fixture.parts.isEmpty && Set(fixture.parts).count == fixture.parts.count)
            #expect(RussianSpeechFixture.missingAnchors(scenario.anchors, in: try fixture.reference()).isEmpty)
            for part in fixture.parts {
                #expect(try Data(contentsOf: RussianSpeechFixture.resource(part)).count < 1_000_000)
            }
        }
    }
    @Test("anchor matching respects complete words and sequence")
    func anchors() {
        #expect(RussianSpeechFixture.missingAnchors(["не удаляй"], in: "вполне удаляй") == ["не удаляй"])
        #expect(RussianSpeechFixture.missingAnchors(["сначала", "потом"], in: "потом сначала") == ["потом"])
    }
}
