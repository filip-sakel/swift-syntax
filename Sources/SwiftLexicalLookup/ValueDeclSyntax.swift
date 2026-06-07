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

  // var names: TokenSyntax? {
  //   switch _syntaxNode.kind {
  //   // Types
  //   case .structDecl:
  //     return _syntaxNode.cast(StructDeclSyntax.self).name
  //   case .enumDecl:
  //     return _syntaxNode.cast(EnumDeclSyntax.self).name
  //   case .classDecl:
  //     return _syntaxNode.cast(ClassDeclSyntax.self).name
  //   case .actorDecl:
  //     return _syntaxNode.cast(ActorDeclSyntax.self).name
  //   case .protocolDecl:
  //     return _syntaxNode.cast(ProtocolDeclSyntax.self).name
  //   case .typeAliasDecl:
  //     return _syntaxNode.cast(TypeAliasDeclSyntax.self).name
  //   case .associatedTypeDecl:
  //     return _syntaxNode.cast(AssociatedTypeDeclSyntax.self).name
  //   // Functions
  //   case .functionDecl:
  //     // TODO: Handle callAsFunction
  //     return _syntaxNode.cast(FunctionDeclSyntax.self).name
  //   case .initializerDecl:
  //     // TODO: Handle inits like Hello() but also the fact that we can't do [1,2].map(String.)
  //     return "init"
  //   case .deinitializerDecl:
  //     // deinits don't have a name
  //     return nil
  //   // Storage
  //   case .identifierPattern:
  //     return _syntaxNode.cast(IdentifierPatternSyntax.self).identifier
  //   case .subscriptDecl:
  //     // TODO: Fix with DeclName
  //     return nil
  //   // Macro
  //   case .macroDecl:
  //     return _syntaxNode.cast(MacroDeclSyntax.self).name
  //   // Enum element
  //   case .enumCaseElement:
  //     return _syntaxNode.cast(EnumCaseElementSyntax.self).name
  //   default:
  //     fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
  //   }
  // }
}

// MARK: Decl Name

extension ValueDeclSyntax {
  enum DeclNameFailure: Error {

  }

  /// Helper that converts a function parameter clause to declaration-name arguments
  func _paramsToArgs(_ parameterClause: FunctionParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``FunctionParameterSyntax/firstName`` is either an identifier
    // or "_". If it's "_", then `firstName.identifier` is `nil`.
    parameterClause.parameters.map({ Identifier(validating: $0.firstName) })
  }
  /// Helper that converts a subscript parameter clause to declaration-name arguments
  ///
  /// This is because subscripts don't have argument labels by default.
  func _subscriptParamsToArgs(_ parameterClause: FunctionParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``FunctionParameterSyntax/firstName`` is either an identifier
    // or "_". If it's "_", then `firstName.identifier` is `nil`.
    parameterClause.parameters.map({
      // Subscripts need both names to get an argument label.
      guard $0.secondName != nil else { return nil }
      return Identifier(validating: $0.firstName)
    })
  }
  /// Helper that converts an enum case element's parameter clause to declaration-name arguments
  ///
  /// Note that since enum elements with parentheses but no associated values aren't allowed,
  /// e.g., `myCase()`, we treat them identifiers without arguments, i.e., `myCase`.
  func _enumParamsToArgs(_ parameterClause: EnumCaseParameterClauseSyntax) -> DeclNameArgs? {
    // According to the docs, ``EnumCaseParameterClauseSyntax/firstName`` is either an identifier,
    // "_" or nil. So if it's not convertible to an identifier, it must be `nil`.
    let args = parameterClause.parameters.map({ $0.firstName.flatMap(Identifier.init(validating:)) })
    // No associated values => no arguments (because `myCase()` is illegal)
    return args.isEmpty ? nil : args
  }

  /// Returns true if the given macro is freestanding; false if attached.
  func _macroType(_ macroDecl: MacroDeclSyntax) -> DeclName.MacroType {
    // TODO: Implement in a way that handles if configs

    // return macroDecl.attributes.reduce(
    //   DeclName.MacroType(isFreestanding: false, isAttached: false),
    //   { (macroType: DeclName.MacroType, attribute: AttributeListSyntax.Element) -> DeclName.MacroType in
    //     return DeclName.MacroType(
    //       isFreestanding: macroType.isFreestanding
    //         || attribute.attributeName.as(IdentifierTypeSyntax.self)?.name == .identifier("freestanding"),
    //       isAttached: macroType.isAttached
    //         || attribute.attributeName.as(IdentifierTypeSyntax.self)?.name == .identifier("attached")
    //     )
    //   }
    // )
    print("[SwiftLexicalLookup] Warning: Macro type determination hasn't been implemented yet.")
    return DeclName.MacroType(isFreestanding: false, isAttached: false)
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
      return DeclName.fromToken(_syntaxNode.cast(IdentifierPatternSyntax.self).identifier, args: nil)
    // Functions
    case .functionDecl:
      let funcDecl = _syntaxNode.cast(FunctionDeclSyntax.self)
      guard let identifier = Identifier(validating: funcDecl.name) else {
        return DeclName.invalid(
          nonIdentifier: funcDecl.name.tokenKind,
          args: _paramsToArgs(funcDecl.signature.parameterClause)
        )
      }
      // Check for callAsFunction (instance method named `callAsFunction`).
      if identifier.name == "callAsFunction", self.isStatic == .success(false) {
        return DeclName.callAsFunction(args: _paramsToArgs(funcDecl.signature.parameterClause))
      }
      return DeclName.identifier(identifier: identifier, args: _paramsToArgs(funcDecl.signature.parameterClause))
    case .initializerDecl:
      let initDecl = _syntaxNode.cast(InitializerDeclSyntax.self)
      return DeclName.`init`(args: _paramsToArgs(initDecl.signature.parameterClause))
    case .deinitializerDecl:
      // deinits don't have a name
      return DeclName.deinit
    // Storage

    case .subscriptDecl:
      let subscriptDecl = _syntaxNode.cast(SubscriptDeclSyntax.self)
      return DeclName.subscript(args: _subscriptParamsToArgs(subscriptDecl.parameterClause))
    // Macro
    case .macroDecl:
      let macroDecl = _syntaxNode.cast(MacroDeclSyntax.self)
      return DeclName.fromToken(
        macroDecl.name,
        macro: _macroType(macroDecl),
        args: _paramsToArgs(macroDecl.signature.parameterClause)
      )
    // Enum element
    case .enumCaseElement:
      let enumElement = _syntaxNode.cast(EnumCaseElementSyntax.self)
      return DeclName.fromToken(
        enumElement.name,
        args: enumElement.parameterClause.flatMap(_enumParamsToArgs(_:))
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
  init?(validating token: TokenSyntax) {
    guard let identifier = token.identifier, !token.hasError else {
      return nil
    }
    self = identifier
  }
}

indirect enum DeclName: Hashable, CustomDebugStringConvertible {
  /// A macro can be freestanding and/or attached.
  ///
  /// Both flags are off when the user failed to specify
  /// their macro's type.
  struct MacroType: Hashable {
    let isFreestanding: Bool
    let isAttached: Bool
  }

  /// A declaration name formed by an identifier and, possibly, an argument list.
  ///
  /// Regular declarations like functions have `macro == nil` and only macros
  /// set `MacroType`.
  case identifier(identifier: Identifier, macro: MacroType? = nil, args: DeclNameArgs?)

  /// A declaration name formed by token syntax that isn't a valid identifier
  /// and, possibly, an argument list.
  ///
  /// Note that `nonIdentifier` is a ``TokenKind`` instead of `TokenSyntax`
  /// because the latter tracks things like leading and trailing trivia which
  /// makes comparisons harder.
  case invalid(nonIdentifier: TokenKind, macro: MacroType? = nil, args: DeclNameArgs?)

  /// An instance method named `callAsFunction` can be applied called as
  /// `instance.callAsFunction(...)`, or equivalently `instance(...)`.
  /// See [proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0253-callable.md)
  case callAsFunction(args: DeclNameArgs)
  case `init`(args: DeclNameArgs)

  // Special names, i.e. names the user can't directly look up.

  /// Deinit can't be looked up via a user query, e.g. `MyClass.deinit` ❌.
  /// However, tooling may look for deinits in a class.
  case `deinit`
  /// Similar to deinits, subscripts can't be referenced directly. Tooling
  /// may look them up by getting the name of a SubscriptCallExpr.
  case `subscript`(args: DeclNameArgs)

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
    macro: MacroType? = nil,
    args: DeclNameArgs?
  ) -> DeclName {
    guard let identifier = Identifier(validating: token) else {
      return DeclName.invalid(nonIdentifier: token.tokenKind, macro: macro, args: args)
    }
    return DeclName.identifier(identifier: identifier, macro: macro, args: args)
  }

  var isEditorPlaceholder: Bool {
    switch self {
    case .identifier(let id, _, _): id.isEditorPlaceholder
    default: false
    }
  }
  var debugDescription: String {
    /// Create a debug string for the given arguments. The argument list is
    /// empty when `args == nil`. Enclose in parentheses if `withParens == true`.
    func describeArgs(_ args: DeclNameArgs?, withParens: Bool = true) -> String {
      guard let args else { return "" }
      // Args have the form `(arg1:arg2:...)`. Args without labels
      // use an underscore.
      let argList = args.map({ ($0?.name ?? "_") + ":" }).joined(separator: "")
      return if withParens { "(\(argList))" } else { argList }
    }

    func describeMacro(_ macroType: MacroType?) -> String {
      guard let macroType else { return "" }
      // Match freestanding/attached
      return switch (macroType.isFreestanding, macroType.isAttached) {
      case (true, true): "(#/@)"
      case (true, false): "#"
      case (false, true): "@"
      case (false, false): "(??)"
      }
    }

    let baseName: String =
      switch self {
      case .identifier(let identifier, let macro, let args):
        "\(describeMacro(macro))\(identifier.name)\(describeArgs(args))"

      case .invalid(let nonIdentifier, let macro, let args):
        "\(describeMacro(macro))<?\(nonIdentifier)?>\(describeArgs(args))"
      case .callAsFunction(let args): "*callAsFunction*\(describeArgs(args))"

      case .subscript(let args): "[\(describeArgs(args, withParens: false))]"
      case .`init`(let args): "*init*\(describeArgs(args))"
      // Trivial cases
      case .deinit: "*deinit*"
      }

    return "''\(baseName)''"
  }

  enum MatchFailure: Error {
    case idMismatch
    case noMatch
    case wrongMacroType
    case argumentMismatch
    case macroMismatch
  }
  /// Try to match this declaration's name with the given
  func tryMatch(reference: DeclNameRef.CoreName) -> Result<Void, MatchFailure> {
    let callAsFunctionId = Identifier(canonicalName: "callAsFunction")

    switch (self, reference) {
    // Deinits always match
    case (.deinit, .deinit):
      return .success(())

    // Match init if reference doesn't provide arguments.
    case (.`init`(_), .`init`(args: nil)),
      (.callAsFunction(args: _), .identifier(identifier: callAsFunctionId, macro: nil, args: nil)):
      return .success(())
    // For inits (named and unnamed), subscripts and `callAsFunction` (named and unnamed),
    // check that arguments match.
    //
    // Recall that init can be referenced both as `<Type>.init(...)` and
    // as `<Type>(...)` (represented by ``unnamedCall``).
    //
    // Similarly, we can do both `<myValue>.callAsFunction(...)` and `<myValue>(...)`
    case (.`init`(let argsA), .unnamedCall(let argsB)),
      (.`init`(let argsA), .`init`(let argsB?)),
      (.subscript(let argsA), .subscript(let argsB)),
      (.callAsFunction(let argsA), .unnamedCall(let argsB)),
      (
        .callAsFunction(let argsA),
        .identifier(identifier: callAsFunctionId, nil, let argsB?)
      ):
      guard argsA == argsB else { return .failure(MatchFailure.argumentMismatch) }
      return .success(())
    // Identifiers need to check macro type, identifiers and arguments
    case let (.identifier(idA, macroType, optionalArgsA), .identifier(idB, macroRef, optionalArgsB)):
      // Check if macro types match
      //
      // E.g. If we're expecting `@Observable` we can match with neither
      // `#Observable` nor `Observable`
      let macroMatches =
        switch (macroType, macroRef) {
        case (nil, nil): true
        case (let macroType?, .freestanding): macroType.isFreestanding
        case (let macroType?, .attached): macroType.isAttached
        default: false
        }
      guard macroMatches else { return .failure(MatchFailure.wrongMacroType) }

      // Check ids match
      print(
        "[Lookup Debugging] Match between .identifier; id match between '\(idA.name)' and '\(idB.name)': \(idA == idB)"
      )
      guard idA == idB else { return .failure(MatchFailure.idMismatch) }

      // Check args only if both the declaration and reference specify them.
      //
      // Here are some valid examples:
      // 1. Neither declaration nor reference have args:
      //      let a = 5
      //      a // Reference "a" has type "Int"
      // 2. Declaration has args, but reference doesn't:
      //      func f(x: Int) {}
      //      let ref = f // Reference "f" has type "(Int) -> Void"
      // 3. Declaration has no args, but reference does:
      //      let f = { 5 }
      //      f(5) // Reference "f" has type Int
      //    Note that in this example there's one, unlabeled argument.
      // func f(x: Int) {}
      if let argsA = optionalArgsA, let argsB = optionalArgsB, argsA != argsB {
        return .failure(MatchFailure.argumentMismatch)
      }

      return .success(())
    default:
      return .failure(MatchFailure.noMatch)
    }
  }
}

struct DeclNameRef: Hashable, CustomDebugStringConvertible {
  /// A macro reference is either freestanding or attached
  enum MacroReference: Hashable {
    case freestanding
    case attached
  }

  /// Similar to `DeclNameRef` but allows referring to a declaration by writing
  /// non-compound name, e.g. we can refer to the init in `struct A { init(a: Int) {} }`
  /// both as `A.init(a:)` and `A.init`.
  indirect enum CoreName: Hashable, CustomDebugStringConvertible {
    /// Like `DeclName/identifier` but with a specific macro reference.
    ///
    /// Unlike `DeclName`, this could include `callAsFunction`.
    case identifier(identifier: Identifier, macro: MacroReference? = nil, args: DeclNameArgs? = nil)

    /// An explicit reference to init. E.g. `MyType.init`. Note that the user
    /// may not specify arguments when just referencing init.
    case `init`(args: DeclNameArgs?)

    /// An unnamed call could refer to an init in a static context
    /// or a `callAsFunction` if it's an instance. It could also
    /// refer to `@dynamicallyCallable` or `@dynamicMemberLookup`.
    case unnamedCall(args: DeclNameArgs)

    // Special names, i.e. names the user can't directly look up.

    /// Only tooling can reference deinits.
    case `deinit`

    case `self`
    case `Type`
    case `Protocol`

    /// Similar to deinits, subscripts can't be referenced directly. Tooling
    /// may look them up by getting the name of a SubscriptCallExpr.
    case `subscript`(args: DeclNameArgs)

    // /// Tries to construct a regular name by extracting an identifier from the given token
    // /// and attaching the given args. Returns invalid name otherwise.
    // static func fromToken(
    //   _ token: TokenSyntax,
    //   macro: MacroReference? = nil,
    //   args: DeclNameArgs?
    // ) -> DeclNameRef? {
    //   guard let identifier = Identifier(validating: token) else { return nil }
    //   // TODO: Handle module selector
    //   return DeclNameRef(coreName: .identifier: identifier, macro: macro, args: args))
    // }

    var debugDescription: String {
      /// Create a debug string for the given arguments. The argument list is
      /// empty when `args == nil`. Enclose in parentheses if `withParens == true`.
      func describeArgs(_ args: DeclNameArgs?, withParens: Bool = true) -> String {
        guard let args else { return "" }
        // Args have the form `(arg1:arg2:...)`. Args without labels
        // use an underscore.
        let argList = args.map({ ($0?.name ?? "_") + ":" }).joined(separator: "")
        return if withParens { "(\(argList))" } else { argList }
      }

      let baseName: String
      switch self {
      case .identifier(let identifier, let macroRef, let args):
        let prefix =
          switch macroRef {
          case nil: ""  // e.g. `Int`
          case .attached: "@"  // e.g. `@Observable`
          case .freestanding: "#"  // e.g. `#file`
          }
        baseName = "\(prefix)\(identifier.name)\(describeArgs(args))"

      case .subscript(let args): baseName = "[\(describeArgs(args, withParens: false))]"
      case .unnamedCall(let args): baseName = describeArgs(args)
      case .`init`(let args): baseName = "*init*\(describeArgs(args))"
      // Trivial cases
      case .deinit: baseName = "*deinit*"
      case .self: baseName = "*self*"
      case .Type: baseName = "*Type*"
      case .Protocol: baseName = "*Protocol*"
      }

      return "`\(baseName)`"
    }
  }

  let moduleIdentifier: Identifier?
  let coreName: CoreName

  init(moduleIdentifier: Identifier? = nil, coreName: CoreName) {
    self.moduleIdentifier = moduleIdentifier
    self.coreName = coreName
  }

  var debugDescription: String {
    let modulePrefix = if let moduleIdentifier { "\(moduleIdentifier.name)::" } else { "" }
    return "\(modulePrefix)\(coreName.debugDescription)"
  }
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

  /// Get the variable declaration parent of this identifier pattern
  /// value-declaration. Returns `nil` if the scope is invalid.
  private func _findVariableDeclSyntax(
    _ identifierPattern: IdentifierPatternSyntax
  ) -> VariableDeclSyntax? {
    // The hierarchy goes as follows
    //   VariableDecl -> PatternBindingList -> PatternBinding -> Pattern
    guard
      let binding = identifierPattern.parent?.as(PatternBindingSyntax.self),
      let bindingList = binding.parent?.as(PatternBindingListSyntax.self),
      let varDecl = bindingList.parent?.as(VariableDeclSyntax.self)
    else {
      return nil
    }
    return varDecl
  }
  /// Get the enum case declaration parent of this enum element
  /// value-declaration. Returns `nil` if the scope is invalid.
  private func _findEnumCaseDeclSyntax(
    _ enumElement: EnumCaseElementSyntax
  ) -> EnumCaseDeclSyntax? {
    // The hierarchy goes as follows
    //   EnumCaseDecl -> EnumCaseElementList -> EnumCaseElement
    guard
      let elementList = enumElement.parent?.as(EnumCaseElementListSyntax.self),
      let caseDecl = elementList.parent?.as(EnumCaseDeclSyntax.self)
    else {
      return nil
    }
    return caseDecl
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

  /// The modifiers attached to this value declaration (or the respective parent).
  ///
  /// Since identifier patterns and enum elements aren't themselves declarations
  /// and don't have modifiers, we return `nil` if we can't find their parents.
  var modifiers: DeclModifierListSyntax? {
    switch _syntaxNode.as(SyntaxEnum.self) {
    // Types
    case .structDecl(let structDecl):
      return structDecl.modifiers
    case .enumDecl(let enumDecl):
      return enumDecl.modifiers
    case .classDecl(let classDecl):
      return classDecl.modifiers
    case .actorDecl(let actorDecl):
      return actorDecl.modifiers
    case .protocolDecl(let protocolDecl):
      return protocolDecl.modifiers
    case .typeAliasDecl(let typeAliasDecl):
      return typeAliasDecl.modifiers
    case .associatedTypeDecl(let typeAliasDecl):
      return typeAliasDecl.modifiers
    // Functions
    case .functionDecl(let funcDecl):
      return funcDecl.modifiers
    case .initializerDecl(let initDecl):
      return initDecl.modifiers
    case .deinitializerDecl(let deinitDecl):
      return deinitDecl.modifiers
    // Storage
    case .identifierPattern(let identifierPattern):
      return _findVariableDeclSyntax(identifierPattern)?.modifiers
    case .subscriptDecl(let subscriptDecl):
      return subscriptDecl.modifiers
    // Macro
    case .macroDecl(let macroDecl):
      return macroDecl.modifiers
    // Enum element
    case .enumCaseElement(let enumElement):
      return _findEnumCaseDeclSyntax(enumElement)?.modifiers
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  var attributes: AttributeListSyntax? {
    switch _syntaxNode.as(SyntaxEnum.self) {
    // Types
    case .structDecl(let structDecl):
      return structDecl.attributes
    case .enumDecl(let enumDecl):
      return enumDecl.attributes
    case .classDecl(let classDecl):
      return classDecl.attributes
    case .actorDecl(let actorDecl):
      return actorDecl.attributes
    case .protocolDecl(let protocolDecl):
      return protocolDecl.attributes
    case .typeAliasDecl(let typeAliasDecl):
      return typeAliasDecl.attributes
    case .associatedTypeDecl(let typeAliasDecl):
      return typeAliasDecl.attributes
    // Functions
    case .functionDecl(let funcDecl):
      return funcDecl.attributes
    case .initializerDecl(let initDecl):
      return initDecl.attributes
    case .deinitializerDecl(let deinitDecl):
      return deinitDecl.attributes
    // Storage
    case .identifierPattern(let identifierPattern):
      return _findVariableDeclSyntax(identifierPattern)?.attributes
    case .subscriptDecl(let subscriptDecl):
      return subscriptDecl.attributes
    // Macro
    case .macroDecl(let macroDecl):
      return macroDecl.attributes
    // Enum element
    case .enumCaseElement(let enumElement):
      return _findEnumCaseDeclSyntax(enumElement)?.attributes
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  enum StaticLookupFailure: Equatable, Error {
    /// Static only makes sense in a nominal type.
    ///
    /// That is, we check that the value declaration appears inside a decl
    /// group (nominal type including protocols, or extension thereof).
    case unsupportedAtTopLevel
    /// Macros may only appear at file scope; it's not clear what "static" means
    case macrosOnlyAtFileScope
    /// The value declaration has an invalid scope: this is either
    /// an enum element without an enum case parent, or an identifier
    /// pattern without a variable declaration parent.
    case scopeFailure
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
  /// 1. This query considers parent context, e.g., querying ``isStatic`` on a
  ///    top-level declaration fails with ``ScopeLookupFailure.unsupportedAtTopLevel``.
  ///    However, it's flexible and will accept `class func` as static even in
  ///    a struct (assuming the user meant `static`).
  /// 2. Macro declarations will return a `macrosOnlyAtFileScope` failure.
  /// 3. Pattern identifiers that aren't inside a ``VariableDeclSyntax``
  ///    scope, or enum elements that aren't in ``EnumCaseDeclSyntax``
  ///    return the respective `ScopeLookupFailure`.
  var isStatic: Result<Bool, StaticLookupFailure> {
    /// Check that this value declaration is in a declaration group.
    func checkParentIsDeclGroup(_ parent: Syntax?) throws(StaticLookupFailure) {
      // The hierarchy is as follows:
      //    DeclGroup->MemberBlock->MemberBlockItemList->MemberBlockItem-><value decl>
      // So traverse bottom-up
      guard
        let item = parent?.as(MemberBlockItemSyntax.self),
        let list = item.parent?.as(MemberBlockItemListSyntax.self),
        let block = list.parent?.as(MemberBlockSyntax.self),
        // Check we get a decl group
        block.parent?.is(DeclGroupSyntaxType.self) == true
      else {
        throw StaticLookupFailure.unsupportedAtTopLevel
      }
    }

    return Result(catching: { () throws(StaticLookupFailure) -> Bool in
      switch _syntaxNode.as(SyntaxEnum.self) {
      // Types are always static
      case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl,
        // Inits are static, e.g., MyStruct.init(...)
        .initializerDecl:
        try checkParentIsDeclGroup(self.parent)
        return true
      // Enum cases elements are static, e.g., MyEnum.myCase
      case .enumCaseElement(let enumElement):
        // Find the enum case declaration parent.
        guard let enumCaseDecl = _findEnumCaseDeclSyntax(enumElement) else {
          throw StaticLookupFailure.scopeFailure
        }
        // Check the var declaration's parent is a group declaration
        //
        // We don't care if the parent is specifically an enum to tolerate user
        // error. For instance, the user might have converted an enum to a
        // struct and have a leftover case declaration; we just interpret that
        // as a static method and diagnose elsewhere.
        try checkParentIsDeclGroup(enumCaseDecl.parent)
        return true

      // Deinits operate on instances, so not static.
      case .deinitializerDecl:
        try checkParentIsDeclGroup(self.parent)
        return false

      // Functions, variables and subscripts can be static or non-static
      //
      // This depends on whether they have the 'static'/'class' modifiers
      case .functionDecl(let funcDecl):
        try checkParentIsDeclGroup(self.parent)
        return _modifiersIncludeStatic(funcDecl.modifiers)
      case .subscriptDecl(let subscriptDecl):
        try checkParentIsDeclGroup(self.parent)
        return _modifiersIncludeStatic(subscriptDecl.modifiers)
      case .identifierPattern(let identifierPattern):
        // We need to find the parent variable declaration
        guard let varDecl = _findVariableDeclSyntax(identifierPattern) else {
          throw StaticLookupFailure.scopeFailure
        }
        // Check the var declaration's parent is a group declaration
        try checkParentIsDeclGroup(varDecl.parent)
        return _modifiersIncludeStatic(varDecl.modifiers)
      // Macro
      case .macroDecl:
        throw StaticLookupFailure.macrosOnlyAtFileScope
      default:
        fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
      }
    })
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
}

// MARK: Type Queries

/// The context in which a type is defined.
// enum DeclContext {
//   /// A type that can be referenced "globally" in the module,
//   /// versus in an "anonymous" context (see ``DeclContext/anonymous``).
//   ///
//   /// Global doesn't refer to access control; it simply contrasts with
//   /// ``anonymous`` contexts. For instance, consider:
//   ///   struct A { struct B {} }
//   ///   func myFunc() { struct C {} }
//   /// Though `B` is nested, we can still refer to it as `A.B`. However,
//   /// there's no way to refer to `C` outside the body of `myFunc`.
//   case global
//
//   /// An anonymous context is any context whose child declarations can't
//   /// be referenced outside said context.
//   ///
//   /// Basically any ``CodeBlockItemListSyntax`` that isn't the direct
//   /// descendant of ``SourceFileSyntax`` introduces an anonymous context.
//   /// For instance, we have no way of referring to `MyStruct` outside of
//   /// `myFunc` body:
//   ///   func myFunc() { struct MyStruct {} }
//   case anonymous(inside: DeclSyntax)
// }

extension SyntaxProtocol {
  /// Try to convert this syntax to a declaration scope consisting of the
  /// underlying codeblock list item list and a flag for whether this is file scope.
  ///
  /// If this declaration isn't a declaration scope, we return `nil`. If it
  /// is a declaration scope (code block item list syntax) without a parent,
  /// we set `isFileScope` to `nil`. We only get `isFileScope == true`
  /// when the scope is the direct child of ``SourceFileSyntax``.
  fileprivate var _asDeclScope: (CodeBlockItemListSyntax, isFileScope: Bool?)? {
    // Check we a code block with a parent.
    guard let codeBlock = self.as(CodeBlockItemListSyntax.self) else { return nil }

    // There's one ``SourceFileSyntax`` per syntax tree with exactly one
    // ``CodeBlockItemListSyntax`` child.
    //
    // If the code block doesn't have a parent, the syntax tree is likely
    // invalid so we set `isSourceFile` to nil.
    let isSourceFile = codeBlock.parent?.is(SourceFileSyntax.self)

    return (codeBlock, isSourceFile)
  }

  /// Finds the declaration scope of the current value declaration by looking
  /// through its recursive parents.
  ///
  /// A declaration scope is basically any ``CodeBlockItemListSyntax``, whose
  /// child declarations can only be referenced within said scope's block
  /// items (with the exception of ``SourceFileSyntax``). The most common
  /// declaration scope is the code block of the source file itself:
  ///   // File.swift
  ///   struct MyStruct {}
  /// Here, `MyStruct` is accessible within the entire file and --because
  /// source files are special-- within the rest of the module.
  ///
  /// Here's a more elaborate example:
  ///   // File.swift
  ///   struct A {
  ///     struct B {}
  ///     func myFunc() { struct C {} }
  ///   }
  /// In this example there are two declarations scope: (1) the source file
  /// itself (like in any valid syntax tree) and (2) the body of `myFunc`.
  /// Because structs `A` and `B` are in the same scope, which happens to be
  /// a file scope, they're accessible in the entire module as `A` and `A.B`.
  /// However, they're no way to refer to `C` outside of the body of `myFunc`.
  var declScope: (CodeBlockItemListSyntax, isFileScope: Bool?)? {
    // No parent means no scope.
    //
    // In this case, if `self` isn't a `SourceFileSyntax`, the syntax tree
    // is likely invalid
    guard let parent else { return nil }

    // See if parent is a declaration context; otherwise, get its context.
    return parent._asDeclScope ?? parent.declScope

    // // See if our parent forms a declaration context.
    // guard let codeBlock = parent.as(CodeBlockItemListSyntax.self) else {
    //   // Otherwise, check parent's context
    //   return parent.declContext
    // }
    //
    // // Every valid ``CodeBlockItemListSyntax`` has a parent. Basically anything
    // // with a code block item list syntax conforms to ``WithStatementsSyntax``.
    // //
    // // If we can't find a code block's parents, the syntax tree is likely
    // // invalid so we return `nil`.
    // guard let codeBlockContainer = codeBlock.parent else { return nil }
    //
    // // There's one ``SourceFileSyntax`` per syntax tree with exactly one
    // // ``CodeBlockItemListSyntax`` child.
    // let isSourceFile = codeBlockContainer.is(SourceFileSyntax.self)
    //
    // return (codeBlock, isSourceFile)
  }
}

indirect enum UnresolvedTypeRef: Equatable {
  // E.g. Int, Swift::Int, String::Swift::UTF8View
  // TODO: Implement generics
  case member(base: UnresolvedTypeRef?, moduleName: Identifier?, typeName: Identifier)
  // `any <ProtocolOrObject>`. Note that we don't check if `base` is actually a protocol or object.
  // E.g. `any CustomStringConvertible`
  case existential(base: UnresolvedTypeRef)
  // <Type>.Type. Note that `<MyProto>.Protocol` is translated as `(any <MyProto>).Type`
  // E.g. `Int.Type`
  case metatype(base: UnresolvedTypeRef)
  // case `function`(args: [UnresolvedTypeRef], returnType: [UnresolvedTypeRef])

  // init(syntax: TypeSyntax) {
  //   // FIXME: TODO
  // }

  enum Failure: Error {
    case invalidKind(SyntaxKind)
    case invalidIdentifier(TokenSyntax)
    case genericsNotYetSupported
    /// The ``MetatypeTypeSyntax/metatypeSpecifier`` field
    /// was neither `Type` nor `Protocol`
    /// Shouldn't occur with a valid syntax tree.
    case invalidMetatypeSpecifier(TokenSyntax)
  }

  static let _stdlibModuleIdentifier = Identifier(canonicalName: "Swift")

  // TODO: Implement the rest
  static func fromTypeSyntax(_ typeSyntax: TypeSyntax) -> Result<UnresolvedTypeRef, Failure> {
    func parseIdentifier(token: TokenSyntax) throws(Failure) -> Identifier {
      guard let identifier = Identifier(validating: token) else {
        throw Failure.invalidIdentifier(token)
      }
      return identifier
    }
    func parseGenerics(_ genericArgumentClause: GenericArgumentClauseSyntax?) throws(Failure) {
      if genericArgumentClause != nil { throw Failure.genericsNotYetSupported }
    }

    return Result(catching: { () throws(Failure) -> UnresolvedTypeRef in
      switch typeSyntax.as(TypeSyntaxEnum.self) {
      case .identifierType(let identifierType):
        try parseGenerics(identifierType.genericArgumentClause)
        return UnresolvedTypeRef.member(
          base: nil,
          moduleName: try (identifierType.moduleSelector?.moduleName).map(parseIdentifier(token:)),
          typeName: try parseIdentifier(token: identifierType.name),
        )
      case .memberType(let memberType):
        try parseGenerics(memberType.genericArgumentClause)
        return UnresolvedTypeRef.member(
          base: try fromTypeSyntax(typeSyntax).get(),
          moduleName: try (memberType.moduleSelector?.moduleName).map(parseIdentifier(token:)),
          typeName: try parseIdentifier(token: memberType.name)
        )
      case .metatypeType(let metatypeType):
        // According to the docs, metatypeSpecifier := `Type` | `Protocol`
        switch metatypeType.metatypeSpecifier.tokenKind {
        case .keyword(.Type):
          return UnresolvedTypeRef.metatype(base: try fromTypeSyntax(metatypeType.baseType).get())
        case .keyword(.Protocol):
          return UnresolvedTypeRef.metatype(
            base: UnresolvedTypeRef.existential(base: try fromTypeSyntax(metatypeType.baseType).get())
          )
        default:
          throw Failure.invalidMetatypeSpecifier(metatypeType.metatypeSpecifier)
        }
      // Example of handling built-in types
      // case .optionalType(let optionalType):
      //   return UnresolvedTypeRef.member(
      //     base: nil,
      //     moduleName: Self._stdlibModuleIdentifier,
      //     typeName: Identifier(canonicalName: "Optional")
      //   )
      default:
        throw .invalidKind(typeSyntax.kind)
      }
    })
  }
}

//
// extension ValueDeclSyntax {
//
//   // TODO: Figure out how to handle nominal types inside function-likes
//   // (funcs, inits, deinits, var accessors, subscripts), i.e., 'anonymous' contexts
//   private func _getTypeDeclType(_ typeDecl: some NominalTypeDeclSyntax) -> UnresolvedTypeRef? {
//     // Approach 1: If the type of the parent named decl is a metatype, then attach ourselves instead of .Type
//     //
//     // Approach 2: Go up the tree and check for 3 things:
//     //   (1) found decl context => return as global type
//     //   (2) found nominal type || prptocol => return membertype of <decl group type>.name
//     //   (3) found extension => return <extension type>.name
//     //   (4) anything else => keep going up
//
//     // No type with invalid identifier
//     guard let name: String = Identifier(validating: typeDecl.name) else { return nil }
//     func process(node: Syntax) -> UnresolvedTypeRef? {
//       if self._asDeclContext != nil {
//         return TypeRef.member(nil, moduleName: nil, typeMember: name)
//       } else if let nominalParent = node.asProtocol((any NominalTypeDeclSyntax).self) {
//         return TypeRef.member(ValueDeclSyntax(nominalParent).contextualType, moduleName: nil, typeMember: name)
//       } else if let extensionParent = node.as(ExtensionDeclSyntax.self) {
//         return TypeRef.member(TypeRef(syntax: extensionParent.extendedType), moduleName: nil, typeMember: name)
//       } else if let grandparent = node.parent {
//         return process(node: grandparent)
//       } else {
//         return nil
//       }
//     }
//
//     return parent.flatMap(process(node:))
//   }
//
//   /// A type that's valid in ``ValueDeclSyntax/declContext``.
//   var contextualType: UnresolvedTypeRef? {
//     // fatalError("[SwiftLexicalLookup] Internal Error: `type` query is not yet implemented for ValueDeclSyntax")
//     switch _syntaxNode.kind {
//     // Types
//     case .structDecl:
//       return _getDeclGroupType(_syntaxNode.cast(StructDeclSyntax.self))
//     case .enumDecl:
//       return _getDeclGroupType(_syntaxNode.cast(EnumDeclSyntax.self))
//     case .classDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ClassDeclSyntax.self))
//     case .actorDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ActorDeclSyntax.self))
//     case .protocolDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ProtocolDeclSyntax.self))
//     case .typeAliasDecl:
//       return TypeRef(syntax: _syntaxNode.cast(TypeAliasDeclSyntax.self).initializer.value)
//     case .associatedTypeDecl:
//       return _syntaxNode.cast(AssociatedTypeDeclSyntax.self).name
//
//     case .initializerDecl:
//       // (Args...) -> Self
//     case .deinitializerDecl:
//       // (Self) -> () -> Void
//       // Function-like, user provided
//     case .identifierPattern:
//       // Either ScopeLookupError, or RetType not provided error for computer, or .inferFromLet, or VarDecl RetType
//     case .functionDecl:
//       // Either (Self) -> (Args...) -> RetType or (Args...) -> RetType
//       // TODO: Handle callAsFunction
//       return _syntaxNode.cast(FunctionDeclSyntax.self).name
//     case .subscriptDecl:
//       // Either (Self) -> (Args...) -> RetType or (Args...) -> RetType
//
//       // Macro
//     case .macroDecl:
//       return _syntaxNode.cast(MacroDeclSyntax.self).name
//     // Enum element
//     case .enumCaseElement:
//       return _syntaxNode.cast(EnumCaseElementSyntax.self).name
//     default:
//       fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
//     }
//
//   }
// }

// MARK: Upcasting

// Conrete types
extension ValueDeclSyntax {
  // Types
  public init(_ syntax: StructDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: EnumDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ClassDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ActorDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ProtocolDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: TypeAliasDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: AssociatedTypeDeclSyntax) {
    self.init(syntax)!
  }

  // Function decls
  public init(_ syntax: FunctionDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: InitializerDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: DeinitializerDeclSyntax) {
    self.init(syntax)!
  }

  // Storage decls
  public init(_ syntax: IdentifierPatternSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: SubscriptDeclSyntax) {
    self.init(syntax)!
  }

  // Macro decl
  public init(_ syntax: MacroDeclSyntax) {
    self.init(syntax)!
  }

  // Enum case elements
  public init(_ syntax: EnumCaseElementSyntax) {
    self.init(syntax)!
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
