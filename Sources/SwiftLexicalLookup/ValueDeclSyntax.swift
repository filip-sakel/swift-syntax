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

@_spi(RawSyntax) import SwiftSyntax

/// A value declaration is a declaration that evaluates to a value and
/// which typically has a type and a name.
///
/// Value declarations are:
/// 1. Type declarations, meaning: nominal types (structs, enums, classes, actors),
///                                protocols, type aliases, associated types,
/// TODO: What about generic parameter types? `https://download.swift.org/docs/assets/generics.pdf`
///                                generic parameter declarations
/// 2. Abstract function declarations (functions, initializers, deinitializers)
/// 3. Abstract storage declarations (variables and subscripts)
/// 4. Macro declarations
/// 5. Enum element declarations
///
/// Basically, anything that named lookup can return.
public struct ValueDeclSyntax: DeclSyntaxProtocol, SyntaxHashable {
  public let _syntaxNode: Syntax

  /// Create a ``DeclSyntax`` node from a specialized optional syntax node.
  public init?(_ syntax: __shared (some DeclSyntaxProtocol)?) {
    guard let syntax = syntax else {
      return nil
    }
    self.init(syntax)
  }

  public init(fromProtocol syntax: __shared DeclSyntaxProtocol) {
    // We know this cast is going to succeed. Go through `init(_: SyntaxData)` just to double-check and
    // verify the kind matches in debug builds and get maximum performance in release builds.
    self = Syntax(syntax).cast(Self.self)
  }

  /// Create a ``DeclSyntax`` node from a specialized optional syntax node.
  public init?(fromProtocol syntax: __shared DeclSyntaxProtocol?) {
    guard let syntax = syntax else {
      return nil
    }
    self.init(fromProtocol: syntax)
  }

  public init?(_ node: __shared some SyntaxProtocol) {
    switch node.raw.kind {
    // Types (nominal, protocols, aliases, associated types, generic types)
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl,
      .typeAliasDecl, .associatedTypeDecl,
      // Functions (funcs, inits, deinits)
      .functionDecl, .initializerDecl, .deinitializerDecl,
      // Storage (vars, subscripts)
      .variableDecl, .subscriptDecl,
      // Macro & Enum element
      .macroDecl, .enumCaseDecl:
      self._syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  /// Syntax nodes always conform to `DeclSyntaxProtocol`. This API is just
  /// added for consistency.
  ///
  ///  - Note:  This will incur an existential conversion.
  @available(*, deprecated, message: "Expression always evaluates to true")
  public func isProtocol(_: DeclSyntaxProtocol.Protocol) -> Bool {
    return true
  }

  /// Return the non-type erased version of this syntax node.
  ///
  ///  - Note:  This will incur an existential conversion.
  public func asProtocol(_: DeclSyntaxProtocol.Protocol) -> DeclSyntaxProtocol {
    return Syntax(self).asProtocol(DeclSyntaxProtocol.self)!
  }

  public static var structure: SyntaxNodeStructure {
    return .choices([
      .node(AccessorDeclSyntax.self),
      .node(ActorDeclSyntax.self),
      .node(AssociatedTypeDeclSyntax.self),
      .node(ClassDeclSyntax.self),
      .node(DeinitializerDeclSyntax.self),
      .node(EditorPlaceholderDeclSyntax.self),
      .node(EnumCaseDeclSyntax.self),
      .node(EnumDeclSyntax.self),
      .node(ExtensionDeclSyntax.self),
      .node(FunctionDeclSyntax.self),
      .node(IfConfigDeclSyntax.self),
      .node(ImportDeclSyntax.self),
      .node(InitializerDeclSyntax.self),
      .node(MacroDeclSyntax.self),
      .node(MacroExpansionDeclSyntax.self),
      .node(MissingDeclSyntax.self),
      .node(OperatorDeclSyntax.self),
      .node(PoundSourceLocationSyntax.self),
      .node(PrecedenceGroupDeclSyntax.self),
      .node(ProtocolDeclSyntax.self),
      .node(StructDeclSyntax.self),
      .node(SubscriptDeclSyntax.self),
      .node(TypeAliasDeclSyntax.self),
      .node(UnexpectedCodeDeclSyntax.self),
      .node(UsingDeclSyntax.self),
      .node(VariableDeclSyntax.self),
    ])
  }
}
