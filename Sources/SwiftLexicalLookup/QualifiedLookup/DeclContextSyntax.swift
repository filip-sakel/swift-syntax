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

/// Syntax that directly contains declarations: either
/// 1. a ``DeclGroupSyntaxType`` (nominal type or protocol), or
/// 2. a ``CodeBlockItemListSyntax`` (e.g., source-file or function-body statements).
@_spi(_QualifiedLookup)
public struct DeclContextSyntax: SyntaxHashable {
  public let _syntaxNode: Syntax

  public init?(_ node: __shared some SyntaxProtocol) {
    switch node._syntaxNode.kind {
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .extensionDecl,
      .codeBlockItemList:
      self._syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  public static let structure: SyntaxNodeStructure = .choices([
    .node(DeclGroupSyntaxType.self), .node(CodeBlockItemListSyntax.self),
  ])
}

// MARK: Lookup

extension DeclContextSyntaxProtocol {
  /// Helper for `visitDirectMembers` conformances
  fileprivate func _visitDirectMembersOfDecl(
    decl: DeclSyntax,
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  ) {
    /// Process a member or a member nested inside an if-config declaration.
    ///
    /// This pattern is similar to the SyntaxVisitor pattern, but a SyntaxVisitor
    /// doesn't work because we use custom syntax like `ValueDeclSyntax`
    func processMember(decl: DeclSyntax) {
      // Get only value declarations
      if let valueDecl = decl.as(ValueDeclSyntax.self) {
        visit(valueDecl)
      }
      // Visit variable declarations to get identifier patterns
      else if let varDecl = decl.as(VariableDeclSyntax.self) {
        for binding in varDecl.bindings {
          guard let valueDecl = ValueDeclSyntax(binding.pattern.as(IdentifierPatternSyntax.self)) else { continue }
          visit(valueDecl)
        }
      }
      // Visit enum cases to get enum elements
      else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
        for enumElement in enumCase.elements {
          visit(ValueDeclSyntax(enumElement))
        }
      }
      // If configuredRegions is set, visit the members of the active clause (if it exists)
      //
      // We do this recursively to handle nested if-config declarations
      else if let ifConfigDecl = decl.as(IfConfigDeclSyntax.self),
        let configuredRegions,
        case .decls(let members) = configuredRegions.activeClause(for: ifConfigDecl)?.elements
      {
        for member in members {
          processMember(decl: member.decl)
        }
      }
      // If configuredRegions is nil, visit all if-config clauses
      else if let ifConfigDecl = decl.as(IfConfigDeclSyntax.self),
        configuredRegions == nil
      {
        for clause in ifConfigDecl.clauses {
          guard case .decls(let members) = clause.elements else { return }
          for member in members {
            processMember(decl: member.decl)
          }
        }
      }
    }

    // Find all ValueDeclSyntax members in this declaration
    processMember(decl: decl)
  }
}

// MARK: Protocol

/// Protocol encapsulating `DeclContextSyntax`. Only `[Struct/Enum/Class/Actor/Protocol/Extension]DeclSyntax`
/// and `CodeBlockItemListSyntax` should conform.
@_spi(_QualifiedLookup) public protocol DeclContextSyntaxProtocol: SyntaxProtocol {
  /// Visits the value declarations directly declared in this context.
  ///
  /// If `configuredRegions` is provided, only visit members of active
  /// `#if` clauses; otherwise, visit the members of every clause.
  func visitDirectMembers(
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  )
}

@_spi(_QualifiedLookup)
extension CodeBlockItemListSyntax: DeclContextSyntaxProtocol {
  public func visitDirectMembers(
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  ) {
    for listItem in self {
      guard case .decl(let decl) = listItem.item else { continue }
      _visitDirectMembersOfDecl(
        decl: decl,
        configuredRegions: configuredRegions,
        visit: visit
      )
    }
  }
}

// SwiftLexicalLookup doesn't own `DeclContextSyntax`, so we just conform
// `DeclContextSyntaxType` and have `NominalTypeDeclSyntax` refine
// `DeclContextSyntaxProtocol`.
@_spi(_QualifiedLookup)
extension DeclGroupSyntax where Self: DeclContextSyntaxProtocol {
  public func visitDirectMembers(
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  ) {
    // If we're in a disabled region, visit nothing
    if let configuredRegions, configuredRegions.isActive(self) != .active { return }

    for member in memberBlock.members {
      _visitDirectMembersOfDecl(decl: member.decl, configuredRegions: configuredRegions, visit: visit)
    }
  }
}
@_spi(_QualifiedLookup)
extension DeclGroupSyntaxType: DeclContextSyntaxProtocol {}
@_spi(_QualifiedLookup)
extension ExtensionDeclSyntax: DeclContextSyntaxProtocol {}

extension DeclContextSyntax: DeclContextSyntaxProtocol {
  public func visitDirectMembers(
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  ) {
    if let codeItems = _syntaxNode.as(CodeBlockItemListSyntax.self) {
      codeItems.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
    } else if let declGroup = _syntaxNode.as(DeclGroupSyntaxType.self) {
      declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
    } else {
      fatalError("[Internal Error] Invalid syntax kind for DeclContextSyntax: \(_syntaxNode.kind)")
    }
  }
}

extension Attached where Node: DeclContextSyntaxProtocol {
  /// Finds the type declarations named `name` directly declared in this
  /// context, using the provided `configuredRegions`.
  internal func _findDirectMemberTypes(
    named name: Identifier,
    configuredRegions: ConfiguredRegions?
  ) -> [Attached<TypeDeclSyntax>] {
    var result = [Attached<TypeDeclSyntax>]()
    node.visitDirectMembers(
      configuredRegions: configuredRegions,
      visit: { valueDecl in
        // Only accept declarations with the given name
        guard
          let typeDecl = valueDecl.as(TypeDeclSyntax.self),
          let typeDeclName = Identifier(validating: typeDecl.name),
          typeDeclName == name
        else {
          return
        }
        // Force-unwrap because the children of an attached declaration are also attached.
        result.append(Attached<TypeDeclSyntax>(typeDecl)!)
      }
    )
    return result
  }
}

// MARK: Lookup Utilities

extension Attached where Node: DeclContextSyntaxProtocol {
  internal func _groupTypeMembers(
    configuredRegions: ConfiguredRegions?
  ) -> [Identifier: [Attached<TypeDeclSyntax>]] {
    var result = [Identifier: [Attached<TypeDeclSyntax>]]()
    node.visitDirectMembers(
      configuredRegions: configuredRegions,
      visit: { valueDecl in
        guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
        guard let typeIdentifier = Identifier(validating: typeDecl.name) else { return }
        // Since these are our children, they will also be scope in the file,
        // so we can force-unwrap.
        let wrappedTypeDecl = Attached<TypeDeclSyntax>(typeDecl)!
        result[typeIdentifier, default: []].append(wrappedTypeDecl)
      }
    )
    return result
  }
}

// MARK: Upcasts

extension Attached where Node == DeclContextSyntax {
  public init<T: DeclGroupSyntax>(_ declGroup: Attached<T>) {
    self = declGroup.as(DeclContextSyntax.self)!
  }
  public init(_ codeBlockItemList: Attached<CodeBlockItemListSyntax>) {
    self = codeBlockItemList.as(DeclContextSyntax.self)!
  }
}
