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

@_spi(_QualifiedLookup)
public struct DeclGroupSyntaxType: SyntaxProtocol, SyntaxHashable {
  public internal(set) var _syntaxNode: Syntax

  public init?(_ node: __shared some SyntaxProtocol) {
    switch node._syntaxNode.kind {
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .extensionDecl:
      self._syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  public static let structure: SwiftSyntax.SyntaxNodeStructure = .choices([
    .node(NominalTypeDeclSyntax.self), .node(ExtensionDeclSyntax.self),
  ])
}

@_spi(_QualifiedLookup)
extension DeclGroupSyntaxType: DeclGroupSyntax {
  private func _getGroupProp<T>(_ prop: KeyPath<(any DeclGroupSyntax), T>) -> T {
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let declGroup):
      return declGroup[keyPath: prop]
    case .enumDecl(let declGroup):
      return declGroup[keyPath: prop]
    case .classDecl(let declGroup):
      return declGroup[keyPath: prop]
    case .actorDecl(let declGroup):
      return declGroup[keyPath: prop]
    case .protocolDecl(let declGroup):
      return declGroup[keyPath: prop]
    case .extensionDecl(let declGroup):
      return declGroup[keyPath: prop]
    default:
      fatalError("[Internal Error] Invalid syntax kind for DeclGroupSyntaxType: \(_syntaxNode.kind)")
    }
  }
  private mutating func _setGroupProp<T>(
    _ keyPath: WritableKeyPath<(any DeclGroupSyntax), T>,
    newValue: T
  ) {
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .enumDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .classDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .actorDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .protocolDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .extensionDecl(let declGroup):
      var box: any DeclGroupSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    default:
      fatalError("[Internal Error] Invalid syntax kind for DeclGroupSyntaxType: \(_syntaxNode.kind)")
    }
  }

  public init(_ syntax: __shared some DeclGroupSyntax) {
    self = Syntax(syntax).cast(Self.self)
  }

  public var attributes: AttributeListSyntax {
    get { _getGroupProp(\.attributes) }
    set { _setGroupProp(\.attributes, newValue: newValue) }
  }

  public var modifiers: DeclModifierListSyntax {
    get { _getGroupProp(\.modifiers) }
    set { _setGroupProp(\.modifiers, newValue: newValue) }
  }
  public var introducer: TokenSyntax {
    get { _getGroupProp(\.introducer) }
    set { _setGroupProp(\.introducer, newValue: newValue) }
  }

  public var inheritanceClause: InheritanceClauseSyntax? {
    get { _getGroupProp(\.inheritanceClause) }
    set { _setGroupProp(\.inheritanceClause, newValue: newValue) }
  }

  public var genericWhereClause: GenericWhereClauseSyntax? {
    get { _getGroupProp(\.genericWhereClause) }
    set { _setGroupProp(\.genericWhereClause, newValue: newValue) }
  }

  public var memberBlock: MemberBlockSyntax {
    get { _getGroupProp(\.memberBlock) }
    set { _setGroupProp(\.memberBlock, newValue: newValue) }
  }

  // Useful for ASTGen validation
  public var _asLookInMembersScope: LookInMembersScopeSyntax? {
    Syntax(self).asProtocol((any SyntaxProtocol).self) as? any LookInMembersScopeSyntax
  }
}

// MARK: Lookup

// Note: We need `Self: DeclContextSyntaxProtocol` because `DeclGroupSyntax`
// doesn't inherit from `DeclContextSyntaxProtocol` (though all conforming types do).
@_spi(_QualifiedLookup)
extension DeclGroupSyntax where Self: DeclContextSyntaxProtocol {
  /// Find named member declarations in the given group declaration.
  ///
  /// Results are filtered in the following ways:
  /// 1. If an identifier is given, only return declaration matching that name.
  /// 2. Only returns declarations matching `memberKind`.
  /// 3. If a configuredRegion is provided, consider only the active clause's
  ///    members.
  ///
  /// Note that implicit members such as `self`, `Type`, or `Protocol` aren't
  /// value declarations (they're not actual members) and we don't return them here.
  public func findDirectMembers(
    name: DeclNameReference?,
    kind memberKind: MemberKind = .default,
    configuredRegions: ConfiguredRegions? = nil
  ) -> [ValueDeclSyntax] {
    var valueDecls = [ValueDeclSyntax]()
    visitDirectMembers(
      configuredRegions: configuredRegions,
      visit: { valueDecl in
        // If given a name, check for a match
        if let expectedName = name,
          case .failure = valueDecl.declName.tryMatch(reference: expectedName.baseName)
        {
          return
        }
        // Filter for the kind
        guard valueDecl.isKind(memberKind) else { return }

        // Add to the results
        valueDecls.append(valueDecl)
      }
    )
    return valueDecls
  }
}

// MARK: Utilities

extension DeclGroupSyntaxType {
  /// The type syntax of this declaration group. An identifier type syntax for nominal types,
  /// or the extended type for extensions.
  ///
  /// Useful for debugging
  @_spi(_QualifiedLookup) public var type: TypeSyntax? {
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let structDecl):
      return TypeSyntax(IdentifierTypeSyntax(name: structDecl.name))
    case .enumDecl(let enumDecl):
      return TypeSyntax(IdentifierTypeSyntax(enumDecl.name))
    case .classDecl(let classDecl):
      return TypeSyntax(IdentifierTypeSyntax(classDecl.name))
    case .actorDecl(let actorDecl):
      return TypeSyntax(IdentifierTypeSyntax(actorDecl.name))
    case .protocolDecl(let protocolDecl):
      return TypeSyntax(IdentifierTypeSyntax(protocolDecl.name))
    case .extensionDecl(let extensionDecl):
      return extensionDecl.extendedType
    default:
      fatalError("[Internal Error] Invalid syntax kind for DeclGroupSyntaxType: \(_syntaxNode.kind)")
    }
  }
}

// MARK: Debugging

extension DeclGroupSyntax {
  /// Removes member blocks and gets trimmed description for better
  /// readability in debug output.
  @_spi(_QualifiedLookupTests) public var _memberlessDescription: String {
    self.with(\.memberBlock, MemberBlockSyntax(members: [])).trimmedDescription
  }
}

extension Attached where Node: DeclGroupSyntax {
  internal var _memberlessDescription: String {
    node._memberlessDescription
  }
}

extension Attached where Node == DeclGroupSyntaxType {
  internal init<DeclGroup: DeclGroupSyntax>(_ syntax: Attached<DeclGroup>) {
    self = syntax.as(DeclGroupSyntaxType.self)!
  }
}
