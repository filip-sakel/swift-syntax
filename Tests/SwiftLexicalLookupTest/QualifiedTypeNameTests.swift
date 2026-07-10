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
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) @_spi(Experimental) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

// Convenience `String` initializer for `TypeLikeSyntax`
extension TypeLikeSyntax: ExpressibleByStringLiteral {
  public init(stringLiteral value: StringLiteralType) {
    self.init(TypeSyntax(stringLiteral: value))
  }
}

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

  /// The nominal type used in failures is a marker character that points
  /// to the actual nominal type declaration.
  // TODO: Could make the "ExtendedType" an array that includes the primary declaration & all the bound extensions
  typealias QualifierFailure = TypeQualifierFailure<Character, Character>

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
      result: Result<MemberLookupResult<Character>, QualifierFailure>,
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
      resultOrFailure: Result<MemberLookupResult<Character>, QualifierFailure>,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.references(result: resultOrFailure, file: file, line: line))
    }
    mutating func appendInterpolation(
      failure: QualifierFailure,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.references(result: .failure(failure), file: file, line: line))
    }
    mutating func appendInterpolation(
      result: MemberLookupResult<Character>,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.references(result: .success(result), file: file, line: line))
    }
    mutating func appendInterpolation(
      references markers: [Character],
      file: StaticString = #file,
      line: UInt = #line
    ) {
      appendInterpolation(result: .memberResults(markers), file: file, line: line)
    }
    mutating func appendInterpolation(
      reference marker: Character,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      appendInterpolation(references: [marker], file: file, line: line)
    }
  }

  /// The source with all markers removed
  let source: String
  /// A list of markers and names.
  let markersAndNames: [(marker: Character, index: String.Index, name: String, file: StaticString, line: UInt)]
  /// A map from positions in the string to the expected type-lookup result at that location.
  let positionsToExpectations:
    [String.Index: (
      markers: Result<MemberLookupResult<Character>, QualifierFailure>, file: StaticString, line: UInt
    )]

  init(stringInterpolation: Interpolation) {
    var source = ""
    var markersAndNames: [(marker: Character, index: String.Index, name: String, file: StaticString, line: UInt)] = []
    var positionsToExpectations:
      [String.Index: (
        markers: Result<MemberLookupResult<Character>, QualifierFailure>, file: StaticString, line: UInt
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

extension ResolvedNominalTypeReference {
  fileprivate static func _mockMarkerType(_ kind: SyntaxKind, marker: Character) -> ResolvedNominalTypeReference? {
    // Get the declaration kind
    let rawTypeDecl: DeclSyntax
    switch kind {
    case .structDecl: rawTypeDecl = "struct"
    case .enumDecl: rawTypeDecl = "enum"
    case .classDecl: rawTypeDecl = "class"
    case .actorDecl: rawTypeDecl = "actor"
    case .protocolDecl: rawTypeDecl = "protocol"
    default: return nil
    }
    let originatingSyntax: TypeSyntax = "\(raw: marker)"

    // We should only get type declarations
    let typeDecl = NominalTypeDeclSyntax(rawTypeDecl)!
    return ResolvedNominalTypeReference._mockMarkerType(
      mainDecl: typeDecl,
      originatingSyntax: originatingSyntax
    )
  }
}

final class TestQualifiedTypeName: XCTestCase {
  func assertQualifiedTypeName(
    _ lookupSources: [String: QualifiedTypeNameSource],
    moduleName: StaticString = "MyModule",
    configuredRegions: ConfiguredRegions? = nil,
    file: StaticString = #file,
    line: UInt = #line,
    verbose: Bool = false,
    assertSymbolTableState: (borrowing SymbolTable3) -> Void = { _ in }
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
      Character: (nominalDecl: NominalTypeDeclSyntax, name: String, file: StaticString, line: UInt)
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
        guard let nominalDecl = introducerToken.parent?.as(NominalTypeDeclSyntax.self) else {
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

    // Perform lookup
    let symbolTable = SymbolTable3(
      moduleToSources: [Identifier(canonicalName: moduleName): lookupFiles],
      configuredRegions: configuredRegions,
    )
    var typeQualifier = TypeQualifier(
      symbolTable: symbolTable,
      _verbose: verbose
    )
    for (fileName, lookupSource) in lookupSources {
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
        let targetTypeSyntax = findHeadTypeSyntax(of: typeSyntax)

        // Print target syntax (to show the syntax kinds)
        if verbose {
          print("Target syntax parsed as: \(targetTypeSyntax.debugDescription)")
        }

        // Find the minimal-nominal type
        let expectedMarkers: [Character]
        let declsToNames: [NominalTypeDeclSyntax: String]
        var typeResolutionDependencies = [ExtensionBindingResult.Dependency]()
        let lookupResultOrFailure: Result<MemberLookupResult<ResolvedNominalTypeReference>, TypeQualifier.Failure> =
          typeQualifier.resolveSyntax(
            typeSyntax: targetTypeSyntax,
            memberDependencies: &typeResolutionDependencies,
            visitedTypeSyntax: []
          )
        // _ = consume typeResolutionDependencies

        // Report result
        if verbose {
          print(">>> Result of `\(targetTypeSyntax.trimmedDescription)` lookup: \(lookupResultOrFailure)")
          print("Symbol table: \(symbolTable.debugDescription)\n")
        }

        // Match success with success and failure with failure
        switch (expectedResult, lookupResultOrFailure) {
        case (.success(.memberResults(let markers)), .success(.memberResults(let nominalTypes))):
          expectedMarkers = markers
          // Map tuple to results
          var namesToDeclsTemporary = [NominalTypeDeclSyntax: String]()
          for nominalType in nominalTypes {
            let nameDescription = describeQualifiedName(nominalType.qualifiedName)
            guard namesToDeclsTemporary[nominalType.mainDecl] == nil else { continue assertionLoop }
            namesToDeclsTemporary[nominalType.mainDecl] = nameDescription
          }
          declsToNames = namesToDeclsTemporary
        case (.success(let expectedLookupResult), .success(let lookupResult)):
          XCTAssertEqual(
            // We handled members above, so map to `Bool` to facilitate comparison.
            expectedLookupResult.mapMembers({ _ in false }),
            lookupResult.mapMembers({ _ in false }),
            "Mismatch in expetced type-qualifier lookup result of `\(targetTypeSyntax.trimmedDescription)` and actual result.",
            file: file,
            line: line
          )
          continue
        case (.failure(let expectedFailure), .failure(let failure)):
          // TODO: Implement proper comparisons
          let markerToQualifiedName = { (nominalMarker: Character) -> String in
            guard let nominalDecl = markerToType[nominalMarker] else { return "_" }
            return nominalDecl.name
          }
          let expectedFailureDescription = expectedFailure._describeDebug(
            resolveMininalNominal: markerToQualifiedName,
            resolveExtendedNominal: markerToQualifiedName
          )
          let failureDescription = failure._describeDebug(
            resolveMininalNominal: { describeQualifiedName($0.qualifiedName) },
            resolveExtendedNominal: { describeQualifiedName($0.qualifiedName) }
          )
          XCTAssertEqual(
            expectedFailureDescription,
            failureDescription,
            "Mismatch in expected type-qualifier failure and actual failure.",
            file: file,
            line: line
          )
          continue
        default:
          XCTFail(
            "Lookup of `\(targetTypeSyntax.trimmedDescription)` didn't succeed/fail as expected. Expected '\(expectedResult)'; got: '\(lookupResultOrFailure)'",
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
            XCTFail(
              "Lookup of `\(targetTypeSyntax.trimmedDescription)` didn't return expected nominal type at marker '\(marker)'.",
              file: file,
              line: line
            )
            continue
          }
          unmatchedResults[expected.nominalDecl] = nil

          // Check decl names match
          XCTAssertEqual(
            expected.name,
            resultDeclName,
            "Lookup of `\(targetTypeSyntax.trimmedDescription)` matched main declaration but gave invalid name '\(resultDeclName)'.",
            file: file,
            line: line
          )
        }

        // Diagnose unmatched
        for (name, nominalDecl) in unmatchedResults {
          XCTFail(
            "[Lookup Failure] Lookup of `\(targetTypeSyntax.trimmedDescription)` found unexpected declaration named '\(name)' (main decl: ```\(nominalDecl)```)",
            file: file,
            line: line
          )
        }
      }
    }
    // Assert symbolTable state after lookup
    assertSymbolTableState(symbolTable)
  }

  func testSimpleCase() {
    assertQualifiedTypeName(
      [
        "MyFile.swift": """
        \("🟥", name: "_(MyFile.swift)::A")
        struct A {
          static func f() -> \(reference: "🟥")A {}
          static func g() -> \(failure: .noTypeInScope)B {}
        }
        """ as QualifiedTypeNameSource
      ]
    )
  }

  // func testParseErrorResilience() {
  //   assertQualifiedTypeName(
  //     [
  //       "MyFile.swift": """
  //       \("🟥", name: "_(MyFile.swift)::A")
  //       struct A {}
  //
  //       \("🟩", name: "_(MyFile.swift)::`0`")
  //       struct 0 {
  //         typealias B = A
  //
  //         func f(_: \(reference: "🟩")`0`)
  //         func g(_: \(reference: "🟥")B)
  //       }
  //       """ as QualifiedTypeNameSource
  //     ],
  //     verbose: true
  //   )
  // }
  func testSimpleNestedCase() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::Hi")
      struct Hi {

        \("🟩", name: "_(MyFile.swift)::Hi._(MyFile.swift)::A")
        struct A {
          static func f() -> \(reference: "🟩")A {}
        }

      }
      func g(_: \(reference: "🟩")Hi.A)
      func h(_: \(reference: "🟥")Hi)
      """ as QualifiedTypeNameSource
    ])
  }

  // MARK: Simple Non Nominal
  func testSimpleFunction() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      typealias A = \(result: .function(argumentCount: 2))(_ a: Int, _ b: Int) -> Int
      """ as QualifiedTypeNameSource
    ])
  }
  func testSimpleTuple() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      func f(_: \(result: .tuple(labels: [Identifier(canonicalName: "a"), nil]))(a: Int, Bool))
      """ as QualifiedTypeNameSource
    ])
  }
  func testSimpleAnyType() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      func f(_: \(result: .anyType)Any)
      func g(_: \(result: .anyType)(Any & Any) & Any)
      """ as QualifiedTypeNameSource
    ])
  }
  /// "Empty types" are metatypes, named opaque types, and class restrictions
  /// that produce no types for lookup (and have no members).
  func testSimpleEmptyTypes() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      // Meta types
      struct A {}
      func f(_: \(references: [])A.Type)

      // Named opaque return types
      func g() -> <T> \(references: [])T { 1 }

      // Class restrictions
      protocol A: \(references: [])class {}
      """ as QualifiedTypeNameSource
    ])
  }

  /// Types that forward resolution to the underlying syntax, including
  /// some/any types, attributed types (e.g. `inout Int`), and pack
  /// element/expansion syntax.
  func testSimpleRecursiveTypes() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      // Any/some types forward to the underlying protocol (but we
      // don't actually check that the base type is a protocol)
      \("🟥", name: "_(MyFile.swift)::A")
      protocol A {}

      func f(_: \(references: ["🟥"])some A)
      func g(_: \(references: ["🟥"])any A)

      // Attributed types (and modifiers)
      func h(_: @escaping \(result: MemberLookupResult.function(argumentCount: 0))() -> Void)
      func i(_: sending \(references: ["🟥"])A)

      // Pack elements & expansions
      func f<each T>(_: \(failure: .genericParameterOrAssociatedType)(repeat each T)) {}
      """ as QualifiedTypeNameSource
    ])
  }

  // MARK: Generic Parameters & Associated Types
  func testSimpleGenericParameters() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      struct A<T> {
        func f(_: \(failure: .genericParameterOrAssociatedType)T)
      }
      protocol B {
        associatedtype U
        func g(_: \(failure: .invalidMembers([("U", .genericParameterOrAssociatedType)]))U)
      }
      """ as QualifiedTypeNameSource
    ])

  }

  // MARK: Aliases

  func testSimpleAlias() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      typealias A = \(reference: "🟥")B

      \("🟥", name: "_(MyFile.swift)::B")
      struct B {
        static func f() -> \(reference: "🟥")A {}
        static func g() -> \(reference: "🟥")B {}
      }
      func f() -> \(reference: "🟥")A {}
      func g() -> \(reference: "🟥")B {}
      """ as QualifiedTypeNameSource
    ])
  }

  func testNestedAlias() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::Outer")
      struct Outer {
        typealias B = \(reference: "🟩")A

        \("🟩", name: "_(MyFile.swift)::Outer._(MyFile.swift)::A")
        struct A {
          static func f() -> \(reference: "🟩")B {}
          static func g() -> \(reference: "🟩")B {}
        }
      }
      func f(_: \(reference: "🟩")Outer.A)
      func g(_: \(reference: "🟩")Outer.B)
      """ as QualifiedTypeNameSource
    ])
  }

  // MARK: Alias Cycles

  func testSimpleCycle() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A
      func f(_: \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))A)
      """ as QualifiedTypeNameSource
    ])
  }

  func testAliasesToCycle() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      // Cycle
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A
      // Non-cyclical references
      typealias C = B
      typealias D = C
      func f(_: \(failure: .invalidAliasedType(.invalidAliasedType(.cyclicalTypeReference(cycle: ["A", "B"]))))D)
      """ as QualifiedTypeNameSource
    ])
  }

  func testExtensionOfCycle() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      // Cycle
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A

      extension A {
        struct C {
          func f(_: \(failure: .invalidBaseType(.invalidBaseType(.cyclicalTypeReference(cycle: ["B", "A"]))))C)
          func g(_: \(failure: .invalidBaseType(.invalidBaseType(.cyclicalTypeReference(cycle: ["B", "A"]))))Self)
        }
        func h(_: \(failure: .invalidBaseType(.cyclicalTypeReference(cycle: ["B", "A"])))C)
      }
      """ as QualifiedTypeNameSource
    ])
  }

  func testNestedCycle() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A { typealias Element = B.Element }
      struct B { typealias Element = A.Element }

      func f(_: \(references: ["🟥"])A)
      func g(_: \(failure: .invalidMembers([("A.Element", .cyclicalTypeReference(cycle: ["B.Element", "A.Element"]))]))A.Element)
      """ as QualifiedTypeNameSource
    ])
  }

  // MARK: Compositions

  func testSimpleComposition() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      typealias C = \(references: ["🟥", "🟩"])A & B

      \("🟥", name: "_(MyFile.swift)::A")
      protocol A {}

      \("🟩", name: "_(MyFile.swift)::B")
      protocol B {}
      """ as QualifiedTypeNameSource
    ])
  }

  func testAnyTypeComposition() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}
      \("🟩", name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}
      func f(_: \(references: ["🟥"])(Any & ProtoA) & Any)
      func g(_: \(references: ["🟥", "🟩"])((ProtoB & Any) & Any) & ProtoB)
      """ as QualifiedTypeNameSource
    ])
  }

  func testNonnominalComposition() {
    assertQualifiedTypeName(
      [
        "MyFile.swift": """
        // Cannot compose non nominal types
        \("🟥", name: "_(MyFile.swift)::A")
        struct A {}

        struct B {}

        typealias A = \(failure: .invalidComposition([
          ("((A, B) -> Int)", .cannotComposeNonClassOrProtocol(resolved: .function(argumentCount: 2))),
          ("A", .cannotComposeNonClassOrProtocol(resolved: .memberResults(["🟥"]))),
        ]))
        ((A, B) -> Int) & A
        """ as QualifiedTypeNameSource
      ]
    )
  }

  func testDuplicateComposition() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}
      \("🟩", name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}
      func f(_: \(references: ["🟥"])ProtoA & Any & ProtoA)
      func g(_: \(references: ["🟥", "🟩"])(ProtoA & ProtoB) & ProtoA)
      """ as QualifiedTypeNameSource
    ])
  }
  // func testTupleComposition() {
  //   assertQualifiedTypeName([
  //     "MyFile.swift": """
  //     func f(_: \(result: .tuple(labels: [Identifier(canonicalName: "a"), nil]))(a: Int, Bool))
  //     """ as QualifiedTypeNameSource
  //   ])
  // }

  // MARK: Non-Nominal Members
  func testNonNominalMembers() {
    // A member "MyType"
    let myTypeMember = ImplicitTypeReferenceComponent(
      from: PartiallyResolvedTypeIdentifier.Component(
        module: nil,
        name: Identifier(canonicalName: "MyType"),
        introducingSyntax: "MyType"
      )
    )
    assertQualifiedTypeName([
      "MyFile.swift": """
      struct A {}
      struct B {}

      // Tuples, functions, and metatypes don't have type members
      var x: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.tuple(labels: [nil, nil])))(A, B).MyType
      var y: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.function(argumentCount: 1)))((A) -> B).MyType
      var z: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.memberResults([])))A.Type.MyType
      """ as QualifiedTypeNameSource
    ])
  }

  // MARK: Extensions

  func testSimpleExtension() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}

      extension A {
        \("🟩", name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {}
      }
      func f(_: \(references: ["🟩"])A.B)
      // Test that incremental binding still works with a second request
      func g(_: \(references: ["🟩"])A.B)
      """ as QualifiedTypeNameSource
    ])
  }
  func testTypeInExtension() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}

      extension A {
        \("🟩", name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {
          func f(_: \(references: ["🟩"])B)
        }
        func g(_: \(references: ["🟩"])B)
      }
      func h(_: \(references: ["🟩"])A.B)
      """ as QualifiedTypeNameSource
    ])
  }

  func testSimpleRecursiveExtension() {
    assertQualifiedTypeName([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}
      extension A.B { struct A {} }
      extension A { typealias B = A }

      func f(_: \(failure: .noTypeMember(member: ImplicitTypeReferenceComponent(from: PartiallyResolvedTypeIdentifier.Component(module: nil, name: Identifier(canonicalName: "A"), introducingSyntax: "A")), in: MemberLookupResult.memberResults(["🟥"])))A.A)
      """ as QualifiedTypeNameSource
    ])
  }
  // func testCrossFileExtension() {
  //   assertQualifiedTypeName([
  //     "FileA.swift": """
  //     \("🟥", name: "_(FileA.swift)::A")
  //     struct A {}
  //     func f(_: \(references: ["🟩"])A.B)
  //     """ as QualifiedTypeNameSource,
  //
  //     "FileB.swift": """
  //     extension A {
  //       \("🟩", name: "_(FileA.swift)::A._(FileB.swift)::B")
  //       struct B {}
  //     }
  //     func g(_: \(references: ["🟩"])A.B)
  //     """ as QualifiedTypeNameSource,
  //   ])
  // }

  // TODO: Test cycles

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

  // TODO: Add `AnyObject` test

  // TODO: Test lookup of an associated type and how it interacts with MyProto.Type, etc.

  // TODO: Test multiple variables/patterns and finding those, e.g., var a, b, c: Int {}, etc.

  // TODO: Test weird parameters: variadics (+packs) & trailing closures.

  // TODO: Test nested and non-nested (invalid) macro lookup
  // TODO: Test macro and non-`macro` attributes, e.g., actors, result builders, property wrappers

  // TODO: Test supertype cycles protocol A: B {}; protocol B: A {}

  // TODO: Handle lookup in struct nested inside function, e.g. func hi() { struct Hello { var a }; Hello().a }

  // TODO: Macro test, e.g. @freestanding macro noargsButCallable() = ...; #closure(args)

  // TODO: Test same-file redeclarations
  // e.g.
  // // FileA.swift
  // protocol A {}
  // struct A {}
  //
  // e.g.
  // func f() {
  //   struct A {}
  //   typealias A = Int
  // }

  // TODO: Aliased suppressed type test (base type / suppressed base type can be aliased & composed)
  // NOTE: Looks like this is SEMA (name lookup also diagnoses later)
  //   typealias A = Escapable
  //   struct B: ~A {}
  // Another legal program:
  //   typealias A = Hashable & ~Escapable & ~Copyable
  //   struct B: A {}
  //
  // Also failing test:
  //   typealias A = Encodable
  //   typealias B = ~A & Hashable // ❌ cannot suppress `Encodable`
  //   func f(b: B) {
  //     b.invalidProp // ✅ not diagnosed
  //   }
  //
  // Second failing test:
  //   typealias A = ~(Escapable & Copyable)
  // Third failing test:
  //   typealias A = Hashable & ~Escapable & ~Copyable
  //   struct B: ~A {}
  //
  // Fourth failing:
  //   typealias A = ~Sendable

  // TODO: Shadowing tests. Local; same file; same-mdoule, etc.

  // TODO: Diagnose compositions with `anyType`
  // e.g.
  //   protocol MyProto: ~Copyable {}
  //   extension MyProto & ~Copyable {} // ❌ error: non-nominal type 'MyProto & ~Copyable' cannot be extended
  //   extension MyProto & Any {} // ⚠️ extending a protocol composition is not supported; extending 'MyProto' instead

  // TODO: Test syntax resolution request in disabled `#if`
  // TODO: Test syntax resolution requesr with `ConfiguredRegions` across multiple files

  // TODO: Dependent extension tests
  //
  // Example A
  // ```swift
  // struct A {}
  // extension A.Inner {} // error: ambiguous type name 'Inner' in 'A'
  // extension A { typealias Inner = A }
  // extension A.Inner { // error: ambiguous type name 'Inner' in 'A'
  //     typealias Inner = Int //  error: invalid redeclaration of 'Inner'
  // }
  // ```
  // Example B
  //  <bug report>
  //
  // Example C (from docstrings)
  // ```
  // struct A {}
  // extension A.Inner {}
  // extension A { typealias A = Inner }
  // ```
  //
  // Example C (corrected?)
  // ```swiftc
  // struct C {}
  // struct A { typealias B = C }
  // extension A.B {} // Bind here
  // extension A { struct C {} }
  // ```
  //
  // Example D (with comments explaining rationale)
  //
  // ```swift
  // struct C {}
  // struct A { typealias B = C }
  //
  // // Finds A -> (MyFile.swift)::A with member `B`->`typealias B = C`
  // // Binds to (MyFile.swift)::C
  // //   Depending on `A` having no type member `C`
  // //   Introducing type member `typealias D = C`
  // extension A.B { typealias D = C }
  //
  // // Finds A -> (MyFile.swift)::A with member `B`->`typealias B = C`
  // // Resolves member `A.B` to (MyFile.swift)::C with type member `D`
  // // Resolves `A.B.D` to (MyFile.swift)::C
  // //   Depending on `C` having no type member `C
  // // Try to bind `extension A.B.D` to (MyFile.swift)::C
  // //   Introduces `struct C` violating dependence
  // extension A.B.D { struct C {} }
  // ```
  //
  // Example E (with rationale)
  //
  // ```swift
  // struct A {}
  // extension A.Inner {} // - error: extension of type 'A.Inner' (aka 'A') must be declared as an extension of 'A'
  // extension A.Outer { typealias Inner = Self }
  // extension A { typealias Outer = A }
  // ```
  // I think our method for find extended (MyFile.swift)::A would be:
  // 1. Visit `extension A.Inner`
  //    a. Resolve `A` to (MyFile.swift)::A
  //    b. Resolve extension to 'no member `Inner`' error
  //       1. Depends on type (MyFile.swift)::A > Inner
  // 2. Visit `extension A.Outer`
  //    a. Resolve `A` to (MyFile.swift)::A
  //    b. Resolve extension to 'no member `Outer`' error
  //       1. Depends on type (MyFile.swift)::A > Outer`
  // 3. Visit `extension A`
  //    a. Resolve `A` to (MyFile.swift)::A
  //    b. Bind to (MyFile.swift)::A
  //       1. No dependencies
  //    c. Update `extension A.Outer` [no dependency constraints]
  //       1. Resolve `A` to (MyFile.swift)::A
  //       2. Resolve `A.Outer` to (MyFile.swift)::A
  //          a. Depending on (MyFile.swift)::A having no member `A`
  //       3. Bind `extension A.Outer` to (MyFile.swift)::A
  //          a. Depending on (MyFile.swift)::A having no member `A`
  //          b. Introducing type member `Inner`
  //    d. Update `extension A.Inner` [implicit dependency: no member `A`]
  //       1. Resolve `A` to (MyFile.swift)::A
  //       2. Resolve `A.Inner` to (MyFile.swift)::A
  //          a. Depending on (MyFile.swift)::A having no member `Self`
  //       3. Bind `extension A.Inner` to (MyFile.swift)::A
  //          a. Depending on (MyFile.swift)::A having no members `Self`
  //          b. Introducing no members
  // // Assuming this turns out to be valid, what happens if we add an `extension A.Inner.Outer { typealias `Self` = Int }`
  //
  // Example F
  //
  // ```swift
  // struct A {}
  // struct B { typealias C = A } // error: type alias 'C' references itself
  // extension B.C {} // <- Bind here
  // struct D { typealias E = B.C }
  // extension B { typealias A = D.E }
  // ```
  //
  // Example G
  // ```swift
  // struct A {}
  // struct B { typealias C = A }
  // extension B.C {} // <- Bind here
  //           `- warning: warning: extending a protocol composition is not supported; extending 'A' instead
  // struct D { typealias E = B }
  // extension B { typealias A = D.E }
  // ```

}
