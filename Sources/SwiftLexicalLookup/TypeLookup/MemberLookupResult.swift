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

/// The type result of structural type resolution. `Result`
/// represents a nominal type.
@_spi(_QualifiedLookup) public enum MemberLookupResult<Result> {
  case function(argumentCount: Int)
  case tuple(labels: [Identifier?])
  case memberResults([Result])
  case anyType

  public func mapMembers<NewResult>(_ transform: (Result) -> NewResult) -> MemberLookupResult<NewResult> {
    switch self {
    case .function(let argumentCount):
      return .function(argumentCount: argumentCount)
    case .tuple(let labels):
      return .tuple(labels: labels)
    case .anyType:
      return .anyType
    case .memberResults(let results):
      return .memberResults(results.map(transform))
    }
  }
}

// MARK: Conformances

extension MemberLookupResult: Sendable where Result: Sendable {}
extension MemberLookupResult: Equatable where Result: Equatable {}
extension MemberLookupResult: Hashable where Result: Hashable {}

// MARK: Debug Description

extension MemberLookupResult {
  internal func _describe(describeMembers: ([Result]) -> String) -> String {
    switch self {
    case .function(let argumentCount):
      return ".function(argumentCount: \(argumentCount))"
    case .tuple(let labels):
      return ".tuple(\(labels.map({ $0?.name ?? "_"}))"
    case .anyType:
      return ".anyType"
    case .memberResults(let members):
      return ".memberResults([\(describeMembers(members))])"
    }
  }
}

extension MemberLookupResult: CustomDebugStringConvertible where Result: CustomDebugStringConvertible {
  public var debugDescription: String {
    _describe(describeMembers: { members in
      members.map({ "```\($0.debugDescription)```" }).joined(separator: "\n")
    })
  }
}
