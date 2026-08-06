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

// MARK: Result Types

// TODO: Handle `AnyObject`
@_spi(_QualifiedLoookupTests)
public enum PartiallyResolvedType {
  case anyType
  case typeIdentifier(Result<TypeReference.Component, InvalidTypeIdentifierFailure>)
  case function(argumentCount: Int)
  case tuple(labels: [Identifier?])
  case member(
    base: SourceFileRoot<TypeSyntax>,
    memberComponent: Result<TypeReference.Component, InvalidTypeIdentifierFailure>
  )
  case composition([SourceFileRoot<TypeSyntax>])
}

@_spi(_QualifiedLookupTests)
public struct TypeReference: Sendable, CustomDebugStringConvertible {
  public struct Component: Hashable, Sendable, CustomDebugStringConvertible {
    let module: Identifier?
    let name: Identifier
    /// The `TypeSyntax` or `TokenSyntax` from which we derived this type reference component;
    /// used for targeted diagnostics.
    public let introducingSyntax: SourceFileRoot<TypeSyntax>

    public init(
      module: Identifier? = nil,
      name: Identifier,
      introducingSyntax: SourceFileRoot<TypeSyntax>
    ) {
      self.module = module
      self.name = name
      self.introducingSyntax = introducingSyntax
    }

    public var debugDescription: String {
      let modulePrefix = if let module { "\(module.name)::" } else { "" }
      return "\(modulePrefix)\(name.name)"
    }
  }
  public let base: Component
  public private(set) var memberChain: [Component] = []

  var lastComponent: Component {
    memberChain.last ?? base
  }

  func addingComponents(
    _ newComponents: [Component] /*, newTypeSyntax: TypeSyntax*/
  ) -> TypeReference {
    TypeReference(
      base: base,
      memberChain: self.memberChain + newComponents
        // typeSyntax: newTypeSyntax
    )
  }

  public var debugDescription: String {
    "\(base.debugDescription)\(memberChain.map({ ".\($0.debugDescription)" }).joined())"
  }
}

@_spi(_QualifiedLoookupTests)
public enum PartialTypeResolutionFailure: Error {
  /// Missing types produce errors
  case missingType

  /// We defer wildcard types to the type checker (e.g., `_`, `_.MyType`, `any _`).
  case wildcardType
  /// We report unknown supressed types, e.g., `~CustomStringConvertible`
  case unknownSuppressedType
}

@_spi(_QualifiedLoookupTests)
public struct InvalidTypeIdentifierFailure: Error {
  let invalidModuleName: TokenSyntax?
  let invalidName: TokenSyntax?
}

// MARK: Helpers

extension PartiallyResolvedType {
  /// Types for which we can use the suppression syntax.
  /// E.g., `AnyKeyPath & ~Sendable`
  fileprivate static let _knownSuppressibleTypes: Array = [
    Identifier(canonicalName: "Copyable"),
    Identifier(canonicalName: "Escapable"),
  ]
}

extension TypeReference.Component {
  // E.g., `Int?` or `Int!` -> `Optional<Int>`
  fileprivate static func _optionalType(type: SourceFileRoot<TypeSyntax>) -> TypeReference.Component {
    TypeReference.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Optional"),
      // introducingSyntax: TypeLikeSyntax.typeSyntax(type)
      introducingSyntax: type
    )
  }
  /// E.g., `[Int]` -> `Array<Int>`
  fileprivate static func _arrayType(type: SourceFileRoot<TypeSyntax>) -> TypeReference.Component {
    TypeReference.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Array"),
      // introducingSyntax: TypeLikeSyntax.typeSyntax(type)
      introducingSyntax: type
    )
  }
  // E.g., `[5 of Int]` -> `InlineArray<5, Int>`
  fileprivate static func _inlineArrayType(
    type: SourceFileRoot<TypeSyntax>
  ) -> TypeReference.Component {
    TypeReference.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "InlineArray"),
      // introducingSyntax: TypeLikeSyntax.typeSyntax(type)
      introducingSyntax: type
    )
  }
  // E.g., `[String: Int]` -> `Dictionary<String, Int>`
  fileprivate static func _dictionaryType(type: SourceFileRoot<TypeSyntax>) -> TypeReference.Component {
    TypeReference.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Dictionary"),
      // introducingSyntax: TypeLikeSyntax.typeSyntax(type)
      introducingSyntax: type
    )
  }
}

/// Parses the given module and identifier originating from `typeSyntax`.
/// Otherwise, returns the appropriate failures.
private func _parseModuleAndIdentifier(
  moduleNameToken: TokenSyntax?,
  nameToken: TokenSyntax,
  typeSyntax: SourceFileRoot<TypeSyntax>
) -> Result<TypeReference.Component, InvalidTypeIdentifierFailure> {
  switch (moduleNameToken.map({ Identifier(validating: $0) }), Identifier(validating: nameToken)) {
  // Valid cases are:
  // (a) no module, valid name
  case (nil, let name?):
    return .success(
      TypeReference.Component(
        module: nil,
        name: name,
        introducingSyntax: typeSyntax
      )
    )
  // (b) valid module, valid name
  case (let moduleName??, let name?):
    return .success(
      TypeReference.Component(
        module: moduleName,
        name: name,
        introducingSyntax: typeSyntax
      )
    )
  // Invalid cases are:
  // (a) no module/valid module,  invalid name
  case (nil, nil), (_??, nil):
    return .failure(InvalidTypeIdentifierFailure(invalidModuleName: nil, invalidName: nameToken))
  // (b) invalid module, valid name
  case (.some(nil), _?):
    return .failure(InvalidTypeIdentifierFailure(invalidModuleName: moduleNameToken, invalidName: nil))
  // (c) invalid module, invalid name
  case (.some(nil), nil):
    return .failure(InvalidTypeIdentifierFailure(invalidModuleName: moduleNameToken, invalidName: nameToken))
  }
}

// MARK: Partial Resolution

extension SourceFileRoot where Node: TypeSyntaxProtocol {
  // We force unwrap because type resolution just visits a type syntax's children.
  fileprivate func _castChild<S: SyntaxProtocol>(_ syntax: S) -> SourceFileRoot<S> {
    SourceFileRoot<S>(syntax)!
  }

  @_spi(_QualifiedLoookup)
  public func partiallyResolve() -> Result<PartiallyResolvedType, PartialTypeResolutionFailure> {
    switch TypeSyntax(node).as(TypeSyntaxEnum.self) {
    // Non-nominal base cases
    //
    // Functions
    case .functionType(let functionType):
      return Result.success(PartiallyResolvedType.function(argumentCount: functionType.parameters.count))
    // Valid tuples (we treat single-element tuples as their only contained type below)
    case .tupleType(let tupleType):
      // Single-element tuples are just the type, e.g., the tuple type syntax
      // `(Int)` is just `Int`.
      // We diagnose single-element labels elsewhere
      // TODO: Should we diagnose single-element labels here?
      if let soleTupleElement = tupleType.elements.first, tupleType.elements.count == 1 {
        // Forward resolution
        return _castChild(soleTupleElement.type).partiallyResolve()
      }

      // Get labels and collect identifier errors
      let labels: [Identifier?] = tupleType.elements.map({ label -> Identifier? in
        // Tuple elements get their labels from the first name.
        //
        // According to the ``TupleTypeSyntax`` docs, the first name is `nil` (implicitly no label),
        // `_` (explicitly no label), or an identifier (the label). So if the first name isn't a
        // valid identifier, the tuple has no label or the parser already diagnosed that.
        guard
          let labelToken = label.firstName,
          let label = Identifier(validating: labelToken)
        else { return nil }
        return label
      })
      // Add tuple type
      return Result.success(PartiallyResolvedType.tuple(labels: labels))

    // Nominal base cases
    case .identifierType(let identifierType):
      // According to the docs, `moduleSelector.moduleName` should be an identifier
      // and `name` is an identifier, `Self`, `Any` or `_`. Here's how we handle each:
      let moduleNameToken = identifierType.moduleSelector?.moduleName
      let nameToken: TokenSyntax
      switch (identifierType.moduleSelector, identifierType.name.tokenKind) {
      // === Wildcard `_` ===
      // We can't do anything smart, so we defer to the type checker.
      case (_, .wildcard):
        return Result.failure(PartialTypeResolutionFailure.wildcardType)
      // === `Any` ===
      // Without a module selector, the keyword "Any" and the backtick-escaped
      // identifier "`Any`" are completely different in terms of lookup. Hence,
      // we treat the keyword "Any" like we do metatypes below by returning no
      // nominal results.
      //
      // However, if a module selector is specified, we treat it just like an
      // identifier.
      //
      // Here's an example where unqualified "`Any`" doesn't shadow `Any`:
      //   typealias `Any` = Int
      //   func g(a: Any) -> Int {
      //     a + 1 // ❌ cannot convert value of type 'Any' to expected argument type 'Int'
      //   }
      // And here's an example where unqualified "`Any`" doesn't resolve to `Any`:
      //   func g(a: `Any`) -> Int { // ❌ cannot find type 'Any' in scope
      //     a + 1
      //   }
      //
      // Here's an example where `MyModule::Any` acts like an identifier:
      //   func g(a: output::Any) -> Int {} // ❌ cannot find type 'output::Any' in scope
      case (nil, .keyword(.Any)):
        return Result.success(PartiallyResolvedType.anyType)
      case (_?, .keyword(.Any)):
        // TODO: Is this safe?
        nameToken = identifierType.name.with(\.tokenKind, .identifier("Any"))
      // === `Self` ===
      // Basically the opposite of `Any`: Whether with or without a module
      // selector, we treat "Self" like the backtick-escaped identifier
      // "`Self`", because it participates in normal lookup. Hence, we
      // convert the "Self" keyword to an identifier.
      //
      // Here's an example where "`Self`" shadows
      // implicit "Self":
      //  typealias `Self` = Int
      //  func f(a: Self) -> Int { // This is the keyword "Self" not the backtick-escaped "`Self`"
      //    a + 1 // ✅
      //  }
      // And here's an example where "`Self`" resolves to implicit "Self":
      //  struct A {
      //    func f(x: inout `Self`) {
      //      x = A() // ✅
      //    }
      //  }
      //
      // Example with module selector:
      //   struct A {
      //     func f(_: MyModule::Self) {} // ✅
      //     func g(_: MyModule::`Self`) {} // ✅
      //   }
      // Note that `Self` has different module-selector lookup behavior than
      // other identifiers because typically `MyModule::MyType` issues a
      // top-level lookup so writing:
      //   struct A { struct B {}; func f(_: MyModule::B) }
      //  fails because `B` is nested within `A`.
      case (_, .keyword(.Self)):
        nameToken = identifierType.name.with(\.tokenKind, .identifier("Self"))
      default:
        nameToken = identifierType.name
      }

      // Parse the module name (if provided), and the type name
      let parsedResult = _parseModuleAndIdentifier(
        moduleNameToken: moduleNameToken,
        nameToken: nameToken,
        typeSyntax: _castChild(TypeSyntax(identifierType))
      )
      return Result.success(PartiallyResolvedType.typeIdentifier(parsedResult))
    case .memberType(let memberType):
      // Resolve base type
      //
      // We use a new `baseTypes` array because we'll need to pass the base types
      // into the `.nominalMember` case.
      //
      // However, we pass the same `failures` array because failures record the
      // problematic type syntax so we can trace them back to source. Also, we
      // resolve the base type even if the `moduleName` and `typeName` below
      // are invalid to produce thorough and consistent diagnostics.
      // let baseTypes = memberType.baseType.partiallyResolve()

      // According to the ``MemberTypeSyntax`` docs, `name` is either an identifier
      // or the `self` keyword.
      //
      // Here's an example where "`self`" shadows implicit "self":
      //   struct A {
      //     typealias `self` = Int
      //
      //     func f(a: A.self) -> Int {
      //       a + 1 // ✅
      //     }
      //   }
      // And an example for "`self`" and "self" give identical results when
      // type lookup fails:
      //   let _: Int.`self` // ❌ error: 'self' is not a member type of struct 'output.A'
      //   let _: Int.self   // ❌ error: (same exact error)
      // TODO: Handle implicit `.self` lookup. E.g. 'Int.self' vs 'Int.`self`' are different.
      let moduleNameToken = memberType.moduleSelector?.moduleName
      let nameToken: TokenSyntax
      if memberType.name.tokenKind == .keyword(.`self`) {
        nameToken = memberType.name.with(\.tokenKind, .identifier("self"))
      } else {
        nameToken = memberType.name
      }

      // Parse the module name (if provided), and member-type name; then,
      // append to base types
      let parsedResult = _parseModuleAndIdentifier(
        moduleNameToken: moduleNameToken,
        nameToken: nameToken,
        typeSyntax: _castChild(TypeSyntax(memberType))
      )
      return Result.success(
        PartiallyResolvedType.member(base: _castChild(memberType.baseType), memberComponent: parsedResult)
      )

    // Base cases that don't produce types
    case .metatypeType, .namedOpaqueReturnType, .classRestrictionType:
      return Result.success(PartiallyResolvedType.composition([]))
    case .suppressedType:
      // Don't diagnose here since suprressed types can be aliased, e.g.:
      //   typealias A = Escapable
      //   struct B: ~A {}
      return Result.success(PartiallyResolvedType.anyType)

    // Invalid base case
    case .missingType:
      return Result.failure(PartialTypeResolutionFailure.missingType)

    // Type-sugar is a nominal-type base case
    case .optionalType(let optionalType):
      return Result.success(
        PartiallyResolvedType.typeIdentifier(
          Result.success(._optionalType(type: _castChild(TypeSyntax(optionalType))))
        )
      )
    case .implicitlyUnwrappedOptionalType(let implicitlyUnwrappedOptionalType):
      return Result.success(
        PartiallyResolvedType.typeIdentifier(
          Result.success(._optionalType(type: _castChild(TypeSyntax(implicitlyUnwrappedOptionalType))))
        )
      )
    case .arrayType(let arrayType):
      return Result.success(
        PartiallyResolvedType.typeIdentifier(
          Result.success(._arrayType(type: _castChild(TypeSyntax(arrayType))))
        )
      )
    case .inlineArrayType(let inlineArrayType):
      return Result.success(
        PartiallyResolvedType.typeIdentifier(
          Result.success(._inlineArrayType(type: _castChild(TypeSyntax(inlineArrayType))))
        )
      )
    case .dictionaryType(let dictionaryType):
      return Result.success(
        PartiallyResolvedType.typeIdentifier(
          Result.success(._dictionaryType(type: _castChild(TypeSyntax(dictionaryType))))
        )
      )

    // Recursive cases
    case .attributedType(let attributedType):
      return _castChild(attributedType.baseType).partiallyResolve()
    case .someOrAnyType(let someOrAnyTypeType):
      return _castChild(someOrAnyTypeType.constraint).partiallyResolve()
    case .packElementType(let packElementType):
      // Same behavior as the compiler
      return _castChild(packElementType.pack).partiallyResolve()
    case .packExpansionType(let packExpansionType):
      return _castChild(packExpansionType.repetitionPattern).partiallyResolve()
    case .compositionType(let compositionType):
      return Result.success(
        PartiallyResolvedType.composition(
          compositionType.elements.map({ _castChild($0.type) })
        )
      )
    }
  }
}
