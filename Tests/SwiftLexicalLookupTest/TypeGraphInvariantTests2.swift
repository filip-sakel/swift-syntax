import SwiftIfConfig
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) import SwiftLexicalLookup
import SwiftSyntax
import XCTest

// MARK: Helpers

final class TypeGraphInvariantTests2: XCTestCase {
  // Common types
  typealias Name = TypeGraph.GlobalTypeName
  typealias Nominal = TypeGraph.NominalType
  typealias Extension = TypeGraph.ExtensionState
  typealias Dependency = TypeGraph.ExtensionDependency

  /// The contents of the main file `FileA.swift`
  static let fileA: SourceFileSyntax = """
    // Top-level
    struct A {            // `structA`
      typealias B = A     // `typealiasB`
    }
    // Second top-level
    struct B {            // `structB`
      struct D {}         // `structD`
    }
    // Extensions
    extension A {}        // `extensionA`
    extension B {}        // `extensionB`
    extension A.B {       // `extensionAB`
      struct A {}         // `nestedStructA`
    }
    extension Unknown {}  // `extensionUnknown`
    """
  // Attached declarations we reference in the tests.
  let structA = fileA.attachedChildren(ofType: NominalTypeDeclSyntax.self)[0]
  let structB = fileA.attachedChildren(ofType: NominalTypeDeclSyntax.self)[1]
  let structD = fileA.attachedChildren(ofType: NominalTypeDeclSyntax.self)[2]
  let extensionA = fileA.attachedChildren(ofType: ExtensionDeclSyntax.self)[0]
  let extensionB = fileA.attachedChildren(ofType: ExtensionDeclSyntax.self)[1]
  let extensionAB = fileA.attachedChildren(ofType: ExtensionDeclSyntax.self)[2]
  let extensionUnknown = fileA.attachedChildren(ofType: ExtensionDeclSyntax.self)[3]
  // Members for dependencies
  let typealiasB = Dependency.Member(
    introducingExtensionOrMainDecl: nil,
    typeDecl: fileA.attachedChildren(ofType: TypeDeclSyntax.self)[1]
  )
  let nestedStructA = Dependency.Member(
    introducingExtensionOrMainDecl: fileA.attachedChildren(ofType: ExtensionDeclSyntax.self)[2],  // `extensionAB`
    typeDecl: fileA.attachedChildren(ofType: TypeDeclSyntax.self)[4]
  )

  /// The symbol table using the above files/declarations
  private let symbolTable: SymbolTable = SymbolTable(
    moduleName: "MyModule",
    moduleToSources: [
      "MyModule": [
        "FileA.swift": fileA,
        // Different file gives us more `[GlobalType]Name`s
        "FileB.swift": "",
      ]
    ],
    buildConfiguration: StaticBuildConfiguration(
      languageVersion: VersionTuple(6, 3, 1),
      compilerVersion: VersionTuple(6, 3, 1)
    )
  )!

  /// Assert the given graph referencing the above declarations produces the given
  /// `GraphFailure?` invariant violation.
  ///
  /// Notes:
  /// 1. Pass `expected: nil` if no invariant is violated.
  /// 2. Using a string-literal initializer, such as `Attached<NominalTypeDeclSyntax>(stringLiteral:)`,
  ///    gives a detached declaration.
  func assertInvariantViolation(
    expected: TypeGraph.GraphFailure?,
    graph: TypeGraph,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let actual = graph._firstInvariantViolation(symbolTable: symbolTable)
    XCTAssertEqual(
      expected,
      actual,
      "Expected invariant violation '\(expected.debugDescription)' but got '\(actual.debugDescription)'.",
      file: file,
      line: line
    )
  }
}

extension TypeGraph.ExtensionDependency {
  init(baseType nameDescription: String, members: [(name: Identifier, decls: [Member])]) {
    self.init(
      dependencyTypeName: TypeGraph.GlobalTypeName._mock(nameDescription: nameDescription),
      members: members
    )
  }
}

// MARK: Assertions

extension TypeGraphInvariantTests2 {
  func testDuplicateMainDecl() {
    assertInvariantViolation(
      expected: .duplicateMainDecl,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
          ),
          // Re-register `struct A {}` under different file
          Name._mock(nameDescription: "_(FileB.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
          ),
        ]
      )
    )
  }

  func testNoFileInfo() {
    assertInvariantViolation(
      expected: .noFileInfo,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            // As noted in the `assertInvariantViolation` docstring,
            // "struct A {}" below is detached.
            _uncheckedMainDecl: "struct A {}",
          )
        ]
      )
    )
  }

  func testDanglingExtension() {
    assertInvariantViolation(
      expected: .danglingExtension,
      graph: TypeGraph(
        extensionsToState: [
          // Extension points to unadmitted type
          extensionUnknown: Extension(
            dependencies: [],
            resolvedType: .success(Name._mock(nameDescription: "_(FileA.swift)::Unknown"))
          )
        ]
      )
    )
  }

  func testUnboundExtension() {
    assertInvariantViolation(
      expected: .unboundExtension,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admitted type doesn't reference extension
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
          )
        ],
        extensionsToState: [
          extensionUnknown: Extension(
            dependencies: [],
            resolvedType: .success(Name._mock(nameDescription: "_(FileA.swift)::A"))
          )
        ]
      )
    )
  }

  func testMisboundExtension() {
    // Test binding to invalid extension
    assertInvariantViolation(
      expected: .misboundExtension,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admitted type binds invalid extension
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
            boundExtensions: ["MyModule": [extensionUnknown]]
          )
        ],
        extensionsToState: [
          extensionUnknown: Extension(
            dependencies: [],
            resolvedType: .failure(.noTypeInScope)
          )
        ]
      )
    )
    // Test binding to other type's extension
    assertInvariantViolation(
      expected: .misboundExtension,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admitted type binds invalid extension
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
            boundExtensions: ["MyModule": [extensionB]]
          ),
          // Admit the other type (to avoid `.danglingExtension` and `.unboundExtension`)
          Name._mock(nameDescription: "_(FileA.swift)::B"): Nominal(
            _uncheckedMainDecl: structB,
            boundExtensions: ["MyModule": [extensionB]]
          ),
        ],
        extensionsToState: [
          extensionB: Extension(
            dependencies: [],
            resolvedType: .success(Name._mock(nameDescription: "_(FileA.swift)::B"))
          )
        ]
      )
    )
  }

  func testDuplicateDependency() {
    assertInvariantViolation(
      expected: .duplicateDependency,
      graph: TypeGraph(
        extensionsToState: [
          extensionAB: Extension(
            dependencies: [
              Dependency(baseType: "_(FileA.swift)::A", members: [("B", [])]),
              // Create new dependency for the same type as above
              Dependency(baseType: "_(FileA.swift)::A", members: [("C", [])]),
            ],
            // Use generic failure to avoid binding (binding surfaces more Invariants)
            resolvedType: .failure(.extensionNotBoundYet)
          )
        ]
      )
    )
  }

  func testDanglingDependency() {
    assertInvariantViolation(
      expected: .danglingDependency,
      graph: TypeGraph(
        extensionsToState: [
          extensionAB: Extension(
            dependencies: [
              // `_(FileA.swift)::A` is unadmitted
              Dependency(baseType: "_(FileA.swift)::A", members: [("B", [typealiasB])])
            ],
            // Use generic failure to avoid binding
            resolvedType: .failure(.extensionNotBoundYet)
          )
        ]
      )
    )
  }

  func testMissingDependent() {
    assertInvariantViolation(
      expected: .missingDependent,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admit type but don't register extension as dependent
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA
          )
        ],
        extensionsToState: [
          extensionAB: Extension(
            dependencies: [
              Dependency(baseType: "_(FileA.swift)::A", members: [("B", [typealiasB])])
            ],
            // Use generic failure to avoid binding
            resolvedType: .failure(.extensionNotBoundYet)
          )
        ]
      )
    )
  }

  func testMissingDependency() {
    assertInvariantViolation(
      expected: .missingDependency,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admit type and register dependent
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
            dependents: [("B", extensionAB)]
          )
        ],
        extensionsToState: [
          extensionAB: Extension(
            // No dependency
            dependencies: [],
            // Use generic failure to avoid binding
            resolvedType: .failure(.extensionNotBoundYet)
          )
        ]
      )
    )
  }

  func testStaleDependency() {
    assertInvariantViolation(
      expected: .staleDependency,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admit type and register dependent
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal(
            _uncheckedMainDecl: structA,
            dependents: [("B", extensionAB)]
          )
        ],
        extensionsToState: [
          extensionAB: Extension(
            dependencies: [
              // We say there are no declarations, but there's actually a `typealias B` member
              Dependency(
                dependencyTypeName: Name._mock(nameDescription: "_(FileA.swift)::A"),
                members: [(name: "B", decls: [])]
              )
            ],
            // Use generic failure to avoid binding
            resolvedType: .failure(.extensionNotBoundYet)
          )
        ]
      )
    )
  }

  func testParentlessType() {
    assertInvariantViolation(
      expected: .parentlessType,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admit nested type but no parent
          Name._mock(nameDescription: "_(FileA.swift)::B", "_(FileA.swift)::D"): Nominal(
            _uncheckedMainDecl: structD
          )
        ]
      )
    )
  }

  func testDependencyCycle() {
    assertInvariantViolation(
      expected: .dependencyCycle,
      graph: TypeGraph(
        _uncheckedNamesToTypes: [
          // Admit a type that binds an extension dependent on it (cyclical)
          Name._mock(nameDescription: "_(FileA.swift)::A"): Nominal.init(
            _uncheckedMainDecl: structA,
            boundExtensions: ["MyModule": [extensionAB]],
            dependents: [("B", extensionAB), ("A", extensionAB)]
          )
        ],
        extensionsToState: [
          extensionAB: Extension(
            dependencies: [
              Dependency(
                baseType: "_(FileA.swift)::A",
                // The `_(FileA.swift)::A > A` member resolves to the
                // `nestedStructA` declaration to avoid a `staleDependency` violation
                members: [(name: "B", decls: [typealiasB]), (name: "A", decls: [nestedStructA])]
              )
            ],
            resolvedType: .success(Name._mock(nameDescription: "_(FileA.swift)::A"))
          )
        ]
      )
    )
  }
}
