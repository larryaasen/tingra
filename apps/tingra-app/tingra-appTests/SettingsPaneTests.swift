//
//  SettingsPaneTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

@Suite("SettingsPane")
struct SettingsPaneTests {
    @Test("the six panes are listed in the sidebar's order, General first and About last")
    func panesInOrder() {
        #expect(SettingsPane.allCases == [.general, .permissions, .shortcuts, .data, .logging, .about])
    }

    @Test("every pane has its own sidebar symbol")
    func distinctSymbols() {
        let symbols = SettingsPane.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    @Test("the Logging pane's symbol is a document under a magnifier")
    func loggingSymbol() {
        #expect(SettingsPane.logging.systemImage == "doc.text.magnifyingglass")
    }
}
