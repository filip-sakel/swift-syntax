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
import SwiftSyntax
import XCTest

final class TypeResolutionTests: XCTestCase {
  func testSimpleCase() {
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(name: "_(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "_(MyFile.swift)::A")A {}
          static func g() -> \(failure: .noTypeInScope)B {}
        }
        """ as LexicalLookupSource
      ]
    )
  }

  func testSimpleNestedCase() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::A")
      struct A {

        \(name: "_(MyFile.swift)::A._(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::A")A {}
        }

      }
      func g(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::A")A.A)
      func h(_: \(nominal: "_(MyFile.swift)::A")A)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Simple Non Nominal
  func testSimpleFunction() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(failure: .partialTypeResolutionFailure(.functionType))(_ a: Int, _ b: Int) -> Int
      """ as LexicalLookupSource
    ])
  }
  func testSimpleTuple() {
    assertTypeResolution([
      "MyFile.swift": """
      func f(_: \(type: .tuple(labels: [Identifier(canonicalName: "a"), nil]))(a: Int, Bool))
      """ as LexicalLookupSource
    ])
  }
  func testSimpleAnyType() {
    assertTypeResolution([
      "MyFile.swift": """
      func f(_: \(type: .anyType)Any)
      func g(_: \(type: .anyType)(Any & Any) & Any)
      """ as LexicalLookupSource
    ])
  }
  /// "Empty types" are metatypes, named opaque types, and class restrictions
  /// that produce no types for lookup (and have no members).
  func testSimpleEmptyTypes() {
    assertTypeResolution([
      "MyFile.swift": """
      // Meta types
      \(name: "_(MyFile.swift)::A")
      struct A {}

      func f(_: \(type: .metatype(base: .nominalTypes(["_(MyFile.swift)::A"])))A.Type)

      // Named opaque return types
      func g() -> <T> \(nominals: [])T { 1 }

      // Class restrictions
      protocol B: \(nominals: [])class {}
      """ as LexicalLookupSource
    ])
  }

  /// Types that forward resolution to the underlying syntax, including
  /// some/any types, attributed types (e.g. `inout Int`), and pack
  /// element/expansion syntax.
  func testSimpleForwardingTypes() {
    assertTypeResolution([
      "MyFile.swift": """
      // Any/some types forward to the underlying protocol (but we
      // don't actually check that the base type is a protocol)
      \(name: "_(MyFile.swift)::A")
      protocol A {}

      func f(_: \(nominal: "_(MyFile.swift)::A")some A)
      func g(_: \(nominal: "_(MyFile.swift)::A")any A)

      // Attributed types (and modifiers)
      func h(_: @escaping \(failure: .partialTypeResolutionFailure(.functionType))() -> Void)
      func i(_: sending \(nominal: "_(MyFile.swift)::A")A)

      // Pack elements & expansions
      func f<each T>(_: \(failure: .genericParameterOrAssociatedType)(repeat each T)) {}
      """ as LexicalLookupSource
    ])
  }

  // MARK: Generic Parameters & Associated Types
  func testSimpleGenericParameters() {
    assertTypeResolution([
      "MyFile.swift": """
      struct A<T> {
        func f(_: \(failure: .genericParameterOrAssociatedType)T)
      }
      protocol B {
        associatedtype U
        func g(_: \(failure: .invalidMembers([("U", .genericParameterOrAssociatedType)]))U)
      }
      """ as LexicalLookupSource
    ])

  }

  // MARK: Local Types
  func testSimpleLocalTypes() {
    let structA = TypeResolver.ResolvedTypeSyntax.local("struct A {}")
    let structB = TypeResolver.ResolvedTypeSyntax.local("struct B {}")

    assertTypeResolution([
      "MyFile.swift": """
      func f() {
        let a: \(nominal: structA)A
        let b: \(nominal: structB)A.B
        let invalidB: \(failure: .noTypeInScope)B

        \(name: structA)
        struct A {
          let a: \(nominal: structA)A
          let b: \(nominal: structB)B

          \(name: structB)
          struct B {
            let a: \(nominal: structA)A
            let b: \(nominal: structB)B
          }

          let a: \(nominal: structA)A
          let b: \(nominal: structB)B
        }

        let a: \(nominal: structA)A
        let b: \(nominal: structB)A.B
        let invalidB: \(failure: .noTypeInScope)B
      }
      """
    ])
  }

  // MARK: Redeclarations

  func testSimpleRedeclarations() {
    assertTypeResolution([
      "MyFile.swift": """
      protocol A {}
      struct A {}

      let _: \(failure: .ambiguousTypeDecl(["protocol A {}", "struct A {}"]))A

      func f() {
        enum A {}
        typealias A = ()

        let _: \(failure: .ambiguousTypeDecl(["enum A {}", "typealias A = ()"]))A
      }
      """ as LexicalLookupSource
    ])
  }

  func testRedeclarationAcrossExtensions() {
    assertTypeResolution([
      "MyFile.swift": """
      struct A { struct B {} }
      extension A { struct B {} }

      let _: \(failure: .invalidMembers(
          [("A.B", .ambiguousTypeDecl(["struct B {}", "struct B {}"]))]
        ))A.B
      """
    ])
  }

  // MARK: If Config
  func testIfConfig() {
    let baseSourceInterpolation: LexicalLookupSource<TypeResolutionMatcher>.Interpolation = """
      \(name: "_(MyFile.swift)::A")
      struct A {}
      \(name: "_(MyFile.swift)::B")
      struct B {}
      \(name: "_(MyFile.swift)::C")
      struct C {}
      \(name: "_(MyFile.swift)::D")
      struct D {}

      #if FlagA
      extension A {
        #if !FlagB
        typealias T = A
        #else
        typealias T = B
        #endif
      }
      #elseif FlagB
      typealias AliasedA = A
      extension AliasedA {
        #if FlagC
        typealias T = C
        #endif
        #if FlagD
        typealias T = D
        #endif
      }
      #endif
      """

    func flagsConfig(_ flags: Set<String>) -> StaticBuildConfiguration {
      StaticBuildConfiguration(
        customConditions: flags,
        languageVersion: VersionTuple(6),
        compilerVersion: VersionTuple(6, 2)
      )
    }
    let memberT = TypeReference(
      name: Identifier(canonicalName: "T"),
      introducingSyntax: "T"
    )

    // We'll look up `A.T` with different flags
    //
    // Flags: FlagA => `struct A`
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(nominal: "_(MyFile.swift)::A")A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagA"]),
      verbose: true
    )
    // Flags: FlagA, FlagB => `struct B`
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(nominal: "_(MyFile.swift)::B")A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagA", "FlagB"])
    )
    // Flags: FlagB => no member
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(failure: .noTypeMember(member: memberT, in: .nominalTypes(["_(MyFile.swift)::A"])))A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagB"]),
      verbose: true
    )
    // Flags: FlagB, FlagC => `struct C`
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(nominal: "_(MyFile.swift)::C")A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagB", "FlagC"])
    )
    // Flags: FlagB, FlagD => `struct D`
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(nominal: "_(MyFile.swift)::D")A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagB", "FlagD"])
    )
    // Flags: FlagB, FlagC, FlagD => ambiguity between `typealias T = C` & `typealias T = D`
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(interpolation: baseSourceInterpolation)

        let _: \(failure: .invalidMembers(
          [("A.T", .ambiguousTypeDecl(["typealias T = C", "typealias T = D"]))]
        ))A.T
        """
      ],
      buildConfiguration: flagsConfig(["FlagB", "FlagC", "FlagD"])
    )
  }

  // MARK: Aliases

  func testSimpleAlias() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(nominal: "_(MyFile.swift)::B")B

      \(name: "_(MyFile.swift)::B")
      struct B {
        static func f() -> \(nominal: "_(MyFile.swift)::B")A {}
        static func g() -> \(nominal: "_(MyFile.swift)::B")B {}
      }
      func f() -> \(nominal: "_(MyFile.swift)::B")A {}
      func g() -> \(nominal: "_(MyFile.swift)::B")B {}
      """ as LexicalLookupSource
    ])
  }

  func testNestedAlias() {
    assertTypeResolution([
      "MyFile.swift": """
      struct Outer {
        typealias B = \(nominal: "_(MyFile.swift)::Outer._(MyFile.swift)::A")A

        \(name: "_(MyFile.swift)::Outer._(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "_(MyFile.swift)::Outer._(MyFile.swift)::A")B {}
          static func g() -> \(nominal: "_(MyFile.swift)::Outer._(MyFile.swift)::A")B {}
        }
      }
      func f(_: \(nominal: "_(MyFile.swift)::Outer._(MyFile.swift)::A")Outer.A)
      func g(_: \(nominal: "_(MyFile.swift)::Outer._(MyFile.swift)::A")Outer.B)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Alias Cycles

  func testSimpleCycles() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A
      func f(_: \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))A)

      // Self referencing alias
      typealias C = \(failure: .cyclicalTypeReference(cycle: ["C"]))C
      func g(_: \(failure: .cyclicalTypeReference(cycle: ["C"]))C)
      """ as LexicalLookupSource
    ])
  }

  func testAliasesToCycle() {
    assertTypeResolution([
      "MyFile.swift": """
      // Cycle
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A
      // Non-cyclical references
      typealias C = B
      typealias D = C
      func f(_: \(failure: .invalidAliasedType(.invalidAliasedType(.cyclicalTypeReference(cycle: ["A", "B"]))))D)
      """ as LexicalLookupSource
    ])
  }

  func testExtensionOfCycle() {
    assertTypeResolution([
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
      """ as LexicalLookupSource
    ])
  }

  func testNestedCycle() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::A")
      struct A { typealias Element = B.Element }
      struct B { typealias Element = A.Element }

      func f(_: \(nominal: "_(MyFile.swift)::A")A)
      func g(_: \(failure: .invalidMembers([("A.Element", .cyclicalTypeReference(cycle: ["B.Element", "A.Element"]))]))A.Element)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Compositions

  func testSimpleComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias C = \(nominals: ["_(MyFile.swift)::A", "_(MyFile.swift)::B"])A & B

      \(name: "_(MyFile.swift)::A")
      protocol A {}

      \(name: "_(MyFile.swift)::B")
      protocol B {}
      """ as LexicalLookupSource
    ])
  }

  func testAnyTypeComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}

      \(name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}

      let x: \(nominal: "_(MyFile.swift)::ProtoA")
        (Any & ProtoA) & Any & ProtoA

      let y: \(nominals: ["_(MyFile.swift)::ProtoA", "_(MyFile.swift)::ProtoB"])
        ((ProtoA & Any) & Any) & ProtoB
      """ as LexicalLookupSource
    ])
  }

  func testNonnominalComposition() {
    assertTypeResolution(
      [
        "MyFile.swift": """
        // Cannot compose non nominal types
        \(name: "_(MyFile.swift)::A")
        struct A {}

        struct B {}

        typealias C = \(failure: .invalidComposition([
          ("((A, B) -> Int)", .partialTypeResolutionFailure(.functionType)),
          ("A", .cannotComposeNonClassOrProtocol(resolved: .nominalTypes(["_(MyFile.swift)::A"]))),
        ]))
        ((A, B) -> Int) & A
        """ as LexicalLookupSource
      ]
    )
  }

  func testSelfReferencingAlias() {
    assertTypeResolution(
      [
        "MyFile.swift": """
        struct A {}

        // type alias 'A' references 'A' in its initializer
        typealias A = \(failure: .invalidComposition([
          ("A", .ambiguousTypeDecl(["struct A {}", "typealias A = A & ~Escapable"])),
        ]))A & ~Escapable
        """ as LexicalLookupSource
      ]
    )
  }

  func testDuplicateComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}
      \(name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}

      func f(_: \(nominal: "_(MyFile.swift)::ProtoA")ProtoA & Any & ProtoA)

      func g(_: \(nominals: ["_(MyFile.swift)::ProtoA", "_(MyFile.swift)::ProtoB"])(ProtoA & ProtoB) & ProtoA)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Non-Nominal Members
  func testNonNominalMembers() {
    // A member "MyType"
    let myTypeMember = TypeReference(
      name: "MyType",
      introducingSyntax: "MyType"
    )
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::A")
      struct A {}
      struct B {}

      // Tuples, functions, and metatypes don't have type members
      var x: \(failure: .noTypeMember(member: myTypeMember, in: .tuple(labels: [nil, nil])))
             (A, B).MyType
      var y: \(failure: .partialTypeResolutionFailure(.functionType))
             ((A) -> B).MyType
      var z: \(failure: .noTypeMember(member: myTypeMember, in: .metatype(base: .nominalTypes(["_(MyFile.swift)::A"]))))
             A.Type.MyType
      """ as LexicalLookupSource
    ])
  }

  // MARK: `Self`
  func testTopLevelSelf() {
    assertTypeResolution([
      "MyFile.swift": """
      func f() { let _: \(failure: .noTypeInScope)Self }
      """
    ])
  }

  func testLocalTopLevelSelf() {
    assertTypeResolution([
      "MyFile.swift": """
      func f() {
        func g() { let _: \(failure: .noTypeInScope)Self }
        \(name: .local("struct A {}"))
        struct A {
          // Add expectation here
          func h() { let _: Self }
        }
      }
      """
    ])
    // TODO: Add the following lookup expectation inside `struct A` when `Self`
    // is fixed. Currently fails because unqualified lookup emits implicit
    // `Self` only inside protocols/extensions to match ASTScope behavior.
    // ```
    // func h() { let _: \(nominal: .local("A"))Self }
    // ```
  }

  // MARK: Extensions

  func testSimpleExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      struct A {}

      extension A {
        \(name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {}
      }
      func f(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::B")A.B)
      // Test that incremental binding still works with a second request
      func g(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::B")A.B)
      """ as LexicalLookupSource
    ])
  }

  func testExtendedType() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA: ~Copyable {}

      // Tuple
      \(extensionState: ExtensionState(
        dependencies: [],
        resolvedType: .failure(.cannotExtendNonNominal(nonnominal: .tuple(labels: [])))
      ))
      extension () {}

      // Metatype
      typealias Metatype = ProtoA.Type
      \(extensionState: ExtensionState(
        dependencies: [],
        resolvedType: .failure(.cannotExtendNonNominal(
          nonnominal: .metatype(base: .nominalTypes(["_(MyFile.swift)::ProtoA"]))
        ))
      ))
      extension Metatype {}

      // Any
      \(extensionState: ExtensionState(
        dependencies: [],
        resolvedType: .failure(.cannotExtendNonNominal(nonnominal: .anyType))
      ))
      extension Any & ~Escapable {}

      // Valid Compositions
      //
      // We defer diagnostics to SEMA
      \(extensionState: .bound(dependencies: [], typeName: "_(MyFile.swift)::ProtoA"))
      extension ProtoA & ~Copyable {}

      typealias ProtoAndAny = ProtoA & Any
      \(extensionState: .bound(dependencies: [], typeName: "_(MyFile.swift)::ProtoA"))
      extension ProtoAndAny {}

      // Invalid Compositions
      \(name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}

      \(extensionState: ExtensionState(
        dependencies: [],
        resolvedType: .failure(.cannotExtendNonNominal(nonnominal: .nominalTypes([
          "_(MyFile.swift)::ProtoA", "_(MyFile.swift)::ProtoB"
        ])))
      ))
      extension ProtoA & ProtoB {}
      """
    ])
  }
  func testTypeInExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      struct A {}

      extension A {
        \(name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {
          func f(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::B")B)
        }
        func g(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::B")B)
      }
      func h(_: \(nominal: "_(MyFile.swift)::A._(MyFile.swift)::B")A.B)
      """ as LexicalLookupSource
    ])
  }

  func testSimpleRecursiveExtension() {
    assertTypeResolution(
      [
        "MyFile.swift": """
        \(name: "_(MyFile.swift)::A")
        struct A {}

        \(extensionState: .invalidCycle(
          dependencies: [
            // We evidently depend on `A.B`. We also depend on `_(MyFile.swift)::A`
            // not having a type member `A` to that `typealias B = A` resolves to `A`.
            ExtensionDependency(baseType: "_(MyFile.swift)::A", members: ["B", "A"]),
          ],
          // This extension violates its own dependency
          cycleElements: [],
          // I.e. `struct A`
          conflictingMember: "A"
        ))
        extension A.B { struct A {} }

        extension A { typealias B = A }
        """ as LexicalLookupSource
      ]
    )
  }
  // FIXME: Add expectations
  func testRedeclarationWithRecursiveExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      \(name: "_(MyFile.swift)::A")
      struct A {}

      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(MyFile.swift)::A", members: ["B", "A"])],
        typeName: "_(MyFile.swift)::A"
      ))
      extension A.B {}

      \(extensionState: .bound(dependencies: [], typeName: "_(MyFile.swift)::A"))
      extension A { typealias B = A }

      \(extensionState: .invalidCycle(
        dependencies: [ExtensionDependency(baseType: "_(MyFile.swift)::A", members: ["B", "A"])],
        cycleElements: [],
        conflictingMember: "B"
      ))
      extension A.B { typealias B = OtherType }
      """ as LexicalLookupSource
    ])
  }

  func testPathologicalN3() {
    // When debugging this by logging the graph's state, remember
    // that we start binding extensions at `\(extensionState: ...)` expectations.
    // So in the following example, we admit `extension T_0.Last` first (not
    // `extension T_0`), and continue from there.
    assertTypeResolution([
      "File.swift": """
      \(name: "_(File.swift)::T_0")
      struct T_0 {}
      \(name: "_(File.swift)::T_1")
      struct T_1 {}
      \(name: "_(File.swift)::T_2")
      struct T_2 {}
      \(name: "_(File.swift)::T_3")
      struct T_3 {}

      extension T_0 { typealias Last = T_3 }


      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_0", members: ["Last", "T_3"])],
        typeName: "_(File.swift)::T_3",
      ))
      extension T_0.Last { typealias Prev = T_2 }


      // j=3
      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_3", members: ["Prev", "T_2"])],
        typeName: "_(File.swift)::T_2",
      ))
      extension T_3.Prev { typealias Prev = T_1 }


      // j=2
      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_2", members: ["Prev", "T_1"])],
        typeName: "_(File.swift)::T_1"
      ))
      extension T_2.Prev { typealias Prev = T_0 }

      \(extensionState: .invalidCycle(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::T_1", members: ["Prev", "T_0"])
        ],
        cycleElements: [
          (introducingDecl: "typealias Prev = T_0", extension: "extension T_2.Prev {}", base: "_(File.swift)::T_1"),
          (introducingDecl: "typealias Prev = T_1", extension: "extension T_3.Prev {}", base: "_(File.swift)::T_2"),
          (introducingDecl: "typealias Prev = T_2", extension: "extension T_0.Last {}", base: "_(File.swift)::T_3"),
        ],
        conflictingMember: "T_3"
      ))
      extension T_1.Prev { struct T_3 {} }
      """
    ])
  }
  /// Same as `testPathologicalN3` but the last extension actually removes all
  /// cycles.
  func testFixedPathologicalN3() {
    assertTypeResolution([
      "File.swift": """
      \(name: "_(File.swift)::T_0")
      struct T_0 {}
      \(name: "_(File.swift)::T_1")
      struct T_1 {}
      \(name: "_(File.swift)::T_2")
      struct T_2 {}
      \(name: "_(File.swift)::T_3")
      struct T_3 {}

      extension T_0 { typealias Last = T_3 }

      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_0", members: ["Last", "T_3"])],
        typeName: "_(File.swift)::T_3"
      ))
      extension T_0.Last { typealias Prev = T_2 }

      // j=3
      extension T_3.Prev { typealias Prev = T_1 }

      // j=2
      extension T_2.Prev { typealias Prev = T_0 }

      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_1", members: ["Prev", "T_0"])],
        typeName: "_(File.swift)::T_1._(File.swift)::T_0"
      ))
      extension T_1.Prev { struct T_3 {} }

      extension T_1 {
        \(name: "_(File.swift)::T_1._(File.swift)::T_0")
        struct T_0 {}
      }
      """
    ])
  }

  /// Similar to pathological n=3 above, but for any `n`
  func testPathologicalArbitrary() {
    typealias GlobalTypeRef = TypeGraph.GlobalTypeRef
    typealias GlobalTypeName = TypeGraph.GlobalTypeName
    typealias ResolvedTypeSyntax = TypeResolver.ResolvedTypeSyntax

    let n = 20
    precondition(n >= 2, "Pathological case requires `n` of at least 2.")

    var lookupSource = LexicalLookupSource<TypeResolutionMatcher>.Interpolation()

    // Add the type definitions: struct T_0, ..., struct T_N
    for i in 0...n {
      lookupSource.appendInterpolation(name: ResolvedTypeSyntax(stringLiteral: "_(File.swift)::T_\(i)"))
      lookupSource.appendLiteral("struct T_\(i) {}")
    }
    lookupSource.appendLiteral("\n")

    // Link to the last type
    lookupSource.appendInterpolation(
      extensionState: .bound(
        dependencies: [],
        typeName: GlobalTypeName(stringLiteral: "_(File.swift)::T_0")
      )
    )
    lookupSource.appendLiteral(
      """
      extension T_0 { typealias Last = T_\(n) }
      extension T_0.Last { typealias Prev = T_\(n-1) }

      """
    )

    // Link all the way back to T_N.Prev > T_{N-2} ..to.. T_2.Prev > T_0
    for i in stride(from: n, to: 1, by: -1) {
      lookupSource.appendInterpolation(
        extensionState: .bound(
          dependencies: [
            ExtensionDependency(
              baseType: GlobalTypeName(stringLiteral: "_(File.swift)::T_\(i)"),
              members: [
                "Prev",
                // 'T_{i-1}'
                // Since it's created dynamically, it can't be a static string so
                // we must allocate it in `lookupSource` to retain the allocation.
                IdentifierWrapper(string: "T_\(i-1)", allocatingIn: &lookupSource),
              ]
            )
          ],
          typeName: GlobalTypeName(stringLiteral: "_(File.swift)::T_\(i-1)")
        )
      )
      lookupSource.appendLiteral(
        """
        extension T_\(i).Prev { typealias Prev = T_\(i-2) }

        """
      )
    }

    // Introduce (and check for) the cycle
    var cycleElements: [(introducingDecl: String?, extension: String, base: GlobalTypeRef)] = (0..<n - 1).map({ i in
      (
        introducingDecl: "typealias Prev = T_\(i)", extension: "extension T_\(i+2).Prev {}",
        base: GlobalTypeRef(stringLiteral: "_(File.swift)::T_\(i+1)")
      )
    })
    cycleElements.append(
      (
        introducingDecl: "typealias Prev = T_\(n-1)" as String?,
        extension: "extension T_0.Last {}",
        base: GlobalTypeRef(stringLiteral: "_(File.swift)::T_\(n)")
      )
    )
    lookupSource.appendInterpolation(
      extensionState: ExtensionState.invalidCycle(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::T_1", members: ["Prev", "T_0"])
        ],
        cycleElements: cycleElements,
        conflictingMember: IdentifierWrapper(string: "T_\(n)", allocatingIn: &lookupSource)
      )
    )
    lookupSource.appendLiteral(
      """
      extension T_1.Prev { struct T_\(n) {} }
      """
    )

    assertTypeResolution([
      "File.swift": LexicalLookupSource<TypeResolutionMatcher>(stringInterpolation: lookupSource)
    ])
  }

  func testExtensionDoubleNestedTypes() {
    assertTypeResolution([
      "File.swift": """
      \(name: "_(File.swift)::A")
      struct A { typealias B = A }

      // Last extension makes `A.B` resolves to `A.A`
      \(extensionState: .bound(
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::A", members: ["B", "A"])],
        typeName: "_(File.swift)::A._(File.swift)::A"
      ))
      extension A.B {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C")
        struct C {
          \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D")
          struct D {}
        }
      }

      \(extensionState: .bound(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::A", members: ["B", "A"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A", members: ["C"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A._(File.swift)::C", members: ["D"]),
        ],
        typeName: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D"
      ))
      extension A.B.C.D {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D._(File.swift)::E")
        struct E {}
      }

      \(extensionState: .bound(dependencies: [], typeName: "_(File.swift)::A"))
      extension A {
        \(name: "_(File.swift)::A._(File.swift)::A")
        struct A {}
      }
      """
    ])
  }

  func testExtensionNestedTypeRedeclaration1() {
    assertTypeResolution([
      "File.swift": """
      \(name: "_(File.swift)::A")
      struct A {
        typealias B = A

        struct C {}
      }

      \(extensionState: .bound(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::A", members: ["B", "A"]),
        ],
        typeName: "_(File.swift)::A._(File.swift)::A"
      ))
      extension A.B {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C")
        struct C { // Initially treated as redecl
          \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D")
          struct D {}
        }
      }

      // Initially ambiguous ref to `C`
      \(extensionState: .bound(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::A", members: ["B", "A"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A", members: ["C"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A._(File.swift)::C", members: ["D"]),
        ],
        typeName: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D"
      ))
      extension A.B.C.D {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D._(File.swift)::E")
        struct E {}
      }

      // After `A` gains a member type `A`, `struct C` above
      // resolves to `_::A._::A._::C`
      extension A {
        \(name: "_(File.swift)::A._(File.swift)::A")
        struct A {}
      }
      """
    ])
  }

  /// Same as above but we bind `extension A.B.C.D` first.
  func testExtensionNestedTypeRedeclaration2() {
    assertTypeResolution([
      "File.swift": """
      \(name: "_(File.swift)::A")
      struct A {
        typealias B = A
        struct C {}
      }

      extension A.B {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C")
        struct C { // Initially treated as redecl
          \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D")
          struct D {}
        }
      }

      // Initially ambiguous ref to `C`
      //
      // Because this is the first `\\(extensionState: ...)` assertion,
      // we bind this extension first.
      \(extensionState: .bound(
        dependencies: [
          ExtensionDependency(baseType: "_(File.swift)::A", members: ["B", "A"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A", members: ["C"]),
          ExtensionDependency(baseType: "_(File.swift)::A._(File.swift)::A._(File.swift)::C", members: ["D"]),
        ],
        typeName: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D"
      ))
      extension A.B.C.D {
        \(name: "_(File.swift)::A._(File.swift)::A._(File.swift)::C._(File.swift)::D._(File.swift)::E")
        struct E {}
      }

      // After `A` gains a member type `A`, `struct C` above
      // resolves to `_::A._::A._::C`
      extension A {
        \(name: "_(File.swift)::A._(File.swift)::A")
        struct A {}
      }
      """
    ])
  }

  func testRedeclarationInExtension() {
    assertTypeResolution(
      [
        "File.swift": """
        struct A {
          struct B {}
        }

        extension A.B {
          struct C {} // First declaration of `A.B` > `C`
        }

        extension A.B.C { struct D {} } // `A.B.C` > `D`

        extension A.B {
          typealias C = A // Redeclaration of `A.B` > `C`,
                          // so we evict `A.B.C` > `D`
        }

        let _: \(failure: .invalidMembers([
               ("A.B.C", .ambiguousTypeDecl(["struct C {}", "typealias C = A"]))
             ]))
               A.B.C.D
        """
      ]
    )
  }

  // func testCrossFileExtension() {
  //   assertQualifiedTypeName([
  //     "FileA.swift": """
  //     \("🟥", name: "_(FileA.swift)::A")
  //     struct A {}
  //     func f(_: \(references: ["🟩"])A.B)
  //     """ as LexicalLookupSource,
  //
  //     "FileB.swift": """
  //     extension A {
  //       \("🟩", name: "_(FileA.swift)::A._(FileB.swift)::B")
  //       struct B {}
  //     }
  //     func g(_: \(references: ["🟩"])A.B)
  //     """ as LexicalLookupSource,
  //   ])
  // }

  // func testCodeBlockSimpleCase() {
  //   assertQualifiedTypeName([
  //     "MyFile.swift": """
  //     \("🟥", name: "MyModule::A")struct A {
  //       \("🟩", name: "MyModule::A.MyModule::B")struct B {
  //         static func f() -> \(references: "🟩")B {}
  //         static func makeSelf() -> \(references: "🟩")Self
  //       }
  //     }
  //     """ as LexicalLookupSource
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
  //       //   static func invalidRefToC() -> \(result: .nominalTypes([]))C {}
  //       // }
  //       //
  //       // func anonymousScope() {
  //       //   var a: \(result: .nominalTypes([]))Self
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
  //       // \(result: .nominalTypes([]))B
  //       // \(result: .nominalTypes([]))D
  //       // """ as LexicalLookupSource
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

  // TODO: Shadowing tests. Local; same file; same-mdoule, etc.

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
