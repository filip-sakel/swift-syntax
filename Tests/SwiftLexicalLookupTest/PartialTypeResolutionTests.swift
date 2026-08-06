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

// Convenience `String` initializer for `TypeDeclSyntax`; will
// crash at runtime if given a non `TypeDeclSyntax`.
extension TypeDeclSyntax: ExpressibleByStringLiteral {
  public init(stringLiteral value: StringLiteralType) {
    self = Syntax(DeclSyntax(stringLiteral: value)).cast(TypeDeclSyntax.self)
  }
}

extension Attached where Node == TypeSyntax {
  public static func typeSyntax(
    _ syntaxString: StringLiteralType,
    file: StaticString = #file,
    line: UInt = #line
  ) -> Attached<TypeSyntax> {
    var parser = Parser("typealias = \(syntaxString)")
    let fileSyntax = SourceFileSyntax.parse(from: &parser)
    guard let typeSyntax = fileSyntax.children(ofType: TypeSyntax.self).first else {
      fatalError("`\(syntaxString)` didn't parse as type syntax.", file: file, line: line)
    }
    return Attached<TypeSyntax>(typeSyntax)!
  }
}

func assertPartialResolutionResult(
  typeSyntax: String,
  result: Result<PartiallyResolvedType, PartialTypeResolutionFailure>,
  file: StaticString = #file,
  line: UInt = #line
) {
  // Compute
  let actualResult = Attached.typeSyntax(typeSyntax, file: file, line: line).partiallyResolve()
  // Convert to strings to compare syntax
  let expectedDescription = result._debugDescription
  let actualDescription = actualResult._debugDescription
  XCTAssert(
    expectedDescription == actualDescription,
    "Wrong partial-resolution result for `\(typeSyntax)`:\nExpected: \(expectedDescription)\nGot     : \(actualDescription)",
    file: file,
    line: line
  )
}

final class PartialTypeResolutionTests: XCTestCase {
  /// Tests leaf non-nominal types (fully resolved)
  func testIdentifiers() {
    assertPartialResolutionResult(
      typeSyntax: "A",
      result: .success(
        .typeIdentifier(.success(TypeReference.Component(name: "A", introducingSyntax: .typeSyntax("A"))))
      )
    )
    assertPartialResolutionResult(
      typeSyntax: "Module::Type",
      result: .success(
        .typeIdentifier(
          .success(
            TypeReference.Component(module: "Module", name: "Type", introducingSyntax: .typeSyntax("Module::Type"))
          )
        )
      )
    )
    assertPartialResolutionResult(
      typeSyntax: "Module::_",
      result: .success(
        .typeIdentifier(.failure(InvalidTypeIdentifierFailure()))
      )
    )
  }
  func testNonNominalParents() {
    assertPartialResolutionResult(
      typeSyntax: "(a: Int, Bool, c: String)",
      result: .success(
        .tuple(labels: ["a", nil, "c"])
      )
    )
    assertPartialResolutionResult(
      typeSyntax: "Module::MyType & Any",
      result: .success(
        .composition([
          .typeSyntax("Module::MyType"),
          .typeSyntax("Any"),
        ])
      )
    )
  }
}
