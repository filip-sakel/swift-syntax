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

@_spi(_QualifiedLookup) public enum MemberLookupResult<Result> {
  case function(argumentCount: Int)
  case tuple(labels: [Identifier?])
  case memberResults([Result])

  public func mapMembers<NewResult>(_ transform: (Result) -> NewResult) -> MemberLookupResult<NewResult> {
    switch self {
    case .function(let argumentCount):
      return .function(argumentCount: argumentCount)
    case .tuple(let labels):
      return .tuple(labels: labels)
    case .memberResults(let results):
      return .memberResults(results.map(transform))
    }
  }
}

extension MemberLookupResult: Sendable where Result: Sendable {}
extension MemberLookupResult: Equatable where Result: Equatable {}
extension MemberLookupResult: Hashable where Result: Hashable {}

extension MemberLookupResult {
  fileprivate func _description(describeMembers: ([Result]) -> String) -> String {
    switch self {
    case .function(let argumentCount):
      return ".function(argumentCount: \(argumentCount))"
    case .tuple(let labels):
      return ".tuple(\(labels.map({ $0?.name ?? "_"}))"
    case .memberResults(let members):
      return ".memberResults([\(describeMembers(members))])"
    }
  }
}

extension MemberLookupResult: CustomDebugStringConvertible where Result: CustomDebugStringConvertible {
  public var debugDescription: String {
    _description(describeMembers: { members in
      members.map({ "```\($0.debugDescription)```" }).joined(separator: "\n")
    })
  }
}
// extension MemberLookupResult: CustomDebugStringConvertible where Result: SyntaxProtocol {
//   public var debugDescription: String {
//     _description(describeMembers: { members in
//       members.map({ "```\($0.trimmedDescription)```" }).joined(separator: "\n")
//     })
//   }
// }

// extension MemberLookupResult where Result == ValueDeclSyntax {
//   var names: [DeclName] {
//     switch self {
//     case .function(let argumentCount): return [.callAsFunction(args: [Identifier?](repeating: nil, count: argumentCount))]
//     case .tuple(let labels):
//       labels.enumerated().flatMap({ i, optionalLabel in
//         // No way to create `StaticString` name from runtime integer
//         let indexName = DeclName.identifier(macro: nil, identifier: Identifier, args: DeclNameArgs?)
//         if let label = optionalLabel {
//           return [DeclName.identifier(identifier: label, args: )]
//         }
//       })
//     }
//   }
// }
