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

final class TestValueDeclSyntax: XCTestCase {
  /// Assert the given declaration syntax can be cast to a ``ValueDeclSyntax``,
  /// exhibiting the given properties.
  ///
  /// Most tests initialize the DeclSyntax with a string literal.
  ///
  /// Parameters:
  /// - isStatic: As documented in `ValueDeclSyntax/isStatic`, this
  ///             query doesn't care use the declaration's parent
  ///             as context.
  func assertValueDecl(
    of declSyntax: DeclSyntax,
    name: DeclName,
    isStatic: Result<Bool, ValueDeclSyntax.StaticLookupFailure>,
    isTypeDecl: Bool,
    scopeKind: SyntaxKind?,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    // Cast to value declaration
    guard let valueDecl = ValueDeclSyntax(declSyntax) else {
      XCTFail(
        "Couldn't initialize a value declaration from decl of kind '\(declSyntax.kind)'",
        file: file,
        line: line
      )
      return
    }

    // Check equivalent type casting/checking methods
    XCTAssert(
      declSyntax.as(ValueDeclSyntax.self) != nil,
      "Couldn't cast decl of kind '\(declSyntax.kind)' to a value declaration.",
      file: file,
      line: line
    )
    XCTAssert(
      declSyntax.is(ValueDeclSyntax.self),
      "Type check reports that decl of kind '\(declSyntax.kind)' isn't a value declaration",
      file: file,
      line: line
    )

    // Check properties
    //
    // Name
    XCTAssertEqual(
      valueDecl.declName,
      name,
      "Value declaration returned an invalid name",
      file: file,
      line: line
    )
    // isStatic
    XCTAssertEqual(
      valueDecl.isStatic,
      isStatic,
      "Value declaration doesn't match epected `isStatic` property",
      file: file,
      line: line
    )
    // isTypeDecl
    XCTAssertEqual(
      valueDecl.isTypeDecl,
      isTypeDecl,
      "Value declaration doesn't match epected `isTypeDecl` property",
      file: file,
      line: line
    )
    // Scope
    XCTAssertEqual(
      valueDecl.scope?.kind,
      scopeKind,
      "Value declaration doesn't match epected `scope` kind",
      file: file,
      line: line
    )
  }

  func testTypes() {
    // Nominal types + Protocols
    assertValueDecl(
      of: "struct MyStruct {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "MyStruct"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .structDecl
    )

    assertValueDecl(
      of: "enum _ {}",
      name: DeclName.invalid(nonIdentifier: .identifier(""), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .enumDecl
    )

    assertValueDecl(
      of: "class Self {}",
      name: DeclName.invalid(nonIdentifier: .identifier(""), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .classDecl
    )

    assertValueDecl(
      of: "actor `My Actor` {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "My Actor"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .actorDecl
    )

    assertValueDecl(
      of: "protocol $MyProto {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "$MyProto"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .protocolDecl
    )

    // Type Aliases
    assertValueDecl(
      of: "typealias Num = Int",
      name: DeclName.regular(identifier: Identifier(canonicalName: "Num"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      // type aliases introduce a scope for potential generic parameters
      scopeKind: .typeAliasDecl
    )

    // Associated Types
    assertValueDecl(
      of: "associatedtype Element",
      name: DeclName.regular(identifier: Identifier(canonicalName: "Element"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      // associated types don't introduce their own scope
      scopeKind: nil
    )
  }

  // Function-like are value declarations with arguments in their names.
  func testFunctionLike() {
    // === Basic kinds ===
    //
    // Functions, inits, deinits, subscripts, enum elements, macros
    assertValueDecl(
      of: "func myFunc() {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "myFunc"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    assertValueDecl(
      of: "init ()",
      name: DeclName.`init`([]),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .initializerDecl
    )
    assertValueDecl(
      // Test resilience against missing syntax
      of: "deinit",
      name: DeclName.`init`([]),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .initializerDecl
    )
    assertValueDecl(
      // E.g. In a protocol
      of: "subscript() -> Int { get }",
      name: DeclName.subscript([]),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .subscriptDecl
    )
    assertValueDecl(
      // No easy way to use a string literal because "case myCase" parses as
      // an ``EnumCaseDeclSyntax``.
      of: DeclSyntax(EnumCaseElementSyntax(name: "")),
      name: DeclName.subscript([]),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .subscriptDecl
    )

    // Static/class (doesn't care about parent context, i.e. global funcs are nonstatic)
    assertValueDecl(
      of: "static func $myFunc() {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "$myFunc"), []),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    assertValueDecl(
      of: "class subscript func5 {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "func5"), []),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )

    // Test args
    //
    // Even though a function missing the parameter clause syntax,
    // should have an empty arguments array to distinguish it from
    // a variable. For instance, if an autocompletition tool finds
    // this function through, it will still insert the parentheses
    // (since this is a function).
    assertValueDecl(
      of: "func 5 {}",
      name: DeclName.invalid(nonIdentifier: .identifier("5"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    assertValueDecl(
      of: "func 5 {}",
      name: DeclName.invalid(nonIdentifier: .identifier("5"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )

    assertValueDecl(
      of: "func callAsFunction() {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "callAsFunction"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )

    assertValueDecl(
      of: "class func myFunc() {}",
      name: DeclName.regular(identifier: Identifier(canonicalName: "myFunc"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
  }

  func testStorage() {}

  func testMacros() {}

  func testEnumElements() {}

  // Certain declarations aren't value declarations.
  //
  // In particular, check for enum case and var declarations,
  // which one may assume produce names directly (their children do).
  func testNonValueDecls() {
    // === Failing Casts ===
    XCTAssert(
      ValueDeclSyntax(DeclSyntax("case myCase")) == nil,
      "Expected initialization to value declaration to fail: case declarations aren't values; case elements are."
    )
    XCTAssert(
      ValueDeclSyntax(DeclSyntax("var myVar")) == nil,
      "Expected initialization to value declaration to fail: var declarations aren't values; patter identifiers are."
    )
  }
}
