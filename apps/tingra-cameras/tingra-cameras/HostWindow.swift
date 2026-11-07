//
//  HostWindow.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// The window a view is in, for the two things SwiftUI can't do: widening a
/// window that is already open, and closing one window of a group from the
/// menu bar (``WindowStyleCommands``). Held weakly, so a view's state never keeps
/// its own window alive.
final class HostWindow {
    /// The window, once the reader has been added to it.
    fileprivate(set) weak var window: NSWindow?

    /// Widens the window to a width if it is narrower, keeping its left edge
    /// unless that would push it off the screen.
    ///
    /// - Parameter width: The width the window must reach.
    func widen(to width: CGFloat) {
        guard let window, window.frame.width < width else { return }
        var frame = window.frame
        frame.size.width = width
        if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX, visible.maxX - width)
        }
        window.setFrame(frame, display: true)
    }

    /// Closes the window, as its close button would — how switching window
    /// styles retires the window it switched from.
    func close() {
        window?.close()
    }
}

/// An invisible view that tells a ``HostWindow`` which window it is in. Used
/// as a background.
struct HostWindowReader: NSViewRepresentable {
    /// The reference to keep up to date.
    let host: HostWindow

    /// Creates the view that watches for its window.
    func makeNSView(context: Context) -> WindowWatchingView {
        WindowWatchingView(host: host)
    }

    /// Nothing to update: the view reports its window when it moves to one.
    func updateNSView(_ view: WindowWatchingView, context: Context) {}

    /// Reports the window it is added to.
    final class WindowWatchingView: NSView {
        /// The reference to keep up to date.
        private let host: HostWindow

        /// Creates the view.
        ///
        /// - Parameter host: The reference to keep up to date.
        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }

        /// Not used: the view is only ever created in code.
        required init?(coder: NSCoder) {
            return nil
        }

        /// Records the window as the view moves into it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}
