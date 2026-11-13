//
//  AudioProcessChanges.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Dispatch

/// Changes to the HAL's process object list, as a stream — how a capture
/// learns that its application launched, quit, or started a helper process
/// (a browser starts one when playback begins), without ever asking again on
/// a timer (ARCHITECTURE.md, "Application audio", A5 and A6).
public enum AudioProcessChanges {
    /// A stream that yields each time a process opens or closes its audio.
    ///
    /// The stream carries no payload: the list is re-read where it is
    /// needed (``AudioApplication/running(bundleIdentifier:)``). Ending the
    /// stream's iteration removes the listener. Holds the newest change
    /// only, since a burst of changes needs one re-read.
    ///
    /// - Returns: The stream.
    public static func live() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let listener = Listener(continuation: continuation)
        let added = listener.add()
        guard added else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in
            listener.remove()
        }
        return stream
    }

    /// The registered property listener, kept so the exact block can be
    /// removed again — Core Audio removes a listener block by identity.
    private final class Listener: Sendable {
        /// The block Core Audio calls, on its own thread (no queue). Typed as
        /// a block rather than a Swift closure so the same block object is
        /// handed to both the add and the remove, and `@Sendable` because
        /// it captures only the stream's continuation.
        private let block:
            @Sendable @convention(block) (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>) -> Void

        /// Creates the listener over the stream it feeds.
        ///
        /// - Parameter continuation: The stream's continuation.
        init(continuation: AsyncStream<Void>.Continuation) {
            block = { _, _ in
                continuation.yield(())
            }
        }

        /// Registers the block.
        ///
        /// - Returns: Whether Core Audio accepted it.
        func add() -> Bool {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
                == noErr
        }

        /// Removes the block.
        func remove() {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        }
    }
}
