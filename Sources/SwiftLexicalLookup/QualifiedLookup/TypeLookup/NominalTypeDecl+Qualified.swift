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

// For global, we still need to resolve extensions
extension SyntaxProtocol {
  enum QualifiedTypeResolutionFailure: Error {
    /// No scope exists or scope doesn't have a parent (not even `SourceFileSyntax`)
    case invalidScope
  }

  enum ResolutionResult {
   case resolveTopLevelBase(extensionType: TypeSyntax)
   case scope(CodeBlockItemListSyntax, isTopLevel: Bool)
   case resolved(QualifiedTypeName)
   case failure(QualifiedTypeResolutionFailure)
  }

  var _enclosingQualifiedTypeName: Result<QualifiedTypeName, QualifiedTypeResolutionFailure> {
    guard let parent else { return .failure(.invalidScope) }

    if let nominal = NominalTypeDeclSyntax2(parent) {
      nominal._enclosingQualifiedTypeName
    } else if let extension = ExtensionDeclSyntax(parent) {

      } else if let scope = CodeBlockItemListSyntax(parent) {
      // Top level
      // TODO: Use `DeclScope` isFileScope and throw appropriate errors
      if scope.parent?.is(SourceFileSyntax.self) {
        // Global
        return QualifiedTypeName()
      } else {
        // Nested
      }
    }
  }
}

extension NominalTypeDeclSyntax2 {

  var qualifiedTypeName: Result<QualifiedTypeName, QualifiedTypeResolutionFailure> {
    Result(catching: { throws(QualifiedTypeResolutionFailure) in
      // Get scope
      guard
        let scope = self.declScope,
        let isFileScope = scope.isFileScope
      else {
        throw QualifiedTypeResolutionFailure.invalidScope
      }

      // Top-level name
      if isFileScope {

      }
      // Else, nested
      else {

      }
    })
  }
}
