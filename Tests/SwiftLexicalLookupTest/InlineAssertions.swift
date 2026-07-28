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

import SwiftParser
import SwiftSyntax
import XCTest

/// An annotation (used for ``LexicalMatcher`` references and expectations)
/// associates testing data with a syntax node in the given ``LexicalLookupSource``.
///
/// Used by ``_assertLexicalLookup``.
protocol LexicalAnnotation {
  associatedtype SyntaxReference: SyntaxProtocol, SyntaxHashable
  func findSyntaxFromToken(_ token: TokenSyntax, verbose: Bool, file: StaticString, line: UInt) -> SyntaxReference?
}

/// A ``LexicalAnnotation`` resolved by ``_assertLexicalLookup`` to include
/// the target syntax and source-location information.
struct ContextualizedAnnotation<Annotation: LexicalAnnotation> {
  let annotation: Annotation
  let syntax: Annotation.SyntaxReference
  let file: StaticString
  let line: UInt
}

/// A matcher asserts a particular expectation with access to the
/// lexical information and references collected by `_assertLexicalLookup`.
protocol LexicalMatcher {
  associatedtype Reference: LexicalAnnotation, Identifiable, CustomStringConvertible
  associatedtype Expectation: LexicalAnnotation
  typealias ExpectationFailure = LexicalMatcherExpectationFailure<Reference>

  /// Asserts the given expectation by returning failures.
  ///
  /// ### Implementation Note
  ///
  /// We're given two maps for references:
  /// 1. the markers->references map helps us convert markers from expectations
  ///    to actual references
  /// 2. the syntax->references map helps us convert the lookup output's syntax
  ///    to actual references
  /// Then, you can use methods like ``LexicalAssertionUtilities/diffLexicalResults``
  /// to diff the expected vs lookup-produced references.
  func assertExpectation(
    expectation: ContextualizedAnnotation<Expectation>,
    markersToReferences: [Reference.ID: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [Reference.SyntaxReference: ContextualizedAnnotation<Reference>],
    verbose: Bool
  ) -> [ExpectationFailure]

  /// Describes the expectation's syntax to provide more useful `XCTFail` messages.
  func describeExpectationSyntax(_ syntax: Expectation.SyntaxReference) -> String
}

/// A source file annotated with references and expectations on those references.
///
/// All annotations should be placed before the target token.
///
/// Look for examples in `assertTypeResolution` and related assertion methods.
struct LexicalLookupSource<Matcher: LexicalMatcher>: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  enum Annotation {
    case reference(reference: Matcher.Reference)
    case expectations(expectations: [Matcher.Expectation])
  }
  enum Component {
    case stringFragment(String)
    case annotation(annotation: Annotation, file: StaticString, line: UInt)
  }

  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.stringFragment(literal))
    }
    mutating func append(
      reference: Matcher.Reference,
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
  let fileSource: String
  /// Parsed `source`
  let fileSyntax: SourceFileSyntax
  /// A list of annotations, their source index and source location.
  let annotations: [(index: String.Index, annotation: Annotation, file: StaticString, line: UInt)]

  /// Gets the token from the source at the given index of `fileSource`.
  ///
  /// IMPORTANT: Only use for indices acquired from `annotations`.
  func getSourceToken(at index: String.Index) -> TokenSyntax? {
    let sourcePosition = AbsolutePosition(
      utf8Offset: fileSource.distance(
        from: fileSource.startIndex,
        to: index
      )
    )
    return fileSyntax.token(at: sourcePosition)
  }

  init(stringInterpolation: Interpolation) {
    var source = ""
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
      }
    }

    // Parse file
    var parser = Parser(source)

    self.fileSource = source
    self.fileSyntax = SourceFileSyntax.parse(from: &parser)
    self.annotations = annotations
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

/// Used by ``LexicalMatcher/assertExpectation`` to report errors back
/// to `_assertLexicalLookup`.
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
  case other(failure: String)

  /// Converts this failure to a string for `XCTFail`.
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
    case .other(let failure):
      failure
    }
  }
}

// MARK: _assertLexicalLookup

/// Verifies the provided annotated sources and drives `Matcher`
/// to verify lookup results.
///
/// You should wrap this method using a custom `Matcher`
/// for each use-case. See `assertTypeResolution` as an example.
///
/// Note: We don't diagnose unused reference annotations.
func _assertLexicalLookup<Matcher: LexicalMatcher>(
  _ lookupSources: KeyValuePairs<String, LexicalLookupSource<Matcher>>,
  matcher: Matcher,
  file: StaticString,
  line: UInt,
  verbose: Bool = false
) {
  // Find the expected syntax for each reference and expectation.
  //
  // See why we create two maps to references: markers->references, and
  // syntax->references in `LexicalMatcher/assertExpectation`
  var markersToReferences = [Matcher.Reference.ID: ContextualizedAnnotation<Matcher.Reference>]()
  var syntaxToReferences = [Matcher.Reference.SyntaxReference: ContextualizedAnnotation<Matcher.Reference>]()
  var contextualizedExpectations = [ContextualizedAnnotation<Matcher.Expectation>]()
  for (_, lookupSource) in lookupSources {
    for (annotationSourceIndex, annotation, file, line) in lookupSource.annotations {
      // Get the token at this index (e.g. 'struct')
      let token = lookupSource.getSourceToken(at: annotationSourceIndex)
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
          guard
            let expectationSyntax = expectation.findSyntaxFromToken(token, verbose: verbose, file: file, line: line)
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
    for contextualizedExpectation in contextualizedExpectations {
      // Assert the expectations
      let failures = matcher.assertExpectation(
        expectation: contextualizedExpectation,
        markersToReferences: markersToReferences,
        syntaxToReferences: syntaxToReferences,
        verbose: verbose
      )
      let syntaxDescription = matcher.describeExpectationSyntax(contextualizedExpectation.syntax)
      for failure in failures {
        let failureDescription = failure.describe(describeReference: \.annotation.description)
        XCTFail(
          "[Lookup of `\(syntaxDescription)`] \(failureDescription)",
          file: contextualizedExpectation.file,
          line: contextualizedExpectation.line
        )
      }
    }
  }
}

enum LexicalAssertionUtilities {
  /// Find the direct parent of the given token and cast it to the desired
  /// `Parent` syntax type.
  ///
  /// Parameters:
  /// - annotationKindDescription: Helps make the casting-failure message more
  ///   specific.
  static func findDirectParent<Parent: SyntaxProtocol>(
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

  static func diffLexicalResults<Reference: LexicalAnnotation & Identifiable>(
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
}
