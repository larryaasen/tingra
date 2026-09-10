//
//  CommittingNumberFieldTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

@Suite("CommittingNumberField")
struct CommittingNumberFieldTests {
    @Test("typed text parses as a number, with surrounding whitespace and a grouping separator tolerated")
    func parsesTypedText() {
        #expect(CommittingNumberField.parse("400") == 400)
        #expect(CommittingNumberField.parse(" 400 ") == 400)
        #expect(CommittingNumberField.parse("0.5") == 0.5)
        #expect(CommittingNumberField.parse("-12") == -12)
        #expect(CommittingNumberField.parse("1,611") == 1611)
    }

    @Test("text that is not a number parses to nil, so the field reverts instead of committing")
    func rejectsNonNumbers() {
        #expect(CommittingNumberField.parse("") == nil)
        #expect(CommittingNumberField.parse("abc") == nil)
        #expect(CommittingNumberField.parse("4x") == nil)
    }

    @Test("a value formats with exactly the requested fraction digits")
    func formatsWithFractionDigits() {
        #expect(CommittingNumberField.formatted(22, fractionDigits: 0) == "22")
        #expect(
            CommittingNumberField.formatted(0.25, fractionDigits: 1) == "0.2"
                || CommittingNumberField.formatted(0.25, fractionDigits: 1) == "0.3")
        #expect(CommittingNumberField.formatted(1611, fractionDigits: 0) == "1,611")
    }
}
