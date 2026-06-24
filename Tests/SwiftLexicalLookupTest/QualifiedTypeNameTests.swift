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

import Foundation
import SwiftIfConfig
@_spi(_QualifiedLookup) @_spi(Experimental) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

/// Source code annotated with qualified-lookup expectations.
///
/// Examples at `assertTypeMemberLookup` documentation.
struct QualifiedTypeNameSource: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  /// An expectation describes the lookup parameters that should surfaces the attached
  /// declaration at qualified lookup. It also includes source location for better
  /// diagnostics during testing.
  ///
  /// For example:
  ///   """
  ///   class A {
  ///     \(.deinit()) //   searching for the name `*deinit*` should surface
  ///     deinit {}    //<- this declaration
  ///   }
  ///   """
  ///
  /// Most ways to create a lookup expectation are wrappers around ``DeclNameRef``.
  /// The default ``memberKind`` looks only for instance members. So --for now--
  /// the only way to modify ``memberKind`` is to adding `.static()`, e.g.:
  ///   """
  ///   struct A {
  ///     static \(.named("f", args: []).static()) func f() {}
  ///   }
  ///   """
  struct TypeNameExpectation {
    let marker: Character
    let expectedName: String
  }
  struct TypeSyntaxExpectation {
    let definitionMarker: Character
    // Source location where this expectation was created
    // let file: StaticString
    // let line: UInt
  }

  // ``QualifiedLookupSource`` consists of source code strings and
  // expectation components.
  enum Component {
    case str(String)
    // case definition(TypeNameExpectation, file: StaticString, line: UInt)
    case definition(marker: Character, name: String, file: StaticString, line: UInt)
    case references(
      result: Result<MemberLookupResult<Character>, TypeQualifier.Failure>,
      file: StaticString,
      line: UInt
    )
  }

  // Syntactic sugar for listing expectations alongside source code.
  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.str(literal))
    }
    mutating func appendInterpolation(
      _ marker: Character,
      name: String,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.definition(marker: marker, name: name, file: file, line: line))
    }
    mutating func appendInterpolation(
      resultOrFailure: Result<MemberLookupResult<Character>, TypeQualifier.Failure>,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.references(result: resultOrFailure, file: file, line: line))
    }
    mutating func appendInterpolation(
      result: MemberLookupResult<Character>,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.references(result: .success(result), file: file, line: line))
    }
    mutating func appendInterpolation(
      references markers: Character...,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      appendInterpolation(result: .memberResults(markers), file: file, line: line)
    }
  }

  /// The source with all markers removed
  let source: String
  /// A list of markers and names.
  let markersAndNames: [(marker: Character, index: String.Index, name: String, file: StaticString, line: UInt)]
  /// A map from positions in the string to the expected type-lookup result at that location.
  let positionsToExpectations:
    [String.Index: (
      markers: Result<MemberLookupResult<Character>, TypeQualifier.Failure>, file: StaticString, line: UInt
    )]

  init(stringInterpolation: Interpolation) {
    var source = ""
    var markersAndNames: [(marker: Character, index: String.Index, name: String, file: StaticString, line: UInt)] = []
    var positionsToExpectations:
      [String.Index: (
        markers: Result<MemberLookupResult<Character>, TypeQualifier.Failure>, file: StaticString, line: UInt
      )] = [:]
    for component in stringInterpolation.components {
      switch component {
      case .str(let str):
        source.append(str)
      // Get the endIndex so we refer to the token after the expectation
      case .definition(let marker, let name, let file, let line):
        // We don't diagnose duplicates yet, since markers should be unique
        // across source files and we only have access to one
        markersAndNames.append((marker, source.endIndex, name, file, line))
      case .references(let result, let file, let line):
        // Diagnose existing expectation (we allow only one per source index)
        if let existingExpectation = positionsToExpectations[source.endIndex] {
          XCTFail(
            "[Lookup Failure] Second expectation for same source index is prohibited (original expectation at \(existingExpectation.file):\(existingExpectation.line))",
            file: file,
            line: line
          )
          continue
        }
        // Save expectation
        positionsToExpectations[source.endIndex] = (result, file: file, line: line)
      }
    }

    self.source = source
    self.markersAndNames = markersAndNames
    self.positionsToExpectations = positionsToExpectations
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

final class TestQualifiedTypeName: XCTestCase {
  // override func setUp() {
  //   self.executionTimeAllowance = 1
  // }

  func assertQualifiedTypeName(
    _ lookupSources: [String: QualifiedTypeNameSource],
    moduleName: StaticString = "MyModule",
    configuredRegions: ConfiguredRegions? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    // Parse each source file
    let lookupFiles: [String: SourceFileSyntax] = lookupSources.mapValues({ lookupSource in
      var parser = Parser(lookupSource.source)
      return SourceFileSyntax.parse(from: &parser)
    })
    // // Merger markers
    // let markersToNames = [Character: (source: String, index: String.Index, name: String, file: StaticString, line: UInt)]()
    // for (fileName, lookupSource) in lookupSources {
    //   for marker in lookupSource.markersToNames {
    //     guard markersToNames[]
    //   }
    // }

    /// A map from positions in the string to a list of references for the declaration at that location.

    /// IMPORTANT: Only use for `lookupSource.source` and `sourceFile`.
    func sourcePosition(of index: String.Index, in source: String) -> AbsolutePosition {
      AbsolutePosition(
        utf8Offset: source.distance(
          from: source.startIndex,
          to: index
        )
      )
    }

    // Find the expected nominal-type declaration and qualified-name string for each marker.
    var markerToType = [
      Character: (nominalDecl: NominalTypeDeclSyntax2, name: String, file: StaticString, line: UInt)
    ]()
    for (fileName, lookupSource) in lookupSources {
      let sourceString = lookupSource.source
      // Force-unwrapped because we just created `lookupFile` with the same `fileName`s
      let sourceFile = lookupFiles[fileName]!
      for (marker, sourceIndex, name, file, line) in lookupSource.markersAndNames {
        // The assertion expects this to be an introducer token (e.g, 'struct')
        guard let introducerToken = sourceFile.token(at: sourcePosition(of: sourceIndex, in: sourceString)) else {
          XCTFail(
            "[Internal Error] Unexpectedly couldn't find token for marker.",
            file: file,
            line: line
          )
          continue
        }

        // We expect the parent to be a nominal-type declaration
        guard let nominalDecl = introducerToken.parent?.as(NominalTypeDeclSyntax2.self) else {
          XCTFail(
            "Invalid marker placement: The parent of the token after the expectation isn't a nominal-type declaration; instead got parent kind '\(String(reflecting: introducerToken.parent?.kind))'.",
            file: file,
            line: line
          )
          continue
        }

        // Ensure we're not overwriting a previous marker
        guard markerToType[marker] == nil else {
          XCTFail(
            "Duplicate marker '\(marker)': Unexpectedly found the same marker for another nominal-type declaration.",
            file: file,
            line: line
          )
          continue
        }
        markerToType[marker] = (nominalDecl, name, file, line)
      }
    }

    // Perform lookup
    let symbolTable = SymbolTable3(moduleToSources: [Identifier(canonicalName: moduleName): lookupFiles])
    for (fileName, lookupSource) in lookupSources {
      // Create "fresh" type qualifier to avoid sharing state (which includes failures)
      var typeQualifier = TypeQualifier(symbolTable: symbolTable, configuredRegions: configuredRegions)

      let sourceString = lookupSource.source
      // Force-unwrapped because we just created `lookupFile` with the same `fileName`s
      let sourceFile = lookupFiles[fileName]!

      assertionLoop: for (sourceIndex, (expectedResult, file, line)) in lookupSource.positionsToExpectations {
        // We're looking for a token that's part of some type syntax
        guard let typeToken = sourceFile.token(at: sourcePosition(of: sourceIndex, in: sourceString)) else {
          XCTFail(
            "[Internal Error] Unexpectedly couldn't find token for marker.",
            file: file,
            line: line
          )
          continue
        }

        // Ensure the token's parent is a type syntax
        guard let typeSyntax = typeToken.parent?.as(TypeSyntax.self) else {
          XCTFail(
            "Invalid type-syntax expectation placement: A qualified-name expectation should be placed right before the target type syntax (parent is '\(String(reflecting: typeToken.parent?.kind))').",
            file: file,
            line: line
          )
          continue
        }

        /// Find the head type-syntax (because for instance `any Encodable & Decodable`
        /// contains the `Encodable & Decodable` nested type syntax)
        func findHeadTypeSyntax(of typeSyntax: TypeSyntax) -> TypeSyntax {
          // Cast the parent to type syntax, or return current type syntax
          guard let parentTypeSyntax = typeSyntax.parent?.as(TypeSyntax.self) else { return typeSyntax }
          // Find parent's head type syntax
          return findHeadTypeSyntax(of: parentTypeSyntax)
        }
        let targetTypeSyntax = findHeadTypeSyntax(of: typeSyntax)

        // Find the minimal-nominal type
        let expectedMarkers: [Character]
        let declsToNames: [NominalTypeDeclSyntax2: String]
        let lookupResultOrFailure: Result<MemberLookupResult<MinimalNominal>, TypeQualifier.Failure> =
          typeQualifier.resolveSyntax(typeSyntax: targetTypeSyntax)

        // Report errors
        if !typeQualifier.failures.isEmpty {
          XCTFail(
            "Type lookup generated errors: \(typeQualifier.failures).",
            file: file,
            line: line
          )
        }
        print(">>> Result: \(lookupResultOrFailure)")

        // Match success with success and failure with failure
        switch (expectedResult, lookupResultOrFailure) {
        case (.success(.memberResults(let markers)), .success(.memberResults(let nominalTypes))):
          expectedMarkers = markers
          // Map tuple to results
          var namesToDeclsTemporary = [NominalTypeDeclSyntax2: String]()
          for nominalType in nominalTypes {
            let nameDescription = nominalType.name.describe(describeFileID: { fileID in
              // Get name of first matching id
              for (fileName, file) in lookupFiles where file.id == fileID {
                return fileName
              }
              return fileID.hashValue.description
            })
            guard namesToDeclsTemporary[nominalType.mainDecl] == nil else { continue assertionLoop }
            namesToDeclsTemporary[nominalType.mainDecl] = nameDescription
          }
          declsToNames = namesToDeclsTemporary
        case (.success(let expectedLookupResult), .success(let lookupResult)):
          XCTAssertEqual(
            // We handled members above, so map to `Bool` to facilitate comparison.
            expectedLookupResult.mapMembers({ _ in false }),
            lookupResult.mapMembers({ _ in false }),
            "Mismatch in expetced type-qualifier lookup result and actual result.",
            file: file,
            line: line
          )
          continue
        case (.failure(let expectedFailure), .failure(let failure)):
          // TODO: Implement proper comparisons
          XCTAssertEqual(
            String(reflecting: expectedFailure),
            String(reflecting: failure),
            "Mismatch in expetced type-qualifier failure and actual failure.",
            file: file,
            line: line
          )
          continue
        default:
          XCTFail(
            "Type-qualifier lookup didn't succeed/fail as expected. Expected '\(expectedResult)'; got: '\(lookupResultOrFailure)'",
            file: file,
            line: line
          )
          continue
        }

        // Cross off matched markers
        var unmatchedResults = declsToNames
        for marker in expectedMarkers {
          // Get the expected nominal type and name
          guard let expected = markerToType[marker] else {
            XCTFail(
              "Undefined marker '\(marker)': The given marker isn't attached to any nominal-type declaration.",
              file: file,
              line: line
            )
            continue
          }

          // Cross off matched result
          guard let resultDeclName = unmatchedResults[expected.nominalDecl] else {
            XCTFail("Lookup didn't return expected nominal type at marker '\(marker)'.")
            continue
          }
          unmatchedResults[expected.nominalDecl] = nil

          // Check decl names match
          XCTAssertEqual(
            expected.name,
            resultDeclName,
            "Type lookup matched main declaration but gave invalid name '\(resultDeclName)'.",
            file: file,
            line: line
          )
        }

        // Diagnose unmatched
        for (name, nominalDecl) in unmatchedResults {
          XCTFail(
            "[Lookup Failure] Lookup `\(targetTypeSyntax.trimmedDescription)` found unexpected declaration named '\(name)' (main decl: ```\(nominalDecl)```)",
            file: file,
            line: line
          )
        }
      }
    }
  }

  func testSimpleCase() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      struct Hi {
        \("🟥", name: "_(MyFile.swift)::Hi._(MyFilee.swift)::A")struct A {
          static func f() -> \(references: "🟥")A {}
        }
      }
      """ as QualifiedTypeNameSource
    ])
  }

  // func testCodeBlockSimpleCase() {
  //   assertQualifiedTypeName([
  //     "MyFile.swift": """
  //     \("🟥", name: "MyModule::A")struct A {
  //       \("🟩", name: "MyModule::A.MyModule::B")struct B {
  //         static func f() -> \(references: "🟩")B {}
  //         static func makeSelf() -> \(references: "🟩")Self
  //       }
  //     }
  //     """ as QualifiedTypeNameSource
  //
  //       // """
  //       //   func anonymousScope() {
  //       //     let a: \(references: "🟥")A = self
  //       //     let me: \(references: "🟥")Self = self
  //       //
  //       //     🟦struct C {
  //       //       func f(c: \(references: "🟦")C) -> \(references: "🟦")Self {
  //       //         self as \(references: "🟦")Self
  //       //       }
  //       //     }
  //       //
  //       //     let c: C = \(references: "🟦")C()
  //       //   }
  //       //
  //       //   static var getA: \(references: "🟥")A { self }
  //       //   static func makeSelf() -> \(references: "🟥")Self {}
  //       //   static func makeB() -> \(references: "🟩")B {}
  //       //
  //       //   static func invalidRefToC() -> \(result: .memberResults([]))C {}
  //       // }
  //       //
  //       // func anonymousScope() {
  //       //   var a: \(result: .memberResults([]))Self
  //       //
  //       //   🟨struct A {
  //       //     subscript(a: \(references: "🟨")A) -> \(references: "🟨")Self { a }
  //       //   }
  //       //   enum D {}
  //       //
  //       //   var a: \(references: "🟨")A {}
  //       // }
  //       //
  //       // \(references: "🟥")A
  //       // \(result: .memberResults([]))B
  //       // \(result: .memberResults([]))D
  //       // """ as QualifiedTypeNameSource
  //   ])
  // }

  func assertIdentifierTypeLookup() {
    // assertTypeIdLookup("""
    // 🟥struct A {
    //   struct 🟩B {
    //     static func f() -> \("🟩")B {}
    //     static func makeSelf() -> \("🟩")Self
    //   }
    //
    //   func anonymousScope() {
    //     let a: \("🟥")A = self
    //     let me: \("🟥")Self = self
    //
    //     🟦struct C {
    //       func f(c: \("🟦")C) -> \("🟦")Self {
    //         self as \("🟦")Self
    //       }
    //     }
    //
    //     let c: C = \("🟦")C()
    //   }
    //
    //   static var getA: \("🟥")A { self }
    //   static func makeSelf() -> \("🟥")Self {}
    //   static func makeB() -> \("🟩")B {}
    //
    //   static func invalidRefToC() -> \(.noResults)C {}
    // }
    //
    // func anonymousScope() {
    //   var a: \(.noResults)Self
    //
    //   🟨struct A {
    //     subscript(a: \("🟨")A) -> \("🟨")Self { a }
    //   }
    //   enum D {}
    //
    //   var a: \("🟨")A {}
    // }
    //
    // \("🟥")A
    // \(.noResults)B
    // \(.noResults)D
    //
    // """)
    // assertTypeIdLookup("""
    // 🟧protocol Proto {
    //   struct 🟪B {
    //     static func f(b: \("🟪")B) -> \("🟪")Self {}
    //   }
    //   static func makeSelf() -> \("🟧")Self
    // }
    // \("🟧")Proto
    // \(.noResults)B
    // """)

  }
  // func testEnumCase() {
  //   assertTypeMemberLookup(
  //     """
  //     struct MyStruct {
  //       // We assume the user meant static functions (diagnosed elsewhere)
  //       case \(.named("case1").static())
  //            case1,
  //            \(.named("case2", args: ["a"]).static())
  //            case2(a: Int)
  //     }
  //     """
  //   )
  // }

  // TODO: Test lookup of an associated type and how it interacts with MyProto.Type, etc.

  // TODO: Test multiple variables/patterns and finding those, e.g., var a, b, c: Int {}, etc.

  // TODO: Test weird parameters: variadics (+packs) & trailing closures.

  // TODO: Test nested and non-nested (invalid) macro lookup
  // TODO: Test macro and non-`macro` attributes, e.g., actors, result builders, property wrappers

  // TODO: Test property wrapper lookup? (idk if it's in scope)

  // TODO: Test cycles, e.g. struct A { typealias Element = B.Element }; struct B { typealias Element = A }
  // typealias A = B; typealias B = A. Or protocol A: B {}; protocol B: A {}

  // TODO: Handle lookup in struct nested inside function, e.g. func hi() { struct Hello { var a }; Hello().a }

  // TODO: Think about isolation use cases? (That seems more like type checking)

  // TODO: Macro test, e.g. @freestanding macro noargsButCallable() = ...; #closure(args)
}
