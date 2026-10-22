//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
// macOS speech to captions: the Speech framework's recognizer, on the device only. Every request sets
// `requiresOnDeviceRecognition`, and none is built for a language whose recognizer cannot run on the device.
#if os(macOS)
import Foundation
import Speech

/// The Speech framework behind `OnDeviceSpeechBackend`.
struct SFSpeechBackend: OnDeviceSpeechBackend {
    func authorization() -> SpeechAuthorization { Self.map(SFSpeechRecognizer.authorizationStatus()) }

    func requestAuthorization() async -> SpeechAuthorization {
        await withCheckedContinuation { (resume: CheckedContinuation<SpeechAuthorization, Never>) in
            SFSpeechRecognizer.requestAuthorization { resume.resume(returning: Self.map($0)) }
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func onDeviceLocales() -> [String] {
        SFSpeechRecognizer.supportedLocales().filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .map(\.identifier).sorted()
    }

    func hasRecognizer(locale: String) -> Bool { SFSpeechRecognizer(locale: Locale(identifier: locale)) != nil }

    func supportsOnDevice(locale: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
    }

    /// The one place a request is built: on-device only, final result only.
    static func makeRequest(url: URL) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return request
    }

    func recognise(path: String, locale: String, cancel: MediaCancellation) async throws -> [SpeechSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable(.noOnDeviceModelForLanguage(locale))
        }
        let request = Self.makeRequest(url: URL(fileURLWithPath: path))
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<[SpeechSegment], Error>) in
                cancel.onCancel { box.cancel(); box.finish { resume.resume(throwing: TranscriptionError.cancelled) } }
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error = error as NSError? {
                        box.finish { resume.resume(throwing: TranscriptionError.recognizerFailed(code: error.code, message: error.localizedDescription)) }
                    } else if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map {
                            SpeechSegment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration, confidence: Double($0.confidence))
                        }
                        box.finish { resume.resume(returning: segments) }
                    }
                }
                if cancel.isCancelled { box.cancel(); box.finish { resume.resume(throwing: TranscriptionError.cancelled) } }
            }
        } onCancel: { box.cancel() }
    }
}

/// Holds the recognition task and makes sure the continuation is resumed once.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var _task: SFSpeechRecognitionTask?
    var task: SFSpeechRecognitionTask? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set { lock.lock(); _task = newValue; lock.unlock() }
    }
    func cancel() { task?.cancel() }
    func finish(_ resume: () -> Void) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { resume() }
    }
}

/// The macOS service: Speech framework recognition on the device.
public func makeMacSpeechTranscriptionService() -> TranscriptionService {
    OnDeviceSpeechService(backend: SFSpeechBackend(), settingPath: macSpeechSettingPath)
}
#endif
