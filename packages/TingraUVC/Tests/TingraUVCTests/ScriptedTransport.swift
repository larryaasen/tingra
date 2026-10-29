//
//  ScriptedTransport.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import TingraUVC

/// A camera with no hardware behind it: it serves a fixed configuration
/// descriptor, answers get requests from a script, stalls anything the
/// script does not answer, and records every request it is sent.
///
/// A `SET_CUR` updates the scripted `GET_CUR` answer, so a write reads back
/// the way a real camera's does.
final class ScriptedTransport: UVCTransport {
    /// Where a scripted answer applies: one request code on one selector of
    /// one entity.
    struct Key: Hashable {
        /// The request code.
        let code: UVCRequestCode
        /// The control selector.
        let selector: UInt8
        /// The entity's ID.
        let entityID: UInt8
    }

    /// The mutable script and log behind the mutex.
    private struct State {
        /// The configuration descriptor the connection serves.
        var descriptor: [UInt8]
        /// The scripted answers, by request.
        var answers: [Key: [UInt8]]
        /// Every request sent, with the bytes a set carried.
        var sent: [(request: UVCRequest, data: [UInt8])] = []
        /// How many connections have been opened.
        var connections = 0
    }

    /// The script and log.
    private let state: Mutex<State>

    /// Creates a scripted camera.
    ///
    /// - Parameters:
    ///   - descriptor: The configuration descriptor to serve.
    ///   - answers: The scripted get answers.
    init(descriptor: [UInt8], answers: [Key: [UInt8]] = [:]) {
        state = Mutex(State(descriptor: descriptor, answers: answers))
    }

    /// Every request sent so far, in order.
    var sentRequests: [UVCRequest] { state.withLock { $0.sent.map(\.request) } }

    /// The data each `SET_CUR` carried, in order.
    var writes: [[UInt8]] {
        state.withLock { $0.sent.filter { $0.request.code == .setCurrent }.map(\.data) }
    }

    /// How many connections have been opened.
    var connectionCount: Int { state.withLock { $0.connections } }

    /// Scripts (or replaces) one answer.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to answer with.
    ///   - key: The request it answers.
    func answer(_ bytes: [UInt8], for key: Key) {
        state.withLock { $0.answers[key] = bytes }
    }

    /// Opens a scripted connection and runs the body with it.
    func withConnection<Result>(_ body: (any UVCConnection) throws -> Result) throws -> Result {
        state.withLock { $0.connections += 1 }
        return try body(Connection(transport: self))
    }

    /// The configuration descriptor, read by the connection.
    fileprivate func descriptor() -> [UInt8] {
        state.withLock { $0.descriptor }
    }

    /// Records a request and answers it from the script.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - data: The bytes a set carries.
    /// - Returns: The scripted answer for a get; empty for a set.
    fileprivate func handle(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8] {
        try state.withLock { state in
            state.sent.append((request, data))
            if request.code == .setCurrent {
                state.answers[Key(code: .getCurrent, selector: request.selector, entityID: request.entityID)] = data
                return []
            }
            let key = Key(code: request.code, selector: request.selector, entityID: request.entityID)
            guard let answer = state.answers[key] else {
                throw UVCError.requestFailed(request, reason: "stalled")
            }
            return answer
        }
    }

    /// One scripted connection.
    private struct Connection: UVCConnection {
        /// The transport that owns the script.
        let transport: ScriptedTransport

        /// Serves the scripted descriptor.
        func configurationDescriptor() throws -> [UInt8] {
            transport.descriptor()
        }

        /// Answers from the script.
        func send(_ request: UVCRequest, data: [UInt8]) throws -> [UInt8] {
            try transport.handle(request, data: data)
        }
    }
}
