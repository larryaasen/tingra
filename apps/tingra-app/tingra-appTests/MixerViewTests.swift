//
//  MixerViewTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Testing

@testable import TingraApp

/// The room the mixer's strips leave under them for the scroller, so the
/// mutes at their foot stay clear of it while the strips scroll.
@Suite("MixerView scroller clearance")
struct MixerViewTests {
    @Test("an overlay scroller, drawn over the content, gets its own thickness of room under the strips")
    func overlayScrollerClearance() {
        let clearance = MixerView.scrollerClearance(for: .overlay)
        #expect(clearance == NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        #expect(clearance > 0)
    }

    @Test("a legacy scroller, which has its own row below the content, gets no room")
    func legacyScrollerClearance() {
        #expect(MixerView.scrollerClearance(for: .legacy) == 0)
    }
}
