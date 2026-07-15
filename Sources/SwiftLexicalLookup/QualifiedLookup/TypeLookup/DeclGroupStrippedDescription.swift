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

import SwiftSyntax

extension DeclGroupSyntax {
  /// Removes member blocks and gets trimmed description for better
  /// readability in debug output.
  @_spi(_QualifiedLookupTests) public var _memberlessDescription: String {
    self.with(\.memberBlock, MemberBlockSyntax(members: [])).trimmedDescription
  }
}
