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
  /// Helper visitor for `findExtensions`
  fileprivate final class _ExtensionVisitor: SyntaxVisitor {
    var extensionDecls = OrderedSet<Attached<ExtensionDeclSyntax>>()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      // Force unwrap because this visitor should be called on `SourceFileSyntax`
      extensionDecls.append(Attached(node)!)
      return .visitChildren
    }
    // Don't go into to nested scopes; just the source file
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      if node.parent?.is(SourceFileSyntax.self) == true {
        return .visitChildren
      } else {
        return .skipChildren
      }
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }
  /// Same as `_ExtensionVisitor`, but only visits active nodes according to
  /// the given configured regions.
  fileprivate final class _ConfiguredExtensionVisitor: ActiveSyntaxVisitor {
    var extensionDecls = OrderedSet<Attached<ExtensionDeclSyntax>>()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
      // Force unwrap because this visitor should be called on `SourceFileSyntax`
      extensionDecls.append(Attached(node)!)
      return .visitChildren
    }
    // Don't go into to nested scopes; just the source file
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
      if node.parent?.is(SourceFileSyntax.self) == true || node.parent?.is(IfConfigClauseSyntax.self) == true {
        return .visitChildren
      } else {
        return .skipChildren
      }
    }
    // Don't go into `DeclGroupSyntax`'s members
    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
      return .skipChildren
    }
  }

  /// Finds all top-level extensions, visiting only active nodes if
  /// ``configuredRegions`` is provided.
  func findExtensions(configuredRegions: ConfiguredRegions?) -> OrderedSet<Attached<ExtensionDeclSyntax>> {
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

extension SymbolTable {
  // TODO: Merge with nominal-type lookup-position-sensitive code
  //
  // Extensions come from several sources:
  // 1. Current file (e.g., fileprivate nominal types draw just from here)
  // 2. Current module (e.g., internal nominal types can only be here)
  // 3. Imported modules
  //    a. Current file's imported modules
  //    b. Internal/public/@_exported modules in other files
  //    c. Transitive dependencies in member visibility migration mode (TODO :Verify)
  //
  func findAllExtensions(
    accessibleFrom lookupFile: SourceFileSyntax
      // TODO: Convert to array
  ) -> OrderedSet<Attached<ExtensionDeclSyntax>> {
    func extractConfiguredRegions(file: SourceFileSyntax) -> ConfiguredRegions? {
      switch getConfiguredRegions(forFile: file) {
      case .success(let success):
        return success
      case .failure(.unregisteredFileRoot):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly couldn't find configured regions for file: \(file.trimmedDescription)"
        )
      }
    }

    // TODO: This should be imported *decls*, e.g., import struct Swift.Int
    let lookupFileConfiguredRegions = extractConfiguredRegions(file: lookupFile)
    let imports = lookupFile.findImportDecls(using: lookupFileConfiguredRegions)
    let importedModules = imports.flatMap({ $0.path.compactMap({ Identifier(validating: $0.name) }) })

    guard let lookupModule = self.moduleMap[lookupFile] else {
      // TODO: Handle error
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly couldn't find lookup file in symbol table's module map."
      )
    }
    guard let internalSources = moduleToSources[lookupModule] else {
      // TODO: Handle error
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly couldn't find lookup file for a given lookup module."
      )
    }

    // Look in file
    var results = lookupFile.findExtensions(configuredRegions: lookupFileConfiguredRegions)
    // Look in this module
    for file in internalSources.values where file != lookupFile {
      results.formUnion(file.findExtensions(configuredRegions: extractConfiguredRegions(file: file)))
    }
    // Look for imported modules (reversed order to account for shadowing)
    for module in importedModules.reversed() {
      guard let moduleSources = moduleToSources[module] else {
        // Handle error
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly couldn't find lookup file in symbol table's module map."
        )
      }
      for file in moduleSources.values {
        results.formUnion(file.findExtensions(configuredRegions: extractConfiguredRegions(file: file)))
      }
    }

    return results
  }
}
