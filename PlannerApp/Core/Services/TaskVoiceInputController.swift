import AVFoundation
import Combine
import Speech
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TaskVoiceInputState: Equatable {
    case idle
    case requestingPermission
    case listening
    case failed(String)
}

enum TaskVoiceInputError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case invalidAudioInput
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Доступ к распознаванию речи запрещён. Разрешите его в системных настройках."
        case .microphonePermissionDenied:
            "Доступ к микрофону запрещён. Разрешите его в системных настройках."
        case .recognizerUnavailable:
            "Русское распознавание речи сейчас недоступно."
        case .invalidAudioInput:
            "Не удалось получить аудиосигнал с микрофона."
        case .recognitionFailed(let message):
            "Не удалось распознать речь: \(message)"
        }
    }
}

@MainActor
protocol TaskSpeechInputProviding: AnyObject {
    func requestAuthorization() async -> Result<Void, TaskVoiceInputError>
    func start(
        locale: Locale,
        onResult: @escaping (String, Bool) -> Void,
        onFailure: @escaping (TaskVoiceInputError) -> Void
    ) throws
    func stop()
}

@MainActor
final class SystemTaskSpeechInputProvider: TaskSpeechInputProviding {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var onResult: ((String, Bool) -> Void)?
    private var onFailure: ((TaskVoiceInputError) -> Void)?

    func requestAuthorization() async -> Result<Void, TaskVoiceInputError> {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return .failure(.speechPermissionDenied)
        }

        #if os(iOS)
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif

        return microphoneGranted ? .success(()) : .failure(.microphonePermissionDenied)
    }

    func start(
        locale: Locale,
        onResult: @escaping (String, Bool) -> Void,
        onFailure: @escaping (TaskVoiceInputError) -> Void
    ) throws {
        stop()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TaskVoiceInputError.recognizerUnavailable
        }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TaskVoiceInputError.invalidAudioInput
        }

        self.onResult = onResult
        self.onFailure = onFailure
        recognitionRequest = request

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.onResult?(result.bestTranscription.formattedString, result.isFinal)
                    if result.isFinal {
                        self.finish(cancelRecognition: false)
                    }
                } else if let error {
                    let handler = self.onFailure
                    self.finish(cancelRecognition: true)
                    handler?(.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        finish(cancelRecognition: true)
    }

    private func finish(cancelRecognition: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        recognitionRequest?.endAudio()
        if cancelRecognition {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionRequest = nil
        onResult = nil
        onFailure = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

@MainActor
final class TaskVoiceInputController: ObservableObject {
    @Published private(set) var state: TaskVoiceInputState = .idle
    @Published private(set) var activeFieldID: String?

    private let provider: TaskSpeechInputProviding
    private var baseText = ""
    private var updateText: ((String) -> Void)?
    private var requestGeneration = UUID()

    init(provider: TaskSpeechInputProviding? = nil) {
        self.provider = provider ?? SystemTaskSpeechInputProvider()
    }

    func toggle(fieldID: String, currentText: String, updateText: @escaping (String) -> Void) {
        if activeFieldID == fieldID, state == .listening || state == .requestingPermission {
            stop()
            return
        }

        stop()
        let generation = UUID()
        requestGeneration = generation
        activeFieldID = fieldID
        baseText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updateText = updateText
        state = .requestingPermission

        Task {
            let authorization = await provider.requestAuthorization()
            guard requestGeneration == generation, activeFieldID == fieldID else { return }

            switch authorization {
            case .success:
                do {
                    try provider.start(
                        locale: Locale(identifier: "ru-RU"),
                        onResult: { [weak self] transcript, isFinal in
                            Task { @MainActor in
                                self?.receive(transcript: transcript, isFinal: isFinal, fieldID: fieldID)
                            }
                        },
                        onFailure: { [weak self] error in
                            Task { @MainActor in
                                self?.fail(error, fieldID: fieldID)
                            }
                        }
                    )
                    state = .listening
                } catch let error as TaskVoiceInputError {
                    fail(error, fieldID: fieldID)
                } catch {
                    fail(.recognitionFailed(error.localizedDescription), fieldID: fieldID)
                }
            case .failure(let error):
                fail(error, fieldID: fieldID)
            }
        }
    }

    func stop(ifActive fieldID: String? = nil) {
        if let fieldID, activeFieldID != fieldID {
            return
        }
        stop()
    }

    func stop() {
        requestGeneration = UUID()
        provider.stop()
        activeFieldID = nil
        updateText = nil
        baseText = ""
        if case .failed = state {
            return
        }
        state = .idle
    }

    func isActive(fieldID: String) -> Bool {
        activeFieldID == fieldID && (state == .listening || state == .requestingPermission)
    }

    func errorMessage(fieldID: String) -> String? {
        guard activeFieldID == fieldID, case .failed(let message) = state else {
            return nil
        }
        return message
    }

    func clearError(fieldID: String) {
        guard activeFieldID == fieldID else { return }
        activeFieldID = nil
        state = .idle
    }

    static func mergedText(base: String, transcript: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return transcript }
        if transcript.isEmpty { return base }
        return base + " " + transcript
    }

    private func receive(transcript: String, isFinal: Bool, fieldID: String) {
        guard activeFieldID == fieldID else { return }
        updateText?(Self.mergedText(base: baseText, transcript: transcript))
        if isFinal {
            provider.stop()
            activeFieldID = nil
            updateText = nil
            baseText = ""
            state = .idle
        }
    }

    private func fail(_ error: TaskVoiceInputError, fieldID: String) {
        guard activeFieldID == fieldID else { return }
        provider.stop()
        updateText = nil
        baseText = ""
        state = .failed(error.localizedDescription)
    }
}

struct TaskVoiceInputButton: View {
    enum Presentation {
        case compact
        case toolbar
    }

    @EnvironmentObject private var controller: TaskVoiceInputController
    let fieldID: String
    @Binding var text: String
    let label: String
    let presentation: Presentation

    init(
        fieldID: String,
        text: Binding<String>,
        label: String = "Надиктовать название задачи",
        presentation: Presentation = .compact
    ) {
        self.fieldID = fieldID
        _text = text
        self.label = label
        self.presentation = presentation
    }

    var body: some View {
        Button {
            controller.toggle(fieldID: fieldID, currentText: text) { text = $0 }
        } label: {
            if controller.activeFieldID == fieldID, controller.state == .requestingPermission {
                ProgressView()
                    .controlSize(.small)
                    .tint(PlannerTheme.accent)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: presentation == .toolbar ? 14 : 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
        }
        .buttonStyle(
            GlassHoverIconButtonStyle(
                size: presentation == .toolbar ? 26 : 28,
                tint: controller.isActive(fieldID: fieldID) ? PlannerTheme.danger : PlannerTheme.secondaryText,
                isProminent: false,
                appliesEffect: presentation == .toolbar
            )
        )
        .help(controller.isActive(fieldID: fieldID) ? "Остановить диктовку" : label)
        .accessibilityLabel(controller.isActive(fieldID: fieldID) ? "Остановить диктовку" : label)
        .alert("Голосовой ввод", isPresented: failureBinding) {
            Button("Настройки") { openSystemSettings() }
            Button("ОК", role: .cancel) { controller.clearError(fieldID: fieldID) }
        } message: {
            Text(controller.errorMessage(fieldID: fieldID) ?? "")
        }
        .onDisappear { controller.stop(ifActive: fieldID) }
    }

    private var systemImage: String {
        if presentation == .toolbar {
            return controller.isActive(fieldID: fieldID) ? "stop.fill" : "mic.fill"
        }
        return controller.isActive(fieldID: fieldID) ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var iconColor: Color {
        if presentation == .toolbar {
            return controller.isActive(fieldID: fieldID) ? PlannerTheme.danger : PlannerTheme.secondaryText
        }
        return controller.isActive(fieldID: fieldID) ? PlannerTheme.danger : PlannerTheme.accent
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { controller.errorMessage(fieldID: fieldID) != nil },
            set: { if !$0 { controller.clearError(fieldID: fieldID) } }
        )
    }

    private func openSystemSettings() {
        controller.clearError(fieldID: fieldID)
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
