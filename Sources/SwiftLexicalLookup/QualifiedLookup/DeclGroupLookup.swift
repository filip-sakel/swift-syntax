//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

@_spi(_QualifiedLookup) public struct DeclGroupSyntaxType: DeclGroupSyntax {
  // TODO: Consider using the underlying syntax node (like ``ValueDeclSyntax``)
  private var box: any DeclGroupSyntax

  public init?(_ node: borrowing some SyntaxProtocol) {
    if let castNode = node.asProtocol((any NominalTypeDeclSyntax).self) {
      box = castNode
    } else if let castNode = node.as(ProtocolDeclSyntax.self) {
      box = castNode
    } else if let castNode = node.as(ExtensionDeclSyntax.self) {
      box = castNode
    } else {
      return nil
    }
  }

  public init(exactly node: some DeclGroupSyntax) {
    box = node
  }
  // public var identifier: Identifier? {
  //   if let castNode = box.as(StructDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(EnumDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ClassDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ActorDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ProtocolDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else { /* extensions have types not identifiers */
  //     nil
  //   }
  // }

  // TODO: Implement canonical type
  public var type: TypeSyntax? {
    if let castNode = box.as(StructDeclSyntax.self) {
      TypeSyntax(IdentifierTypeSyntax(name: castNode.name))
    } else if let castNode = box.as(EnumDeclSyntax.self) {
      TypeSyntax(IdentifierTypeSyntax(castNode.name))
    } else if let castNode = box.as(ClassDeclSyntax.self) {
      TypeSyntax(IdentifierTypeSyntax(castNode.name))
    } else if let castNode = box.as(ActorDeclSyntax.self) {
      TypeSyntax(IdentifierTypeSyntax(castNode.name))
    } else if let castNode = box.as(ProtocolDeclSyntax.self) {
      TypeSyntax(IdentifierTypeSyntax(castNode.name))
    } else if let castNode = box.as(ExtensionDeclSyntax.self) {
      castNode.extendedType
    } else {
      nil
    }
  }

  public var attributes: SwiftSyntax.AttributeListSyntax {
    get { box.attributes }
    set { box.attributes = newValue }
  }

  public var modifiers: SwiftSyntax.DeclModifierListSyntax {
    get { box.modifiers }
    set { box.modifiers = newValue }
  }

  public var introducer: SwiftSyntax.TokenSyntax {
    get { box.introducer }
    set { box.introducer = newValue }
  }

  public var inheritanceClause: SwiftSyntax.InheritanceClauseSyntax? {
    get { box.inheritanceClause }
    set { box.inheritanceClause = newValue }
  }

  public var genericWhereClause: SwiftSyntax.GenericWhereClauseSyntax? {
    get { box.genericWhereClause }
    set { box.genericWhereClause = newValue }
  }

  public var memberBlock: SwiftSyntax.MemberBlockSyntax {
    get { box.memberBlock }
    set { box.memberBlock = newValue }
  }

  public var _syntaxNode: SwiftSyntax.Syntax {
    box._syntaxNode
  }

  public static let structure: SwiftSyntax.SyntaxNodeStructure = .choices([
    .node(StructDeclSyntax.self), .node(EnumDeclSyntax.self), .node(ClassDeclSyntax.self),
    .node(ActorDeclSyntax.self), .node(ProtocolDeclSyntax.self), .node(ExtensionDeclSyntax.self),
  ])

  @_spi(Experimental)
  public var _asLookInMembersScope: LookInMembersScopeSyntax? {
    Syntax(self).asProtocol((any SyntaxProtocol).self) as? any LookInMembersScopeSyntax
  }
}
