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

@_spi(_QualifiedLookupInternal) public struct ProtocolsLackGenericParametersError: Equatable, Error {}

/// Protocol encapusulating `NominalTypeDeclSyntax`. Only `[Struct/Enum/Class/Actor/Protocol]DeclSyntax`
/// should conform.
@_spi(_QualifiedLookup) public protocol NominalTypeDeclSyntaxProtocol: DeclGroupSyntax, NamedDeclSyntax {
  // @_spi(_QualifiedLookupInternal) var _genericParameterClause:
  //   Result<GenericParameterClauseSyntax?, ProtocolsLackGenericParametersError>
  // { get }
}

// // Structs, enums, classes, and actors may have generic-parameter clauses.
// extension NominalTypeDeclSyntaxProtocol where Self: WithGenericParametersSyntax {
//   @_spi(_QualifiedLookupInternal) public var _genericParameterClause:
//     Result<GenericParameterClauseSyntax?, ProtocolsLackGenericParametersError>
//   {
//     .success(genericParameterClause)
//   }
// }
// @_spi(_QualifiedLookup) extension StructDeclSyntax: NominalTypeDeclSyntaxProtocol {}
// @_spi(_QualifiedLookup) extension EnumDeclSyntax: NominalTypeDeclSyntaxProtocol {}
// @_spi(_QualifiedLookup) extension ClassDeclSyntax: NominalTypeDeclSyntaxProtocol {}
// @_spi(_QualifiedLookup) extension ActorDeclSyntax: NominalTypeDeclSyntaxProtocol {}
//
// // Protocols don't have generic-parameter clauses; they may just have primary
// // associated types (but we use regular associated types for lookup).
// @_spi(_QualifiedLookup) extension ProtocolDeclSyntax: NominalTypeDeclSyntaxProtocol {
//   @_spi(_QualifiedLookupInternal) public var _genericParameterClause:
//     Result<SwiftSyntax.GenericParameterClauseSyntax?, ProtocolsLackGenericParametersError>
//   {
//     .failure(ProtocolsLackGenericParametersError())
//   }
// }

/// A nominal type declaration (struct, enum, class, actor, protocol).
@_spi(_QualifiedLookup) public struct NominalTypeDeclSyntax: NominalTypeDeclSyntaxProtocol, SyntaxHashable {
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
  private func _getGroupProp<T>(_ prop: KeyPath<any NominalTypeDeclSyntaxProtocol, T>) -> T {
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
    _ keyPath: WritableKeyPath<any NominalTypeDeclSyntaxProtocol, T>,
    newValue: T
  ) {
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let declGroup):
      var box: any NominalTypeDeclSyntaxProtocol = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .enumDecl(let declGroup):
      var box: any NominalTypeDeclSyntaxProtocol = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .classDecl(let declGroup):
      var box: any NominalTypeDeclSyntaxProtocol = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .actorDecl(let declGroup):
      var box: any NominalTypeDeclSyntaxProtocol = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    case .protocolDecl(let declGroup):
      var box: any NominalTypeDeclSyntaxProtocol = declGroup
      box[keyPath: keyPath] = newValue
      _syntaxNode = box._syntaxNode
    default:
      fatalError("[Internal Error] Invalid syntax kind for DeclGroupSyntaxType: \(_syntaxNode.kind)")
    }
  }

  public init(_ syntax: __shared some NominalTypeDeclSyntaxProtocol) {
    self = Syntax(syntax).cast(Self.self)
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

// MARK: Upcasts

extension SourceFileRoot where Node == TypeDeclSyntax {
  init<S: NominalTypeDeclSyntaxProtocol>(_ node: __shared SourceFileRoot<S>) {
    // All nominal-type declarations are type declarations.
    self = node.as(TypeDeclSyntax.self)!
  }
}
