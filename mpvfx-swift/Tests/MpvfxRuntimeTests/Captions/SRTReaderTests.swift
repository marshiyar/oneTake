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
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

/// SRT import (issue #81, acceptance 3): what the reader accepts and the line-naming errors it refuses with.
final class SRTReaderTests: XCTestCase {
    private func read(_ text: String) throws -> [NativeCaptionCue] { try SRTReader.read(Data(text.utf8)) }
    private func assertRefuses(_ data: Data, _ kind: SRTReadError.Kind, line: Int, _ text: String,
                         file: StaticString = #filePath, lineNumber: UInt = #line) {
        XCTAssertThrowsError(try SRTReader.read(data), file: file, line: lineNumber) { error in
            guard let e = error as? SRTReadError else { return XCTFail("untyped \(error)", file: file, line: lineNumber) }
            XCTAssertEqual(e.kind, kind, e.message, file: file, line: lineNumber)
            XCTAssertEqual(e.line, line, e.message, file: file, line: lineNumber)
            XCTAssertTrue(e.message.contains(text), e.message, file: file, line: lineNumber)
            if line > 0 { XCTAssertTrue(e.message.hasPrefix("Line \(line): "), e.message, file: file, line: lineNumber) }
        }
    }
    private func assertRefuses(_ text: String, _ kind: SRTReadError.Kind, line: Int, _ message: String,
                         file: StaticString = #filePath, lineNumber: UInt = #line) {
        assertRefuses(Data(text.utf8), kind, line: line, message, file: file, lineNumber: lineNumber)
    }

    private let expected = [
        NativeCaptionCue(id: "cue-1", startMs: 1000, endMs: 2500, text: "Hello"),
        NativeCaptionCue(id: "cue-2", startMs: 3_723_004, endMs: 3_725_000, text: "<i>two</i>\nlines"),
    ]
    private let lf = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n01:02:03,004 --> 01:02:05,000\n<i>two</i>\nlines\n"

    func testReadsCommaAndDotTimestamps() throws {
        XCTAssertEqual(try read(lf), expected)
        XCTAssertEqual(try read(lf.replacingOccurrences(of: ",", with: ".")), expected)
        XCTAssertEqual(SRTReader.parseTimestamp("1:02:03.004"), 3_723_004)
        XCTAssertEqual(SRTReader.parseTimestamp("999:59:59,999"), NATIVE_CAPTION_MAX_MILLISECONDS)
    }

    func testReadsCRLFLFAndCRLineEndings() throws {
        XCTAssertEqual(try read(lf.replacingOccurrences(of: "\n", with: "\r\n")), expected)
        XCTAssertEqual(try read(lf.replacingOccurrences(of: "\n", with: "\r")), expected)
        let mixed = "1\r\n00:00:01,000 --> 00:00:02,500\nHello\r\n\r\n2\n01:02:03,004 --> 01:02:05,000\r<i>two</i>\r\nlines"
        XCTAssertEqual(try read(mixed), expected)
    }

    func testReadsAByteOrderMarkInUTF8AndUTF16() throws {
        XCTAssertEqual(try SRTReader.read(Data([0xEF, 0xBB, 0xBF]) + Data(lf.utf8)), expected)
        let le = Data([0xFF, 0xFE]) + Data(lf.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let be = Data([0xFE, 0xFF]) + Data(lf.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        XCTAssertEqual(try SRTReader.read(le), expected)
        XCTAssertEqual(try SRTReader.read(be), expected)
    }

    func testReadsMultiLineCuesAMissingFinalBlankLineAndExtraBlankLines() throws {
        let sloppy = "\n\n1\n00:00:01,000 --> 00:00:02,500 X1:10 X2:20 Y1:30 Y2:40\nHello\n \n\t\n\n2\n01:02:03,004-->01:02:05,000\n<i>two</i>\nlines"
        XCTAssertEqual(try read(sloppy), expected)
        XCTAssertEqual(try read("00:00:01,000 --> 00:00:02,500\nno counter\n").map(\.text), ["no counter"])
        XCTAssertEqual(try read("1\n00:00:00,000 --> 00:00:01,000\nα β\u{2028}γ\n").map(\.text), ["α β\u{2028}γ"])
    }

    func testRefusesBadTimestampsNamingTheLine() {
        assertRefuses("1\n00:00:01,000 --> 00:00:02,500\nA\n\n2\n00:61:00,000 --> 00:62:00,000\nB\n", .invalidTimestamp, line: 6, "start time \"00:61:00,000\"")
        assertRefuses("1\n00:00:01,000 --> 00:00:02\nA\n", .invalidTimestamp, line: 2, "end time \"00:00:02\"")
        assertRefuses("1\n00:00:01,00 --> 00:00:02,000\nA\n", .invalidTimestamp, line: 2, "HH:MM:SS,mmm")
        assertRefuses("1\n1000:00:01,000 --> 1000:00:02,000\nA\n", .invalidTimestamp, line: 2, "start time")
        assertRefuses("1\n00:00:01,000 --> \nA\n", .invalidTimestamp, line: 2, "end time \"\"")
        assertRefuses("1\n٠٠:00:01,000 --> 00:00:02,000\nA\n", .invalidTimestamp, line: 2, "start time")
    }

    func testRefusesOverlapsOrderAndNegativeDurationsNamingTheLine() {
        assertRefuses("1\n00:00:01,000 --> 00:00:03,000\nA\n\n2\n00:00:02,000 --> 00:00:04,000\nB\n", .invalidCue, line: 6, "overlaps the previous cue")
        assertRefuses("1\n00:00:05,000 --> 00:00:06,000\nA\n\n2\n00:00:01,000 --> 00:00:02,000\nB\n", .invalidCue, line: 6, "start order")
        assertRefuses("1\n00:00:05,000 --> 00:00:04,000\nA\n", .invalidCue, line: 2, "must end after it starts")
    }

    func testRefusesWrongEncodingsNamingTheLine() {
        assertRefuses(Data("1\n00:00:01,000 --> 00:00:02,000\ncaf".utf8) + Data([0xE9]) + Data("\n".utf8), .invalidEncoding, line: 3, "not UTF-8")
        let utf16NoMark = Data("1\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        assertRefuses(utf16NoMark, .invalidEncoding, line: 1, "NUL")
        assertRefuses(Data([0xFF, 0xFE, 0x31]), .invalidEncoding, line: 0, "odd number of bytes")
        assertRefuses(Data([0xFF, 0xFE, 0x00, 0xD8, 0x31, 0x00]), .invalidEncoding, line: 1, "not UTF-16")
        assertRefuses("1\n00:00:01,000 --> 00:00:02,000\nbad \u{FFFD}\n", .invalidCue, line: 3, "U+FFFD")
        // CR-only and CRLF files count lines the same way when decoding fails (Codex review on PR #139).
        let cr = Data("1\r00:00:01,000 --> 00:00:02,000\rcaf".utf8) + Data([0xE9])
        assertRefuses(cr, .invalidEncoding, line: 3, "not UTF-8")
        assertRefuses(Data("1\r\n00:00:01,000 --> 00:00:02,000\r\n\u{0}".utf8), .invalidEncoding, line: 3, "NUL")
    }

    func testRefusesMalformedBlocksNamingTheLine() {
        assertRefuses("", .noCues, line: 0, "no captions")
        assertRefuses("\r\n \r\n", .noCues, line: 0, "no captions")
        assertRefuses("hello\n", .expectedTiming, line: 1, "Expected a cue number or a timing line")
        assertRefuses("1\n2\nA\n", .expectedTiming, line: 2, "followed by its timing line")
        assertRefuses("1\n", .expectedTiming, line: 2, "followed by its timing line")
        assertRefuses("1\n00:00:01,000 --> 00:00:02,000\n\n", .invalidCue, line: 2, "no text")
        assertRefuses("1\n00:00:01,000 --> 00:00:02,000\nA\n2\n00:00:03,000 --> 00:00:04,000\nB\n", .invalidCue, line: 5, "blank line missing")
        assertRefuses("1\n00:00:01,000 --> 00:00:02,000\nbell\u{07}\n", .invalidCue, line: 3, "control characters")
        assertRefuses(Data(count: SRTReader.maxBytes + 1), .tooLarge, line: 0, "refused")
    }

    func testErrorsAreTypedAndActionable() {
        let e = SRTReadError(.invalidTimestamp, line: 4, "The start time \"x\" is not HH:MM:SS,mmm")
        XCTAssertEqual("\(e)", "Line 4: The start time \"x\" is not HH:MM:SS,mmm")
    }
}
