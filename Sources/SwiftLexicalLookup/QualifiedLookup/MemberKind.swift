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

/// Describes a kind of value declaration to filter results in qualified lookup.
///
/// Each base kind is additive (e.g. include instance members, include global
/// declarations, etc.). To remove a kind, use OptionSet's subtraction operator.
@_spi(_QualifiedLookup) public struct MemberKind: OptionSet, Hashable, Sendable, CustomDebugStringConvertible {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Include instance methods
  public static let includeInstance = MemberKind(rawValue: 1 << 0)
  /// Include public static decls that aren't types
  public static let includeNonTypeStatic = MemberKind(rawValue: 1 << 1)
  /// Include types (public statically available)
  public static let includeTypes = MemberKind(rawValue: 1 << 2)
  /// Include globals
  public static let includeGlobals = MemberKind(rawValue: 1 << 3)

  public static let includeStatic: MemberKind = [.includeNonTypeStatic, .includeTypes]
  public static let includeAllMembers: MemberKind = [.includeInstance, .includeStatic]
  public static let includeAll: MemberKind = [.includeAllMembers, .includeGlobals]

  public static let `default` = MemberKind.includeInstance

  /// Return a copy of this kind, excluding instance members.
  public func onlyStatic() -> MemberKind {
    self.subtracting([.includeInstance])
  }

  public var debugDescription: String {
    // Special cases
    if self == .includeStatic { return "[.includeStatic]" }
    if self == .includeAllMembers { return "[.includeAllMembers]" }
    if self == .includeAll { return "[.includeAll]" }

    // Map the core properties
    let corePropDescriptions = [
      MemberKind.includeInstance: ".includeInstance",
      MemberKind.includeNonTypeStatic: ".includeNonTypeStatic",
      MemberKind.includeTypes: ".includeTypes",
      MemberKind.includeGlobals: ".includeGlobals",
    ]
    // Collect all the core properties we have
    let commaSeparatedProps =
      corePropDescriptions
      .compactMap({ (key, description) in
        guard self.contains(key) else { return nil }
        return description
      })
      .joined(separator: ", ")

    return "[\(commaSeparatedProps)]"
  }
}

extension ValueDeclSyntax {
  /// Check if this value declaration fits the given kind.
  public func isKind(_ memberKind: MemberKind) -> Bool {
    // We shouldn't surface declarations that are always global,
    // currently just macros.
    guard !self.isAlwaysGlobal else { return false }

    // Check whether it's a type
    let isTypeDecl = self.isTypeDecl
    if isTypeDecl && memberKind.contains(.includeTypes) {
      return true
    }

    // Check whether it's non-type static
    let isStatic = self.isStatic
    if !isTypeDecl && isStatic == .success(true) && memberKind.contains(.includeNonTypeStatic) {
      return true
    }

    // Checker whether it's an instance member
    if isStatic == .success(false) && memberKind.contains(.includeInstance) {
      return true
    }

    // No matches
    return false
  }
}
