//
//  NewProjectNameTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// The name File > New Project suggests: the lowest free Project N in the
/// folder being saved to, the way the Finder numbers a new folder.
@Suite("NewProjectName")
struct NewProjectNameTests {
    /// A fixed English wording, so the expectations hold whatever language
    /// the test host runs in.
    private static func english(_ number: Int) -> String { "Project \(number)" }

    /// The next name among the given file names, in the fixed wording.
    ///
    /// - Parameter fileNames: The folder's file names.
    /// - Returns: The suggested name.
    private func next(_ fileNames: [String]) -> String {
        NewProjectName.next(amongFileNames: fileNames, naming: Self.english)
    }

    @Test("an empty folder suggests Project 1")
    func emptyFolderSuggestsOne() {
        #expect(next([]) == "Project 1")
    }

    @Test("each project file present moves the suggestion on: Project 2, then Project 3")
    func countsUp() {
        #expect(next(["Project 1.tingraproject"]) == "Project 2")
        #expect(next(["Project 1.tingraproject", "Project 2.tingraproject"]) == "Project 3")
    }

    @Test("a gap left by a removed project is filled before the count moves on")
    func fillsTheLowestGap() {
        #expect(next(["Project 1.tingraproject", "Project 3.tingraproject"]) == "Project 2")
        #expect(next(["Project 2.tingraproject"]) == "Project 1")
    }

    @Test("names are compared ignoring case, as the Mac's file system does")
    func ignoresCase() {
        #expect(next(["project 1.TINGRAPROJECT"]) == "Project 2")
    }

    @Test("a file with another extension, or a name that only starts the same, takes no number")
    func onlyProjectFilesCollide() {
        #expect(
            next(["Project 1.txt", "Project 1", "Project 1 copy.tingraproject", "Project 10.tingraproject"])
                == "Project 1")
    }

    @Test("the default project's file is Project 1, so the next suggestion beside it is Project 2")
    func defaultProjectIsTheFirst() {
        #expect(ProjectStore.fileName == "Project 1.tingraproject")
        #expect(next([ProjectStore.fileName]) == "Project 2")
    }

    @Test("a folder on disk is numbered from the project files it holds")
    func numbersARealFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tingra-new-project-name-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "\(NewProjectName.title(1)).tingraproject"))
        try Data().write(to: folder.appending(path: "\(NewProjectName.title(2)).tingraproject"))
        #expect(NewProjectName.next(in: folder) == NewProjectName.title(3))
    }

    @Test("no folder, or one that cannot be listed, suggests the first name")
    func unlistableFolderSuggestsOne() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "tingra-missing-\(UUID())")
        #expect(NewProjectName.next(in: nil) == NewProjectName.title(1))
        #expect(NewProjectName.next(in: missing) == NewProjectName.title(1))
    }

    @Test("the numbered name carries its number")
    func titleCarriesTheNumber() {
        #expect(NewProjectName.title(7).contains("7"))
        #expect(NewProjectName.title(7) != NewProjectName.title(8))
    }

    @Test("the name field shows the suggestion with or without the project extension, in any case")
    func fieldShowsTheSuggestion() {
        #expect(NewProjectName.fieldShows("Project 2", fieldValue: "Project 2"))
        #expect(NewProjectName.fieldShows("Project 2", fieldValue: "Project 2.tingraproject"))
        #expect(NewProjectName.fieldShows("Project 2", fieldValue: "Project 2.TingraProject"))
    }

    @Test("a name the operator typed is not the suggestion")
    func typedNameIsNotTheSuggestion() {
        #expect(!NewProjectName.fieldShows("Project 2", fieldValue: "Sunday Service"))
        #expect(!NewProjectName.fieldShows("Project 2", fieldValue: "Project 2 final.tingraproject"))
        #expect(!NewProjectName.fieldShows("Project 2", fieldValue: ""))
    }
}
