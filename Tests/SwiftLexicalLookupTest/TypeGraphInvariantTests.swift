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
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) import SwiftLexicalLookup
import SwiftParser
import SwiftSyntax
import XCTest

/// A hand-built, valid graph for the following file. Each test breaks one
/// invariant and checks `TypeGraph/_firstInvariantViolation` reports it.
private struct Fixture {
  typealias GlobalTypeName = TypeGraph.GlobalTypeName

  static let source = """
    struct A { struct Inner {} }
    extension A { typealias B = A }
    extension A.B { struct C {} }
    struct Unrelated {}
    """

  let symbolTable: SymbolTable
  let a, inner, unrelated: Attached<NominalTypeDeclSyntax>
  /// `extension A { typealias B = A }`
  let aliasExtension: Attached<ExtensionDeclSyntax>
  /// `extension A.B { struct C {} }`
  let aliasedExtension: Attached<ExtensionDeclSyntax>
  /// A nominal type and extension from a file that isn't in `symbolTable`.
  let foreignType: Attached<NominalTypeDeclSyntax>
  let foreignExtension: Attached<ExtensionDeclSyntax>

  let nameA = Fixture.name("A")
  let nameUnrelated = Fixture.name("Unrelated")

  var namesToTypes: [GlobalTypeName: TypeGraph.NominalType] = [:]
  var extensionsToState: [Attached<ExtensionDeclSyntax>: TypeGraph.ExtensionState] = [:]

  init() {
    let file = Parser.parse(source: Self.source)
    let module = Identifier(canonicalName: "MyModule")
    symbolTable = SymbolTable(
      moduleName: module,
      moduleToSources: [module: ["File.swift": file]],
      buildConfiguration: StaticBuildConfiguration(
        customConditions: [],
        languageVersion: VersionTuple(5, 5),
        compilerVersion: VersionTuple(6, 0)
      )
    )!
    let decls = file.statements.map(\.item)
    a = Attached(NominalTypeDeclSyntax(decls[0])!)!
    inner = Attached(NominalTypeDeclSyntax(decls[0].cast(StructDeclSyntax.self).memberBlock.members.first!.decl)!)!
    aliasExtension = Attached(decls[1].cast(ExtensionDeclSyntax.self))!
    aliasedExtension = Attached(decls[2].cast(ExtensionDeclSyntax.self))!
    unrelated = Attached(NominalTypeDeclSyntax(decls[3])!)!

    let foreignDecls = Parser.parse(source: "struct Foreign {}; extension Foreign {}").statements.map(\.item)
    foreignType = Attached(NominalTypeDeclSyntax(foreignDecls[0])!)!
    foreignExtension = Attached(foreignDecls[1].cast(ExtensionDeclSyntax.self))!

    namesToTypes = [
      nameA: type(
        a,
        boundExtensions: [aliasExtension, aliasedExtension],
        dependents: [dependent("B", aliasedExtension)]
      ),
      Fixture.name("A", "Inner"): type(inner),
    ]
    extensionsToState = [
      aliasExtension: state(),
      aliasedExtension: state(dependencies: [dependency("B", decls: [(aliasExtension, "B")])]),
    ]
  }

  /// The name of a type nested in `File.swift`, e.g. `name("A", "Inner")`.
  static func name(_ names: String...) -> GlobalTypeName {
    GlobalTypeName(_uncheckedInternalNames: names, fileID: "File.swift")
  }

  var violation: TypeGraph.GraphFailure? {
    TypeGraph(_uncheckedNamesToTypes: namesToTypes, extensionsToState: extensionsToState)
      ._firstInvariantViolation(symbolTable: symbolTable)
  }

  /// An identifier from the fixture's syntax tree.
  ///
  /// Note: `Identifier`'s synthesized hash includes its arena, so identifiers
  /// must come from the same tree to be found in the graph's type tables.
  func identifier(_ name: String) -> Identifier {
    Identifier(a.fileRoot.tokens(viewMode: .sourceAccurate).first(where: { $0.text == name })!)!
  }

  func type(
    _ mainDecl: Attached<NominalTypeDeclSyntax>,
    boundExtensions: [Attached<ExtensionDeclSyntax>] = [],
    dependents: [(memberType: Identifier, dependentExtension: Attached<ExtensionDeclSyntax>)] = []
  ) -> TypeGraph.NominalType {
    TypeGraph.NominalType(
      _uncheckedMainDecl: mainDecl,
      boundExtensions: boundExtensions.isEmpty ? [:] : [symbolTable.moduleName: boundExtensions],
      dependents: dependents
    )
  }

  func dependent(
    _ member: String,
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> (memberType: Identifier, dependentExtension: Attached<ExtensionDeclSyntax>) {
    (memberType: identifier(member), dependentExtension: extensionDecl)
  }

  /// A dependency on `baseTypeName` (default: `A`) > `member`, whose
  /// declarations are given as (introducing extension, member name) pairs.
  func dependency(
    on baseTypeName: GlobalTypeName? = nil,
    _ member: String,
    decls: [(Attached<ExtensionDeclSyntax>, String)]
  ) -> TypeGraph.ExtensionDependency {
    let memberDecls = decls.map({ (extensionDecl, name) in
      let typeDecl = extensionDecl.node.memberBlock.members.lazy
        .compactMap({ TypeDeclSyntax($0.decl) })
        .first(where: { $0.name.text == name })!
      return TypeGraph.ExtensionDependency.Member(
        introducingExtensionOrMainDecl: extensionDecl,
        typeDecl: Attached(typeDecl)!
      )
    })
    return TypeGraph.ExtensionDependency(
      dependencyTypeName: baseTypeName ?? nameA,
      members: [(name: identifier(member), decls: memberDecls)]
    )
  }

  /// An extension state resolved to `A`, unless `resolved` is `false`.
  func state(dependencies: [TypeGraph.ExtensionDependency] = [], resolved: Bool = true) -> TypeGraph.ExtensionState {
    TypeGraph.ExtensionState(
      _uncheckedDependencies: dependencies,
      resolvedType: resolved ? .success(nameA) : .failure(.noTypeInScope)
    )
  }
}

final class TypeGraphInvariantTests: XCTestCase {
  func testValidGraph() {
    XCTAssertNil(Fixture().violation)
  }

  // MARK: No readmission

  func testDuplicateMainDecl() {
    var fixture = Fixture()
    // Also admit `Inner` as a top-level type
    fixture.namesToTypes[Fixture.name("Inner")] = fixture.type(
      fixture.inner
    )
    XCTAssertEqual(fixture.violation, .duplicateMainDecl)
  }

  // MARK: Registered file roots

  func testTypeWithoutFileInfo() {
    var fixture = Fixture()
    fixture.namesToTypes[fixture.nameUnrelated] = fixture.type(
      fixture.foreignType
    )
    XCTAssertEqual(fixture.violation, .noFileInfo)
  }

  func testExtensionWithoutFileInfo() {
    var fixture = Fixture()
    fixture.extensionsToState[fixture.foreignExtension] = fixture.state(resolved: false)
    XCTAssertEqual(fixture.violation, .noFileInfo)
  }

  // MARK: Bound extensions

  func testDanglingExtension() {
    var fixture = Fixture()
    fixture.namesToTypes[fixture.nameA] = nil
    XCTAssertEqual(fixture.violation, .danglingExtension)
  }

  func testUnboundExtension() {
    var fixture = Fixture()
    fixture.namesToTypes[fixture.nameA] = fixture.type(
      fixture.a,
      boundExtensions: [fixture.aliasExtension],
      dependents: [fixture.dependent("B", fixture.aliasedExtension)]
    )
    XCTAssertEqual(fixture.violation, .unboundExtension)
  }

  func testMisboundExtension() {
    var fixture = Fixture()
    fixture.extensionsToState[fixture.aliasExtension] = fixture.state(resolved: false)
    XCTAssertEqual(fixture.violation, .misboundExtension)
  }

  // MARK: Dependencies and dependents match

  func testDuplicateDependency() {
    var fixture = Fixture()
    let dependencyOnB = fixture.dependency("B", decls: [(fixture.aliasExtension, "B")])
    fixture.extensionsToState[fixture.aliasedExtension] = fixture.state(dependencies: [dependencyOnB, dependencyOnB])
    XCTAssertEqual(fixture.violation, .duplicateDependency)
  }

  func testDanglingDependency() {
    var fixture = Fixture()
    fixture.extensionsToState[fixture.aliasExtension] = fixture.state(dependencies: [
      fixture.dependency(on: fixture.nameUnrelated, "B", decls: [])
    ])
    XCTAssertEqual(fixture.violation, .danglingDependency)
  }

  func testMissingDependent() {
    var fixture = Fixture()
    fixture.namesToTypes[fixture.nameA] = fixture.type(
      fixture.a,
      boundExtensions: [fixture.aliasExtension, fixture.aliasedExtension]
    )
    XCTAssertEqual(fixture.violation, .missingDependent)
  }

  func testMissingDependency() {
    var fixture = Fixture()
    fixture.namesToTypes[fixture.nameA] = fixture.type(
      fixture.a,
      boundExtensions: [fixture.aliasExtension, fixture.aliasedExtension],
      dependents: [fixture.dependent("B", fixture.aliasedExtension), fixture.dependent("B", fixture.aliasExtension)]
    )
    XCTAssertEqual(fixture.violation, .missingDependency)
  }

  // MARK: Extensions depend on type members

  func testStaleDependency() {
    var fixture = Fixture()
    // `A > B` is introduced by `aliasExtension`, but the dependency says it doesn't exist.
    fixture.extensionsToState[fixture.aliasedExtension] = fixture.state(dependencies: [
      fixture.dependency("B", decls: [])
    ])
    XCTAssertEqual(fixture.violation, .staleDependency)
  }

  // MARK: Nested types have parents

  func testNestedTypeNotAMember() {
    var fixture = Fixture()
    fixture.namesToTypes[Fixture.name("A", "Unrelated")] = fixture.type(
      fixture.unrelated
    )
    XCTAssertEqual(fixture.violation, .parentlessType)
  }

  func testNestedTypeWithoutAdmittedParent() {
    var fixture = Fixture()
    fixture.namesToTypes[Fixture.name("A", "Inner")] = nil
    fixture.namesToTypes[Fixture.name("Unrelated", "Inner")] = fixture.type(
      fixture.inner
    )
    XCTAssertEqual(fixture.violation, .parentlessType)
  }

  // MARK: No cycles

  func testDirectDependencyCycle() {
    var fixture = Fixture()
    // `aliasExtension` introduces `A > B` and depends on it.
    fixture.extensionsToState[fixture.aliasExtension] = fixture.state(dependencies: [
      fixture.dependency("B", decls: [(fixture.aliasExtension, "B")])
    ])
    fixture.namesToTypes[fixture.nameA] = fixture.type(
      fixture.a,
      boundExtensions: [fixture.aliasExtension, fixture.aliasedExtension],
      dependents: [fixture.dependent("B", fixture.aliasedExtension), fixture.dependent("B", fixture.aliasExtension)]
    )
    XCTAssertEqual(fixture.violation, .dependencyCycle)
  }

  func testTransitiveDependencyCycle() {
    var fixture = Fixture()
    // `aliasExtension` depends on `A > C` from `aliasedExtension`, which
    // depends on `A > B` from `aliasExtension`.
    fixture.extensionsToState[fixture.aliasExtension] = fixture.state(dependencies: [
      fixture.dependency("C", decls: [(fixture.aliasedExtension, "C")])
    ])
    fixture.namesToTypes[fixture.nameA] = fixture.type(
      fixture.a,
      boundExtensions: [fixture.aliasExtension, fixture.aliasedExtension],
      dependents: [fixture.dependent("B", fixture.aliasedExtension), fixture.dependent("C", fixture.aliasExtension)]
    )
    XCTAssertEqual(fixture.violation, .dependencyCycle)
  }
}
