import SwiftUI
import AVFoundation
import AppKit

// MARK: - Configuration

enum Config {
    /// Корень нашего апп-репо (Silero + F5 скрипты, venv, voice_samples).
    static let appRoot = ("~/projects/supertonic-mac" as NSString).expandingTildeInPath
    /// Корень upstream Supertonic-клона (ONNX assets и example_onnx.py).
    static let upstreamRoot = ("~/projects/supertonic" as NSString).expandingTildeInPath

    static var pythonBin: String { "\(appRoot)/py/.venv/bin/python" }
    static var pyWorkDir: String { "\(appRoot)/py" }

    static var supertonicScript: String { "\(upstreamRoot)/py/example_onnx.py" }
    static var supertonicWorkDir: String { "\(upstreamRoot)/py" }
    static var voiceStylesDir: String { "\(upstreamRoot)/assets/voice_styles" }

    static var sileroScript: String { "\(appRoot)/py/silero_synth.py" }
    static var f5Script: String { "\(appRoot)/py/f5_synth.py" }
    static var asrScript: String { "\(appRoot)/py/asr_gigaam.py" }
    static var workerScript: String { "\(appRoot)/py/tts_worker.py" }

    static var voiceSamplesDir: String { "\(appRoot)/voice_samples" }
    static var voiceSamplesIndex: String { "\(voiceSamplesDir)/index.json" }

    static let supertonicVoices = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
    static let sileroVoices = ["aidar", "baya", "kseniya", "xenia", "eugene"]
}

// MARK: - Voice samples (for F5 cloning)

struct VoiceSample: Codable, Identifiable, Equatable, Hashable {
    var id: String              // slug, also used as voice name in pickers
    var displayName: String
    var audioPath: String       // absolute path inside voice_samples/
    var refText: String         // transcription of what's spoken in the audio
    var createdAt: Date

    static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.lowercaseLetters
            .union(CharacterSet.decimalDigits)
            .union(CharacterSet(charactersIn: "-_"))
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var raw = String(mapped)
        while raw.contains("--") {
            raw = raw.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "sample-\(Int(Date().timeIntervalSince1970))" : trimmed
    }
}

@MainActor
final class VoiceSamplesStore: ObservableObject {
    @Published private(set) var samples: [VoiceSample] = []

    init() { load() }

    private func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: Config.voiceSamplesDir,
            withIntermediateDirectories: true
        )
    }

    func load() {
        ensureDir()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Config.voiceSamplesIndex)),
              let list = try? JSONDecoder.iso.decode([VoiceSample].self, from: data) else {
            samples = []
            return
        }
        samples = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        ensureDir()
        let data = (try? JSONEncoder.pretty.encode(samples)) ?? Data()
        try? data.write(to: URL(fileURLWithPath: Config.voiceSamplesIndex), options: .atomic)
    }

    @discardableResult
    func importSample(name: String, sourceAudio: URL, refText: String) throws -> VoiceSample {
        ensureDir()
        let slug = VoiceSample.slug(from: name)
        // ensure uniqueness
        var unique = slug
        var n = 1
        while samples.contains(where: { $0.id == unique }) {
            n += 1
            unique = "\(slug)-\(n)"
        }
        let ext = sourceAudio.pathExtension.isEmpty ? "wav" : sourceAudio.pathExtension
        let dest = URL(fileURLWithPath: Config.voiceSamplesDir)
            .appendingPathComponent("\(unique).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceAudio, to: dest)
        let sample = VoiceSample(
            id: unique,
            displayName: name.isEmpty ? unique : name,
            audioPath: dest.path,
            refText: refText,
            createdAt: Date()
        )
        samples.insert(sample, at: 0)
        save()
        return sample
    }

    func delete(_ sample: VoiceSample) {
        try? FileManager.default.removeItem(atPath: sample.audioPath)
        samples.removeAll { $0.id == sample.id }
        save()
    }

    func update(_ sample: VoiceSample) {
        if let idx = samples.firstIndex(where: { $0.id == sample.id }) {
            samples[idx] = sample
            save()
        }
    }

    func sample(byId id: String) -> VoiceSample? {
        samples.first { $0.id == id }
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Engine

enum Engine: String, CaseIterable, Identifiable {
    case auto
    case supertonic
    case silero
    case f5

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .supertonic: return "Supertonic"
        case .silero: return "Silero (RU)"
        case .f5: return "F5 (clone)"
        }
    }

    var defaultVoice: String {
        switch self {
        case .supertonic, .auto: return "M1"
        case .silero: return "aidar"
        case .f5: return ""
        }
    }

    /// Голоса для пресетных движков. Для .f5 список голосов формируется из VoiceSamplesStore отдельно.
    func presetVoices() -> [String] {
        switch self {
        case .supertonic: return Config.supertonicVoices
        case .silero: return Config.sileroVoices
        case .auto: return Config.supertonicVoices + Config.sileroVoices
        case .f5: return []
        }
    }
}

/// Считает долю кириллических букв среди буквенных символов.
func cyrillicShare(_ text: String) -> Double {
    var letters = 0
    var cyr = 0
    for s in text.unicodeScalars where CharacterSet.letters.contains(s) {
        letters += 1
        let v = s.value
        if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
            cyr += 1
        }
    }
    guard letters > 0 else { return 0 }
    return Double(cyr) / Double(letters)
}

func resolveEngine(selected: Engine, text: String) -> Engine {
    if selected != .auto { return selected }
    // Auto never picks F5 — F5 needs an explicit voice sample.
    return cyrillicShare(text) > 0.3 ? .silero : .supertonic
}

// MARK: - Synthesis engine

enum SynthesisError: Error, LocalizedError {
    case pythonMissing
    case scriptFailed(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "Не найден Python venv по пути \(Config.pythonBin). Запустите `uv sync` в \(Config.pyWorkDir)."
        case .scriptFailed(let s): return "Ошибка синтеза: \(s)"
        case .noOutput: return "Скрипт отработал, но WAV не появился."
        }
    }
}

// MARK: - Persistent Python worker

enum WorkerError: Error, LocalizedError {
    case pythonMissing
    case workerDied(String)
    case badResponse(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing: return "Не найден Python venv (\(Config.pythonBin))."
        case .workerDied(let s): return "Python worker умер: \(s)"
        case .badResponse(let s): return "Неверный ответ worker'а: \(s)"
        case .remote(let s): return s
        }
    }
}

/// Long-lived Python process shared by all engines.
/// Single instance, serial command queue (actor ensures one-at-a-time).
actor WorkerEngine {
    static let shared = WorkerEngine()

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var readBuffer = Data()

    private func ensureRunning() async throws {
        if let p = process, p.isRunning { return }
        guard FileManager.default.fileExists(atPath: Config.pythonBin) else {
            throw WorkerError.pythonMissing
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Config.pythonBin)
        proc.currentDirectoryURL = URL(fileURLWithPath: Config.pyWorkDir)
        proc.arguments = [Config.workerScript]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Drain stderr so the pipe never fills and stalls Python.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try proc.run()
        process = proc
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading
        readBuffer = Data()

        // Wait for {"ready": true}
        let ready = try await readLineFromStdout(timeoutSeconds: 30)
        guard ready.contains("\"ready\"") else {
            throw WorkerError.workerDied("first line was '\(ready)' instead of ready signal")
        }
    }

    private func readLineFromStdout(timeoutSeconds: TimeInterval) async throws -> String {
        guard let out = stdout else { throw WorkerError.workerDied("no stdout") }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let newline = UInt8(0x0A)
        while true {
            if let i = readBuffer.firstIndex(of: newline) {
                let lineData = readBuffer.subdata(in: 0..<i)
                readBuffer.removeSubrange(0...i)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = out.availableData
            if chunk.isEmpty {
                if let p = process, !p.isRunning {
                    throw WorkerError.workerDied("exit code \(p.terminationStatus)")
                }
                if Date() > deadline {
                    throw WorkerError.workerDied("readline timeout after \(Int(timeoutSeconds))s")
                }
                // Brief sleep to avoid busy loop. availableData is non-blocking.
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            readBuffer.append(chunk)
        }
    }

    /// Send a request, await one JSON response. Big synthesis calls get long timeouts.
    func send(_ payload: [String: Any], timeoutSeconds: TimeInterval = 600) async throws -> [String: Any] {
        try await ensureRunning()
        guard let inHandle = stdin else { throw WorkerError.workerDied("no stdin") }

        let data = try JSONSerialization.data(withJSONObject: payload)
        inHandle.write(data)
        inHandle.write(Data([0x0A]))

        let line = try await readLineFromStdout(timeoutSeconds: timeoutSeconds)
        guard let bytes = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw WorkerError.badResponse(line)
        }
        if let ok = obj["ok"] as? Bool, ok == false {
            throw WorkerError.remote(obj["error"] as? String ?? "unknown error")
        }
        return obj
    }
}

// MARK: - ASR (GigaAM v3 MLX)

enum ASRError: Error, LocalizedError {
    case pythonMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing: return "Не найден Python venv (\(Config.pythonBin))."
        case .failed(let s): return "ASR ошибка: \(s)"
        }
    }
}

struct ASR {
    static func transcribe(audio: URL) async throws -> String {
        do {
            let resp = try await WorkerEngine.shared.send(
                ["action": "asr_gigaam", "audio": audio.path],
                timeoutSeconds: 60
            )
            return (resp["text"] as? String) ?? ""
        } catch let WorkerError.remote(msg) {
            throw ASRError.failed(msg)
        }
    }
}

struct Synthesizer {
    static func synthesize(text: String, voice: String, engine: Engine, sample: VoiceSample? = nil) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supertonic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let outFile = tmpDir.appendingPathComponent("out.wav")

        var payload: [String: Any]
        switch engine {
        case .silero:
            payload = [
                "action": "synthesize_silero",
                "voice": voice,
                "text": text,
                "out": outFile.path,
            ]
        case .f5:
            guard let sample else {
                throw SynthesisError.scriptFailed("F5: не выбран голосовой образец")
            }
            payload = [
                "action": "synthesize_f5",
                "text": text,
                "ref_audio": sample.audioPath,
                "ref_text": sample.refText,
                "out": outFile.path,
                "backend": "auto",
            ]
        case .supertonic, .auto:
            payload = [
                "action": "synthesize_supertonic",
                "voice": voice,
                "text": text,
                "out": outFile.path,
            ]
        }

        do {
            _ = try await WorkerEngine.shared.send(payload, timeoutSeconds: 600)
        } catch let WorkerError.remote(msg) {
            throw SynthesisError.scriptFailed(msg)
        } catch WorkerError.pythonMissing {
            throw SynthesisError.pythonMissing
        }

        guard FileManager.default.fileExists(atPath: outFile.path) else {
            throw SynthesisError.noOutput
        }
        return outFile
    }
}

// MARK: - View model

@MainActor
final class AppModel: ObservableObject {
    @Published var text: String = "Привет! Это локальный синтез на твоём маке."
    @Published var engine: Engine = .auto
    @Published var voice: String = "aidar"
    @Published var status: String = ""
    @Published var isGenerating: Bool = false
    @Published var isPlaying: Bool = false

    let samples: VoiceSamplesStore

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var cachedWav: URL?
    private var cacheKey: String = ""

    init(samples: VoiceSamplesStore) {
        self.samples = samples
    }

    var effectiveEngine: Engine { resolveEngine(selected: engine, text: text) }

    var availableVoices: [String] {
        if effectiveEngine == .f5 {
            return samples.samples.map(\.id)
        }
        return effectiveEngine.presetVoices()
    }

    /// Гарантирует, что выбранный голос валиден для текущего движка.
    func ensureVoiceValid() {
        let voices = availableVoices
        if voices.isEmpty {
            voice = effectiveEngine.defaultVoice
        } else if !voices.contains(voice) {
            voice = voices.first ?? effectiveEngine.defaultVoice
        }
    }

    private func currentKey() -> String { "\(effectiveEngine.rawValue)::\(voice)::\(text)" }

    private func currentSample() -> VoiceSample? {
        guard effectiveEngine == .f5 else { return nil }
        return samples.sample(byId: voice)
    }

    private func engineLabel(_ e: Engine) -> String {
        switch e {
        case .silero: return "Silero"
        case .f5: return "F5"
        case .supertonic, .auto: return "Supertonic"
        }
    }

    func playOrStop() {
        if isPlaying {
            player?.stop()
            isPlaying = false
            status = "Остановлено"
            return
        }
        Task { await generateAndPlay() }
    }

    private func generateAndPlay() async {
        let key = currentKey()
        if let url = cachedWav, key == cacheKey {
            play(url: url)
            return
        }
        isGenerating = true
        status = "Генерация…"
        let start = Date()
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                status = "Введите текст"
                isGenerating = false
                return
            }
            let eng = effectiveEngine
            let engLabel = engineLabel(eng)
            if eng == .f5 && currentSample() == nil {
                status = "Загрузите хотя бы один образец голоса"
                isGenerating = false
                return
            }
            status = "\(engLabel): генерация…"
            let url = try await Synthesizer.synthesize(text: trimmed, voice: voice, engine: eng, sample: currentSample())
            cachedWav = url
            cacheKey = key
            let took = Date().timeIntervalSince(start)
            status = String(format: "%@: готово за %.2fс", engLabel, took)
            isGenerating = false
            play(url: url)
        } catch {
            isGenerating = false
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func play(url: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let delegate = PlayerDelegate { [weak self] in
                Task { @MainActor in
                    self?.isPlaying = false
                }
            }
            p.delegate = delegate
            playerDelegate = delegate
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
        } catch {
            status = "Не удалось проиграть: \(error.localizedDescription)"
        }
    }

    func export() {
        Task { await ensureWavThenExport() }
    }

    private func ensureWavThenExport() async {
        let key = currentKey()
        var url = cachedWav
        if url == nil || key != cacheKey {
            isGenerating = true
            status = "Генерация для экспорта…"
            do {
                let u = try await Synthesizer.synthesize(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    voice: voice,
                    engine: effectiveEngine,
                    sample: currentSample()
                )
                cachedWav = u
                cacheKey = key
                url = u
                status = "Готово"
            } catch {
                isGenerating = false
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
            isGenerating = false
        }
        guard let wavURL = url else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = suggestedFilename()
        panel.canCreateDirectories = true
        let response = panel.runModal()
        if response == .OK, let dst = panel.url {
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: wavURL, to: dst)
                status = "Сохранено: \(dst.lastPathComponent)"
            } catch {
                status = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }

    private func suggestedFilename() -> String {
        let words = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .joined(separator: "_")
        let base = words.isEmpty ? "supertonic" : String(words.prefix(40))
        return "\(base).wav"
    }

    func invalidateCache() {
        cachedWav = nil
        cacheKey = ""
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish()
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var samplesStore: VoiceSamplesStore
    @StateObject private var model: AppModel
    @FocusState private var textFocused: Bool
    @State private var showHelp = false
    @State private var showSamples = false

    init() {
        let store = VoiceSamplesStore()
        _samplesStore = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: AppModel(samples: store))
    }

    private var autoBadge: String {
        guard model.engine == .auto else { return "" }
        return "auto → \(model.effectiveEngine == .silero ? "Silero" : "Supertonic")"
    }

    private func voiceLabel(_ id: String) -> String {
        if let s = samplesStore.sample(byId: id) { return s.displayName }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Supertonic")
                    .font(.system(size: 22, weight: .semibold))
                Button(action: { showHelp.toggle() }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Подсказка: как делать паузы, ударения и теги")
                .popover(isPresented: $showHelp, arrowEdge: .top) {
                    HelpView()
                }
                Spacer()
            }

            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .focused($textFocused)
                .frame(minHeight: 180)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .onChange(of: model.text) { _, _ in
                    model.invalidateCache()
                    model.ensureVoiceValid()
                }

            HStack(spacing: 12) {
                Text("Движок:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.engine) {
                    ForEach(Engine.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: model.engine) { _, _ in
                    model.invalidateCache()
                    model.ensureVoiceValid()
                }

                Text("Голос:")
                    .foregroundStyle(.secondary)
                if model.availableVoices.isEmpty {
                    Text("(нет образцов)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                } else {
                    Picker("", selection: $model.voice) {
                        ForEach(model.availableVoices, id: \.self) { v in
                            Text(voiceLabel(v)).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: model.voice) { _, _ in model.invalidateCache() }
                }

                Button(action: { showSamples = true }) {
                    Image(systemName: "person.crop.square.badge.plus")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Управление голосовыми образцами (для F5)")

                Spacer()

                Text(autoBadge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(Capsule())

                if model.isGenerating {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }

                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button(action: { model.playOrStop() }) {
                    Label(model.isPlaying ? "Стоп" : "Play",
                          systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 70)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isGenerating || model.text.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(action: { model.export() }) {
                    Label("Экспорт WAV", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.isGenerating || model.text.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 420)
        .sheet(isPresented: $showSamples) {
            SamplesSheet(store: samplesStore)
                .frame(minWidth: 600, minHeight: 420)
        }
        .onChange(of: samplesStore.samples) { _, _ in
            model.ensureVoiceValid()
        }
    }
}

// MARK: - Voice samples UI

struct SamplesSheet: View {
    @ObservedObject var store: VoiceSamplesStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Голосовые образцы")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: { showAdd = true }) {
                    Label("Добавить", systemImage: "plus")
                }
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.return, modifiers: [])
            }

            if store.samples.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "person.crop.square.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Образцов пока нет")
                        .foregroundStyle(.secondary)
                    Text("Импортируйте WAV/MP3 с записью голоса (≥5 секунд) и укажите, что в нём говорится. Этот текст важен для F5 — он используется как образец произношения.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(store.samples) { sample in
                        SampleRow(sample: sample, store: store)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .sheet(isPresented: $showAdd) {
            AddSampleSheet(store: store)
                .frame(minWidth: 540, minHeight: 380)
        }
    }
}

struct SampleRow: View {
    let sample: VoiceSample
    @ObservedObject var store: VoiceSamplesStore
    @State private var editingText: String = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sample.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(sample.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { previewAudio() }) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .help("Проиграть образец")

                Button(action: { startEdit() }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Изменить транскрипцию")

                Button(action: { store.delete(sample) }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Удалить")
            }
            if isEditing {
                TextEditor(text: $editingText)
                    .font(.system(size: 12))
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                HStack {
                    Spacer()
                    Button("Отмена") { isEditing = false }
                    Button("Сохранить") {
                        var updated = sample
                        updated.refText = editingText
                        store.update(updated)
                        isEditing = false
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            } else {
                Text(sample.refText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func startEdit() {
        editingText = sample.refText
        isEditing = true
    }

    private func previewAudio() {
        // Open in default player — keep it simple. Used for quick verification.
        NSWorkspace.shared.open(URL(fileURLWithPath: sample.audioPath))
    }
}

struct AddSampleSheet: View {
    @ObservedObject var store: VoiceSamplesStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var sourceURL: URL?
    @State private var refText: String = ""
    @State private var errorMessage: String = ""
    @State private var isRecognizing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новый образец голоса")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Имя (как будет в списке голосов)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("например: my-voice", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Аудиофайл (WAV / MP3 / FLAC, 5–15 сек)").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Text(sourceURL?.lastPathComponent ?? "не выбран")
                        .foregroundStyle(sourceURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Выбрать…") { pickFile() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Что говорится в этом файле — транскрипция")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: { recognize() }) {
                        HStack(spacing: 4) {
                            if isRecognizing {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "waveform.badge.magnifyingglass")
                            }
                            Text(isRecognizing ? "Распознаю…" : "Распознать (GigaAM)")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(sourceURL == nil || isRecognizing)
                    .help("Распознать речь через локальный GigaAM v3 (MLX). Работает офлайн.")
                }
                TextEditor(text: $refText)
                    .font(.system(size: 13))
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                Text("Важно: текст должен совпадать с тем, что реально звучит в файле. F5 использует это как образец произношения.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") { addSample() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(sourceURL == nil || refText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceURL = url
            if displayName.isEmpty {
                displayName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func recognize() {
        guard let url = sourceURL, !isRecognizing else { return }
        isRecognizing = true
        errorMessage = ""
        Task {
            do {
                let text = try await ASR.transcribe(audio: url)
                await MainActor.run {
                    refText = text
                    isRecognizing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isRecognizing = false
                }
            }
        }
    }

    private func addSample() {
        guard let url = sourceURL else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : displayName
        do {
            try store.importSample(
                name: name,
                sourceAudio: url,
                refText: refText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = "Не удалось импортировать: \(error.localizedDescription)"
        }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Как управлять синтезом")
                    .font(.system(size: 15, weight: .semibold))

                section(
                    title: "Паузы — обычной пунктуацией",
                    rows: [
                        ("запятая", "короткая пауза:  \"привет, как дела\""),
                        ("точка / ! / ?", "длиннее, со сменой интонации"),
                        ("многоточие", "ещё длиннее:  \"я думаю… да\""),
                        ("новая строка", "≈ 0.3 сек — длинный текст автоматически делится на чанки"),
                    ]
                )

                section(
                    title: "Интонация",
                    rows: [
                        ("?", "вопросительная — \"уверен?\""),
                        ("!", "восклицательная — \"невероятно!\""),
                        ("кавычки", "обычно произносятся естественнее: \"и тогда он сказал «нет»\""),
                    ]
                )

                section(
                    title: "Выразительные теги (Supertonic, 3 из 10 публично известны)",
                    rows: [
                        ("<laugh>", "смешок:  \"и это было смешно <laugh>\""),
                        ("<breath>", "вдох:  \"<breath> начнём сначала\""),
                        ("<sigh>", "вздох:  \"<sigh> ну ладно\""),
                    ],
                    footer: "Автор заявляет 10 тегов, но полный список не опубликован. Работают только в Supertonic. В Silero (RU) используются другие управляющие конструкции — см. ниже."
                )

                section(
                    title: "Silero (русский) — ударения и паузы",
                    rows: [
                        ("автоматика", "Silero сам ставит ударения и ё. В большинстве случаев — правильно."),
                        ("+гласная", "Ручное ударение, если автоматика ошиблась: \"с+интез\", \"за́мок vs зам+ок\""),
                        ("<break time=\"500ms\"/>", "Явная пауза заданной длины"),
                        ("<prosody rate=\"slow\">…</prosody>", "Замедление куска речи"),
                        ("<p>…</p>", "Параграф — длинная пауза до и после"),
                        ("<s>…</s>", "Предложение — короткая пауза"),
                    ],
                    footer: "SSML-теги распознаёт только Silero. Supertonic их игнорирует."
                )

                section(
                    title: "Числа, даты, аббревиатуры",
                    rows: [
                        ("автоматически", "\"31.12.2025\", \"1500₽\", \"км/ч\" — нормализуются в речь без ручной разметки"),
                        ("эмодзи", "удаляются автоматически перед синтезом"),
                    ]
                )

                section(
                    title: "Выбор движка",
                    rows: [
                        ("Auto", "Определяет язык по тексту: >30% кириллицы → Silero, иначе Supertonic. F5 руками."),
                        ("Supertonic", "M1–F5, лучший английский, 30+ языков, без управления ударениями."),
                        ("Silero (RU)", "5 голосов, чистый русский, ударения автомат + ручные через +."),
                        ("F5 (clone)", "Клонирует голос из загруженного образца. Любой язык, но качество зависит от референса."),
                    ]
                )

                section(
                    title: "F5 — голосовое клонирование",
                    rows: [
                        ("образец", "Нажми иконку «человек+» рядом с picker голоса → импортируй WAV/MP3 5–15 сек чёткой речи без шума."),
                        ("транскрипция", "Введи в точности, что произносится в файле. F5 использует это как образец произношения."),
                        ("первый запуск", "F5 скачает ~1.4 ГБ модели при первом синтезе. Дальше — секунды на инициализацию."),
                        ("backend (auto)", "EN/ZH текст → MLX (native Apple Silicon, RTF ~2–3×). Кириллица → torch (медленнее RTF ~10×, но русский произносит без акцента)."),
                    ],
                    footer: "Лицензия модели F5-TTS — CC-BY-NC (некоммерческая). Для личного использования ок."
                )

                Text("Подсказка по горячим клавишам: ⌘↩ — Play / Стоп, ⌘E — экспорт WAV")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 460, alignment: .leading)
        }
        .frame(width: 460, height: 520)
    }

    @ViewBuilder
    private func section(title: String, rows: [(String, String)], footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

@main
struct SupertonicApp: App {
    var body: some Scene {
        WindowGroup("Supertonic") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
