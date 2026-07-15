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

// Convenience `String` initializer for `TypeLikeSyntax`
extension TypeLikeSyntax: ExpressibleByStringLiteral {
  public init(stringLiteral value: StringLiteralType) {
    self.init(TypeSyntax(stringLiteral: value))
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
  func testSimpleCase() {
    assertTypeResolution(
      [
        "MyFile.swift": """
        \("🟥", name: "_(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "🟥")A {}
          static func g() -> \(failure: .noTypeInScope)B {}
        }
        """ as LexicalLookupSource
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
  //       """ as LexicalLookupSource
  //     ],
  //     verbose: true
  //   )
  // }
  func testSimpleNestedCase() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::Hi")
      struct Hi {

        \("🟩", name: "_(MyFile.swift)::Hi._(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "🟩")A {}
        }

      }
      func g(_: \(nominal: "🟩")Hi.A)
      func h(_: \(nominal: "🟥")Hi)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Simple Non Nominal
  func testSimpleFunction() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(type: .function(argumentCount: 2))(_ a: Int, _ b: Int) -> Int
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
      struct A {}
      func f(_: \(nominals: [])A.Type)

      // Named opaque return types
      func g() -> <T> \(nominals: [])T { 1 }

      // Class restrictions
      protocol A: \(nominals: [])class {}
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
      \("🟥", name: "_(MyFile.swift)::A")
      protocol A {}

      func f(_: \(nominal: "🟥")some A)
      func g(_: \(nominal: "🟥")any A)

      // Attributed types (and modifiers)
      func h(_: @escaping \(type: .function(argumentCount: 0))() -> Void)
      func i(_: sending \(nominal: "🟥")A)

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

  // MARK: Aliases

  func testSimpleAlias() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(nominal: "🟥")B

      \("🟥", name: "_(MyFile.swift)::B")
      struct B {
        static func f() -> \(nominal: "🟥")A {}
        static func g() -> \(nominal: "🟥")B {}
      }
      func f() -> \(nominal: "🟥")A {}
      func g() -> \(nominal: "🟥")B {}
      """ as LexicalLookupSource
    ])
  }

  func testNestedAlias() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::Outer")
      struct Outer {
        typealias B = \(nominal: "🟩")A

        \("🟩", name: "_(MyFile.swift)::Outer._(MyFile.swift)::A")
        struct A {
          static func f() -> \(nominal: "🟩")B {}
          static func g() -> \(nominal: "🟩")B {}
        }
      }
      func f(_: \(nominal: "🟩")Outer.A)
      func g(_: \(nominal: "🟩")Outer.B)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Alias Cycles

  func testSimpleCycle() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias A = \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))B
      typealias B = A
      func f(_: \(failure: .cyclicalTypeReference(cycle: ["B", "A"]))A)
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
      \("🟥", name: "_(MyFile.swift)::A")
      struct A { typealias Element = B.Element }
      struct B { typealias Element = A.Element }

      func f(_: \(nominal: "🟥")A)
      func g(_: \(failure: .invalidMembers([("A.Element", .cyclicalTypeReference(cycle: ["B.Element", "A.Element"]))]))A.Element)
      """ as LexicalLookupSource
    ])
  }

  // MARK: Compositions

  func testSimpleComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      typealias C = \(nominals: ["🟥", "🟩"])A & B

      \("🟥", name: "_(MyFile.swift)::A")
      protocol A {}

      \("🟩", name: "_(MyFile.swift)::B")
      protocol B {}
      """ as LexicalLookupSource
    ])
  }

  func testAnyTypeComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}
      \("🟩", name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}
      func f(_: \(nominal: "🟥")(Any & ProtoA) & Any)
      func g(_: \(nominals: ["🟥", "🟩"])((ProtoB & Any) & Any) & ProtoB)
      """ as LexicalLookupSource
    ])
  }

  func testNonnominalComposition() {
    assertTypeResolution(
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
        """ as LexicalLookupSource
      ]
    )
  }

  func testDuplicateComposition() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::ProtoA")
      protocol ProtoA {}
      \("🟩", name: "_(MyFile.swift)::ProtoB")
      protocol ProtoB {}
      func f(_: \(nominal: "🟥")ProtoA & Any & ProtoA)
      func g(_: \(nominals: ["🟥", "🟩"])(ProtoA & ProtoB) & ProtoA)
      """ as LexicalLookupSource
    ])
  }
  // func testTupleComposition() {
  //   assertQualifiedTypeName([
  //     "MyFile.swift": """
  //     func f(_: \(result: .tuple(labels: [Identifier(canonicalName: "a"), nil]))(a: Int, Bool))
  //     """ as LexicalLookupSource
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
    assertTypeResolution([
      "MyFile.swift": """
      struct A {}
      struct B {}

      // Tuples, functions, and metatypes don't have type members
      var x: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.tuple(labels: [nil, nil])))(A, B).MyType
      var y: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.function(argumentCount: 1)))((A) -> B).MyType
      var z: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.memberResults([])))A.Type.MyType
      """ as LexicalLookupSource
    ])
  }

  // MARK: Extensions

  func testSimpleExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}

      extension A {
        \("🟩", name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {}
      }
      func f(_: \(nominal: "🟩")A.B)
      // Test that incremental binding still works with a second request
      func g(_: \(nominal: "🟩")A.B)
      """ as LexicalLookupSource
    ])
  }
  func testTypeInExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}

      extension A {
        \("🟩", name: "_(MyFile.swift)::A._(MyFile.swift)::B")
        struct B {
          func f(_: \(nominal: "🟩")B)
        }
        func g(_: \(nominal: "🟩")B)
      }
      func h(_: \(nominal: "🟩")A.B)
      """ as LexicalLookupSource
    ])
  }

  func testSimpleRecursiveExtension() {
    // A type member `A`
    let typeMemberA = ImplicitTypeReferenceComponent(
      from: PartiallyResolvedTypeIdentifier.Component(
        module: nil,
        name: Identifier(canonicalName: "A"),
        introducingSyntax: "A"
      )
    )

    assertTypeResolution(
      [
        "MyFile.swift": """
        \("🟥", name: "_(MyFile.swift)::A")
        struct A {}
        extension A.B { struct A {} }
        extension A { typealias B = A }

        func f(_: \(failure: .noTypeMember(member: typeMemberA, in: .memberResults(["🟥"])))A.A)
        """ as LexicalLookupSource
      ],
      assertSymbolTableState: { symbolTable in
        guard
          let (_, extensionState) = symbolTable.extensionState.first(where: {
            (extensionDecl, _) in extensionDecl._memberlessDescription == "extension A.B {}"
          })
        else {
          XCTFail("Expected `extension A.B {}` to have been resolved.", file: #file, line: #line)
          return
        }

        guard case ExtensionBindingState.cannotDependOnIntroducedMembers(let introducedTypeMembers) = extensionState
        else {
          XCTFail(
            "Expected `extension A.B {}` to be unbound because of a cycle; instead, got state: \(extensionState)",
            file: #file,
            line: #line
          )
          return
        }

        XCTAssertEqual(
          introducedTypeMembers.map(\.trimmedDescription),
          ["struct A {}"],
          "Invalid cycle detected: `extension A.B {}` depends on the wrong type members."
        )
      },
      verbose: true
    )
  }
  func testRedeclarationWithRecursiveExtension() {
    assertTypeResolution([
      "MyFile.swift": """
      \("🟥", name: "_(MyFile.swift)::A")
      struct A {}
      extension A.B {}
      extension A { typealias B = A }
      extension A.B { typealias B = OtherType }
      """ as LexicalLookupSource
    ])
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
