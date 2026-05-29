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
import SwiftLexicalLookup
import SwiftSyntax
import XCTest

final class TestQualifiedLookup: XCTestCase {
  func testCodeBlockSimpleCase() {
    // TODO: Implement type-lookup helper first.
    assertLexicalNameLookup(
      source: """
        struct MyStruct {
          static func hello() {}

          🅰️func hi() {
            MyStruct.hello()
          }
        }
        """,
      references: [
        "3️⃣": [.fromScope(CodeBlockSyntax.self, expectedNames: ["1️⃣"])],
        "5️⃣": [.fromScope(CodeBlockSyntax.self, expectedNames: ["1️⃣"])],
        "7️⃣": [
          .fromScope(CodeBlockSyntax.self, expectedNames: ["6️⃣"]),
          .fromScope(CodeBlockSyntax.self, expectedNames: ["1️⃣"]),
        ],
        "8️⃣": [.fromScope(CodeBlockSyntax.self, expectedNames: ["2️⃣"])],
        "9️⃣": [.fromScope(CodeBlockSyntax.self, expectedNames: ["4️⃣"])],
      ],
      expectedResultTypes: .all(IdentifierPatternSyntax.self)
    )
  }
}
