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

final class UnqualifiedTypeLookupTests: XCTestCase {
  func testTopScopeDecls() {
    assertUnqualifiedTypeLookup(
      """
      struct A {}
      typealias A

      let _: \(results: [
        .decls(["struct A {}", "typealias A"], inScope: nil),
        .lookInModule,
      ])A

      func f() \("🟩"){
        struct B {}
        typealias B

        // A is still accessible from function scope
        let _: \(results: [
          .decls(["struct A {}", "typealias A"], inScope: nil),
          .lookInModule,
        ])A

        let _: \(results: [
          .decls(["struct B {}", "typealias B"], inScope: "🟩"),
          .lookInModule,
        ])B

        while \("🟪"){
          // Shadowing
          struct A {}

          let a: \(results: [
            .decls(["struct A {}"], inScope: "🟪"),
            .decls(["struct A {}", "typealias A"], inScope: nil),
            .lookInModule,
          ])A
        }
      }
      """
    )
  }

  func testTypeMembers() {
    // Nominals at top and local scope; doubly nested nominals; in extensions;
    // in doubly nested within extensions

    assertUnqualifiedTypeLookup(
      """
      // Test simple member type at top level
      struct A {
        let _: B\(results: [
          .lookForMember(declGroupParent: "struct A {}", lookForSelf: false),
          .lookInModule
        ])

        struct B {
          let _: B\(results: [
            .lookForMember(declGroupParent: "struct B {}", lookForSelf: false),
            .lookForMember(declGroupParent: "struct A {}", lookForSelf: false),
            .lookInModule
          ])
        }
      }

      // Test nested member types in local scopes
      func f() {
        struct C {
          let _: C \(results: [
            .lookForMember(declGroupParent: "struct C {}", lookForSelf: false),
            .lookInModule
          ])

          func g() {
            struct D {
              struct C {
                let _: C\(results: [
                  .lookForMember(declGroupParent: "struct C {}", lookForSelf: false),
                  .lookForMember(declGroupParent: "struct D {}", lookForSelf: false),
                  .lookForMember(declGroupParent: "struct C {}", lookForSelf: false),
                  .lookInModule
                ])
              }
            }
          }
        }
      }

      // Test nested member types in an extension
      extension T {
        struct C {
          let _: D\(results: [
            .lookForMember(declGroupParent: "struct C {}", lookForSelf: false),
            .lookForMember(declGroupParent: "extension T {}", lookForSelf: false),
            .lookInModule
          ])

          struct D {
            let _: D\(results: [
              .lookForMember(declGroupParent: "struct D {}", lookForSelf: false),
              .lookForMember(declGroupParent: "struct C {}", lookForSelf: false),
              .lookForMember(declGroupParent: "extension T {}", lookForSelf: false),
              .lookInModule
            ])
          }
        }
      }
      """
    )
  }

  func testGenericParameters() {
    assertUnqualifiedTypeLookup(
      """
      extension MyType \("🟩"){
        let _: A\(results: [
          .lookForGenericParameters(extensionDecl: "extension MyType {}"),
          .lookInModule,
        ])

        struct Nested<A> \("🟨"){
          let _: A\(results: [
            .decls([.genericParameter("A")], inScope: "🟨"),
            .lookForGenericParameters(extensionDecl: "extension MyType {}"),
            .lookInModule,
          ])

          func f<A, B>() \("🟪"){
            let _: A\(results: [
              .decls([.genericParameter("A")], inScope: "🟪"),
              .decls([.genericParameter("A")], inScope: "🟨"),
              .lookForGenericParameters(extensionDecl: "extension MyType {}"),
              .lookInModule,
            ])

            do { // nested sequential scope
              let _: B\(results: [
                .decls([.genericParameter("A")], inScope: "🟪"),
                .lookForGenericParameters(extensionDecl: "extension MyType {}"),
                .lookInModule,
              ])
            }
          }
        }
      }
      """
    )
  }
  func testAssociatedTypes() {
    assertUnqualifiedTypeLookup(
      """
      // Simple case
      protocol ProtoA \("🟩"){
        associatedtype A
        associatedtype B

        func f() -> A\(results: [
          .decls(["associatedtype A"], inScope: "🟩"),
          .lookForMember(declGroupParent: "protocol ProtoA {}", lookForSelf: false),
          .lookInModule,
        ])
      }

      // Protocol inside a struct
      struct B<B> \("🟨"){
        typealias B
        associatedtype B // Structs can't have associated types

        // Protocols can only be declared in non generic structs, but
        // we don't diagnose here
        protocol B \("🟪"){
          associatedtype B

          func f() -> B\(results: [
            .decls(["associatedtype B"], inScope: "🟪"),
            .lookForMember(declGroupParent: "protocol B {}", lookForSelf: false),
            .decls(["typealias B"], inScope: "🟨"),
            .lookForMember(declGroupParent: "struct B<B> {}", lookForSelf: false),
            .decls(["struct B<B> {}"], inScope: nil),
            .lookInModule,
          ])

        }
      }

      // Extensions also can't have associated types
      extension A {
        associatedtype A

        func f() -> A\(results: [
          .lookForMember(declGroupParent: "extension A {}", lookForSelf: false),
          .lookInModule
        ])
      }
      """
    )
  }
  func testImplicitSelf() {
    // Protocols, extensions; note limitation (link to issue?)

    // Implicit `Self` only appears in extensions and protocols
    // https://github.com/swiftlang/swift-syntax/pull/2852#discussion_r1775049671
    assertUnqualifiedTypeLookup(
      """
      // Protocol
      protocol P {
        func f() -> Self\(results: [
          .lookForMember(declGroupParent: "protocol P", lookForSelf: false),
          // Implicit `Self`
          .lookForMember(declGroupParent: "protocol P", lookForSelf: true),
          .lookInModule
        ])
      }

      // Extension
      extension A {
        func f() {
          let _: Self\(results: [
            .lookForMember(declGroupParent: "extension A", lookForSelf: false),
            .lookForMember(declGroupParent: "extension A", lookForSelf: true),
            .lookInModule
          ])

          func g() {
            let _: Self\(results: [
              .lookForMember(declGroupParent: "extension A", lookForSelf: false),
              .lookForMember(declGroupParent: "extension A", lookForSelf: true),
              .lookInModule
            ])
          }
        }
      }
      """
    )
  }
}
