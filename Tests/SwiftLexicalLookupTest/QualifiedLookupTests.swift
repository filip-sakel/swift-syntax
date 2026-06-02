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

import Foundation
import SwiftParser
import SwiftSyntax
import XCTest

@_spi(Experimental) @testable import SwiftLexicalLookup

struct QualifiedLookupSource: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  enum Expectation: ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral {
    case referenceMarker(Character)
    // case `Self`

    init(unicodeScalarLiteral value: Character) {
      self = .referenceMarker(value)
    }
    init(extendedGraphemeClusterLiteral value: Character) {
      self = .referenceMarker(value)
    }
  }
  enum Component {
    case str(String)
    case expectations([Expectation], file: StaticString, line: UInt)
  }

  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.str(literal))
    }
    mutating func appendInterpolation(
      references expectations: Expectation...,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.expectations(expectations, file: file, line: line))
    }
  }

  /// The source with all markers removed
  let source: String
  /// A dictionary mapping markers (symbol referenced from `expectations`)
  /// to a valid index in `source`.
  let markerToIndexMap: [Character: String.Index]
  /// A collection of expectations when performing lookup at the given
  /// index.
  let positionsAndExpectations: [(fromIndex: String.Index, expecting: [Expectation], file: StaticString, line: UInt)]

  /// Records duplicate markers found in source (markers should be unique)
  let duplicateMarkers: Set<Character>

  init(stringInterpolation: Interpolation) {
    let components = stringInterpolation.components

    let markers = components.flatMap { component -> [Character] in
      // Only expectations generate markers
      guard case .expectations(let expectations, _, _) = component else {
        return []
      }
      return expectations.compactMap({ expectation in
        guard case .referenceMarker(let marker) = expectation else { return nil }
        return marker
      })
    }

    var source = ""
    var markerToIndexMap = [Character: String.Index]()
    var positionsAndExpectations = [
      (fromIndex: String.Index, expecting: [Expectation], file: StaticString, line: UInt)
    ]()

    // Test diagnostics
    var duplicateMarkers = Set<Character>()

    for component in components {
      switch component {
      case .str(let str):
        // Add each character to the source, unless it's a marker
        for char in str {
          if !markers.contains(char) {  // .contains is O(n) but we should have few markers
            // Append normal characters
            source.append(char)
          } else {
            // If it's a marker, check it's not a duplicate and record the end index
            if markerToIndexMap[char] != nil { duplicateMarkers.insert(char) }
            markerToIndexMap[char] = source.endIndex
          }
        }
      case .expectations(let expectations, let file, let line):
        // If it's an expectation, record the position BEFORE the end.
        //
        // E.g. In "myFunc\(to: "🅰️")", after processing "myFunc", the
        // endIndex would point to past the end of the string. So by taking the
        // index before the end, we now refer to "c".
        positionsAndExpectations.append(
          (
            fromIndex: source.index(before: source.endIndex),
            expecting: expectations,
            file: file, line: line
          )
        )
      }
    }

    self.source = source
    self.markerToIndexMap = markerToIndexMap
    self.positionsAndExpectations = positionsAndExpectations
    // Tets validation
    self.duplicateMarkers = duplicateMarkers
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

final class TestQualifiedLookup: XCTestCase {
  /// Check each of the `\(toType: ...)`-suffixed `<Type>.<member>`
  /// names map to the correct member declarations.
  ///
  /// Each declaration-reference name suffixed with a '\(toDecl: ...)' so-called
  /// expectation must be valid type syntax identifier type syntax or member type
  /// syntax consisting solely of other member type syntax or identifier type nodes.
  ///
  /// Further, each marker should be attached right in front of the introducer keyword
  /// of the named declaration it identifies. For instance:
  ///   public 🟥MyStruct {
  ///     @MainActor static private 🟩func myFunc() {}
  ///   }
  func assertTypeMemberLookup(
    _ lookupSource: QualifiedLookupSource,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    var parser = Parser(lookupSource.source)
    let sourceFile = SourceFileSyntax.parse(from: &parser)

    // Ensure markers are unique
    XCTAssert(
      lookupSource.duplicateMarkers.isEmpty,
      "Unexpectedly found duplicate markers \(Array(lookupSource.duplicateMarkers))",
      file: file,
      line: line
    )

    /// IMPORTANT: Only use for `lookupSource.source` and `sourceFile`.
    func sourcePosition(of index: String.Index) -> AbsolutePosition {
      AbsolutePosition(
        utf8Offset: lookupSource.source.distance(
          from: lookupSource.source.startIndex,
          to: index
        )
      )
    }

    // Extract declarations identifier by each marker
    var markerToDecl = [Character: any NamedDeclSyntax]()
    for (marker, sourceIndex) in lookupSource.markerToIndexMap {
      // The assertion expects this to be an introducer token
      guard let introducerToken = sourceFile.token(at: sourcePosition(of: sourceIndex)) else {
        XCTFail(
          "[Internal Error] Unexpectedly couldn't find token for marker '\(marker)'",
          file: file,
          line: line
        )
        continue
      }

      // Since this is an introducer, the named declaration should be its parent; try to cast it.
      guard let introducerParent = introducerToken.parent else {
        XCTFail(
          "Marker '\(marker)' points to token without parent. Ensure marker is placed before the named declaration's introducer keyword, like 'struct'.",
          file: file,
          line: line
        )
        continue
      }
      guard let namedDecl = introducerParent.asProtocol((any NamedDeclSyntax).self) else {
        XCTFail(
          "Marker '\(marker)' points to token whose parent isn't a named declaration. Ensure marker is placed before the named declaration's introducer keyword, like 'struct'.",
          file: file,
          line: line
        )
        continue
      }

      markerToDecl[marker] = namedDecl
    }

    // Validate each expectation
    let symbolTable = SymbolTable(fileSyntax: sourceFile)
    for (sourceIndex, expectations, file, line) in lookupSource.positionsAndExpectations {
      // === Validate Test === \\

      // --- Test Markers ---
      // Check expectations refer to valid markers
      enum ExpectationDecl {
        case decl(any NamedDeclSyntax, marker: Character)
      }
      let expectationDecls = expectations.compactMap({ expectation -> ExpectationDecl? in
        switch expectation {
        case .referenceMarker(let marker):
          // Ensure marker is valid
          guard lookupSource.markerToIndexMap[marker] != nil else {
            XCTFail(
              "Expectation requires lookup to produce result to nonexistent marker \(marker).",
              file: file,
              line: line
            )
            return nil
          }

          // Get valid declaration
          guard let decl = markerToDecl[marker] else {
            return nil  // Diagnosed when generating `markerToDecl`
          }

          return ExpectationDecl.decl(decl, marker: marker)
        }
      })

      // --- Extract Syntax for Lookup ---
      // Get all identifier tokens separated by dots
      guard let memberToken = sourceFile.token(at: sourcePosition(of: sourceIndex)) else {
        XCTFail(
          "[Internal Error] Unexpectedly couldn't find token to look up for expectation",
          file: file,
          line: line
        )
        continue
      }

      // Ensure token is an identifier (this is where we'll do lookup)
      guard let memberIdentifier = memberToken.identifier else {
        XCTFail(
          "Expected tested token to be an identifier, but got \(memberToken.tokenKind) instead.",
          file: file,
          line: line
        )
        continue
      }
      guard let baseDeclRef = memberToken.parent?.as(DeclReferenceExprSyntax.self) else {
        XCTFail(
          "Expected tested token's parent to be a 'DeclReferenceExprSyntax', but got \(String(describing: memberToken.parent?.kind)).",
          file: file,
          line: line
        )
        continue
      }

      // The given declaration reference should be part of a MemberAccessExprSyntax with a valid base
      // E.g., "TypeA.myFunc` or `TypeA.TypeB` or `TypeA.TypeB.funcA`.
      guard
        let memberAccessExpr = baseDeclRef.parent?.as(MemberAccessExprSyntax.self),
        let memberAccessBase = memberAccessExpr.base
      else {
        // TODO: Consider other test case
        // 2. The given declaration may be a standalone declaration (we assume it's a type here
        //    to test the base type lookup)
        //    TODO: Look into expanding this as general name lookup
        XCTFail(
          "Expected tested token's grandparent to be a 'MemberAccessExprSyntax' with a *valid* base, but got syntax type \(String(describing: baseDeclRef.parent?.kind)).",
          file: file,
          line: line
        )
        continue
      }

      guard Syntax(memberAccessExpr.base) != Syntax(baseDeclRef) else {
        XCTFail(
          "Expectation cannot refer to the base of a member access expression. This may be caused from a bare-type lookup, e.g. `MyStruct\\(references: ...)`.",
          file: file,
          line: line
        )
        continue
      }

      // Reinterpret the member-access base as a member type expression
      // (we assume it's a type for this test)
      let typeSyntax: TypeSyntax = "\(raw: memberAccessBase.description)"

      // === Test Lookup === \\

      // Perform lookup
      let foundDecls = symbolTable.lookupMember(
        withIdentifier: memberIdentifier,
        inType: typeSyntax,
        atLocation: memberToken.position,
        options: SymbolTable.LookupOptions.qualifiedDefault
      )

      // Check expectations match
      var idsToFoundDecl = Dictionary(grouping: foundDecls, by: \.id).mapValues({ decls in
        guard let decl = decls.first, decls.count == 1 else {
          fatalError(
            "[Internal Error] Unexpectedly found multiple declarations with id \(String(describing: decls.first?.id))"
          )
        }
        return decl
      })
      for expectation in expectationDecls {
        switch expectation {
        case .decl(let expectedDecl, let marker):
          // Ensure lookup surfaced expected declaration
          XCTAssert(
            idsToFoundDecl[expectedDecl.id] != nil,
            "Lookup of `\(typeSyntax.trimmed)/\(memberIdentifier.name)` didn't return declaration '\(marker)'.",
            file: file,
            line: line
          )
          // Check declaration off the list
          idsToFoundDecl[expectedDecl.id] = nil
        }
      }

      // Ensure lookup didn't give us more than expected
      if !idsToFoundDecl.isEmpty {
        for (_, decl) in idsToFoundDecl {
          XCTFail(
            "Lookup of `\(typeSyntax.trimmed)/\(memberIdentifier.name)` found non-expected declaration of type '\(decl.kind)': \n`\(decl.description)`",
            file: file,
            line: line
          )
        }
      }
    }
  }

  func testCodeBlockSimpleCase() {
    // TODO: Implement type-lookup helper first.
    assertTypeMemberLookup(
      """
      🅰️struct MyStruct {
        static 🅱️func hello() {}

        struct TypeB {}

        func hi() {
          MyStruct.TypeB\(references: "🅰️").hello\(references: "🅱️")
        }
      }
      """
    )
  }

  // TODO: Test lookup of an associated type and how it interacts with MyProto.Type, etc.

  // TODO: Test multiple variables/patterns and finding those, e.g., var a, b, c: Int {}, etc.

  // TODO: Test function-like parameters with firstName="_", variadic arguments, trailing closures, etc.

  // TODO: Test nested and non-nested macro lookup

  // TODO: Test cycles, e.g. struct A { typealias Element = B.Element }; struct B { typealias Element = A }
  // typealias A = B; typealias B = A. Or protocol A: B {}; protocol B: A {}

  // TODO: Handle lookup in struct nested inside function, e.g. func hi() { struct Hello { var a }; Hello().a }

  // TODO: Think about isolation use cases? (That seems more like type checking)
}
