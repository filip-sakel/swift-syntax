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

@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) @_spi(Experimental) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

protocol LexicalAnnotation {
  associatedtype SyntaxReference: SyntaxProtocol, SyntaxHashable
  func findSyntaxFromToken(_ token: TokenSyntax, verbose: Bool, file: StaticString, line: UInt) -> SyntaxReference?
}

struct ContextualizedAnnotation<Annotation: LexicalAnnotation> {
  let annotation: Annotation
  let syntax: Annotation.SyntaxReference
  let file: StaticString
  let line: UInt
}

protocol LexicalMatcher {
  associatedtype Reference: LexicalAnnotation, Identifiable, CustomStringConvertible
  associatedtype Expectation: LexicalAnnotation
  typealias ExpectationFailure = LexicalMatcherExpectationFailure<Reference>

  /// Asserts the given expectation; returns matched references.
  func assertExpectation(
    expectation: ContextualizedAnnotation<Expectation>,
    markersToReferences: [Reference.ID: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [Reference.SyntaxReference: ContextualizedAnnotation<Reference>],
    verbose: Bool
  ) -> [ExpectationFailure]  //-> Set<Reference.ID>

  func describeExpectationSyntax(_ syntax: Expectation.SyntaxReference) -> String
  // func describeReference(_ reference: ContextualizedAnnotation<Reference>) -> String
}

/// A source file annotated with references and expectations on those references.
///
/// All annotations should be placed before the target token.
struct LexicalLookupSource<Matcher: LexicalMatcher>: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  enum Annotation {
    case reference(reference: Matcher.Reference)
    case expectations(expectations: [Matcher.Expectation])
  }
  enum Component {
    case stringFragment(String)
    case annotation(annotation: Annotation, file: StaticString, line: UInt)
    // case reference(reference: Matcher.Reference, file: StaticString, line: UInt)
    // case expectations(expectations: [Matcher.Expectation], file: StaticString, line: UInt)
  }

  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.stringFragment(literal))
    }
    mutating func appendInterpolation(
      _ reference: Matcher.Reference,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.annotation(annotation: .reference(reference: reference), file: file, line: line))
    }
    mutating func appendInterpolation(
      expects expectations: [Matcher.Expectation],
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.annotation(annotation: .expectations(expectations: expectations), file: file, line: line))
    }
  }

  /// The source with all references/expectations removed
  let source: String
  // /// A list of references and their source index / source location.
  // let references: [(reference: Matcher.Reference, index: String.Index, file: StaticString, line: UInt)]
  // /// A map from positions in the string to the expected result at that location.
  // let positionsToExpectations:
  //   [String.Index: (
  //     expectations: [Matcher.Expectation], file: StaticString, line: UInt
  //   )]
  let annotations: [(index: String.Index, annotation: Annotation, file: StaticString, line: UInt)]

  init(stringInterpolation: Interpolation) {
    var source = ""
    // var references: [(reference: Matcher.Reference, index: String.Index, file: StaticString, line: UInt)] = []
    // var positionsToExpectations:
    //   [String.Index: (
    //     expectations: [Matcher.Expectation], file: StaticString, line: UInt
    //   )] = [:]
    var annotations = [(index: String.Index, annotation: Annotation, file: StaticString, line: UInt)]()

    for component in stringInterpolation.components {
      switch component {
      case .stringFragment(let str):
        source.append(str)
      case .annotation(let annotation, let file, let line):
        // Get the endIndex so we refer to the token after the expectation
        let index = source.endIndex

        // Diagnose same annotation in the same location
        if let lastAnnotation = annotations.last,
          lastAnnotation.index == index
        {
          XCTFail(
            "[Lookup Failure] Second annotation for same source index is prohibited (original annotation at \(lastAnnotation.file):\(lastAnnotation.line))",
            file: file,
            line: line
          )
          continue
        }
        // Save expectation
        annotations.append((index, annotation, file: file, line: line))

      // Get the endIndex so we refer to the token after the expectation
      // case .reference(let reference, let file, let line):
      //   // We don't diagnose duplicates yet, since markers should be unique
      //   // across source files and we only have access to one
      //   references.append((reference, source.endIndex, file, line))
      // case .expectations(let expectations, let file, let line):
      //   // Diagnose existing expectation (we allow only one per source index)
      //   if let existingExpectation = positionsToExpectations[source.endIndex] {
      //     XCTFail(
      //       "[Lookup Failure] Second expectation for same source index is prohibited (original expectation at \(existingExpectation.file):\(existingExpectation.line))",
      //       file: file,
      //       line: line
      //     )
      //     continue
      //   }
      //   // Save expectation
      //   positionsToExpectations[source.endIndex] = (expectations, file: file, line: line)
      }
    }

    self.source = source
    self.annotations = annotations
    // self.references = references
    // self.positionsToExpectations = positionsToExpectations
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

enum LexicalMatcherExpectationFailure<Reference: LexicalAnnotation & Identifiable> {
  /// This expectation references a marker that wasn't declared in source
  case referencesUndefinedMarker(Reference.ID)
  /// The produced lookup result produces a syntax that hasn't
  /// been annotated with a marker
  case resultReferencesUnmarkedSyntax(syntaxDescription: String)
  /// The result didn't produce the expected marker
  case resultMissesReferences([ContextualizedAnnotation<Reference>])
  /// The result added an additional (unexpected) marker
  case resultAddsReferences([ContextualizedAnnotation<Reference>])
  /// Results are in the wrong order
  case invalidResultOrder(
    expected: [ContextualizedAnnotation<Reference>],
    actual: [ContextualizedAnnotation<Reference>]
  )
  /// Wrong result type. E.g., expected failure, but succeeded
  case invalidResultType(failure: String)

  func describe(describeReference: (ContextualizedAnnotation<Reference>) -> String) -> String {
    switch self {
    case .referencesUndefinedMarker(let marker):
      "Expectation references undefined marker '\(marker)'"
    case .resultReferencesUnmarkedSyntax(let syntaxDescription):
      "Lookup result references syntax that wasn't marked: `\(syntaxDescription)`"
    case .resultMissesReferences(let references):
      "Lookup didn't find expected result '\(references.map(describeReference))'"
    case .resultAddsReferences(let references):
      "Lookup introduced unexpected result '\(references.map(describeReference))'"
    case .invalidResultOrder(let expected, let actual):
      "Lookup returned results in wrong order. Expected: \(expected.map(describeReference)). Got: \(actual.map(describeReference))"
    case .invalidResultType(let failure):
      failure
    }
  }
}

func _assertLexicalLookup<Matcher: LexicalMatcher>(
  _ lookupSources: KeyValuePairs<String, LexicalLookupSource<Matcher>>,
  moduleName: StaticString,
  matcher: Matcher,
  file: StaticString,
  line: UInt,
  verbose: Bool = false
) {
  // Parse each source file
  // let lookupFiles: [(name: String, text: String, syntax: SourceFileSyntax)] = lookupSources.map({
  //   fileName,
  //   lookupSource in
  //   var parser = Parser(lookupSource.source)
  //   return (fileName, lookupSource.source, SourceFileSyntax.parse(from: &parser))
  // })

  /// IMPORTANT: Only use for the given files with matching source/parsedSource.
  func sourceToken(at index: String.Index, fileSource: String, fileSyntax: SourceFileSyntax) -> TokenSyntax? {
    let sourcePosition = AbsolutePosition(
      utf8Offset: fileSource.distance(
        from: fileSource.startIndex,
        to: index
      )
    )
    return fileSyntax.token(at: sourcePosition)
  }

  // Find the expected syntax for each reference and expectation.
  var markersToReferences = [
    Matcher.Reference.ID: ContextualizedAnnotation<Matcher.Reference>
  ]()
  var syntaxToReferences = [Matcher.Reference.SyntaxReference: ContextualizedAnnotation<Matcher.Reference>]()
  var contextualizedExpectations = [ContextualizedAnnotation<Matcher.Expectation>]()
  for (_, lookupSource) in lookupSources {
    // Parse file
    var parser = Parser(lookupSource.source)
    let fileSyntax = SourceFileSyntax.parse(from: &parser)

    for (annotationSourceIndex, annotation, file, line) in lookupSource.annotations {
      // Get the token at this index (e.g. 'struct')
      let token = sourceToken(
        at: annotationSourceIndex,
        fileSource: lookupSource.source,
        fileSyntax: fileSyntax
      )
      guard let token else {
        XCTFail(
          "[Internal Error] Unexpectedly couldn't find token for annotation.",
          file: file,
          line: line
        )
        continue
      }

      // Find the annotated syntax and save
      switch annotation {
      case .reference(let reference):
        // Ensure we're not overwriting a previous one.
        guard markersToReferences[reference.id] == nil else {
          XCTFail(
            "Duplicate reference marker '\(reference.id)': Unexpectedly found the same marker in a different lexical reference.",
            file: file,
            line: line
          )
          continue
        }

        // Find annotated syntax
        guard let referenceSyntax = reference.findSyntaxFromToken(token, verbose: verbose, file: file, line: line)
        else {
          // We leave diagnostics to `findSyntaxFromToken` since they'll be more precise
          continue
        }

        // Ensure this syntax has only one marker
        if let existingReferenceID = syntaxToReferences[referenceSyntax] {
          XCTFail(
            "Duplicate marker: Syntax '\(referenceSyntax.trimmedDescription)' was already annotated with '\(existingReferenceID)' and can't be re-referenced as '\(reference.id)'",
            file: file,
            line: line
          )
          continue
        }

        // Save
        let contextualizedReference = ContextualizedAnnotation(
          annotation: reference,
          syntax: referenceSyntax,
          file: file,
          line: line
        )
        markersToReferences[reference.id] = contextualizedReference
        syntaxToReferences[referenceSyntax] = contextualizedReference
      case .expectations(let expectations):
        for expectation in expectations {
          // Find annotated syntax (like above)
          guard let expectationSyntax = expectation.findSyntaxFromToken(token, verbose: verbose, file: file, line: line)
          else {
            // We leave diagnostics to `findSyntaxFromToken` since they'll be more precise
            continue
          }

          // Save
          contextualizedExpectations.append(
            ContextualizedAnnotation(annotation: expectation, syntax: expectationSyntax, file: file, line: line)
          )
        }

      }
    }

    // Try to match each expectation with at least one reference

    // var unmatchedReferenceIDs: Set<Matcher.Reference.ID> = Set(markersToReferences.keys)
    for contextualizedExpectation in contextualizedExpectations {
      // Assert the expectations
      let failures = matcher.assertExpectation(
        expectation: contextualizedExpectation,
        markersToReferences: markersToReferences,
        syntaxToReferences: syntaxToReferences,
        verbose: verbose
      )
      for failure in failures {
        XCTFail(
          failure.describe(describeReference: \.annotation.description),
          file: contextualizedExpectation.file,
          line: contextualizedExpectation.line
        )
      }
      // // Updates matched ids
      // unmatchedReferenceIDs.subtract(newlyMatchedIDs)
    }

    // // Diagnose unmatched references
    // for id in unmatchedReferenceIDs {
    //   XCTFail("Unmatched marker: No expectation matched reference '\(id)'", file: file, line: line)
    // }
  }
}

/// Find the direct parent of the given token and cast it to the desired
/// `Parent` syntax type.
///
/// Parameters:
/// - annotationKindDescription: Helps make the casting-failure message more
///   specific.
func findDirectParent<Parent: SyntaxProtocol>(
  from introducerToken: TokenSyntax,
  ofType _: Parent.Type,
  file: StaticString,
  line: UInt,
  annotationKindDescription: String? = nil
) -> Parent? {
  // Get parent
  guard let rawParent = introducerToken.parent else {
    XCTFail(
      "Annotation lacks parent: Token '\(introducerToken.trimmedDescription)' has no parent node.",
      file: file,
      line: line
    )
    return nil
  }

  // Cast to right type
  guard let parent = rawParent.as(Parent.self) else {
    // Explains why the casting is necessary
    let messageQualifier: String
    if let annotationKindDescription {
      messageQualifier = " for \(annotationKindDescription) annotations."
    } else {
      messageQualifier = ""
    }

    XCTFail(
      "Invalid annotation placement: Token '\(introducerToken.trimmedDescription)' should have a \(Parent.self) parent\(messageQualifier).",
      file: file,
      line: line
    )
    return nil
  }

  return parent
}

func diffLexicalResults<Reference: LexicalAnnotation & Identifiable>(
  expected: [ContextualizedAnnotation<Reference>],
  actual: [ContextualizedAnnotation<Reference>],
  failures: inout [LexicalMatcherExpectationFailure<Reference>]
) {
  // Convert to sets
  let expectedMarkers = Set(expected.map(\.annotation.id))
  let actualMarkers = Set(expected.map(\.annotation.id))

  // Calculate differences
  let missingReferences = expected.filter({ !actualMarkers.contains($0.annotation.id) })
  if !missingReferences.isEmpty {
    failures.append(.resultMissesReferences(missingReferences))
  }
  let addedReferences = actual.filter({ !expectedMarkers.contains($0.annotation.id) })
  if !addedReferences.isEmpty {
    failures.append(.resultMissesReferences(addedReferences))
  }

  // Check order (through markers)
  if expected.map(\.annotation.id) != actual.map(\.annotation.id) {
    failures.append(.invalidResultOrder(expected: expected, actual: actual))
  }
}

struct TypeLookupMatcher: LexicalMatcher {
  /// A type-lookup reference has a marker and the resolved qualified name.
  /// A reference is tied to a `NominalTypeDeclSyntax`
  struct Reference: LexicalAnnotation, Identifiable, CustomStringConvertible {
    let marker: Character
    let name: QualifiedTypeName

    typealias SyntaxReference = NominalTypeDeclSyntax
    func findSyntaxFromToken(
      _ token: SwiftSyntax.TokenSyntax,
      verbose: Bool,
      file: StaticString,
      line: UInt
    ) -> NominalTypeDeclSyntax? {
      findDirectParent(from: token, ofType: NominalTypeDeclSyntax.self, file: file, line: line)
    }

    var id: Character { marker }

    var description: String { name.debugDescription }
  }
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
  enum Expectation: LexicalAnnotation {
    case syntaxResolution(Result<MemberLookupResult<Character>, TypeQualifierFailure<Character, Character>>)
    case extensionBinding(ExtensionBindingState)

    typealias SyntaxReference = TypeSyntaxOrExtension

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
        return findDirectParent(
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

        /// Find the head type-syntax (because for instance `any Encodable & Decodable`
        /// contains the `Encodable & Decodable` nested type syntax)
        func findHeadTypeSyntax(of typeSyntax: TypeSyntax) -> TypeSyntax {
          // Cast the parent to type syntax, or return current type syntax
          //
          // Check for special-cases first (e.g., compositions)
          if typeSyntax.parent?.is(CompositionTypeElementSyntax.self) == true,
            let compositionSyntax = typeSyntax.parent?.parent?.parent?.as(CompositionTypeSyntax.self)
          {
            return findHeadTypeSyntax(of: TypeSyntax(compositionSyntax))
          }
          // General case
          guard let parentTypeSyntax = typeSyntax.parent?.as(TypeSyntax.self) else { return typeSyntax }
          // Find parent's head type syntax
          return findHeadTypeSyntax(of: parentTypeSyntax)
        }
        let typeSyntax = findHeadTypeSyntax(of: baseTypeSyntax)

        return TypeSyntaxOrExtension(typeSyntax)
      }
    }
  }

  let symbolTable: SymbolTable3
  let moduleName: Identifier
  let lookupFiles: [(String, SourceFileSyntax)]

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
  ) -> [ExpectationFailure] {  //-> Set<Character> {
    var typeQualifier = TypeQualifier(symbolTable: symbolTable, _verbose: verbose)

    switch expectation.annotation {
    case Expectation.syntaxResolution(let expectedResult):
      guard let typeSyntax = expectation.syntax.as(TypeSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal test error: Expected syntax-resolution queries to find 'TypeSyntax' nodes, but got '\(expectation.syntax.kind)'."
        )
      }

      // Print target syntax (to show the syntax kinds)
      if verbose {
        print("Target syntax parsed as:\n\(typeSyntax.debugDescription)\n")
      }

      // Perform the lookup
      let lookupResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, TypeQualifier.Failure>
      do {
        var memberDependencies = [ExtensionBindingResult.Dependency]()
        lookupResult = typeQualifier.resolveSyntax(
          typeSyntax: typeSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: []
        )
      }
      return assertTypeSyntax(
        expectedResult: expectedResult,
        actualResult: lookupResult,
        markersToReferences: markersToReferences,
        syntaxToReferences: syntaxToReferences,
        verbose: verbose
      )
    case Expectation.extensionBinding(let expectedState):
      guard let extensionDecl = expectation.syntax.as(ExtensionDeclSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal test error: Expected syntax-resolution queries to find 'ExtensionDeclSyntax' nodes, but got '\(expectation.syntax.kind)'."
        )
      }

      // Look up extended type if not already resolved
      let actualState: ExtensionBindingState
      // Try to get already-resolved state
      if let existingState = symbolTable.extensionState[extensionDecl] {
        actualState = existingState
      } else {
        if verbose {
          print("Extension `\(extensionDecl._memberlessDescription)` not already bound; initating binding.")
        }

        // Evaluate the extended type
        var memberDependencies = [ExtensionBindingResult.Dependency]()
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
          XCTFail(
            "Invalid extended type: Couldn't resolve extended type for given extension: \(failure.debugDescription)",
            file: expectation.file,
            line: expectation.line
          )
          return []
        }

        // Trigger binding and ensure we have a state
        _ = typeQualifier.resolveNominalType(typeReference: nominalReference)
        guard let producedState = symbolTable.extensionState[extensionDecl] else {
          let availableExtensions = symbolTable.extensionState.keys.map(\._memberlessDescription)
          XCTFail(
            "No extension state: Couldn't find extension state even after nominal-type resolution; available extensions are: \(availableExtensions)",
            file: expectation.file,
            line: expectation.line
          )
          return []
        }

        actualState = producedState
      }

      // FIXME: Do proper printing
      let expectedStateDescription = String(reflecting: expectedState)
      let actualStateDescription = String(reflecting: actualState)
      guard expectedStateDescription == actualStateDescription else {
        return [
          ExpectationFailure.invalidResultType(
            failure: "Extension-state mismatch. Expected: \(expectedStateDescription)\nGot: \(actualStateDescription)"
          )
        ]
      }
      return []
    }

  }

  /// Helper for converting a qualified type name to a string description
  func describeQualifiedName(_ name: QualifiedTypeName) -> String {
    name._describe(describeFileID: { fileID in
      // Get name of first matching id
      for (fileName, file) in lookupFiles {
        guard file.id == fileID else { continue }
        return fileName
      }
      return fileID.hashValue.description
    })
  }

  func assertTypeSyntax(
    expectedResult: Result<MemberLookupResult<Character>, TypeQualifierFailure<Character, Character>>,
    actualResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, TypeQualifier.Failure>,
    markersToReferences: [Character: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [NominalTypeDeclSyntax: ContextualizedAnnotation<Reference>],
    verbose: Bool,
  ) -> [ExpectationFailure] {  // -> Set<Character> {
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
      diffLexicalResults(expected: expectations, actual: results, failures: &failures)
    case (.success(let expectedLookupResult), .success(let actualLookupResult)):
      // We handled members above, so map to `Bool` to facilitate the comparison.
      if expectedLookupResult.mapMembers({ _ in false }) != actualLookupResult.mapMembers({ _ in false }) {
        failures.append(
          ExpectationFailure.invalidResultType(
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
        return nominalDecl.annotation.name.debugDescription
      }
      let expectedFailureDescription = expectedFailure._describeDebug(
        resolveMininalNominal: markerToQualifiedName,
        resolveExtendedNominal: markerToQualifiedName
      )

      // Describe the lookup failure
      let actualFailureDescription = actualFailure._describeDebug(
        resolveMininalNominal: { describeQualifiedName($0.qualifiedName) },
        resolveExtendedNominal: { describeQualifiedName($0.qualifiedName) }
      )

      // Check equality
      if expectedFailureDescription != actualFailureDescription {
        failures.append(
          ExpectationFailure.invalidResultType(
            failure: "Failure mismatch. Expected:\(expectedFailureDescription)\nGot:\(actualFailureDescription)"
          )
        )
      }
    default:
      failures.append(
        ExpectationFailure.invalidResultType(
          failure:
            "Lookup didn't succeed/fail as expected. Expected '\(expectedResult)'; got: '\(actualResult)'"
        )
      )
    }
    return failures
  }
}
