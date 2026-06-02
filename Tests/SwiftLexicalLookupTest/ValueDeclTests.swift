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

private class SyntaxAsTypeVisitor<T: SyntaxProtocol>: SyntaxAnyVisitor {
  var collectedNodes = [T]()

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    if let castNode = node.as(T.self) {
      collectedNodes.append(castNode)
    }
    return .visitChildren
  }
}
extension SyntaxProtocol {
  func children<T: SyntaxProtocol>(ofType: T.Type) -> [T] {
    let visitor = SyntaxAsTypeVisitor<T>(viewMode: .all)
    visitor.walk(self)
    return visitor.collectedNodes
  }
}

final class TestValueDeclSyntax: XCTestCase {
  /// Assert the given declaration syntax can be cast to a ``ValueDeclSyntax``,
  /// exhibiting the given properties.
  ///
  /// Most tests pass a DeclSyntax initialized with a string literal for `syntax`.
  ///
  /// Parameters:
  /// - isStatic: As documented in `ValueDeclSyntax/isStatic`, this
  ///             query doesn't care use the declaration's parent
  ///             as context.
  func assertValueDecl(
    of syntax: some SyntaxProtocol,
    name: DeclName,
    isStatic: Result<Bool, ValueDeclSyntax.StaticLookupFailure>,
    isTypeDecl: Bool,
    scopeKind: SyntaxKind?,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    // Cast to value declaration
    guard let valueDecl = ValueDeclSyntax(syntax) else {
      XCTFail(
        "Couldn't initialize a value declaration from decl of kind '\(syntax.kind)'",
        file: file,
        line: line
      )
      return
    }

    // Check equivalent type casting/checking methods
    XCTAssert(
      syntax.as(ValueDeclSyntax.self) != nil,
      "Couldn't cast decl of kind '\(syntax.kind)' to a value declaration.",
      file: file,
      line: line
    )
    XCTAssert(
      syntax.is(ValueDeclSyntax.self),
      "Type check reports that decl of kind '\(syntax.kind)' isn't a value declaration",
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
      of: DeclSyntax("struct MyStruct {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "MyStruct"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .structDecl
    )

    assertValueDecl(
      of: DeclSyntax("enum _ {}"),
      name: DeclName.invalid(nonIdentifier: .identifier(""), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .enumDecl
    )

    assertValueDecl(
      of: DeclSyntax("class Self {}"),
      name: DeclName.invalid(nonIdentifier: .identifier(""), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .classDecl
    )

    assertValueDecl(
      of: DeclSyntax("actor `My Actor` {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "My Actor"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .actorDecl
    )

    assertValueDecl(
      of: DeclSyntax("protocol $MyProto {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "$MyProto"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      scopeKind: .protocolDecl
    )

    // Type Aliases
    assertValueDecl(
      of: DeclSyntax("typealias Num = Int"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "Num"), nil),
      isStatic: .success(true),
      isTypeDecl: true,
      // type aliases introduce a scope for potential generic parameters
      scopeKind: .typeAliasDecl
    )

    // Associated Types
    assertValueDecl(
      of: DeclSyntax("associatedtype Element"),
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
      of: DeclSyntax("func myFunc() {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "myFunc"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    assertValueDecl(
      of: DeclSyntax("init ()"),
      name: DeclName.`init`([]),
      isStatic: .success(true),  // Always static
      isTypeDecl: false,
      scopeKind: .initializerDecl
    )
    assertValueDecl(
      // Test resilience against missing syntax
      of: DeclSyntax("deinit"),
      name: DeclName.`init`([]),
      isStatic: .success(false),  // Always non-static
      isTypeDecl: false,
      scopeKind: .initializerDecl
    )
    assertValueDecl(
      // E.g. In a protocol
      of: DeclSyntax("subscript() -> Int { get }"),
      name: DeclName.subscript([]),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .subscriptDecl
    )
    assertValueDecl(
      of: EnumCaseElementSyntax(name: "myCase"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "myCase"), nil),
      isStatic: .success(true),  // Always static
      isTypeDecl: false,
      scopeKind: .enumCaseDecl
    )
  }

  func testFunctionLikeStatic() {
    // Note that static/class doesn't care about parent context, (e.g. global
    // funcs are 'nonstatic')

    // Simple cases
    assertValueDecl(
      of: DeclSyntax("static func $myFunc() {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "$myFunc"), []),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    assertValueDecl(
      of: DeclSyntax("class subscript func5 {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "func5"), []),
      isStatic: .success(true),
      isTypeDecl: false,
      scopeKind: .subscriptDecl
    )
    // Identifier pattern in variable declaration (for scope)
    do {
      assertValueDecl(
        // Extract the identifier pattern from the variable declaration
        of: DeclSyntax(stringLiteral: "var myVar").children(ofType: IdentifierPatternSyntax.self)[0],
        name: DeclName.regular(identifier: Identifier(canonicalName: "myVar"), []),
        isStatic: .success(false),
        isTypeDecl: false,
        scopeKind: .variableDecl
      )

      // Add static
      assertValueDecl(
        // Extract the identifier pattern from the variable declaration
        of: DeclSyntax(stringLiteral: "static var myVar").children(ofType: IdentifierPatternSyntax.self)[0],
        name: DeclName.regular(identifier: Identifier(canonicalName: "myVar"), []),
        isStatic: .success(true),
        isTypeDecl: false,
        scopeKind: .variableDecl
      )
    }

    // Failures
    //
    // Macro failure
    assertValueDecl(
      of: DeclSyntax("macro myMacro"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "myMacro"), []),
      isStatic: .failure(.macrosOnlyAtFileScope),
      isTypeDecl: false,
      scopeKind: .macroDecl
    )
    // Scope-lookup failure
    do {
      let ifExpr = ExprSyntax("if let myVar = optionalValue {}").cast(IfExprSyntax.self)
      let identifierValueDecl = ifExpr.conditions.first!.condition.cast(OptionalBindingConditionSyntax.self).pattern
      assertValueDecl(
        // Detached => no scope
        of: identifierValueDecl.detached,
        name: DeclName.regular(identifier: Identifier(canonicalName: "myVar"), []),
        isStatic: .failure(.scopeFailure(.noScope)),
        isTypeDecl: false,
        scopeKind: nil
      )
      assertValueDecl(
        // Attached => wrong scope (IfExprSyntax)
        of: identifierValueDecl,
        name: DeclName.regular(identifier: Identifier(canonicalName: "myVar"), []),
        isStatic: .failure(.scopeFailure(.invalidScope)),
        isTypeDecl: false,
        scopeKind: .ifExpr
      )
    }

    // Test args
    //
    // Even though a function missing the parameter clause syntax,
    // should have an empty arguments array to distinguish it from
    // a variable. For instance, if an autocompletition tool finds
    // this function through, it will still insert the parentheses
    // (since this is a function).
    assertValueDecl(
      of: DeclSyntax("func 5 {}"),
      name: DeclName.invalid(nonIdentifier: .identifier("5"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )
    // This behavior is different for enum cases which can be declared
    // to have no arguments.
    assertValueDecl(
      of: DeclSyntax("func 5 {}"),
      name: DeclName.invalid(nonIdentifier: .identifier("5"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )

    // Test callAsFunction
    assertValueDecl(
      of: DeclSyntax("func callAsFunction() {}"),
      name: DeclName.regular(identifier: Identifier(canonicalName: "callAsFunction"), []),
      isStatic: .success(false),
      isTypeDecl: false,
      scopeKind: .functionDecl
    )

    assertValueDecl(
      of: DeclSyntax("class func myFunc() {}"),
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
