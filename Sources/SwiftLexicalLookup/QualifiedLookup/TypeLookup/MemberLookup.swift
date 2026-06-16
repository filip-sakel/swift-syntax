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

enum TypeLookupState {

}

extension SyntaxProtocol {
  /// Visit type members from this source location
  func visitMembers<Result>(
    of typeSyntax: TypeSyntax,
    map: (_ member: ValueDeclSyntax) -> (Result?, continue: Bool)
  ) -> MemberLookupResult<Result> {
    // Resolve type
    var types = [PartiallyResolvedType]()
    var failures = [TypeResolutionFailure]()
    typeSyntax.partiallyResolve(types: &types, failures: &failures)

    // Check types
    for type in types {
      switch type {
      // Special types (we can't compose function/tuple)
      case .function(let argumentCount):
        return MemberLookupResult.function(argumentCount: argumentCount)
      case .tuple(let labels):
        return MemberLookupResult.tuple(labels: labels)
      case .nominalIdentifier(nil, let name):
        // Top-level lookup

      case .nominalIdentifier(let module?, let name):
        if let module
      case .nominalMember(let bases, let module, let name):

      }
    }

    // Resolve type chain for this source location

  }
}
