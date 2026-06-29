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

@_spi(_QualifiedLookup) public protocol TypeLikeSyntaxProtocol: SyntaxProtocol {}

@_spi(_QualifiedLookup) extension TypeSyntax: TypeLikeSyntaxProtocol {}
@_spi(_QualifiedLookup) extension NominalTypeDeclSyntax2: TypeLikeSyntaxProtocol {}

@_spi(_QualifiedLookup) public struct TypeLikeSyntax: Sendable, Hashable, TypeLikeSyntaxProtocol {
  public private(set) var _syntaxNode: Syntax

  public init?(_ node: __shared some SyntaxProtocol) {
    guard node.is(TypeSyntax.self) || node.is(NominalTypeDeclSyntax2.self) else { return nil }
    _syntaxNode = Syntax(node)
  }

  public init(_ typeLikeSyntax: TypeLikeSyntaxProtocol) {
    self._syntaxNode = typeLikeSyntax._syntaxNode
  }

  // TODO: Are we allowed to have non-primitive node types??
  public static let structure = SyntaxNodeStructure.choices([
    SyntaxNodeStructure.SyntaxChoice.node(TypeSyntax.self),
    SyntaxNodeStructure.SyntaxChoice.node(NominalTypeDeclSyntax2.self),
  ])
}

/// A type reference component either derived from source or implicitly generated.
///
/// E.g. In `let a: Int.MyType`, `MyType` is a source-derived reference. However,
/// we can also have:
///   struct A {
///     struct B {
///       struct C {
///         func f(_: C) // <- Look up here
///       }
///     }
///   }
/// In this case, we look inside "A.B" to find `C`, so we implicitly generate the
/// components `A` and `B`.
@_spi(_QualifiedLookup) public struct ImplicitTypeReferenceComponent: Sendable, CustomDebugStringConvertible {
  let module: Identifier?
  let name: Identifier
  let introducingSyntax: TypeLikeSyntax

  init(from sourceComponent: PartiallyResolvedTypeIdentifier.Component) {
    self.module = sourceComponent.module
    self.name = sourceComponent.name
    self.introducingSyntax = TypeLikeSyntax(sourceComponent.introducingSyntax)
  }

  public var debugDescription: String {
    let modulePrefix: String
    if let module {
      modulePrefix = "\(module)::"
    } else {
      modulePrefix = ""
    }

    return "\(modulePrefix)\(name.name)"
  }
}
