//
//  NewProjectName.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The name File > New Project suggests: **Project 1**, **Project 2**,
/// **Project 3**, … — the lowest number not already taken by a project file
/// in the folder the project is being saved to, the way the Finder numbers
/// a new folder.
///
/// **Per folder, and the lowest free number.** The Finder's rule on both
/// counts: numbering counts only the folder the file lands in (two folders
/// can each hold a Project 1), and a gap left by a deleted project is filled
/// before the count moves on, so the suggestion never skips past a free
/// name. Only a file with the project extension takes a number — a
/// `Project 2.txt` beside it is not a project and is no collision — and the
/// comparison ignores case, as the Mac's file system does.
///
/// The default project's own file is ``ProjectStore/fileName``, Project 1,
/// so the first project a fresh install makes is already the first of these.
nonisolated enum NewProjectName {
    /// The numbered name itself, localized — "Project 2", "Projekt 2",
    /// "Proyecto 2".
    ///
    /// - Parameter number: The project's number, from 1.
    /// - Returns: The name, without the file extension.
    static func title(_ number: Int) -> String {
        String(
            localized: "Project \(number)",
            comment: "Suggested name of a new project file; the placeholder is its number, counting from 1"
        )
    }

    /// The first numbered name whose project file is not among the given
    /// file names.
    ///
    /// - Parameters:
    ///   - fileNames: The names of the files already in the folder, with
    ///     their extensions.
    ///   - naming: How a number becomes a name (``title(_:)`` by default;
    ///     tests pass a fixed wording so they do not depend on the language
    ///     the test host runs in).
    /// - Returns: The name, without the file extension.
    static func next(
        amongFileNames fileNames: some Sequence<String>,
        naming: (Int) -> String = NewProjectName.title(_:)
    ) -> String {
        let taken = Set(fileNames.map { $0.lowercased() })
        var number = 1
        while taken.contains("\(naming(number)).\(ProjectStore.fileExtension)".lowercased()) {
            number += 1
        }
        return naming(number)
    }

    /// Whether a save panel's name field still shows a suggestion rather
    /// than a name the operator typed — what decides whether moving to
    /// another folder may renumber it (``NewProjectNameSuggester``).
    ///
    /// The field may or may not carry the project extension after the name
    /// (the panel appends it when extensions are shown), so a trailing
    /// `.tingraproject` is ignored, in any case.
    ///
    /// - Parameters:
    ///   - suggestion: The name last suggested, without the extension.
    ///   - fieldValue: What the panel's name field holds now.
    /// - Returns: `true` when the field holds exactly the suggestion.
    static func fieldShows(_ suggestion: String, fieldValue: String) -> Bool {
        let fileExtension = ".\(ProjectStore.fileExtension)"
        let name =
            fieldValue.lowercased().hasSuffix(fileExtension)
            ? String(fieldValue.dropLast(fileExtension.count)) : fieldValue
        return name == suggestion
    }

    /// The first numbered name free in a folder.
    ///
    /// A folder that cannot be listed — nil, missing, or unreadable — counts
    /// as empty and gets Project 1: the name is only a suggestion, and the
    /// save panel still asks before replacing a file that turns out to exist.
    ///
    /// - Parameter directory: The folder the project is being saved to.
    /// - Returns: The name, without the file extension.
    static func next(in directory: URL?) -> String {
        guard let directory,
            let fileNames = try? FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false))
        else { return next(amongFileNames: []) }
        return next(amongFileNames: fileNames)
    }
}
