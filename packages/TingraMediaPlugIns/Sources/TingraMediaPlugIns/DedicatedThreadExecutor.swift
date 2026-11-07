//
//  DedicatedThreadExecutor.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// A task executor that runs every job on one thread of its own, for work
/// that must block in a synchronous framework call.
///
/// `AVAssetReaderOutput.copyNextSampleBuffer()` blocks until the reader's
/// pipeline hands it a sample, and the pipeline may need other work to make
/// progress first. Swift's cooperative pool is only as wide as the machine
/// has cores, and a pool thread must never block on something that needs
/// another task to run: three movie inputs blocked in that call took every
/// thread of a three-core CI runner's pool, so nothing else — the readers'
/// own pipeline included, on macOS 27 — could run again. A movie's playback
/// task prefers one of these (`Task(executorPreference:)`), so its blocking
/// reads hold this thread and never the pool.
///
/// The thread lives until ``shutDown()`` and then until it has run every job
/// already queued. Jobs run one at a time, in the order they arrive.
///
/// `@unchecked Sendable` under one rule: `jobs` and `isShutDown` are read
/// and written only while `condition` is locked.
final class DedicatedThreadExecutor: TaskExecutor, @unchecked Sendable {
    /// Guards the queue and wakes the thread when a job or the shutdown
    /// arrives.
    private let condition = NSCondition()

    /// The jobs waiting to run, oldest first. Guarded by `condition`.
    private var jobs: [UnownedJob] = []

    /// Whether ``shutDown()`` was called. Guarded by `condition`.
    private var isShutDown = false

    /// Starts the executor's thread.
    ///
    /// - Parameter name: The thread's name, shown in a debugger and in a
    ///   `sample` of the process.
    init(name: String) {
        // The thread holds the executor until it exits, after shutDown().
        let thread = Thread { [self] in runJobs() }
        thread.name = name
        thread.start()
    }

    /// Queues a job for the executor's thread.
    ///
    /// - Parameter job: The job to run.
    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        condition.lock()
        jobs.append(unownedJob)
        condition.signal()
        condition.unlock()
    }

    /// Lets the thread exit once it has run every job already queued. Safe
    /// to call from a job on this executor and more than once.
    func shutDown() {
        condition.lock()
        isShutDown = true
        condition.signal()
        condition.unlock()
    }

    /// The thread's loop: waits for a job, runs it, and returns once shut
    /// down with nothing left to run.
    private func runJobs() {
        while let job = nextJob() {
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    /// The oldest queued job, waiting for one while the queue is empty, or
    /// nil once shut down with nothing left to run.
    private func nextJob() -> UnownedJob? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && !isShutDown {
            condition.wait()
        }
        guard !jobs.isEmpty else { return nil }
        return jobs.removeFirst()
    }
}
