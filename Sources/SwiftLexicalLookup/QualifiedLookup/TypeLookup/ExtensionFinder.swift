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
  fileprivate final class _ConfiguredImportVisitor: ActiveSyntaxVisitor {
    var importDecls = [ImportDeclSyntax]()

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
      importDecls.append(node)
      return .visitChildren
    }
    // Don't go to nested scopes
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }
  fileprivate final class _ImportVisitor: SyntaxVisitor {
    var importDecls = [ImportDeclSyntax]()

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
      importDecls.append(node)
      return .visitChildren
    }
    // Don't go to nested scopes
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }

  // TODO: Implement
  func findImportDecls(using configuredRegions: ConfiguredRegions?) -> [ImportDeclSyntax] {
    // Get visitor based on config
    if let configuredRegions {
      let visitor = _ConfiguredImportVisitor(viewMode: .all, configuredRegions: configuredRegions)
      visitor.walk(self)
      return visitor.importDecls
    } else {
      let visitor = _ImportVisitor(viewMode: .all)
      visitor.walk(self)
      return visitor.importDecls
    }
  }
}

extension SourceFileSyntax {
  fileprivate final class _ConfiguredExtensionVisitor: ActiveSyntaxVisitor {
    var extensionDecls = [ExtensionDeclSyntax]()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      extensionDecls.append(node)
      return .visitChildren
    }
    // Don't go to nested scopes
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }
  fileprivate final class _ExtensionVisitor: SyntaxVisitor {
    var extensionDecls = [ExtensionDeclSyntax]()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      extensionDecls.append(node)
      return .visitChildren
    }
    // Don't go to nested scopes
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }

  func findExtensions(configuredRegions: ConfiguredRegions?) -> [ExtensionDeclSyntax] {
    if let configuredRegions {
      let visitor = _ConfiguredExtensionVisitor(viewMode: .all, configuredRegions: configuredRegions)
      visitor.walk(self)
      return visitor.extensionDecls
    } else {
      let visitor = _ExtensionVisitor(viewMode: .all)
      visitor.walk(self)
      return visitor.extensionDecls
    }
  }
}

extension SymbolTable3 {
  // TODO: Merge with nominal-type lookup-position-sensitive code
  func findAllExtensions(
    accessibleFrom lookupFile: SourceFileSyntax,
    configuredRegions: ConfiguredRegions?
  ) -> [ExtensionDeclSyntax] {
    // TODO: This should be imported *decls*, e.g., import struct Swift.Int
    let imports = lookupFile.findImportDecls(using: configuredRegions)
    let importedModules = imports.flatMap({ $0.path.compactMap({ Identifier(validating: $0.name) }) })

    guard let lookupModule = self.moduleMap[lookupFile] else {
      // TODO: Handle error
    }
    guard let internalSources = moduleToSources[lookupModule] else {
      // TODO: Handle error
    }

    // Look in file
    var results = lookupFile.findExtensions(configuredRegions: configuredRegions)
    // Look in this module
    for file in internalSources where file != lookupFile {
      results.append(contentsOf: file.findExtensions(configuredRegions: configuredRegions))
    }
    // Look for imported modules (reversed order to account for shadowing)
    for module in importedModules.reversed() {
      guard let moduleSources = moduleToSources[module] else {
        // Handle error
      }
      for file in moduleSources {
        results.append(contentsOf: file.findExtensions(configuredRegions: configuredRegions))
      }
    }

    return results
  }
}
