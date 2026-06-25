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

@_spi(_QualifiedLoookup) public enum PartiallyResolvedType: Sendable {
  // Non-nominal types
  case function(argumentCount: Int)
  case tuple(labels: [Identifier?])
  // Nominal
  case nominalIdentifier(module: Identifier?, name: Identifier)
  case nominalMember(bases: [PartiallyResolvedType], module: Identifier?, name: Identifier)

  // Define known nominal types
  /// E.g., `Int?` -> `Optional<Int>`
  fileprivate static let _optionalType = PartiallyResolvedType.nominalIdentifier(
    module: Identifier(canonicalName: "Swift"),
    name: Identifier(canonicalName: "Optional")
  )
  /// E.g., `[Int]` -> `Array<Int>`
  fileprivate static let _arrayType = PartiallyResolvedType.nominalIdentifier(
    module: Identifier(canonicalName: "Swift"),
    name: Identifier(canonicalName: "Array")
  )
  // E.g., `[5 of Int]` -> `InlineArray<5, Int>`
  fileprivate static let _inlineArrayType = PartiallyResolvedType.nominalIdentifier(
    module: Identifier(canonicalName: "Swift"),
    name: Identifier(canonicalName: "InlineArray")
  )
  // E.g., `[String: Int]` -> `Dictionary<String, Int>`
  fileprivate static let _dictionaryType = PartiallyResolvedType.nominalIdentifier(
    module: Identifier(canonicalName: "Swift"),
    name: Identifier(canonicalName: "Dictionary")
  )
  /// Types for which we can use the suppression syntax.
  /// E.g., `AnyKeyPath & ~Sendable`
  /// TODO: Get them all from the compiler
  fileprivate static let _knownSuppressibleTypes: Set = [
    Identifier(canonicalName: "Copyable"),
    Identifier(canonicalName: "Escapable"),
    Identifier(canonicalName: "Sendable"),
  ]
}

extension PartiallyResolvedTypeIdentifier {
  fileprivate static let _optionalType = PartiallyResolvedTypeIdentifier(
    base: PartiallyResolvedTypeIdentifier.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Optional")
    )
  )
  /// E.g., `[Int]` -> `Array<Int>`
  fileprivate static let _arrayType = PartiallyResolvedTypeIdentifier(
    base: PartiallyResolvedTypeIdentifier.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Array")
    )
  )
  // E.g., `[5 of Int]` -> `InlineArray<5, Int>`
  fileprivate static let _inlineArrayType = PartiallyResolvedTypeIdentifier(
    base: PartiallyResolvedTypeIdentifier.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "InlineArray")
    )
  )
  // E.g., `[String: Int]` -> `Dictionary<String, Int>`
  fileprivate static let _dictionaryType = PartiallyResolvedTypeIdentifier(
    base: PartiallyResolvedTypeIdentifier.Component(
      module: Identifier(canonicalName: "Swift"),
      name: Identifier(canonicalName: "Dictionary")
    )
  )
}

@_spi(_QualifiedLoookup) public enum MemberLookupResultMergeFailure: Error {
  case tupleHasNoTypeMembers
  case functionHasNoTypeMembers
  case cannotComposeTuple
  case cannotComposeFunction
}

@_spi(_QualifiedLoookup) public enum TypeResolutionFailure: Error {
  /// Missing types produce errors
  case missingType
  /// Invalid identifiers produce errors
  case invalidName(invalidModuleName: TokenSyntax?, invalidName: TokenSyntax?)
  /// We defer wildcard types to the type checker (e.g., `_`, `_.MyType`, `any _`).
  case wildcardType
  /// We report unknown supressed types, e.g., `~CustomStringConvertible`
  case unknownSuppressedType
  case mergeError(MemberLookupResultMergeFailure)
}
@_spi(_QualifiedLoookup) public struct LocalizedTypeResolutionFailure: Error {
  let failures: [TypeSyntax: TypeResolutionFailure]
}

extension TypeSyntaxProtocol {
  fileprivate func _parseModuleAndIdentifier(
    moduleNameToken: TokenSyntax?,
    nameToken: TokenSyntax
  ) -> Result<PartiallyResolvedTypeIdentifier.Component, TypeResolutionFailure> {
    switch (moduleNameToken.map({ Identifier(validating: $0) }), Identifier(validating: nameToken)) {
    // Valid cases are:
    // (a) no module, valid name
    case (nil, let name?):
      return .success(PartiallyResolvedTypeIdentifier.Component(module: nil, name: name))
    // (b) valid module, valid name
    case (let moduleName??, let name?):
      return .success(PartiallyResolvedTypeIdentifier.Component(module: moduleName, name: name))
    // Invalid cases are:
    // (a) no module/valid module,  invalid name
    case (nil, nil), (_??, nil):
      return .failure(.invalidName(invalidModuleName: nil, invalidName: nameToken))
    // (b) invalid module, valid name
    case (.some(nil), _?):
      return .failure(.invalidName(invalidModuleName: moduleNameToken, invalidName: nil))
    // (c) invalid module, invalid name
    case (.some(nil), nil):
      return .failure(.invalidName(invalidModuleName: moduleNameToken, invalidName: nameToken))
    }
  }

  // @_spi(_QualifiedLoookup) public func partiallyResolveOld(
  //   types: inout [PartiallyResolvedType],
  //   failures: inout [TypeSyntax: TypeResolutionFailure]
  // ) {
  //   switch TypeSyntax(self).as(TypeSyntaxEnum.self) {
  //   // Non-nominal base cases
  //   //
  //   // Functions
  //   case .functionType(let functionType):
  //     return types.append(.function(argumentCount: functionType.parameters.count))
  //   // Valid tuples (we treat single-element tuples as their only contained type below)
  //   case .tupleType(let tupleType) where tupleType.elements.count >= 1:
  //     // Get labels and collect identifier errors
  //     let labels: [Identifier?] = tupleType.elements.map({ label -> Identifier? in
  //       // Tuple elements get their labels from the first name.
  //       //
  //       // According to the ``TupleTypeSyntax`` docs, the first name is `nil` (implicitly no label),
  //       // `_` (explicitly no label), or an identifier (the label). So if the first name isn't a
  //       // valid identifier, the tuple has no label or the parser already diagnosed that.
  //       guard
  //         let labelToken = label.firstName,
  //         let label = Identifier(validating: labelToken)
  //       else { return nil }
  //       return label
  //     })
  //     // Add tuple type
  //     return types.append(.tuple(labels: labels))
  //
  //   // Nominal base cases
  //   case .identifierType(let identifierType):
  //     // According to the docs, `moduleSelector.moduleName` should be an identifier
  //     // and `name` is an identifier, `Self`, `Any` or `_`. Here's how we handle each:
  //     let moduleNameToken = identifierType.moduleSelector?.moduleName
  //     let nameToken: TokenSyntax
  //     switch (identifierType.moduleSelector, identifierType.name.tokenKind) {
  //     // === Wildcard `_` ===
  //     // We can't do anything smart, so we defer to the type checker.
  //     case (_, .wildcard):
  //       failures[TypeSyntax(identifierType)] = .wildcardType
  //       return
  //     // === `Any` ===
  //     // Without a module selector, the keyword "Any" and the backtick-escaped
  //     // identifier "`Any`" are completely different in terms of lookup. Hence,
  //     // we treat the keyword "Any" like we do metatypes below by returning no
  //     // nominal results.
  //     //
  //     // However, if a module selector is specified, we treat it just like an
  //     // identifier.
  //     //
  //     // Here's an example where unqualified "`Any`" doesn't shadow `Any`:
  //     //   typealias `Any` = Int
  //     //   func g(a: Any) -> Int {
  //     //     a + 1 // ❌ cannot convert value of type 'Any' to expected argument type 'Int'
  //     //   }
  //     // And here's an example where unqualified "`Any`" doesn't resolve to `Any`:
  //     //   func g(a: `Any`) -> Int { // ❌ cannot find type 'Any' in scope
  //     //     a + 1
  //     //   }
  //     //
  //     // Here's an example where `MyModule::Any` acts like an identifier:
  //     //   func g(a: output::Any) -> Int {} // ❌ cannot find type 'output::Any' in scope
  //     case (nil, .keyword(.Any)):
  //       return
  //     case (_?, .keyword(.Any)):
  //       // TODO: Is this safe?
  //       nameToken = identifierType.name.with(\.tokenKind, .identifier("Any"))
  //     // === `Self` ===
  //     // Basically the opposite of `Any`: Whether with or without a module
  //     // selector, we treat "Self" like the backtick-escaped identifier
  //     // "`Self`", because it participates in normal lookup. Hence, we
  //     // convert the "Self" keyword to an identifier.
  //     //
  //     // Here's an example where "`Self`" shadows
  //     // implicit "Self":
  //     //  typealias `Self` = Int
  //     //  func f(a: Self) -> Int { // This is the keyword "Self" not the backtick-escaped "`Self`"
  //     //    a + 1 // ✅
  //     //  }
  //     // And here's an example where "`Self`" resolves to implicit "Self":
  //     //  struct A {
  //     //    func f(x: inout `Self`) {
  //     //      x = A() // ✅
  //     //    }
  //     //  }
  //     //
  //     // Example with module selector:
  //     //   struct A {
  //     //     func f(_: MyModule::Self) {} // ✅
  //     //     func g(_: MyModule::`Self`) {} // ✅
  //     //   }
  //     // Note that `Self` has different module-selector lookup behavior than
  //     // other identifiers because typically `MyModule::MyType` issues a
  //     // top-level lookup so writing:
  //     //   struct A { struct B {}; func f(_: MyModule::B) }
  //     //  fails because `B` is nested within `A`.
  //     case (_, .keyword(.Self)):
  //       nameToken = identifierType.name.with(\.tokenKind, .identifier("Self"))
  //     default:
  //       nameToken = identifierType.name
  //     }
  //
  //     // Parse the module name (if provided), and the type name
  //     switch _parseModuleAndIdentifier(moduleNameToken: moduleNameToken, nameToken: nameToken) {
  //     case .success(let newComponent):
  //       // Add nominal type
  //       types.append(.nominalIdentifier(module: newComponent.module, name: newComponent.name))
  //     case .failure(let failure):
  //       // Report failures
  //       failures[TypeSyntax(identifierType)] = failure
  //     }
  //   case .memberType(let memberType):
  //     // Resolve base type
  //     //
  //     // We use a new `baseTypes` array because we'll need to pass the base types
  //     // into the `.nominalMember` case.
  //     //
  //     // However, we pass the same `failures` array because failures record the
  //     // problematic type syntax so we can trace them back to source. Also, we
  //     // resolve the base type even if the `moduleName` and `typeName` below
  //     // are invalid to produce thorough and consistent diagnostics.
  //     var baseTypes = [PartiallyResolvedType]()
  //     memberType.baseType.partiallyResolve(types: &baseTypes, failures: &failures)
  //
  //     // According to the ``MemberTypeSyntax`` docs, `name` is either an identifier
  //     // or the `self` keyword.
  //     //
  //     // Here's an example where "`self`" shadows implicit "self":
  //     //   struct A {
  //     //     typealias `self` = Int
  //     //
  //     //     func f(a: A.self) -> Int {
  //     //       a + 1 // ✅
  //     //     }
  //     //   }
  //     // And an example for "`self`" and "self" give identical results when
  //     // type lookup fails:
  //     //   let _: Int.`self` // ❌ error: 'self' is not a member type of struct 'output.A'
  //     //   let _: Int.self   // ❌ error: (same exact error)
  //     // TODO: Handle implicit `.self` lookup. E.g. 'Int.self' vs 'Int.`self`' are different.
  //     let moduleNameToken = memberType.moduleSelector?.moduleName
  //     let nameToken: TokenSyntax
  //     if memberType.name.tokenKind == .keyword(.`self`) {
  //       nameToken = memberType.name.with(\.tokenKind, .identifier("self"))
  //     } else {
  //       nameToken = memberType.name
  //     }
  //
  //     // Parse the module name (if provided), and member-type name
  //     switch _parseModuleAndIdentifier(moduleNameToken: moduleNameToken, nameToken: nameToken) {
  //     case .success(let newComponent):
  //       // Add nominal type
  //       types.append(.nominalMember(bases: baseTypes, module: newComponent.module, name: newComponent.name))
  //     case .failure(let failure):
  //       failures[TypeSyntax(memberType)] = failure
  //     }
  //   // Base cases that don't produce types
  //   case .metatypeType, .namedOpaqueReturnType:
  //     break
  //   case .suppressedType(let suppressedType):
  //     // Check the suppressed type is known (but don't add to a resolved type)
  //     guard
  //       let identifierType = suppressedType.type.as(IdentifierTypeSyntax.self),
  //       let typeName = Identifier(validating: identifierType.name),
  //       PartiallyResolvedType._knownSuppressibleTypes.contains(typeName)
  //     else {
  //       failures[TypeSyntax(suppressedType)] = .unknownSuppressedType
  //       return
  //     }
  //     break
  //
  //   // Invalid base case
  //   case .missingType(let missingType):
  //     failures[TypeSyntax(missingType)] = .missingType
  //
  //   // Type-sugar is a nominal-type base case
  //   case .optionalType, .implicitlyUnwrappedOptionalType:
  //     types.append(._optionalType)
  //   case .arrayType:
  //     types.append(._arrayType)
  //   case .inlineArrayType:
  //     types.append(._inlineArrayType)
  //   case .dictionaryType:
  //     types.append(._dictionaryType)
  //
  //   // Recursive cases
  //   case .attributedType(let attributedType):
  //     attributedType.partiallyResolve(types: &types, failures: &failures)
  //   case .someOrAnyType(let someOrAnyTypeType):
  //     someOrAnyTypeType.partiallyResolve(types: &types, failures: &failures)
  //   case .classRestrictionType(let classRestrictionType):
  //     classRestrictionType.partiallyResolve(types: &types, failures: &failures)
  //   // TODO: Explain pack element & expansion types
  //   case .packElementType(let packElementType):
  //     packElementType.partiallyResolve(types: &types, failures: &failures)
  //   case .packExpansionType(let packExpansionType):
  //     packExpansionType.partiallyResolve(types: &types, failures: &failures)
  //   case .tupleType(let tupleType) /* where tupleType.elements.count == 1 */:
  //     // Single-element tuples are invalid; forward to the element's type (diagnosed elsewhere)
  //     guard
  //       let soleTupleElement = tupleType.elements.first,
  //       tupleType.elements.count == 1
  //     else {
  //       fatalError(
  //         "[SwiftLexicalLookup] Internal error: Tuple type unexpectedly has \(tupleType.elements.count) elements, a condition which should have been handled in a previous case."
  //       )
  //     }
  //     // Forward resolution
  //     soleTupleElement.type.partiallyResolve(types: &types, failures: &failures)
  //   case .compositionType(let compositionType):
  //     // Add all types and failures from composition types
  //     for compositionType in compositionType.elements {
  //       compositionType.type.partiallyResolve(types: &types, failures: &failures)
  //     }
  //   }
  // }

  @_spi(_QualifiedLoookup)
  public func partiallyResolve() -> MemberLookupResult<
    Result<PartiallyResolvedTypeIdentifier, LocalizedTypeResolutionFailure>
  > {
    switch TypeSyntax(self).as(TypeSyntaxEnum.self) {
    // Non-nominal base cases
    //
    // Functions
    case .functionType(let functionType):
      return .function(argumentCount: functionType.parameters.count)
    // Valid tuples (we treat single-element tuples as their only contained type below)
    case .tupleType(let tupleType) where tupleType.elements.count >= 1:
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
      return .tuple(labels: labels)

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
        return .memberResults([
          .failure(
            LocalizedTypeResolutionFailure(
              failures: [TypeSyntax(identifierType): .wildcardType]
            )
          )
        ])
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
        return .memberResults([])
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
      switch _parseModuleAndIdentifier(moduleNameToken: moduleNameToken, nameToken: nameToken) {
      case .success(let newComponent):
        // Add nominal type
        return .memberResults([
          Result.success(
            PartiallyResolvedTypeIdentifier(base: newComponent)
          )
        ])
      case .failure(let failure):
        return .memberResults([
          Result.failure(
            LocalizedTypeResolutionFailure(
              failures: [TypeSyntax(identifierType): failure]
            )
          )
        ])
      }
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
      let baseTypes = memberType.baseType.partiallyResolve()

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
      switch _parseModuleAndIdentifier(moduleNameToken: moduleNameToken, nameToken: nameToken) {
      case .success(let newComponent):
        // Try to add
        switch baseTypes {
        // Functions/tuples don't have type memebrs
        case .function:
          return .memberResults([
            Result.failure(
              LocalizedTypeResolutionFailure(failures: [
                TypeSyntax(memberType): .mergeError(MemberLookupResultMergeFailure.functionHasNoTypeMembers)
              ])
            )
          ])
        case .tuple:
          return .memberResults([
            Result.failure(
              LocalizedTypeResolutionFailure(failures: [
                TypeSyntax(memberType): .mergeError(MemberLookupResultMergeFailure.tupleHasNoTypeMembers)
              ])
            )
          ])
        // Append the new component
        case .memberResults(let baseTypeResults):
          return .memberResults(
            baseTypeResults.map({ baseTypeResult in
              baseTypeResult.map({ baseType in baseType.addingComponents([newComponent]) })
            })
          )
        }
      case .failure(let failure):
        // Add failure
        return baseTypes.mapMembers({ baseTypeResult in
          // Get base failures
          var failures: [TypeSyntax: TypeResolutionFailure]
          switch baseTypeResult {
          case .success(_): failures = [:]
          case .failure(let baseFailures): failures = baseFailures.failures
          }

          // Combine with this failure
          failures[TypeSyntax(memberType)] = failure

          return Result.failure(LocalizedTypeResolutionFailure(failures: failures))
        })
      }
    // Base cases that don't produce types
    case .metatypeType, .namedOpaqueReturnType:
      return .memberResults([])
    case .suppressedType(let suppressedType):
      // Check the suppressed type is known (but don't add to a resolved type)
      guard
        let identifierType = suppressedType.type.as(IdentifierTypeSyntax.self),
        let typeName = Identifier(validating: identifierType.name),
        PartiallyResolvedType._knownSuppressibleTypes.contains(typeName)
      else {
        return .memberResults([
          Result.failure(
            LocalizedTypeResolutionFailure(
              failures: [TypeSyntax(suppressedType): .unknownSuppressedType]
            )
          )
        ])
      }
      return .memberResults([])

    // Invalid base case
    case .missingType(let missingType):
      return .memberResults([
        Result.failure(
          LocalizedTypeResolutionFailure(
            failures: [TypeSyntax(missingType): .missingType]
          )
        )
      ])

    // Type-sugar is a nominal-type base case
    case .optionalType, .implicitlyUnwrappedOptionalType:
      return MemberLookupResult.memberResults([Result.success(._optionalType)])
    case .arrayType:
      return MemberLookupResult.memberResults([Result.success(._arrayType)])
    case .inlineArrayType:
      return MemberLookupResult.memberResults([Result.success(._inlineArrayType)])
    case .dictionaryType:
      return MemberLookupResult.memberResults([Result.success(._dictionaryType)])

    // Recursive cases
    case .attributedType(let attributedType):
      return attributedType.partiallyResolve()
    case .someOrAnyType(let someOrAnyTypeType):
      return someOrAnyTypeType.partiallyResolve()
    case .classRestrictionType(let classRestrictionType):
      return classRestrictionType.partiallyResolve()
    // TODO: Explain pack element & expansion types
    case .packElementType(let packElementType):
      return packElementType.partiallyResolve()
    case .packExpansionType(let packExpansionType):
      return packExpansionType.partiallyResolve()
    case .tupleType(let tupleType) /* where tupleType.elements.count == 1 */:
      // Single-element tuples are invalid; forward to the element's type (diagnosed elsewhere)
      guard
        let soleTupleElement = tupleType.elements.first,
        tupleType.elements.count == 1
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Tuple type unexpectedly has \(tupleType.elements.count) elements, a condition which should have been handled in a previous case."
        )
      }
      // Forward resolution
      return soleTupleElement.type.partiallyResolve()
    case .compositionType(let compositionType):
      // Add all types and failures from composition types
      let flattenedResults = compositionType.elements.flatMap({
        compositionElement -> [Result<PartiallyResolvedTypeIdentifier, LocalizedTypeResolutionFailure>] in
        let baseType = compositionType.partiallyResolve()
        switch baseType {
        // Can't compose functions/tuples
        case .function:
          return [
            Result.failure(
              LocalizedTypeResolutionFailure(
                failures: [
                  TypeSyntax(compositionType): .mergeError(MemberLookupResultMergeFailure.cannotComposeFunction)
                ]
              )
            )
          ]
        case .tuple:
          return [
            Result.failure(
              LocalizedTypeResolutionFailure(
                failures: [
                  TypeSyntax(compositionType): .mergeError(MemberLookupResultMergeFailure.cannotComposeTuple)
                ]
              )
            )
          ]
        // Return base member types
        case .memberResults(let results):
          return results
        }
      })
      return MemberLookupResult.memberResults(flattenedResults)
    }
  }
}
