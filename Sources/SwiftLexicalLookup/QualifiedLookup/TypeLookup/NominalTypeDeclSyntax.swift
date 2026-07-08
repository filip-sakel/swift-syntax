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

/// A nominal type declaration (struct, enum, class, actor, protocol).
@_spi(_QualifiedLookup) public struct NominalTypeDeclSyntax: SyntaxProtocol, Hashable {
  public private(set) var _syntaxNode: Syntax

  public init?(_ node: __shared some SyntaxProtocol) {
    switch node.kind {
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl:
      _syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  public static var structure: SyntaxNodeStructure {
    SyntaxNodeStructure.choices([
      .node(StructDeclSyntax.self),
      .node(EnumDeclSyntax.self),
      .node(ClassDeclSyntax.self),
      .node(ActorDeclSyntax.self),
      .node(ProtocolDeclSyntax.self),
    ])
  }
}

extension NominalTypeDeclSyntax: DeclGroupSyntax {
  private func _getGroupProp<T>(_ prop: KeyPath<any DeclGroupSyntax & NamedDeclSyntax, T>) -> T {
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
    default:
      fatalError("[Internal Error] Invalid syntax kind for NominalTypeDeclSyntax \(_syntaxNode.kind)")
    }
  }

  private mutating func _setGroupProp<T>(
    _ keyPath: WritableKeyPath<any DeclGroupSyntax & NamedDeclSyntax, T>,
    newValue: T
  ) {
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let declGroup):
      var box: any DeclGroupSyntax & NamedDeclSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .enumDecl(let declGroup):
      var box: any DeclGroupSyntax & NamedDeclSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .classDecl(let declGroup):
      var box: any DeclGroupSyntax & NamedDeclSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .actorDecl(let declGroup):
      var box: any DeclGroupSyntax & NamedDeclSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .protocolDecl(let declGroup):
      var box: any DeclGroupSyntax & NamedDeclSyntax = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    default:
      fatalError("[Internal Error] Invalid syntax kind for DeclGroupSyntaxType: \(_syntaxNode.kind)")
    }
  }

  public var name: TokenSyntax {
    get { _getGroupProp(\.name) }
    set { _setGroupProp(\.name, newValue: newValue) }
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
}
