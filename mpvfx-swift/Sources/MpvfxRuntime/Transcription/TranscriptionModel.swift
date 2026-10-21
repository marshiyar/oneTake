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
// Speech to captions, step 1: what a transcription job takes, what it returns, and every way it can refuse or fail.
// Recognition runs on the user's machine only; no type here has a network parameter, and an adapter that cannot
// keep the audio on the device reports `.unavailable` rather than sending it anywhere.
import Foundation

/// One recognised word, in source-media milliseconds of the request's audio.
public struct RecognisedWord: Codable, Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// The recognizer's confidence in 0 ... 1, when it reports one.
    public var confidence: Double?
    public init(text: String, startMs: Int, endMs: Int, confidence: Double? = nil) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.confidence = confidence
    }
}

/// The words of one request, in order and never overlapping (a word may start where the one before ends), and the
/// locale they were recognised in.
public struct Transcript: Equatable, Sendable {
    public var words: [RecognisedWord]
    public var locale: String
    public init(words: [RecognisedWord], locale: String) { self.words = words; self.locale = locale }
}

/// The stretch of a clip's own sound to transcribe: `source` is the media file's project-relative path,
/// `sourceStart` and `sourceDuration` the clip's trimmed range in source seconds, `name` the clip's name as the
/// user's messages show it.
public struct TranscriptionClip: Equatable, Sendable {
    public var source: String
    public var sourceStart: Double
    public var sourceDuration: Double
    public var name: String
    public init(source: String, sourceStart: Double, sourceDuration: Double, name: String) {
        self.source = source; self.sourceStart = sourceStart; self.sourceDuration = sourceDuration; self.name = name
    }
}

/// One clip of one project, in one language. The clip's FX, volume and automation are never applied: recognition
/// hears the recording, not the mix.
public struct TranscriptionRequest: Equatable, Sendable {
    public var projectRoot: String
    public var clip: TranscriptionClip
    /// A BCP 47 language tag, for example `en-US`.
    public var locale: String
    public init(projectRoot: String, clip: TranscriptionClip, locale: String) {
        self.projectRoot = projectRoot; self.clip = clip; self.locale = locale
    }
    public var source: String { clip.source }
    public var sourceStart: Double { clip.sourceStart }
    public var sourceDuration: Double { clip.sourceDuration }
    public var clipName: String { clip.name }
    /// The media file's name as the media bin shows it.
    public var assetName: String { PosixPath.basename(clip.source) }
}

/// Pieces recognised so far out of the pieces the request's audio was split into.
public struct TranscriptionProgress: Equatable, Sendable {
    public var piecesDone: Int
    public var piecesTotal: Int
    public init(piecesDone: Int, piecesTotal: Int) { self.piecesDone = piecesDone; self.piecesTotal = piecesTotal }
}

public enum TranscriptionAvailability: Equatable, Sendable {
    case available
    case unavailable(TranscriptionUnavailableReason)
}

/// Why speech cannot be turned into captions here; each carries the sentence the interface shows.
public enum TranscriptionUnavailableReason: Equatable, Sendable {
    /// Linux, and any system without an on-device adapter.
    case platformHasNoOnDeviceRecognizer
    /// The system recognises the language only through a network service, which MpVFX never uses.
    case noOnDeviceModelForLanguage(String)
    /// The user has not allowed speech recognition; `settingPath` names where to allow it.
    case permissionDenied(settingPath: String)
    /// Speech recognition is forbidden here by a device policy, not by the user's own choice.
    case restricted
    /// The system could recognise the language on the device once the user adds its recognizer.
    case recognizerNotInstalled(String)

    public var message: String {
        switch self {
        case .platformHasNoOnDeviceRecognizer:
            return "Speech to captions needs the system's on-device speech recognition, which this system does not provide."
        case .noOnDeviceModelForLanguage(let locale):
            return "This computer can recognise \(languageName(locale)) speech only by sending the audio over the network, "
                + "and MpVFX keeps your audio on this computer. Choose another language."
        case .permissionDenied(let settingPath):
            return "MpVFX is not allowed to use speech recognition. Allow it in \(settingPath), then try again."
        case .restricted:
            return "Speech recognition is turned off on this computer by a policy, so speech cannot be turned into captions."
        case .recognizerNotInstalled(let locale):
            return "No speech recognizer for \(languageName(locale)) is installed on this computer. "
                + "Install one in the system's language settings, then try again."
        }
    }
}

/// Every way a transcription job ends without a transcript; `message` is the sentence the user reads.
public enum TranscriptionError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable(TranscriptionUnavailableReason)
    /// The media file is missing, outside the project, or its sound cannot be decoded.
    case mediaUnreadable(String)
    /// The clip has no sound, or the recognizer heard no words in it.
    case noSpeechFound(String)
    case cancelled
    /// The system recognizer reported an error.
    case recognizerFailed(code: Int, message: String)
    /// The recognizer returned words out of order, overlapping or with impossible times; they are never passed on.
    case invalidResult(String)
    /// The request itself is malformed (a negative or non-finite range, an empty language tag).
    case invalidRequest(String)
    /// The temporary audio pieces cannot be written inside the project (a full disk, a read-only folder).
    case temporaryAudioUnwritable(String)
    /// The job ended but its temporary audio folder inside the project could not be removed.
    case temporaryFilesNotRemoved(String)

    public var message: String {
        switch self {
        case .unavailable(let reason): return reason.message
        case .mediaUnreadable(let asset):
            return "“\(asset)” cannot be read, so its speech cannot be transcribed. Check that the file is still in the project and plays."
        case .noSpeechFound(let clip): return "No speech was found in “\(clip)”."
        case .cancelled: return "Transcription was cancelled."
        case .recognizerFailed(let code, let message):
            return "The system's speech recognition failed (error \(code)): \(message)"
        case .invalidResult(let detail):
            return "The system's speech recognition returned words with impossible times, so none were used (\(detail))."
        case .invalidRequest(let detail): return "This transcription request is not valid: \(detail)."
        case .temporaryAudioUnwritable(let detail):
            return "The audio to transcribe cannot be written in the project folder (\(detail)). "
                + "Check that the disk has free space and the project folder can be written."
        case .temporaryFilesNotRemoved(let folder):
            return "Transcription finished, but its temporary audio in \(folder) could not be removed. Delete that folder."
        }
    }
    public var description: String { message }
}

/// The language's name in English, else the tag itself.
func languageName(_ locale: String) -> String {
    Locale(identifier: "en_US").localizedString(forIdentifier: locale) ?? locale
}
