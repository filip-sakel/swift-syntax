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
/// 3. Abstract storage declarations (variable identifier patterns and subscripts)
/// 4. Macro declarations
/// 5. Enum element declarations
///
/// Most value declarations are actual declarations. However,
/// there are two exceptions: enum case elements (``EnumCaseElementSyntax``)
/// and identifier patterns (``IdentifierPatternSyntax``). These are value
/// declarations because they have names and can evaluate to values, however
/// they're not actual declarations conforming to `DeclSyntaxProtocol` and
/// they lack things like modifiers and attributes.
/// While simple variable declarations like `let a: Int` contain a single
/// identifier pattern `a`, it's possible to write `let a, b: Int`. Similarly,
/// enum cases look like `case myCaseA, myCaseB`. As a result, ``ValueDeclSyntax``
/// doesn't conform to ``DeclSyntaxProtocol``.
///
/// Hence, for queries to work correctly, the scope ``SyntaxProtocol/scope``
/// for ``IdentifierPatternSyntax`` must be ``VariableDeclSyntax`` and the
/// scope for ``EnumCaseElementSyntax`` must be ``EnumCaseDeclSyntax``.
/// Otherwise, queries like ``ValueDeclSyntax/isStatic`` return nil.
///
/// Basically, anything that named lookup can return.
public struct ValueDeclSyntax: SyntaxProtocol, SyntaxHashable {
  public let _syntaxNode: Syntax

  /// Try to cast a specific ``SyntaxProtocol``-conforming type to
  /// a ``ValueDeclSyntax``.
  public init?(_ node: __shared some SyntaxProtocol) {
    switch node.raw.kind {
    // Types (nominal, protocols, aliases, associated types, generic types)
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl,
      .typeAliasDecl, .associatedTypeDecl,
      // Functions (funcs, inits, deinits)
      .functionDecl, .initializerDecl, .deinitializerDecl,
      // Storage (vars, subscripts)
      .identifierPattern, .subscriptDecl,
      // Macro & Enum element
      .macroDecl, .enumCaseElement:
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
      .node(IdentifierPatternSyntax.self),
      .node(SubscriptDeclSyntax.self),
      // Macro
      .node(MacroDeclSyntax.self),
      // Enum element
      .node(EnumCaseElementSyntax.self),
    ])
  }

  // TODO: Create something like `DeclName` (and `DeclRefName` likewise)
  // to properly represent function arguments and subscripts?.
  var names: TokenSyntax? {
    switch _syntaxNode.kind {
    // Types
    case .structDecl:
      return _syntaxNode.cast(StructDeclSyntax.self).name
    case .enumDecl:
      return _syntaxNode.cast(EnumDeclSyntax.self).name
    case .classDecl:
      return _syntaxNode.cast(ClassDeclSyntax.self).name
    case .actorDecl:
      return _syntaxNode.cast(ActorDeclSyntax.self).name
    case .protocolDecl:
      return _syntaxNode.cast(ProtocolDeclSyntax.self).name
    case .typeAliasDecl:
      return _syntaxNode.cast(TypeAliasDeclSyntax.self).name
    case .associatedTypeDecl:
      return _syntaxNode.cast(AssociatedTypeDeclSyntax.self).name
    // Functions
    case .functionDecl:
      // TODO: Handle callAsFunction
      return _syntaxNode.cast(FunctionDeclSyntax.self).name
    case .initializerDecl:
      // TODO: Handle inits like Hello() but also the fact that we can't do [1,2].map(String.)
      return "init"
    case .deinitializerDecl:
      // deinits don't have a name
      return nil
    // Storage
    case .identifierPattern:
      return _syntaxNode.cast(IdentifierPatternSyntax.self).identifier
    case .subscriptDecl:
      // TODO: Fix with DeclName
      return nil
    // Macro
    case .macroDecl:
      return _syntaxNode.cast(MacroDeclSyntax.self).name
    // Enum element
    case .enumCaseElement:
      return _syntaxNode.cast(EnumCaseElementSyntax.self).name
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }
}

// MARK: Decl Name

extension ValueDeclSyntax {
  enum DeclNameFailure: Error {

  }

  /// Helper that converts a function parameter clause to declaration-name arguments
  func _paramsToArgs(_ parameterClause: FunctionParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``FunctionParameterSyntax/firstName`` is either an identifier
    // or "_". If it's "_", then `firstName.identifier` is `nil`.
    // TODO: Test this assumption that "_" Token syntax .identifier == nil
    parameterClause.parameters.map({ $0.firstName.identifier })
  }
  /// Helper that converts an enum case element's parameter clause to declaration-name arguments
  func _enumParamsToArgs(_ parameterClause: EnumCaseParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``EnumCaseParameterClauseSyntax/firstName`` is either an identifier,
    // "_" or nil. So if it's not convertible to an identifier, it must be `nil`.
    // TODO: Test this assumption that "_" Token syntax .identifier == nil
    parameterClause.parameters.map({ $0.firstName?.identifier })
  }

  var declName: DeclName {
    switch _syntaxNode.kind {
    // Types and variable identifiers have no args
    case .structDecl:
      return DeclName.fromToken(_syntaxNode.cast(StructDeclSyntax.self).name, args: nil)
    case .enumDecl:
      return DeclName.fromToken(_syntaxNode.cast(EnumDeclSyntax.self).name, args: nil)
    case .classDecl:
      return DeclName.fromToken(_syntaxNode.cast(ClassDeclSyntax.self).name, args: nil)
    case .actorDecl:
      return DeclName.fromToken(_syntaxNode.cast(ActorDeclSyntax.self).name, args: nil)
    case .protocolDecl:
      return DeclName.fromToken(_syntaxNode.cast(ProtocolDeclSyntax.self).name, args: nil)
    case .typeAliasDecl:
      return DeclName.fromToken(_syntaxNode.cast(TypeAliasDeclSyntax.self).name, args: nil)
    case .associatedTypeDecl:
      return DeclName.fromToken(_syntaxNode.cast(AssociatedTypeDeclSyntax.self).name, args: nil)
    case .identifierPattern:
      return DeclName.fromToken(_syntaxNode.cast(AssociatedTypeDeclSyntax.self).name, args: nil)
    // Functions
    case .functionDecl:
      // TODO: Handle callAsFunction
      let funcDecl = _syntaxNode.cast(FunctionDeclSyntax.self)
      // TODO Perhaps factor `isStatic` out to avoid another enum
      guard let identifier = Identifier(validating: funcDecl.name) else {
        return DeclName.invalid(
          nonIdentifier: funcDecl.name.tokenKind,
          _paramsToArgs(funcDecl.signature.parameterClause)
        )
      }
      // Check for callAsFunction (instance method named `callAsFunction`).
      if identifier.name == "callAsFunction",
        // Check function isn't marked static/class
        !_modifiersIncludeStatic(funcDecl.modifiers),
        // Check we're actually in a decl group
        funcDecl.parentScope?.isProtocol((any DeclGroupSyntax).self) == true
      {
        return DeclName.callAsFunction(_paramsToArgs(funcDecl.signature.parameterClause))
      }
      return DeclName.regular(identifier: identifier, _paramsToArgs(funcDecl.signature.parameterClause))
    case .initializerDecl:
      let initDecl = _syntaxNode.cast(InitializerDeclSyntax.self)
      return DeclName.`init`(_paramsToArgs(initDecl.signature.parameterClause))
    case .deinitializerDecl:
      // deinits don't have a name
      return DeclName.deinit
    // Storage

    case .subscriptDecl:
      let subscriptDecl = _syntaxNode.cast(SubscriptDeclSyntax.self)
      return DeclName.subscript(_paramsToArgs(subscriptDecl.parameterClause))
    // Macro
    case .macroDecl:
      let macroDecl = _syntaxNode.cast(MacroDeclSyntax.self)
      return DeclName.subscript(_paramsToArgs(macroDecl.signature.parameterClause))
    // Enum element
    case .enumCaseElement:
      let enumElement = _syntaxNode.cast(EnumCaseElementSyntax.self)
      return DeclName.fromToken(
        enumElement.name,
        args: enumElement.parameterClause.map(_enumParamsToArgs(_:))
      )
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }
}

/// The labels of function / subscript / enum element arguments used for lookup.//
/// A `nil` identifier indicates a `_` or nonexistent label, e.g. `init(_ param: Int)`
/// or `case myCase(Int)`.
/// TODO: Think about how to handle variadic (parameters + param packs) and trailing closures
typealias DeclNameArgs = [Identifier?]

extension Identifier {
  fileprivate init?(validating token: TokenSyntax) {
    guard let identifier = token.identifier, !token.hasError else {
      return nil
    }
    self = identifier
  }
}

indirect enum DeclName: Hashable {
  /// A declaration name formed by an identifier and, possibly, an argument list.
  case regular(identifier: Identifier, DeclNameArgs?)

  /// A declaration name formed by token syntax that isn't a valid identifier
  /// and, possibly, an argument list.
  ///
  /// Note that `nonIdentifier` is a ``TokenKind`` instead of `TokenSyntax`
  /// because the latter tracks things like leading and trailing trivia which
  /// makes comparisons harder.
  case invalid(nonIdentifier: TokenKind, DeclNameArgs?)

  /// An instance method named `callAsFunction` can be applied called as
  /// `instance.callAsFunction(...)`, or equivalently `instance(...)`.
  /// See [proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0253-callable.md)
  case callAsFunction(DeclNameArgs)
  case `init`(DeclNameArgs)

  // Special names, i.e. names the user can't directly look up.

  /// Deinit can't be looked up via a user query, e.g. `MyClass.deinit` ❌.
  /// However, tooling may look for deinits in a class.
  case `deinit`
  /// Similar to deinits, subscripts can't be referenced directly. Tooling
  /// may look them up by getting the name of a SubscriptCallExpr.
  case `subscript`(DeclNameArgs)

  // /// Special names are names involving some type of special handling.
  // /// Inits can be referenced
  // var isSpecial: Bool {
  //   switch self {
  //   case .normal: true
  //   default: false
  //   }
  // }

  /// Tries to construct a regular name by extracting an identifier from the given token
  /// and attaching the given args. Returns invalid name otherwise.
  static func fromToken(
    _ token: TokenSyntax,
    args: DeclNameArgs?
  ) -> DeclName {
    guard let identifier = Identifier(validating: token) else {
      return DeclName.invalid(nonIdentifier: token.tokenKind, args)
    }
    return DeclName.regular(identifier: identifier, args)
  }

  var isEditorPlaceholder: Bool {
    switch self {
    case .regular(let id, _): id.isEditorPlaceholder
    default: false
    }
  }
}

struct DeclNameRef {
  /// Similar to `DeclNameRef` but allows referring to a declaration by writing
  /// non-compound name, e.g. we can refer to the init in `struct A { init(a: Int) {} }`
  /// both as `A.init(a:)` and `A.init`.
  indirect enum DeclRef {
    case normal(DeclNameArgumentListSyntax?)

    /// An instance method named `callAsFunction` can be applied called as
    /// `instance.callAsFunction(...)`, or equivalently `instance(...)`.
    /// See [proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0253-callable.md)
    case callAsFunction(DeclNameArgumentsSyntax?)
    case `init`(DeclNameArgumentListSyntax?)

    // Special names, i.e. names the user can't directly look up.

    /// Deinit can't be looked up via a user query, e.g. `MyClass.deinit` ❌.
    /// However, tooling may look for deinits in a class.
    case `deinit`
    /// Similar to deinits, subscripts can't be referenced directly. Tooling
    /// may look them up by getting the name of a SubscriptCallExpr.
    case `subscript`(DeclNameArgumentListSyntax)
  }

  let moduleSelector: ModuleSelectorSyntax?
  let coreName: DeclName
}

// MARK: Basic Queries
extension ValueDeclSyntax {
  /// Failure to look up an identifier pattern's or enum element's
  /// scope (see below).
  enum ScopeLookupFailure: Equatable, Error {
    /// The underlying ``IdentifierPatternSyntax`` or ``EnumCaseElementSyntax``
    /// has no scope.
    case noScope
    /// The underlying syntax has an invalid scope type. If this declaration is an
    /// ``IdentifierPatternSyntax``, its scope should be `VariableDeclSyntax`. If
    /// this declaration is an ``EnumCaseElementSyntax``, its scope should be
    /// ``EnumCaseDeclSyntax``.
    case invalidScope
  }

  // /// Like ``SyntaxProtocol/scope`` but verifies` that we get the right type of scope.
  // TODO: Is this useful? And, if so, should associated type decls be scopes?
  // var checkedScope: Result<any ScopeSyntax, ScopeFailure> {
  //   Result(catching: {
  //   switch _syntaxNode.kind {
  //   // Types
  //   case .structDecl:
  //     return _syntaxNode.cast(StructDeclSyntax.self) as any ScopeSyntax
  //   case .enumDecl:
  //     return _syntaxNode.cast(EnumDeclSyntax.self) as any ScopeSyntax
  //   case .classDecl:
  //     return _syntaxNode.cast(ClassDeclSyntax.self) as any ScopeSyntax
  //   case .actorDecl:
  //     return _syntaxNode.cast(ActorDeclSyntax.self) as any ScopeSyntax
  //   case .protocolDecl:
  //     return _syntaxNode.cast(ProtocolDeclSyntax.self) as any ScopeSyntax
  //   case .typeAliasDecl:
  //     return _syntaxNode.cast(TypeAliasDeclSyntax.self) as any ScopeSyntax
  //   case .associatedTypeDecl:
  //     return _syntaxNode.cast(AssociatedTypeDeclSyntax.self)
  //   // Functions
  //   case .functionDecl:
  //     return _syntaxNode.cast(FunctionDeclSyntax.self) as any ScopeSyntax
  //   case .initializerDecl:
  //     return _syntaxNode.cast(InitializerDeclSyntax.self) as any ScopeSyntax
  //   case .deinitializerDecl:
  //     return _syntaxNode.cast(DeinitializerDeclSyntax.self) as any ScopeSyntax
  //   // Storage
  //   case .identifierPattern:
  //     guard let scope = _syntaxNode.cast(IdentifierPatternSyntax.self).scope else {
  //       throw ScopeFailure.noScope
  //     }
  //     guard scope.is(VariableDeclSyntax.self) else {
  //       throw ScopeFailure.invalidScope
  //     }
  //     return scope
  //   case .subscriptDecl:
  //     return _syntaxNode.cast(SubscriptDeclSyntax.self) as any ScopeSyntax
  //   // Macro
  //   case .macroDecl:
  //     return _syntaxNode.cast(MacroDeclSyntax.self) as any ScopeSyntax
  //   // Enum element
  //   case .enumCaseElement:
  //     return _syntaxNode.cast(EnumCaseElementSyntax.self) as any ScopeSyntax
  //   default:
  //     fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
  //   }
  //
  // }
  //

  /// Get the
  private func _findVariableDeclSyntax(
    _ identifierPattern: IdentifierPatternSyntax
  ) -> Result<VariableDeclSyntax, ScopeLookupFailure> {
    guard let scope = self.scope else {
      return Result.failure(.noScope)
    }
    guard let varDecl = scope.as(VariableDeclSyntax.self) else {
      return Result.failure(.invalidScope)
    }
    return .success(varDecl)
  }
  private func _findEnumCaseDeclSyntax(
    _ enumElement: EnumCaseElementSyntax
  ) -> Result<EnumCaseDeclSyntax, ScopeLookupFailure> {
    guard let scope = self.scope else {
      return Result.failure(.noScope)
    }
    guard let enumCaseDecl = scope.as(EnumCaseDeclSyntax.self) else {
      return Result.failure(.invalidScope)
    }
    return .success(enumCaseDecl)
  }

  // enum ModifierLookupFailure: Error {
  //   case noneInEnumCases
  //   case noScope
  //   case invalidScope
  //
  //   init(scopeFailure: ScopeLookupFailure) {
  //     self =
  //       switch scopeFailure {
  //       case .noScope: .noScope
  //       case .invalidScope: .invalidScope
  //       }
  //   }
  // }

  // TODO: Query parents of identifier type
  var modifiers: Result<DeclModifierListSyntax, ScopeLookupFailure> {
    switch _syntaxNode.kind {
    // Types
    case .structDecl:
      return .success(_syntaxNode.cast(StructDeclSyntax.self).modifiers)
    case .enumDecl:
      return .success(_syntaxNode.cast(EnumDeclSyntax.self).modifiers)
    case .classDecl:
      return .success(_syntaxNode.cast(ClassDeclSyntax.self).modifiers)
    case .actorDecl:
      return .success(_syntaxNode.cast(ActorDeclSyntax.self).modifiers)
    case .protocolDecl:
      return .success(_syntaxNode.cast(ProtocolDeclSyntax.self).modifiers)
    case .typeAliasDecl:
      return .success(_syntaxNode.cast(TypeAliasDeclSyntax.self).modifiers)
    case .associatedTypeDecl:
      return .success(_syntaxNode.cast(AssociatedTypeDeclSyntax.self).modifiers)
    // Functions
    case .functionDecl:
      return .success(_syntaxNode.cast(FunctionDeclSyntax.self).modifiers)
    case .initializerDecl:
      return .success(_syntaxNode.cast(InitializerDeclSyntax.self).modifiers)
    case .deinitializerDecl:
      return .success(_syntaxNode.cast(DeinitializerDeclSyntax.self).modifiers)
    // Storage
    case .identifierPattern:
      return _findVariableDeclSyntax(_syntaxNode.cast(IdentifierPatternSyntax.self))
        .map(\.modifiers)
    case .subscriptDecl:
      return .success(_syntaxNode.cast(SubscriptDeclSyntax.self).modifiers)
    // Macro
    case .macroDecl:
      return .success(_syntaxNode.cast(MacroDeclSyntax.self).modifiers)
    // Enum element
    case .enumCaseElement:
      return _findEnumCaseDeclSyntax(_syntaxNode.cast(EnumCaseElementSyntax.self))
        .map(\.modifiers)
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  var attributes: Result<AttributeListSyntax, ScopeLookupFailure> {
    switch _syntaxNode.kind {
    // Types
    case .structDecl:
      return .success(_syntaxNode.cast(StructDeclSyntax.self).attributes)
    case .enumDecl:
      return .success(_syntaxNode.cast(EnumDeclSyntax.self).attributes)
    case .classDecl:
      return .success(_syntaxNode.cast(ClassDeclSyntax.self).attributes)
    case .actorDecl:
      return .success(_syntaxNode.cast(ActorDeclSyntax.self).attributes)
    case .protocolDecl:
      return .success(_syntaxNode.cast(ProtocolDeclSyntax.self).attributes)
    case .typeAliasDecl:
      return .success(_syntaxNode.cast(TypeAliasDeclSyntax.self).attributes)
    case .associatedTypeDecl:
      return .success(_syntaxNode.cast(AssociatedTypeDeclSyntax.self).attributes)
    // Functions
    case .functionDecl:
      return .success(_syntaxNode.cast(FunctionDeclSyntax.self).attributes)
    case .initializerDecl:
      return .success(_syntaxNode.cast(InitializerDeclSyntax.self).attributes)
    case .deinitializerDecl:
      return .success(_syntaxNode.cast(DeinitializerDeclSyntax.self).attributes)
    // Storage
    case .identifierPattern:
      // Grab the attributes from the variable decl, if we can get it.
      return _findVariableDeclSyntax(_syntaxNode.cast(IdentifierPatternSyntax.self))
        .map(\.attributes)
    case .subscriptDecl:
      return .success(_syntaxNode.cast(SubscriptDeclSyntax.self).attributes)
    // Macro
    case .macroDecl:
      return .success(_syntaxNode.cast(MacroDeclSyntax.self).attributes)
    // Enum element
    case .enumCaseElement:
      // Grab the attributes from the enum case decl, if we can get it.
      return _findEnumCaseDeclSyntax(_syntaxNode.cast(EnumCaseElementSyntax.self))
        .map(\.attributes)
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  enum StaticLookupFailure: Equatable, Error {
    /// Macros may only appear at file scope; it's not clear what "static" means
    case macrosOnlyAtFileScope
    /// The value declaration has an nonexistent/invalid scope
    case scopeFailure(ScopeLookupFailure)
  }

  /// Whether the given list of modifiers include the `static` and/or `class` keywords.
  func _modifiersIncludeStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains(where: { modifier in
      modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
    })
  }

  /// Whether the given declaration is available from a static/type context.
  ///
  /// Notes:
  /// 1. This query doesn't care about the value declaration's parent context.
  ///    For instance, if we pass in a global function (without a `static` or
  ///    `class` modifier), we get `isStatic == true`. Further, a `class func`
  ///    inside a `struct` will also return true.
  /// 2. Macro declarations will return a `macrosOnlyAtFileScope` failure.
  /// 3. Pattern identifiers that aren't inside a ``VariableDeclSyntax``
  ///    scope, or enum elements that aren't in ``EnumCaseDeclSyntax``
  ///    return the respective `ScopeLookupFailure`.
  var isStatic: Result<Bool, StaticLookupFailure> {
    switch _syntaxNode.kind {
    // Types are always static
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl,
      // Inits are static, e.g., MyStruct.init(...)
      .initializerDecl,
      // Enum cases elements are static, e.g., MyEnum.myCase.
      .enumCaseElement:
      return .success(true)
    // Deinits operate on instances, so not static.
    case .deinitializerDecl:
      return .success(false)
    // Functions, variables and subscripts can be static or non-static
    case .functionDecl, .identifierPattern, .subscriptDecl:
      return switch self.modifiers {
      case .success(let modifiers):
        // Check for 'static' or 'class' modifiers
        .success(_modifiersIncludeStatic(modifiers))
      case .failure(let scopeFailure):
        .failure(.scopeFailure(scopeFailure))
      }
    // Macro
    case .macroDecl:
      return .failure(.macrosOnlyAtFileScope)
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

  /// Whether this value declaration must always appear at file scope; useful
  /// for filtering declarations during lookup.
  ///
  /// Currently, this includes just macro declarations. Other declarations
  /// of note:
  /// 1. Protocols: Can be nested under nominal type declarations (but not
  ///    other protocols) following SE 404.
  ///
  ///    Note that although a protocol nested under another protocol is still
  ///    illegal, tooling may want to still surface a nested protocol to
  ///    improve developer experience. Consider:
  ///      protocol MyProto { protocol Element {} }
  ///    We can trivially rewrite this illegal program to:
  ///      protocol MyProtoElement {}
  ///      protocol MyProto { typealias Element = MyProtoElement }
  ///
  /// 2. Enum case elements: Only legal inside cases living in enums.
  ///
  ///    Similar to case 1, the user might have accidentally typed `struct { case caseA }`
  ///    instead of using an `enum`, so lookup should be nice to the user.
  ///
  /// 3. Associated types: Only legal inside protocols.
  ///
  ///    Following a similar argument, a user using an associated type inside
  ///    a nominal type might have wanted to use a generic argument. We'll
  ///    still make a best-effort attempt to look it up.
  var isAlwaysGlobal: Bool {
    return switch _syntaxNode.kind {
    case .macroDecl: true
    default: false
    }
  }

  var type: TypeSyntax? {
    fatalError("[SwiftLexicalLookup] Internal Error: `type` query is not yet implemented for ValueDeclSyntax")
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
extension IdentifierPatternSyntax {
  func `as`(_ syntaxType: IdentifierPatternSyntax.Type) -> ValueDeclSyntax {
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
extension EnumCaseElementSyntax {
  func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax {
    return ValueDeclSyntax(_syntaxNode)!
  }
}

// Protocols

extension ValueDeclSyntax {
  init(fromProtocol syntax: __shared any NominalTypeDeclSyntax) {
    // We know this cast is going to succeed. Go through `init(_: SyntaxData)` just to double-check and
    // verify the kind matches in debug builds and get maximum performance in release builds.
    self = Syntax(syntax).cast(ValueDeclSyntax.self)
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
  public func `as`(_ syntaxType: IdentifierPatternSyntax.Type) -> IdentifierPatternSyntax? {
    return IdentifierPatternSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: SubscriptDeclSyntax.Type) -> SubscriptDeclSyntax? {
    return SubscriptDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: MacroDeclSyntax.Type) -> MacroDeclSyntax? {
    return MacroDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: EnumCaseElementSyntax.Type) -> EnumCaseElementSyntax? {
    return EnumCaseElementSyntax(_syntaxNode)
  }

  @available(*, deprecated, message: "This cast will always fail")
  public func `as`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> S? {
    return nil
  }
}

// MARK: DeclSyntaxProtocol Conversions

extension DeclSyntaxProtocol {
  public func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax? {
    Syntax(self).as(ValueDeclSyntax.self)
  }

  public func `is`(_ syntaxType: ValueDeclSyntax.Type) -> Bool {
    self.as(syntaxType) != nil
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
  public func `is`(_ syntaxType: IdentifierPatternSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: SubscriptDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: MacroDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: EnumCaseElementSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }

  @available(*, deprecated, message: "This check will always fail")
  public func `is`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> Bool {
    return false
  }
}
