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
      _syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  public static var structure: SyntaxNodeStructure {
    return .choices([
      // Types
      .node(StructDeclSyntax.self),
      .node(EnumDeclSyntax.self),
      .node(ClassDeclSyntax.self),
      .node(ActorDeclSyntax.self),
      .node(ProtocolDeclSyntax.self),
      .node(TypeAliasDeclSyntax.self),
      .node(AssociatedTypeDeclSyntax.self),
      // Functions
      .node(FunctionDeclSyntax.self),
      .node(InitializerDeclSyntax.self),
      .node(DeinitializerDeclSyntax.self),
      // Storage
      .node(VariableDeclSyntax.self),
      .node(SubscriptDeclSyntax.self),
      // Macro
      .node(MacroDeclSyntax.self),
      // Enum element
      .node(EnumCaseDeclSyntax.self),
    ])
  }

  var name: TokenSyntax {
    return switch _syntaxNode.kind {
    // Types
    case .structDecl:
      _syntaxNode.cast(StructDeclSyntax.self).name
    case .enumDecl:
      _syntaxNode.cast(EnumDeclSyntax.self).name
    case .classDecl:
      _syntaxNode.cast(ClassDeclSyntax.self).name
    case .actorDecl:
      _syntaxNode.cast(ActorDeclSyntax.self).name
    case .protocolDecl:
      _syntaxNode.cast(ProtocolDeclSyntax.self).name
    case .typeAliasDecl:
      _syntaxNode.cast(TypeAliasDeclSyntax.self).name
    case .associatedTypeDecl:
      _syntaxNode.cast(AssociatedTypeDeclSyntax.self).name
    // Functions
    case .functionDecl:
      _syntaxNode.cast(FunctionDeclSyntax.self).name
    case .initializerDecl:
      _syntaxNode.cast(InitializerDeclSyntax.self).name
    case .deinitializerDecl:
      _syntaxNode.cast(DeinitializerDeclSyntax.self).name
    // Storage
    case .variableDecl:
      _syntaxNode.cast(VariableDeclSyntax.self).name
    case .subscriptDecl:
      _syntaxNode.cast(SubscriptDeclSyntax.self).name
    // Macro
    case .macroDecl:
      _syntaxNode.cast(MacroDeclSyntax.self).name
    // Enum element
    case .enumCaseDecl:
      _syntaxNode.cast(EnumCaseDeclSyntax.self).name
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  var modifiers: DeclModifierListSyntax {
    return switch _syntaxNode.kind {
    // Types
    case .structDecl:
      _syntaxNode.cast(StructDeclSyntax.self).modifiers
    case .enumDecl:
      _syntaxNode.cast(EnumDeclSyntax.self).modifiers
    case .classDecl:
      _syntaxNode.cast(ClassDeclSyntax.self).modifiers
    case .actorDecl:
      _syntaxNode.cast(ActorDeclSyntax.self).modifiers
    case .protocolDecl:
      _syntaxNode.cast(ProtocolDeclSyntax.self).modifiers
    case .typeAliasDecl:
      _syntaxNode.cast(TypeAliasDeclSyntax.self).modifiers
    case .associatedTypeDecl:
      _syntaxNode.cast(AssociatedTypeDeclSyntax.self).modifiers
    // Functions
    case .functionDecl:
      _syntaxNode.cast(FunctionDeclSyntax.self).modifiers
    case .initializerDecl:
      _syntaxNode.cast(InitializerDeclSyntax.self).modifiers
    case .deinitializerDecl:
      _syntaxNode.cast(DeinitializerDeclSyntax.self).modifiers
    // Storage
    case .variableDecl:
      _syntaxNode.cast(VariableDeclSyntax.self).modifiers
    case .subscriptDecl:
      _syntaxNode.cast(SubscriptDeclSyntax.self).modifiers
    // Macro
    case .macroDecl:
      _syntaxNode.cast(MacroDeclSyntax.self).modifiers
    // Enum element
    case .enumCaseDecl:
      _syntaxNode.cast(EnumCaseDeclSyntax.self).modifiers
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  var attributes: AttributeListSyntax {
    return switch _syntaxNode.kind {
    // Types
    case .structDecl:
      _syntaxNode.cast(StructDeclSyntax.self).attributes
    case .enumDecl:
      _syntaxNode.cast(EnumDeclSyntax.self).attributes
    case .classDecl:
      _syntaxNode.cast(ClassDeclSyntax.self).attributes
    case .actorDecl:
      _syntaxNode.cast(ActorDeclSyntax.self).attributes
    case .protocolDecl:
      _syntaxNode.cast(ProtocolDeclSyntax.self).attributes
    case .typeAliasDecl:
      _syntaxNode.cast(TypeAliasDeclSyntax.self).attributes
    case .associatedTypeDecl:
      _syntaxNode.cast(AssociatedTypeDeclSyntax.self).attributes
    // Functions
    case .functionDecl:
      _syntaxNode.cast(FunctionDeclSyntax.self).attributes
    case .initializerDecl:
      _syntaxNode.cast(InitializerDeclSyntax.self).attributes
    case .deinitializerDecl:
      _syntaxNode.cast(DeinitializerDeclSyntax.self).attributes
    // Storage
    case .variableDecl:
      _syntaxNode.cast(VariableDeclSyntax.self).attributes
    case .subscriptDecl:
      _syntaxNode.cast(SubscriptDeclSyntax.self).attributes
    // Macro
    case .macroDecl:
      _syntaxNode.cast(MacroDeclSyntax.self).attributes
    // Enum element
    case .enumCaseDecl:
      _syntaxNode.cast(EnumCaseDeclSyntax.self).attributes
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  /// Whether the given declaration is available from a static/type context.
  ///
  /// Note that macro declarations are currently only supported at file scope, so they return `nil`.
  var isStatic: Bool? {
    switch _syntaxNode.kind {
    // Types are always static
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl,
      // Inits are static, e.g., MyStruct.init(...)
      .initializerDecl,
      // Enum cases are static, e.g., MyEnum.myCase.
      .enumCaseDecl:
      return true
    // Deinits operate on instances, so not static.
    case .deinitializerDecl:
      return false
    // Functions, variables and subscripts can be static or non-static,
    // so check for 'static' or 'class' modifiers.
    case .functionDecl, .variableDecl, .subscriptDecl:
      return self.modifiers.contains(where: { modifier in
        modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
      })
    // Macro
    case .macroDecl:
      return nil
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  /// Whether the declaration is a type declaration, meaning it introduces a
  /// new type (or alias thereof).
  var isTypeDecl: Bool {
    switch _syntaxNode.kind {
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl:
      return true
    default:
      return false
    }
  }
}

// MARK: Inits

// Other Types

// Type decls
extension StructDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension EnumDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension ClassDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension ActorDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension ProtocolDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension TypeAliasDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension AssociatedTypeDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
// Function decls
extension FunctionDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension InitializerDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension DeinitializerDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
// Storage decls
extension VariableDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
extension SubscriptDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
// Macro decl
extension MacroDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}
// Enum element decl
extension EnumCaseDeclSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}

// Protocols
extension DeclGroupSyntax {
  init(fromProtocol syntax: __shared any NominalTypeDeclSyntax) {
    // We know this cast is going to succeed. Go through `init(_: SyntaxData)` just to double-check and
    // verify the kind matches in debug builds and get maximum performance in release builds.
    self = Syntax(syntax).cast(Self.self)
  }
}

// MARK: `as` Casts

extension ValueDeclSyntax {
  public func `as`(_ syntaxType: StructDeclSyntax.Type) -> StructDeclSyntax? {
    return StructDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: EnumDeclSyntax.Type) -> EnumDeclSyntax? {
    return EnumDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ClassDeclSyntax.Type) -> ClassDeclSyntax? {
    return ClassDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ActorDeclSyntax.Type) -> ActorDeclSyntax? {
    return ActorDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ProtocolDeclSyntax.Type) -> ProtocolDeclSyntax? {
    return ProtocolDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: TypeAliasDeclSyntax.Type) -> TypeAliasDeclSyntax? {
    return TypeAliasDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: AssociatedTypeDeclSyntax.Type) -> AssociatedTypeDeclSyntax? {
    return AssociatedTypeDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: FunctionDeclSyntax.Type) -> FunctionDeclSyntax? {
    return FunctionDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: InitializerDeclSyntax.Type) -> InitializerDeclSyntax? {
    return InitializerDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: DeinitializerDeclSyntax.Type) -> DeinitializerDeclSyntax? {
    return DeinitializerDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: VariableDeclSyntax.Type) -> VariableDeclSyntax? {
    return VariableDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: SubscriptDeclSyntax.Type) -> SubscriptDeclSyntax? {
    return SubscriptDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: MacroDeclSyntax.Type) -> MacroDeclSyntax? {
    return MacroDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: EnumCaseDeclSyntax.Type) -> EnumCaseDeclSyntax? {
    return EnumCaseDeclSyntax(_syntaxNode)
  }

  @available(*, deprecated, message: "This cast will always fail")
  public func `as`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> S? {
    return nil
  }
}

// MARK: `is` Checks

extension ValueDeclSyntax {
  public func `is`(_ syntaxType: StructDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: EnumDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ClassDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ActorDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ProtocolDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: TypeAliasDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: AssociatedTypeDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: FunctionDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: InitializerDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: DeinitializerDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: VariableDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: SubscriptDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: MacroDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: EnumCaseDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }

  @available(*, deprecated, message: "This check will always fail")
  public func `is`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> Bool {
    return false
  }
}
