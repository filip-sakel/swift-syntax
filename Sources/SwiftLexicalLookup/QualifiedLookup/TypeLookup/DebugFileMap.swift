//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

/// The symbol table's file map; captured only for debug builds
/// to generate deterministic and human-readable
/// `QualifiedTypeNameGlobalType` descriptions.
///
/// No runtime impact in `RELEASE` mode.
///
/// ### Conformances
///
/// Conformances to `Sendable` and `Hashable` aim to make this type
/// transparent. Namely, `Hashable` doesn't hash anything and always
/// returns true.
/// * `Hashable` doesn't combine anything
struct DebugFileMap: Sendable, Hashable {
  #if DEBUG
  let fileMap: [SyntaxIdentifier: (fileName: String, file: SourceFileSyntax)]
  #endif

  // Initialized by SymbolTable
  #if DEBUG
  init(_internalFileMap: [SyntaxIdentifier: (fileName: String, file: SourceFileSyntax)]) {
    self.fileMap = _internalFileMap
  }
  #else
  init() {}
  #endif

  /// Find the file name of the given source-file `SyntaxIdentifier`.
  /// Falls back to printing the file hash (non deterministic;
  /// also for debugging).
  func describeFileID(_ fileID: SyntaxIdentifier) -> String {
    // Try to get name in debug
    #if DEBUG
    if let registeredFile = fileMap[fileID] {
      return registeredFile.fileName
    }
    #endif

    // Fall back to hash value
    return fileID.hashValue.description
  }

  // Similar to `Void`
  static func == (a: DebugFileMap, b: DebugFileMap) -> Bool { true }
  func hash(into hasher: inout Hasher) {}
}
