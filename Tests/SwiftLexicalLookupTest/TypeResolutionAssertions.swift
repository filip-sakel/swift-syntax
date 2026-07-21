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

import SwiftIfConfig
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) @_spi(Experimental) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

/// Asserts the given annotated `TypeSyntax` resolves to the right `NominalTypeDeclSyntax`
/// and qualified name. Also asserts `ExtensionDeclSyntax`-binding produces the expected
/// `ExtensionBindingState`.
/// and `ExtensionDeclSyntax`
struct TypeResolutionMatcher {
  /// A marker and the resolved qualified name of the annotated `NominalTypeDeclSyntax`.
  struct Reference {
    let marker: Character
    let name: String
  }
  /// Annotates `TypeSyntax` with a type-resolution result using markers;
  /// also annotates `ExtensionDeclSyntax` with the desired `ExtensionBindingState`.
  enum Expectation {
    case syntaxResolution(Result<MemberLookupResult<Character>, TypeQualifierFailure<Character, Character>>)
    case extensionBinding(GenericExtensionState<String>)
  }

  let symbolTable: SymbolTable3
  let moduleName: Identifier
  let lookupFiles: [(String, SourceFileSyntax)]
}

// MARK: `Reference` Conformances

extension TypeResolutionMatcher.Reference: LexicalAnnotation, Identifiable, CustomStringConvertible {
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

  var description: String { name }
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
  func describeExpectationSyntax(_ syntax: TypeSyntaxOrExtension) -> String {
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
      return extensionDecl._memberlessDescription
    } else if let typeSyntax = syntax.as(TypeSyntax.self) {
      return typeSyntax.trimmedDescription
    } else {
      fatalError(
        "[SwiftLexicalLookup] Internal test error: Expected TypeSyntaxOrExtension to be either an ExtensionDeclSyntax or TypeSyntax."
      )
    }
  }

  func assertExpectation(
    expectation: ContextualizedAnnotation<Expectation>,
    markersToReferences: [Character: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [NominalTypeDeclSyntax: ContextualizedAnnotation<Reference>],
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
        typeSyntax: typeSyntax,
        expectedResult: expectedResult,
        markersToReferences: markersToReferences,
        syntaxToReferences: syntaxToReferences,
        verbose: verbose
      )
    case .extensionBinding(let expectedState):
      guard let extensionDecl = expectation.syntax.as(ExtensionDeclSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal test error: Expected syntax-resolution queries to find 'ExtensionDeclSyntax' nodes, but got '\(expectation.syntax.kind)'."
        )
      }

      return _assertExtensionBinding(
        extensionDecl: extensionDecl,
        expectedState: expectedState,
        verbose: verbose
      )
    }
  }

  /// Helper for converting a qualified type name to a string description
  private func _describeQualifiedName(_ name: QualifiedTypeName) -> String {
    name._describe(describeFileID: { fileID in
      // Get name of first matching id
      for (fileName, file) in lookupFiles {
        guard file.id == fileID else { continue }
        return fileName
      }
      return fileID.hashValue.description
    })
  }

  /// `assertExpectation` forwards extensions here.
  private func _assertExtensionBinding(
    extensionDecl: ExtensionDeclSyntax,
    expectedState: GenericExtensionState<String>,
    verbose: Bool
  ) -> [ExpectationFailure] {
    // Look up extended type if not already resolved
    let actualState: ExtensionState
    // Try to get already-resolved state
    if let existingState = symbolTable.dependencyGraph.extensionsToState[extensionDecl] {
      actualState = existingState
    } else {
      if verbose {
        print("Extension `\(extensionDecl._memberlessDescription)` not already bound; initating binding.")
      }

      // Evaluate the extended type
      var typeQualifier = TypeQualifier(symbolTable: symbolTable, _verbose: verbose)
      var memberDependencies = DependencyTracker()
      let lookupResult: Result<ResolvedNominalTypeReference, TypeQualifier.Failure> =
        typeQualifier.resolveExtendedTypeSyntax(
          extensionDecl: extensionDecl,
          memberDependencies: &memberDependencies
        )

      // Diagnose type-resolution failures
      let nominalReference: ResolvedNominalTypeReference
      switch lookupResult {
      case .success(let success):
        nominalReference = success
      case .failure(let failure):
        return [
          ExpectationFailure.other(
            failure:
              "Invalid extended type: Couldn't resolve extended type for given extension: \(failure.debugDescription)"
          )
        ]
      }

      // Trigger binding and ensure we have a state
      _ = typeQualifier.resolveNominalType(typeReference: nominalReference)
      guard let producedState = symbolTable.dependencyGraph.extensionsToState[extensionDecl] else {
        let availableExtensions = symbolTable.dependencyGraph.extensionsToState.keys.map(\._memberlessDescription)
        return [
          ExpectationFailure.other(
            failure:
              "No extension state: Couldn't find extension state even after nominal-type resolution; available extensions are: \(availableExtensions)",
          )
        ]
      }

      actualState = producedState
    }

    // We use strings for the expected qualified name; just print that name
    let expectedStateDescription = expectedState._describe(describeTypeName: \.self)
    let actualStateDescription = actualState._describe(describeTypeName: _describeQualifiedName(_:))
    guard expectedStateDescription == actualStateDescription else {
      return [
        ExpectationFailure.other(
          failure: "Extension-state mismatch.\nExpected: \(expectedStateDescription)\nGot: \(actualStateDescription)"
        )
      ]
    }
    return []
  }

  /// `assertExpectation` forwards type syntax here.
  private func _assertTypeSyntax(
    typeSyntax: TypeSyntax,
    expectedResult: Result<MemberLookupResult<Character>, TypeQualifierFailure<Character, Character>>,
    markersToReferences: [Character: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [NominalTypeDeclSyntax: ContextualizedAnnotation<Reference>],
    verbose: Bool,
  ) -> [ExpectationFailure] {
    // Print target syntax (to show the syntax kinds)
    if verbose {
      print("Target syntax parsed as:\n\(typeSyntax.debugDescription)\n")
    }

    // Perform the lookup to get the `actualResult` (as opposed to `expectedResult`)
    var typeQualifier = TypeQualifier(symbolTable: symbolTable, _verbose: verbose)
    let actualResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, TypeQualifier.Failure>
    do {
      var memberDependencies = DependencyTracker()
      actualResult = typeQualifier.resolveSyntax(
        typeSyntax: typeSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: []
      )
    }

    // Assert output
    var failures = [ExpectationFailure]()
    switch (expectedResult, actualResult) {
    case (.success(.memberResults(let markers)), .success(.memberResults(let nominalTypes))):
      // Find the referenced markers
      let expectations: [ContextualizedAnnotation<Reference>] = markers.compactMap({ marker in
        guard let targetReference = markersToReferences[marker] else {
          failures.append(ExpectationFailure.referencesUndefinedMarker(marker))
          return nil
        }
        return targetReference
      })

      let results: [ContextualizedAnnotation<Reference>] = nominalTypes.compactMap({ nominalType in
        guard let targetReference = syntaxToReferences[nominalType.mainDecl] else {
          failures.append(
            ExpectationFailure.resultReferencesUnmarkedSyntax(
              syntaxDescription: nominalType.qualifiedName.debugDescription
            )
          )
          return nil
        }
        return targetReference
      })

      // Don't continue if markers are undefined
      guard !failures.isEmpty else { break }

      // Diff if markers check out
      LexicalAssertionUtilities.diffLexicalResults(expected: expectations, actual: results, failures: &failures)
    case (.success(let expectedLookupResult), .success(let actualLookupResult)):
      // We handled members above, so map to `Bool` to facilitate the comparison.
      if expectedLookupResult.mapMembers({ _ in false }) != actualLookupResult.mapMembers({ _ in false }) {
        failures.append(
          ExpectationFailure.other(
            failure:
              "Resolved-type mismatch. Expected: \(expectedLookupResult)\nGot: \(actualLookupResult)"
          )
        )
      }
    case (.failure(let expectedFailure), .failure(let actualFailure)):
      // Describe the expected failure
      func markerToQualifiedName(marker: Character) -> String {
        guard let nominalDecl = markersToReferences[marker] else {
          failures.append(ExpectationFailure.referencesUndefinedMarker(marker))
          return "_"
        }
        return nominalDecl.annotation.name
      }
      let expectedFailureDescription = expectedFailure._describeDebug(
        resolveMininalNominal: markerToQualifiedName,
        resolveExtendedNominal: markerToQualifiedName
      )

      // Describe the lookup failure
      let actualFailureDescription = actualFailure._describeDebug(
        resolveMininalNominal: { _describeQualifiedName($0.qualifiedName) },
        resolveExtendedNominal: { _describeQualifiedName($0.qualifiedName) }
      )

      // Check equality
      if expectedFailureDescription != actualFailureDescription {
        failures.append(
          ExpectationFailure.other(
            failure: "Failure mismatch. Expected: '\(expectedFailureDescription)'. Got: '\(actualFailureDescription)'"
          )
        )
      }
    default:
      failures.append(
        ExpectationFailure.other(
          failure:
            "Lookup didn't succeed/fail as expected. Expected '\(expectedResult)'. Got: '\(actualResult)'"
        )
      )
    }
    return failures
  }
}

// MARK: Assert Function

func assertTypeResolution(
  _ lookupSources: KeyValuePairs<String, LexicalLookupSource<TypeResolutionMatcher>>,
  moduleName: StaticString = "MyModule",
  configuredRegions: ConfiguredRegions? = nil,
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
      symbolTable: SymbolTable3(
        moduleToSources: [moduleIdentifier: uniquedLookupFiles],
        configuredRegions: configuredRegions
      ),
      moduleName: moduleIdentifier,
      lookupFiles: lookupFiles
    ),
    file: file,
    line: line
  )
}

// MARK: String-Interpolation Helpers

extension LexicalLookupSource.Interpolation where Matcher == TypeResolutionMatcher {
  mutating func appendInterpolation(
    _ marker: Character,
    name: String,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    append(reference: TypeResolutionMatcher.Reference(marker: marker, name: name), file: file, line: line)
  }
  mutating func appendInterpolation(
    extensionState: GenericExtensionState<String>,
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
    result: Result<MemberLookupResult<Character>, TypeQualifierFailure<Character, Character>>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(expects: [TypeResolutionMatcher.Expectation.syntaxResolution(result)], file: file, line: line)
  }
  mutating func appendInterpolation(
    failure: TypeQualifierFailure<Character, Character>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(result: Result.failure(failure), file: file, line: line)
  }
  mutating func appendInterpolation(
    type: MemberLookupResult<Character>,
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
    appendInterpolation(type: MemberLookupResult.memberResults(markers), file: file, line: line)
  }
  mutating func appendInterpolation(
    nominal marker: Character,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(nominals: [marker], file: file, line: line)
  }
}
