//
//  AuthorizationTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

@Suite("Authorization seam")
struct AuthorizationTests {
    @Test("the permission list is the three TCC grants capture depends on, in a stable order")
    func permissionList() {
        #expect(AuthorizationPermission.allCases == [.camera, .microphone, .screenRecording])
    }

    @Test("raw values are the scripting contract and never change")
    func rawValues() {
        #expect(AuthorizationPermission.camera.rawValue == "camera")
        #expect(AuthorizationPermission.microphone.rawValue == "microphone")
        #expect(AuthorizationPermission.screenRecording.rawValue == "screenRecording")
        #expect(AuthorizationStatus.notDetermined.rawValue == "notDetermined")
        #expect(AuthorizationStatus.granted.rawValue == "granted")
        #expect(AuthorizationStatus.denied.rawValue == "denied")
        #expect(AuthorizationStatus.restricted.rawValue == "restricted")
    }

    @Test("a permission and a status round-trip through JSON unchanged")
    func codableRoundTrip() throws {
        struct Record: Codable, Equatable {
            let permission: AuthorizationPermission
            let status: AuthorizationStatus
        }
        let record = Record(permission: .screenRecording, status: .restricted)
        let data = try JSONEncoder().encode(record)
        #expect(String(decoding: data, as: UTF8.self) == #"{"permission":"screenRecording","status":"restricted"}"#)
        #expect(try JSONDecoder().decode(Record.self, from: data) == record)
    }

    @Test("decoding an unknown status throws rather than guessing")
    func unknownStatusThrows() {
        let data = Data(#""maybe""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AuthorizationStatus.self, from: data)
        }
    }

    @Test("statuses compare equal only to themselves")
    func statusEquality() {
        #expect(AuthorizationStatus.granted == .granted)
        #expect(AuthorizationStatus.granted != .denied)
        #expect(AuthorizationStatus.notDetermined != .restricted)
    }

    @Test("the production checker answers every permission without prompting")
    func systemStatusReadsEveryPermission() {
        // A status read never prompts (the seam's contract), so this is safe
        // on a CI runner with no TCC grants at all: whatever the runner's
        // database says is a valid answer — only a trap or a hang would be
        // wrong, and neither can be a return value.
        let checker = SystemAuthorization()
        for permission in AuthorizationPermission.allCases {
            let status = checker.status(of: permission)
            #expect([.notDetermined, .granted, .denied, .restricted].contains(status))
        }
    }

    @Test("Screen Recording never reads as undetermined — preflight is a yes-or-no question")
    func screenRecordingIsBinary() {
        let status = SystemAuthorization().status(of: .screenRecording)
        #expect(status == .granted || status == .denied)
    }
}
