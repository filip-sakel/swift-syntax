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

import SwiftSyntax

extension PartiallyResolvedType {
  // Find the given name (all names if `nil`) of the given kind.
  func add(name: DeclNameRef?, kind: MemberKind = .all, to decls: [DeclName]) {
    // TODO: Copy from direct lookup
    func matchInstanceMember(declName: DeclName) -> DeclName? {
      guard kind.contains(.anyInstanceMember) else { return false }
      guard try? name.tryMatch(declName) != nil else { return false }
      return DeclName
    }

    switch self {
    case .function:
      return matchInstanceMember(declName: .callAsFunction).flatMap({ [$0] }) ?? []
    case .tuple(let labels):
      labels.compactMap({ labelName in
        let name = DeclName.identifiable(identifier: labelName, args: nil)
        return matchInstanceMember(declName: name)
      })
    // TODO: Handle indices
    }
  }
}
