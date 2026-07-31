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

extension SourceFileRoot: ExpressibleByStringLiteral
    & ExpressibleByExtendedGraphemeClusterLiteral
    & ExpressibleByUnicodeScalarLiteral
where
  Node == TypeSyntax
{
  public init(stringLiteral value: StringLiteralType) {
    // Wrap the type syntax in a file
    var parser = Parser("typealias = \(value)")
    let sourceFile = SourceFileSyntax.parse(from: &parser)
    guard let typeSyntax = sourceFile.children(ofType: TypeSyntax.self).first else {
      fatalError("Couldn't parse `\(value)` as TypeSyntax.")
    }
    // We should now be able to cast to SourceFileRoot
    self = SourceFileRoot(typeSyntax)!
  }
}

// Convenience initializer

struct ExtensionDependency {
  let baseType: TestTypeName
  let members: [StaticString]
}

extension GenericExtensionState where TypeName == TestTypeName {
  /// Creates a mock extension state to check an extension's dependencies,
  /// bound type, or failure to bind due to cycles.
  ///
  /// Note: Because `GenericBindingFailure` contains `TypeQualifier.Failure`
  /// (which uses actual `ResolvedNominalTypeReference` and not mock types),
  /// it's hard to test type-resolution failures. You may instead use regular
  /// type-resolution tests and only use this initializer to test extension
  /// binding.
  fileprivate init(
    dependencies: [ExtensionDependency],
    resolvedType: Result<TestTypeName, GenericBindingFailure<TestTypeName>>,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    // Create fake extension (won't be checked)
    //
    // Wrap the type syntax in a file
    var parser = Parser("extension")
    let sourceFile = SourceFileSyntax.parse(from: &parser)
    let mockExtension = SourceFileRoot(sourceFile.children(ofType: ExtensionDeclSyntax.self)[0])!

    self.init(
      _uncheckedDependencies: dependencies.map({
        let mappedMembers: [TypeMember] = $0.members.map({ member in
          TypeMember(name: Identifier(canonicalName: member), decls: [])
        })
        return GenericExtensionDependency<TestTypeName>(dependencyTypeName: $0.baseType, members: mappedMembers)
      }),
      // Extension decl won't be checked
      extensionDecl: mockExtension,
      resolvedType: resolvedType
    )
  }

  fileprivate static func bound(
    to typeName: TestTypeName,
    dependencies: [ExtensionDependency]
  ) -> GenericExtensionState {
    GenericExtensionState<TestTypeName>(dependencies: dependencies, resolvedType: .success(typeName))
  }

  fileprivate static func invalidCycle(
    dependencies: [ExtensionDependency],
    cycleElements: [(introducingDecl: String?, extension: String, base: TestTypeName)],
    conflictingMember: StaticString,
    file: StaticString = #file,
    line: UInt = #line
  ) -> GenericExtensionState {
    let dependencyPath: [GenericDependencyCycleElement<TestTypeName>] = cycleElements.map({
      (introducingTypeDeclText, extensionDeclText, baseTypeName) -> GenericDependencyCycleElement<TestTypeName> in
      let introducingTypeDecl: TypeDeclSyntax?
      if let introducingTypeDeclText {
        let typeDeclRaw = DeclSyntax(stringLiteral: introducingTypeDeclText)
        guard let typeDecl = Syntax(typeDeclRaw).as(TypeDeclSyntax.self) else {
          fatalError(
            "Couldn't cast the cycle element's 'introducingMember' `\(introducingTypeDeclText)` of kind '\(typeDeclRaw.kind)' to TypeDeclSyntax",
            file: file,
            line: line
          )
        }
        introducingTypeDecl = typeDecl
      } else {
        introducingTypeDecl = nil
      }

      let extensionDeclRaw = DeclSyntax(stringLiteral: extensionDeclText)
      guard let extensionDecl = extensionDeclRaw.as(ExtensionDeclSyntax.self) else {
        fatalError(
          "Couldn't cast the cycle element's 'extension' `\(extensionDeclText)` of kind '\(extensionDeclRaw.kind)' to ExtensionDeclSyntax",
          file: file,
          line: line
        )
      }
      return GenericDependencyCycleElement(
        introducingTypeDecl: introducingTypeDecl,
        extensionDecl: extensionDecl,
        boundType: baseTypeName,
      )
    })

    let cycle = GenericExtensionBindingCycle<TestTypeName>(
      dependencyPath: dependencyPath,
      dependencyMember: Identifier(canonicalName: conflictingMember)
    )

    return GenericExtensionState<TestTypeName>(
      dependencies: dependencies,
      resolvedType: Result.failure(GenericBindingFailure.cannotFormCycle(cycle))
    )
  }
}

// // Convenience `String` initializer for `TypeDeclSyntax`; will
// // crash at runtime if given a non `TypeDeclSyntax`.
// extension TypeDeclSyntax: ExpressibleByStringLiteral {
//   public init(stringLiteral value: StringLiteralType) {
//     self = Syntax(DeclSyntax(stringLiteral: value)).cast(TypeDeclSyntax.self)
//   }
// }

// TODO: Remove
// extension ResolvedNominalTypeReference {
//   fileprivate static func _mockMarkerType(_ kind: SyntaxKind, marker: Character) -> ResolvedNominalTypeReference? {
//     // Get the declaration kind
//     let rawTypeDecl: DeclSyntax
//     switch kind {
//     case .structDecl: rawTypeDecl = "struct"
//     case .enumDecl: rawTypeDecl = "enum"
//     case .classDecl: rawTypeDecl = "class"
//     case .actorDecl: rawTypeDecl = "actor"
//     case .protocolDecl: rawTypeDecl = "protocol"
//     default: return nil
//     }
//     let originatingSyntax: TypeSyntax = "\(raw: marker)"
//
//     // We should only get type declarations
//     let typeDecl = NominalTypeDeclSyntax(rawTypeDecl)!
//     return ResolvedNominalTypeReference._mockMarkerType(
//       mainDecl: typeDecl,
//       originatingSyntax: originatingSyntax
//     )
//   }
// }

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
      var x: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.tuple(labels: [nil, nil])))
             (A, B).MyType
      var y: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.function(argumentCount: 1)))
             ((A) -> B).MyType
      var z: \(failure: .noTypeMember(member: myTypeMember, in: MemberLookupResult.memberResults([])))
             A.Type.MyType
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
    assertTypeResolution(
      [
        "MyFile.swift": """
        \("🟥", name: "_(MyFile.swift)::A")
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

  // TODO: Reenable
  func testPathologicalV3() {
    assertTypeResolution([
      "File.swift": """
      struct T_0 {}
      struct T_1 {}
      struct T_2 {}
      struct T_3 {}

      extension T_0 { typealias Last = T_3 }


      //        |- Depends on : ()
      //        `- Introduces : T_0>Last
      //
      //              `- ℹ️ note:  For `T_0`'s member `Last` to resolve to `output.T_3`,
      //                          `T_0` must not contain any type member named `T_3`.



      \(extensionState: .bound(
        to: "_(File.swift)::T_3",
        dependencies: [ExtensionDependency(baseType: "_(File.swift)::T_0", members: ["Last", "T_3"])]
      ))
      extension T_0.Last { typealias Prev = T_2 }


      //        |- Depends on : T_0>Last, T_0>T_3
      //        |- Resolves to: T_3
      //        `- Introduces : T_3>Prev
      //
      //           `- ℹ️ note: `T_0`'s member `Last` is declared in `extension T_0.Last`




      // j=3
      extension T_3.Prev { typealias Prev = T_1 }


      //        |- Depends on : T_3>Prev, T_3>T_2
      //        |- Resolves to: T_2
      //        `- Introduces : T_2>Prev
      //
      //           `- ℹ️ note: `T_3`'s member `Prev` is declared in `extension T_0.Last`





      // j=2
      extension T_2.Prev { typealias Prev = T_0 }


      //        |- Depends on : T_2>Prev, T_2>T_1
      //        |- Resolves to: T_1
      //        `- Introduces : T_1>Prev
      //
      //           `- ℹ️ note: `T_2`'s member `Prev` is declared in `extension T_3.Prev`

      \(extensionState: .invalidCycle(
        dependencies: [
          ExtensionDependency(baseType: "T_1", members: ["Prev", "T_0"])
        ],
        cycleElements: [
          (introducingDecl: "typealias Prev = T_0", extension: "extension T_2.Prev {}", base: "_(File.swift)::T_1"),
          (introducingDecl: "typealias Prev = T_1", extension: "extension T_3.Prev {}", base: "_(File.swift)::T_2"),
          (introducingDecl: "typealias Prev = T_2", extension: "extension T_0.Last {}", base: "_(File.swift)::T_3"),
        ],
        conflictingMember: "T_3"
      ))
      extension T_1.Prev { struct T_3 {} }
      //        |- Depends on : T_1>Prev, T_1>T_0
      //        |- Resolves to: T_0
      //        `- Introduces : T_0>T_3     <- collides with the first extension's empty dependency
      //
      //           `- ℹ️ note: `T_1`'s member `Prev` is declared in `extension T_2.Prev`
      // `- ❌ error: Resolving `extension T_1.Prev` to the extended type `T_0` requires that `T_0`
      //           have no type member `T_3`, but the extension introduces `T_3`.

      extension T_1 { struct T_0 {} }
      """
    ])
  }

  // TODO: Add test where extension state resolves to a cycle, but
  // a later extension actually makes everything resolve fine (look at last bug report)

  /// TODO: Check main decls actually don't have dependencies (with example in `TypeDependencyGraph` of main decl nested in dependency)
  /// We need to save dependencies to the main nominal-type declaration,
  /// which we represent as `nil`.
  ///
  /// For instance, suppose we have `struct A {}` and we bind:
  /// ```swift
  /// extension A.B {}
  /// ```
  /// This extension depends on the member type 'B' of '(MyFile.swift)::A'.
  /// Currently, no extensions introduce this member type but we need to record
  /// the dependency in case another extension introduces
  /// '(MyFile.swift)::A' > 'B'. Hence, we say the introducing decl is `nil` (the
  /// main declaration.)
  ///

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
