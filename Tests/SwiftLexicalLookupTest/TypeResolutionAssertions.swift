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

import RegexBuilder
import SwiftIfConfig
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

typealias TestExtensionState = GenericExtensionState<Character>
typealias TestTypeResolutionFailure = TypeResolver.TestFailure

/// Asserts the given annotated `TypeSyntax` resolves to the right `NominalTypeDeclSyntax`
/// and qualified name. Also asserts `ExtensionDeclSyntax`-binding produces the expected
/// `ExtensionBindingState`.
/// and `ExtensionDeclSyntax`
struct TypeResolutionMatcher {
  /// A marker and the resolved qualified name of the annotated `NominalTypeDeclSyntax`.
  struct Definition {
    let marker: Character
    let name: TypeGraph.GlobalTypeName?
  }
  /// Annotates `TypeSyntax` with a type-resolution result using markers;
  /// also annotates `ExtensionDeclSyntax` with the desired `ExtensionBindingState`.
  enum Expectation {
    case syntaxResolution(
      Result<ResolvedType<Character>, TestTypeResolutionFailure>
    )
    case extensionBinding(TestExtensionState)
  }

  let symbolTable: SymbolTable
  let moduleName: Identifier
  let lookupFiles: [(String, SourceFileSyntax)]
}

// MARK: `Definition` Conformances

extension TypeResolutionMatcher.Definition: LexicalAnnotation, Identifiable, CustomStringConvertible {
  typealias SyntaxReference = NominalTypeDeclSyntax
  func findSyntaxFromToken(
    _ token: SwiftSyntax.TokenSyntax,
    verbose: Bool,
    file: StaticString,
    line: UInt
  ) -> NominalTypeDeclSyntax? {
    LexicalAssertionUtilities.findDirectParent(from: token, ofType: NominalTypeDeclSyntax.self, file: file, line: line)
  }

  var id: Character { marker }

  // Use the name for a more familiar description,
  // or the marker (if we don't care about the name
  // and for local declarations.)
  var description: String {
    name?.debugDescription ?? marker.description
  }
}

// MARK: `Expectation` Conformances

/// Either `TypeSyntax` or `ExtensionDeclSyntax`. Helper
/// for `TypeResolutionMatcher`
struct TypeSyntaxOrExtension: SyntaxProtocol, SyntaxHashable {
  private(set) var _syntaxNode: Syntax
  init?(_ node: __shared some SyntaxProtocol) {
    guard node.is(TypeSyntax.self) || node.is(ExtensionDeclSyntax.self) else { return nil }
    _syntaxNode = Syntax(node)
  }
  static var structure: SyntaxNodeStructure {
    SyntaxNodeStructure.choices([
      .node(TypeSyntax.self),
      .node(ExtensionDeclSyntax.self),
    ])
  }

  // Always succeeding inits
  init(_ node: __shared some TypeSyntaxProtocol) {
    self = Syntax(node).cast(TypeSyntaxOrExtension.self)
  }
  init(_ node: __shared ExtensionDeclSyntax) {
    self = Syntax(node).cast(TypeSyntaxOrExtension.self)
  }
}

extension TypeResolutionMatcher.Expectation: LexicalAnnotation {
  typealias SyntaxReference = TypeSyntaxOrExtension

  /// Find the head type-syntax (because for instance `any Encodable & Decodable`
  /// contains the `Encodable & Decodable` nested type syntax)
  private func _findHeadTypeSyntax(of typeSyntax: TypeSyntax) -> TypeSyntax {
    // Cast the parent to type syntax, or return current type syntax
    //
    // Check for special-cases first (e.g., compositions)
    if typeSyntax.parent?.is(CompositionTypeElementSyntax.self) == true,
      let compositionSyntax = typeSyntax.parent?.parent?.parent?.as(CompositionTypeSyntax.self)
    {
      return _findHeadTypeSyntax(of: TypeSyntax(compositionSyntax))
    }
    // General case
    guard let parentTypeSyntax = typeSyntax.parent?.as(TypeSyntax.self) else { return typeSyntax }
    // Find parent's head type syntax
    return _findHeadTypeSyntax(of: parentTypeSyntax)
  }

  func findSyntaxFromToken(
    _ token: TokenSyntax,
    verbose: Bool,
    file: StaticString,
    line: UInt
  ) -> TypeSyntaxOrExtension? {
    switch self {
    case .extensionBinding:
      // Extensions should be annotated before 'extension' and the direct token
      // parent should be ExtensionDeclSyntax
      return LexicalAssertionUtilities.findDirectParent(
        from: token,
        ofType: ExtensionDeclSyntax.self,
        file: file,
        line: line,
        annotationKindDescription: "extension-binding"
      ).map(TypeSyntaxOrExtension.init(_:))
    case .syntaxResolution:
      // Ensure the token's parent is a type syntax
      guard let baseTypeSyntax = token.parent?.as(TypeSyntax.self) else {
        XCTFail(
          "Invalid type-syntax expectation placement: A qualified-name expectation should be placed right before the target type syntax (parent is '\(String(reflecting: token.parent?.kind))').",
          file: file,
          line: line
        )
        return nil
      }

      let typeSyntax = _findHeadTypeSyntax(of: baseTypeSyntax)

      return TypeSyntaxOrExtension(typeSyntax)
    }
  }
}

// MARK: `LexicalMatcher` Conformance

extension TypeResolutionMatcher: LexicalMatcher {
  func describeContextualizedExpectation(_ expectation: ContextualizedAnnotation<Expectation>) -> String {
    if let extensionDecl = expectation.syntax.as(ExtensionDeclSyntax.self) {
      return extensionDecl._memberlessDescription
    } else if let typeSyntax = expectation.syntax.as(TypeSyntax.self) {
      return typeSyntax.trimmedDescription
    } else {
      fatalError(
        "[SwiftLexicalLookup] Internal test error: Expected TypeSyntaxOrExtension to be either an ExtensionDeclSyntax or TypeSyntax."
      )
    }
  }

  func assertExpectation(
    expectation: ContextualizedAnnotation<Expectation>,
    markersToDefinitions: [Character: ContextualizedAnnotation<Definition>],
    syntaxToDefinitions: [NominalTypeDeclSyntax: ContextualizedAnnotation<Definition>],
    verbose: Bool
  ) -> [ExpectationFailure] {
    switch expectation.annotation {
    case .syntaxResolution(let expectedResult):
      guard let typeSyntax = expectation.syntax.as(TypeSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal test error: Expected syntax-resolution queries to find 'TypeSyntax' nodes, but got '\(expectation.syntax.kind)'."
        )
      }

      return _assertTypeSyntax(
        // Force unwrap because we parsed this from `lookupSources`
        typeSyntax: Attached(typeSyntax)!,
        expectedRawResult: expectedResult,
        markersToDefinitions: markersToDefinitions,
        syntaxToDefinitions: syntaxToDefinitions,
        verbose: verbose
      )
    case .extensionBinding(let expectedState):
      guard let extensionDecl = expectation.syntax.as(ExtensionDeclSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal test error: Expected syntax-resolution queries to find 'ExtensionDeclSyntax' nodes, but got '\(expectation.syntax.kind)'."
        )
      }

      return _assertExtensionBinding(
        // Force unwrap because we parsed this from `lookupSources`
        extensionDecl: Attached(extensionDecl)!,
        expectedRawState: expectedState,
        markersToDefinitions: markersToDefinitions,
        syntaxToDefinitions: syntaxToDefinitions,
        verbose: verbose
      )
    }
  }

  /// `assertExpectation` forwards extensions here.
  private func _assertExtensionBinding(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    expectedRawState: TestExtensionState,
    markersToDefinitions: [Character: ContextualizedAnnotation<Definition>],
    syntaxToDefinitions: [NominalTypeDeclSyntax: ContextualizedAnnotation<Definition>],
    verbose: Bool
  ) -> [ExpectationFailure] {
    // Look up extended type if not already resolved
    let actualRawState: ExtensionState
    // Try to get already-resolved state
    if let existingState = symbolTable.typeGraph.extensionsToState[extensionDecl] {
      actualRawState = existingState
    } else {
      if verbose {
        print("Extension `\(extensionDecl.node._memberlessDescription)` not already bound; initating binding.")
      }

      // Evaluate the extended type
      var typeQualifier = TypeResolver(symbolTable: symbolTable, _verbose: verbose)
      let _: Result<GenericResolvedTypeSyntax<TypeGraph.GlobalNominalTypeRef>, TypeResolver.Failure> =
        typeQualifier.bindExtension(extensionDecl)

      // After binding, we should we have a state
      guard let producedState = symbolTable.typeGraph.extensionsToState[extensionDecl] else {
        let availableExtensions = symbolTable.typeGraph.extensionsToState.keys.map(\.node._memberlessDescription)
        return [
          ExpectationFailure.other(
            failure:
              "No extension state: Couldn't find extension state even after nominal-type resolution; available extensions are: \(availableExtensions)",
          )
        ]
      }

      actualRawState = producedState
    }

    // Map the types
    var mappingFailures = [ExpectationFailure]()
    /// Helper for mapping the expected state
    let expectedState = expectedRawState._mapTypes(mapNominal: { marker -> String in
      guard let targetDefinition = markersToDefinitions[marker] else {
        mappingFailures.append(ExpectationFailure.referencesUndefinedMarker(marker))
        return ""
      }
      guard let expectedName = targetDefinition.annotation.name else {
        mappingFailures.append(
          ExpectationFailure.other(
            failure:
              "Must specify 'name' argument in annotation '\(targetDefinition.annotation.marker)' for declaration '\(targetDefinition.syntax.trimmedDescription)'."
          )
        )
        return ""
      }
      return expectedName.debugDescription
    })
    // Get the type name
    let actualState = actualRawState._mapTypes(mapNominal: \.type._succinctDescription)
    // Don't continue if we couldn't map the states
    guard mappingFailures.isEmpty else { return mappingFailures }

    // We use strings for the expected qualified name; just print that name
    let expectedStateDescription = expectedState.debugDescription
    let actualStateDescription = actualState.debugDescription
    guard expectedStateDescription == actualStateDescription else {
      return [
        ExpectationFailure.other(
          failure:
            "Extension-state mismatch.\nExpected: \(expectedStateDescription)\nBut got:  \(actualStateDescription)"
        )
      ]
    }
    return []
  }

  /// `assertExpectation` forwards type syntax here.
  private func _assertTypeSyntax(
    typeSyntax: Attached<TypeSyntax>,
    expectedRawResult: Result<ResolvedType<Character>, TestTypeResolutionFailure>,
    markersToDefinitions: [Character: ContextualizedAnnotation<Definition>],
    syntaxToDefinitions: [NominalTypeDeclSyntax: ContextualizedAnnotation<Definition>],
    verbose: Bool,
  ) -> [ExpectationFailure] {
    // Print target syntax (to show the syntax kinds)
    if verbose {
      print("Target syntax parsed as:\n\(typeSyntax.node.debugDescription)\n")
    }

    // Perform the lookup to get the `actualResult` (as opposed to `expectedResult`)
    let actualRawResult: TypeResolver.TypeResult<ResolvedType<ResolvedTypeSyntax>> = symbolTable.resolveSyntax(
      typeSyntax: typeSyntax
    )

    // Assert output
    var failures = [ExpectationFailure]()
    switch (expectedRawResult, actualRawResult) {
    case (.success(let expectedType), .success(let actualType)):
      let actualTypeDescription: String = actualType.mapNominals({ nominalType -> String in
        guard let targetDefinition = syntaxToDefinitions[nominalType.type.mainDecl.node] else {
          failures.append(
            ExpectationFailure.resultReferencesUnmarkedSyntax(
              syntaxDescription: nominalType.type.globalName.debugDescription
            )
          )
          return ""
        }
        // Ensure we got the right name
        let actualName = nominalType.type.globalName?.debugDescription
        if let expectedName = targetDefinition.annotation.name?.debugDescription, actualName != expectedName {
          failures.append(
            ExpectationFailure.other(
              failure:
                "Expected name '\(expectedName)' for type marked '\(targetDefinition.annotation.marker)' but got '\(actualName?.debugDescription ?? "nil")'."
            )
          )
          return ""
        }

        return targetDefinition.annotation.description
      })._debugDescription

      let expectedTypeDescription: String = expectedType.mapNominals({ marker -> String in
        guard let targetDefinition = markersToDefinitions[marker] else {
          failures.append(ExpectationFailure.referencesUndefinedMarker(marker))
          return ""
        }
        return targetDefinition.annotation.description
      })._debugDescription

      // Give up if markers are undefined (i.e. we already have failures)
      guard failures.isEmpty else { break }

      if expectedTypeDescription != actualTypeDescription {
        failures.append(
          ExpectationFailure.other(
            failure:
              "Resolved-type mismatch. Expected: \(expectedTypeDescription)\nBut got:  \(actualTypeDescription)"
          )
        )
      }

    case (.failure(let expectedFailure), .failure(let actualFailure)):
      // Describe the expected failure
      func markerToQualifiedName(marker: Character) -> String {
        guard let nominalDecl = markersToDefinitions[marker] else {
          failures.append(ExpectationFailure.referencesUndefinedMarker(marker))
          return "_"
        }
        return nominalDecl.annotation.description
      }
      let expectedFailureDescription = expectedFailure._map(
        mapNominal: markerToQualifiedName(marker:)
      )._debugDescription

      // Describe the lookup failure
      let actualFailureDescription = actualFailure._map(
        mapNominal: { $0.type.globalName?.debugDescription ?? "" }
      )._debugDescription

      // Check equality
      if expectedFailureDescription != actualFailureDescription {
        failures.append(
          ExpectationFailure.other(
            failure:
              "Failure mismatch.\nExpected: '\(expectedFailureDescription)'.\nBut got:  '\(actualFailureDescription)'"
          )
        )
      }
    default:
      failures.append(
        ExpectationFailure.other(
          failure:
            "Lookup didn't succeed/fail as expected. Expected '\(expectedRawResult)'. Got: '\(actualRawResult)'"
        )
      )
    }
    return failures
  }
}

// MARK: Assert Function

/// Creates assertions for type resolution
///
/// Note that we don't guarantee that extension binding will
/// happen in a specific order. If name lookup works properly,
/// this arbitrary order may only impact performance. However,
/// when debugging tests, you can place `\(extensionState: ...)`
/// to the first extension you want to bind. After that, it's still
/// up to the dependency graph to decide which extension goes next.
func assertTypeResolution(
  _ lookupSources: KeyValuePairs<String, LexicalLookupSource<TypeResolutionMatcher>>,
  moduleName: StaticString = "MyModule",
  buildConfiguration: StaticBuildConfiguration? = nil,
  file: StaticString = #file,
  line: UInt = #line,
  verbose: Bool = false
) {
  // Convert data formats
  let moduleIdentifier = Identifier(canonicalName: moduleName)
  // Map files to name & file syntax
  let lookupFiles: [(String, SourceFileSyntax)] = lookupSources.map({ fileName, lookupSource in
    (fileName, lookupSource.fileSyntax)
  })
  // Test cases should give us unique file names
  let uniquedLookupFiles = Dictionary(uniqueKeysWithValues: lookupFiles)

  _assertLexicalLookup(
    lookupSources,
    matcher: TypeResolutionMatcher(
      symbolTable: SymbolTable(
        moduleName: moduleIdentifier,
        moduleToSources: [moduleIdentifier: uniquedLookupFiles],
        buildConfiguration: buildConfiguration
      )!,
      moduleName: moduleIdentifier,
      lookupFiles: lookupFiles
    ),
    file: file,
    line: line,
    verbose: verbose
  )
}

// MARK: String-Interpolation Helpers

extension LexicalLookupSource.Interpolation where Matcher == TypeResolutionMatcher {
  mutating func appendInterpolation(
    _ marker: Character,
    name: TypeGraph.GlobalTypeName? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    append(definition: TypeResolutionMatcher.Definition(marker: marker, name: name), file: file, line: line)
  }
  mutating func appendInterpolation(
    extensionState: TestExtensionState,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(
      expects: [TypeResolutionMatcher.Expectation.extensionBinding(extensionState)],
      file: file,
      line: line
    )
  }
  mutating func appendInterpolation(
    result: Result<ResolvedType<Character>, TestTypeResolutionFailure>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(expects: [TypeResolutionMatcher.Expectation.syntaxResolution(result)], file: file, line: line)
  }
  mutating func appendInterpolation(
    failure: TestTypeResolutionFailure,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(result: Result.failure(failure), file: file, line: line)
  }
  mutating func appendInterpolation(
    type: ResolvedType<Character>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(result: Result.success(type), file: file, line: line)
  }
  mutating func appendInterpolation(
    nominals markers: [Character],
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(type: ResolvedType.nominalTypes(markers), file: file, line: line)
  }
  mutating func appendInterpolation(
    nominal marker: Character,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(nominals: [marker], file: file, line: line)
  }
}

// MARK: Convenience Initializers

extension TypeLikeSyntax: ExpressibleByStringLiteral {
  public init(stringLiteral value: StringLiteralType) {
    self.init(TypeSyntax(stringLiteral: value))
  }
}

extension ExtensionDependency {
  init(baseType: TypeGraph.GlobalTypeName, members: [IdentifierWrapper]) {
    let mappedMembers: [TypeMember] = members.map({ member in
      return TypeMember(name: member.identifier, decls: [])
    })
    self.init(dependencyTypeName: baseType, members: mappedMembers)
  }
}

struct IdentifierWrapper: ExpressibleByStringLiteral {
  let identifier: Identifier

  init(stringLiteral value: StaticString) {
    identifier = Identifier(canonicalName: value)
  }

  init(
    string: String,
    allocatingIn lookupSourceInterpolation: inout LexicalLookupSource<TypeResolutionMatcher>.Interpolation
  ) {
    identifier = lookupSourceInterpolation.allocateIdentifier(string: string)
  }
}

extension TestExtensionState {
  /// Creates a mock extension state to check an extension's dependencies,
  /// bound type, or failure to bind due to cycles.
  ///
  /// Note: Because `GenericBindingFailure` contains `TypeQualifier.Failure`
  /// (which uses actual `ResolvedNominalTypeReference` and not mock types),
  /// it's hard to test type-resolution failures. You may instead use regular
  /// type-resolution tests and only use this initializer to test extension
  /// binding.
  init(
    dependencies: [ExtensionDependency],
    resolvedType: Result<TypeGraph.GlobalTypeName, TestTypeResolutionFailure>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    // Create fake extension (won't be checked)
    //
    // Wrap the type syntax in a file
    var parser = Parser("extension")
    let sourceFile = SourceFileSyntax.parse(from: &parser)
    let mockExtension = Attached(sourceFile.children(ofType: ExtensionDeclSyntax.self)[0])!

    self.init(
      _uncheckedDependencies: dependencies,
      // Extension decl won't be checked
      extensionDecl: mockExtension,
      resolvedType: resolvedType
    )
  }

  static func bound(
    to typeName: TypeGraph.GlobalTypeName,
    dependencies: [ExtensionDependency]
  ) -> TestExtensionState {
    TestExtensionState(dependencies: dependencies, resolvedType: .success(typeName))
  }

  static func invalidCycle(
    dependencies: [ExtensionDependency],
    cycleElements: [(introducingDecl: String?, extension: String, base: TypeGraph.GlobalTypeName)],
    conflictingMember: IdentifierWrapper,
    file: StaticString = #file,
    line: UInt = #line
  ) -> TestExtensionState {
    let dependencyPath: [GenericDependencyCycleElement<TypeGraph.GlobalTypeName>] = cycleElements.map({
      (
        introducingTypeDeclText,
        extensionDeclText,
        baseTypeName
      ) -> GenericDependencyCycleElement<TypeGraph.GlobalTypeName> in
      let introducingTypeDecl: TypeDeclSyntax?
      if let introducingTypeDeclText {
        let typeDeclRaw = DeclSyntax(stringLiteral: introducingTypeDeclText)
        guard let typeDecl = Syntax(typeDeclRaw).as(TypeDeclSyntax.self) else {
          fatalError(
            "Couldn't cast the cycle element's 'introducingMember' `\(introducingTypeDeclText)` of kind '\(typeDeclRaw.kind)' to TypeDeclSyntax",
            file: file,
            line: line
          )
        }
        introducingTypeDecl = typeDecl
      } else {
        introducingTypeDecl = nil
      }

      let extensionDeclRaw = DeclSyntax(stringLiteral: extensionDeclText)
      guard let extensionDecl = extensionDeclRaw.as(ExtensionDeclSyntax.self) else {
        fatalError(
          "Couldn't cast the cycle element's 'extension' `\(extensionDeclText)` of kind '\(extensionDeclRaw.kind)' to ExtensionDeclSyntax",
          file: file,
          line: line
        )
      }
      return GenericDependencyCycleElement(
        introducingTypeDecl: introducingTypeDecl,
        extensionDecl: extensionDecl,
        boundType: baseTypeName,
      )
    })

    let cycle = GenericExtensionBindingCycle<TypeGraph.GlobalTypeName>(
      dependencyPath: dependencyPath,
      dependencyMember: conflictingMember.identifier
    )

    return TestExtensionState(
      dependencies: dependencies,
      resolvedType: Result.failure(TestTypeResolutionFailure.cyclicalExtensionDependency(cycle))
    )
  }
}

extension TypeGraph.GlobalTypeName: ExpressibleByStringLiteral {
  public init(stringLiteral string: String) {
    self.init(_testName: string)
  }
}
