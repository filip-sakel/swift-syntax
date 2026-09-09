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

import SwiftIfConfig
import SwiftSyntax

extension SourceFileSyntax {
  /// Helper visitor for `findExtensions`, handling `#if`
  fileprivate final class _ExtensionVisitor: ActiveSyntaxVisitor {
    var extensionDecls = [Attached<ExtensionDeclSyntax>]()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      // Force unwrap because this visitor should be called on `SourceFileSyntax`
      extensionDecls.append(Attached(node)!)
      return .visitChildren
    }
    // Don't go into to nested scopes; just the source file and `#if` clauses
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      if let parent = node.parent,
        parent.is(SourceFileSyntax.self) || parent.is(IfConfigClauseSyntax.self)
      {
        return .visitChildren
      }

      return .skipChildren
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }

  /// Finds all top-level extensions, visiting only active nodes if
  /// ``configuredRegions`` is provided.
  ///
  /// Returns: The file's extensions in-order and without duplicates.
  func findExtensions(configuredRegions: ConfiguredRegions) -> [Attached<ExtensionDeclSyntax>] {
    let visitor = _ExtensionVisitor(viewMode: .all, configuredRegions: configuredRegions)
    visitor.walk(self)
    return visitor.extensionDecls
  }
}
