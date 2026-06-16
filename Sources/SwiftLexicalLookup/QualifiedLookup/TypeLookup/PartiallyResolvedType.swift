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

@_spi(_QualifiedLoookup) public enum TypeResolutionFailure: Error {
  /// Missing types produce errors
  case missingType(MissingTypeSyntax)
  /// Invalid identifiers produce errors
  case invalidIdentifier(TokenSyntax)
  /// We report unknown supressed types, e.g., `~CustomStringConvertible`
  case unknownSuppressedType(TypeSyntax)
}

extension TypeSyntaxProtocol {
  // TODO: Handle `.Self`, `.Type`, `.Protocol`, etc. (check compiler)
  @_spi(_QualifiedLoookup) public func partiallyResolve(
    types: inout [PartiallyResolvedType],
    failures: inout [TypeResolutionFailure]
  ) {
    switch TypeSyntax(self).as(TypeSyntaxEnum.self) {
    // Non-nominal base cases
    //
    // Functions
    case .functionType(let functionType):
      return types.append(.function(argumentCount: functionType.parameters.count))
    // Valid tuples (we treat single-element tuples as their only contained type below)
    case .tupleType(let tupleType) where tupleType.elements.count >= 1:
      // Get labels and collect identifier errors
      let labels: [Identifier?] = tupleType.elements.map({
        // Tuple elements might not have labels
        guard let labelToken = $0.firstName else { return nil }
        // Ensure label is valid (if not, report error and skip label)
        guard let label = Identifier(validating: labelToken) else {
          failures.append(.invalidIdentifier(labelToken))
          return nil
        }
        return label
      })
      // Add tuple type
      return types.append(.tuple(labels: labels))

    // Nominal base cases
    case .identifierType(let identifierType):
      // Parse module name if provided; fail if invalid.
      //
      // We give up if the module is invalid because we'll likely find bad types.
      let moduleName: Identifier?
      if let moduleSelector = identifierType.moduleSelector {
        guard let moduleIdentifier = Identifier(validating: moduleSelector.moduleName) else {
          failures.append(.invalidIdentifier(moduleSelector.moduleName))
          return
        }
        moduleName = moduleIdentifier
      } else {
        moduleName = nil
      }

      // Parse type name; fail if invalid
      guard let typeName = Identifier(validating: identifierType.name) else {
        failures.append(.invalidIdentifier(identifierType.name))
        return
      }

      // Add nominal type
      types.append(.nominalIdentifier(module: moduleName, name: typeName))
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
      var baseTypes = [PartiallyResolvedType]()
      memberType.baseType.partiallyResolve(types: &baseTypes, failures: &failures)

      // Parse module name if provided; fail if invalid.
      //
      // We give up if the module is invalid because we'll likely find bad types.
      let moduleName: Identifier?
      if let moduleSelector = memberType.moduleSelector {
        // Fail if invalid.
        guard let moduleIdentifier = Identifier(validating: moduleSelector.moduleName) else {
          failures.append(.invalidIdentifier(moduleSelector.moduleName))
          return
        }
        moduleName = moduleIdentifier
      } else {
        moduleName = nil
      }

      // Parse type name; fail if invalid
      guard let typeName = Identifier(validating: memberType.name) else {
        failures.append(.invalidIdentifier(memberType.name))
        return
      }

      // Add nominal type
      types.append(.nominalMember(bases: baseTypes, module: moduleName, name: typeName))

    // Base cases that don't produce types
    case .metatypeType, .namedOpaqueReturnType:
      break
    case .suppressedType(let suppressedType):
      // Check the suppressed type is known (but don't add to a resolved type)
      guard
        let identifierType = suppressedType.type.as(IdentifierTypeSyntax.self),
        let typeName = Identifier(validating: identifierType.name),
        PartiallyResolvedType._knownSuppressibleTypes.contains(typeName)
      else {
        failures.append(.unknownSuppressedType(suppressedType.type))
        return
      }

    // Invalid base case
    case .missingType(let missingType):
      failures.append(.missingType(missingType))

    // Type-sugar is a nominal-type base case
    case .optionalType, .implicitlyUnwrappedOptionalType:
      types.append(._optionalType)
    case .arrayType:
      types.append(._arrayType)
    case .inlineArrayType:
      types.append(._inlineArrayType)
    case .dictionaryType:
      types.append(._dictionaryType)

    // Recursive cases
    case .attributedType(let attributedType):
      attributedType.partiallyResolve(types: &types, failures: &failures)
    case .someOrAnyType(let someOrAnyTypeType):
      someOrAnyTypeType.partiallyResolve(types: &types, failures: &failures)
    case .classRestrictionType(let classRestrictionType):
      classRestrictionType.partiallyResolve(types: &types, failures: &failures)
    // TODO: Explain pack element & expansion types
    case .packElementType(let packElementType):
      packElementType.partiallyResolve(types: &types, failures: &failures)
    case .packExpansionType(let packExpansionType):
      packExpansionType.partiallyResolve(types: &types, failures: &failures)
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
      soleTupleElement.type.partiallyResolve(types: &types, failures: &failures)
    case .compositionType(let compositionType):
      // Add all types and failures from composition types
      for compositionType in compositionType.elements {
        compositionType.type.partiallyResolve(types: &types, failures: &failures)
      }
    }
  }
}
