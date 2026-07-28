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

/// Asserts that the annotated `ValueDeclSyntax` matches the given
/// declaration-name references.
struct DeclNameMatcher {
  /// Marks a given 'ValueDeclSyntax' in source.
  struct Reference {
    let valueDeclMarker: Character
  }

  /// Annotates `ValueDeclSyntax` with the expected declaration-name references
  /// and the other results that each reference should yield.
  struct Expectation {
    // let nameReferences: [(nameReference: DeclNameReference, otherResults: [Character])]
    let nameReference: DeclNameReference
    let kind: MemberKind
    let results: [Character]
  }

  let lookupFile: SourceFileSyntax
}

// // MARK: Enclosing Decl Group
//
// struct TypeMemberSyntax<Node: SyntaxProtocol>: SyntaxProtocol, SyntaxHashable {
//   let node: Node
//   let enclosingdeclGroup: DeclGroupSyntaxType
//
//   /// Walk up the tree to find the enclosing decl group.
//   /// Returns `nil` if `syntax` is declared in a local context (e.g. in a
//   /// `while` body)
//   private static func _findEnclosingDeclGroup(of syntax: some SyntaxProtocol) -> DeclGroupSyntaxType? {
//     // Local declarations are introduced by code-item lists
//     guard let parent = syntax.parent, !parent.is(CodeBlockItemListSyntax.self) else { return nil }
//
//     // Cast the parent to a decl group, or check its parent
//     guard let declGroupParent = parent.as(DeclGroupSyntaxType.self) else {
//       return _findEnclosingDeclGroup(of: parent)
//     }
//
//     // Found the parent
//     return declGroupParent
//   }
//
//   init?(_ node: Node) {
//     guard let enclosingdeclGroup = Self._findEnclosingDeclGroup(of: node) else {
//       return nil
//     }
//
//     self.node = node
//     self.enclosingdeclGroup = enclosingdeclGroup
//   }
//
//   init?(_ rawNode: __shared some SyntaxProtocol) {
//     guard let castNode = Node(rawNode) else { return nil }
//     self.init(castNode)
//   }
//
//   var _syntaxNode: Syntax { node._syntaxNode }
//
//   static var structure: SyntaxNodeStructure { Node.structure }
// }

// MARK: `Reference` Conformances

// Vacuous conformances (`Reference` is unihabited)
extension DeclNameMatcher.Reference: LexicalAnnotation, Identifiable, CustomStringConvertible {
  typealias SyntaxReference = ValueDeclSyntax  //TypeMemberSyntax<ValueDeclSyntax>
  func findSyntaxFromToken(
    _ token: SwiftSyntax.TokenSyntax,
    verbose: Bool,
    file: StaticString,
    line: UInt
  ) -> ValueDeclSyntax? {  // TypeMemberSyntax<ValueDeclSyntax>? {
    // // The parent must be a value declaration nested under a declaration
    // // group (nominal type or extension).
    // //
    // // Note: We don't accept local declarations (nested within a `while` body, etc.)
    // LexicalAssertionUtilities.findDirectParent(
    //   from: token,
    //   ofType: TypeMemberSyntax<ValueDeclSyntax>.self,
    //   file: file,
    //   line: line
    // )

    LexicalAssertionUtilities.findDirectParent(
      from: token,
      ofType: ValueDeclSyntax.self,
      file: file,
      line: line
    )
  }

  var id: Character {
    valueDeclMarker
  }

  var description: String {
    valueDeclMarker.description
  }
}

// MARK: `Expectation` Conformances

extension DeclNameMatcher.Expectation: LexicalAnnotation {
  typealias SyntaxReference = DeclGroupSyntaxType

  func findSyntaxFromToken(
    _ token: TokenSyntax,
    verbose: Bool,
    file: StaticString,
    line: UInt
  ) -> DeclGroupSyntaxType? {
    LexicalAssertionUtilities.findDirectParent(
      from: token,
      ofType: DeclGroupSyntaxType.self,
      file: file,
      line: line
    )
  }
}

// MARK: `LexicalMatcher` Conformance

extension DeclNameMatcher: LexicalMatcher {
  func describeExpectationSyntax(_ syntax: DeclGroupSyntaxType) -> String {
    // Remove member block for readability
    syntax._memberlessDescription
  }

  func assertExpectation(
    expectation: ContextualizedAnnotation<Expectation>,
    markersToReferences: [Character: ContextualizedAnnotation<Reference>],
    syntaxToReferences: [ValueDeclSyntax: ContextualizedAnnotation<Reference>],
    verbose: Bool
  ) -> [ExpectationFailure] {
    // // Extract the declaration group on which we'll perform lookup
    // let (declGroup, valueDecl) = (expectation.syntax.enclosingdeclGroup, expectation.syntax.node)
    //
    // var failures = [ExpectationFailure]()
    // for (nameReference, otherDeclMarkers) in expectation.annotation.nameReferences {
    //   let actualResults = declGroup.findDirectMembers(name: nameReference)
    //
    //   guard actualResults.contains(valueDecl) else {
    //     failures.append(ExpectationFailure.resultMissesReferences([ContextualizedAnnotation<Reference>]))
    //   }
    //
    //   let expectedResults: [ValueDeclSyntax]
    //   do {
    //     var expectedResultsTmp = [valueDecl]
    //
    //     // Add the other markers
    //     for expectedMarker in otherDeclMarkers {
    //       guard let expectedDecl = markersToReferences[expectedMarker] else {
    //         failures.append(ExpectationFailure.referencesUndefinedMarker(expectedMarker))
    //         continue
    //       }
    //       expectedResultsTmp.append(expectedDecl.syntax.node)
    //     }
    //     // Sort results by source position; same as the actual results
    //     expectedResults = expectedResultsTmp.sorted(by: { $0.position < $1.position })
    //   }
    //
    //   LexicalAssertionUtilities.diffLexicalResults(
    //     expected: [ContextualizedAnnotation<Identifiable & LexicalAnnotation>],
    //     actual: [ContextualizedAnnotation<Identifiable & LexicalAnnotation>],
    //     failures: &[LexicalMatcherExpectationFailure<Identifiable & LexicalAnnotation>]
    //   )
    // }
    // return failures
    //

    var failures = [ExpectationFailure]()

    // Map the decls to their definitions
    let actualResults = expectation.syntax.findDirectMembers(
      name: expectation.annotation.nameReference,
      kind: expectation.annotation.kind
    )
    .compactMap({ valueDecl -> ContextualizedAnnotation<Reference>? in
      guard let valueDecl = syntaxToReferences[valueDecl] else {
        failures.append(
          ExpectationFailure.resultReferencesUnmarkedSyntax(syntaxDescription: valueDecl.trimmedDescription)
        )
        return nil
      }
      return valueDecl
    })

    // Map the expectations to definitions
    let expectedResults = expectation.annotation.results
      .compactMap({ marker -> ContextualizedAnnotation<Reference>? in
        guard let valueDecl = markersToReferences[marker] else {
          failures.append(ExpectationFailure.referencesUndefinedMarker(marker))
          return nil
        }
        return valueDecl
      })

    // Diff results
    LexicalAssertionUtilities.diffLexicalResults(
      expected: expectedResults,
      actual: actualResults,
      failures: &failures
    )

    return failures
  }
}

// MARK: Assert Function

func assertDirectLookup(
  _ lookupSource: LexicalLookupSource<DeclNameMatcher>,
  configuredRegions: ConfiguredRegions? = nil,
  file: StaticString = #file,
  line: UInt = #line,
  verbose: Bool = false
) {
  _assertLexicalLookup(
    ["MyFile": lookupSource],
    matcher: DeclNameMatcher(lookupFile: lookupSource.fileSyntax),
    file: file,
    line: line,
    verbose: verbose
  )
}

// MARK: String-Interpolation Helpers

// extension Array where Element == Identifier? {
//   static func args(_ args: [StaticString?]) -> [Identifier?] {
//     args.map({ $0.map(Identifier.init(canonicalName:)) })
//   }
// }

extension Identifier: ExpressibleByStringLiteral {
  // Important: Only use for testing
  public init(stringLiteral value: StaticString) {
    self.init(canonicalName: value)
  }
}

struct TestLookup {
  var name: DeclNameReferenceBase
  var kind: MemberKind

  init(_ name: DeclNameReferenceBase, kind: MemberKind = .default) {
    self.name = name
    self.kind = kind
  }
}

extension LexicalLookupSource.Interpolation where Matcher == DeclNameMatcher {
  mutating func appendInterpolation(
    _ marker: Character,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    append(reference: DeclNameMatcher.Reference(valueDeclMarker: marker), file: file, line: line)
  }
  mutating func appendInterpolation(
    members: KeyValuePairs<TestLookup, [Character]>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    appendInterpolation(
      expects: members.map({
        DeclNameMatcher.Expectation(nameReference: DeclNameReference(baseName: $0.name), kind: $0.kind, results: $1)
      }),
      file: file,
      line: line
    )
  }
}
