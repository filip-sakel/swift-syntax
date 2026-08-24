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
@_spi(_QualifiedLookupTests)
public indirect enum ResolvedType<NominalType> {
  /// E.g. `(A) -> ()`
  case function(argumentCount: Int)
  /// E.g. `(a: A, _: B)`
  case tuple(labels: [Identifier?])
  /// Either a single type or a composition of protocols/classes.
  case nominalTypes([NominalType])
  /// `Any` or suppressed types like `~Copyable`
  case anyType
  /// E.g. `A.Type`, `((A, B).Type).Type`
  case metatype(base: ResolvedType)

  public func mapNominals<NewNominalType>(
    _ transform: (NominalType) -> NewNominalType
  ) -> ResolvedType<NewNominalType> {
    switch self {
    case .function(let argumentCount):
      return .function(argumentCount: argumentCount)
    case .tuple(let labels):
      return .tuple(labels: labels)
    case .anyType:
      return .anyType
    case .metatype(let base):
      return .metatype(base: base.mapNominals(transform))
    case .nominalTypes(let results):
      return .nominalTypes(results.map(transform))
    }
  }
}

// MARK: Conformances

extension ResolvedType: Sendable where NominalType: Sendable {}
extension ResolvedType: Equatable where NominalType: Equatable {}
extension ResolvedType: Hashable where NominalType: Hashable {}

// MARK: Debug Description

extension ResolvedType where NominalType == String {
  @_spi(_QualifiedLookupTests)
  public var _debugDescription: String {
    switch self {
    case .function(let argumentCount):
      return ".function(argumentCount: \(argumentCount))"
    case .tuple(let labels):
      return ".tuple(\(labels.map({ $0?.name ?? "_"}))"
    case .anyType:
      return ".anyType"
    case .metatype(let base):
      return ".metatype(base: \(base.debugDescription)"
    case .nominalTypes(let members):
      return ".nominalTypes([\(members.joined(separator: ", "))])"
    }
  }
}

@_spi(_QualifiedLookupTests)
extension ResolvedType: CustomDebugStringConvertible where NominalType: CustomDebugStringConvertible {
  public var debugDescription: String {
    mapNominals(\.debugDescription)._debugDescription
  }
}

// MARK: ResolvedTypeSyntax

/// A resolved type syntax consists of a resolved type and the syntax that was resolved.
@_spi(_QualifiedLookup)
public struct GenericResolvedTypeSyntax<ResolvedType: Sendable & Hashable & CustomDebugStringConvertible>:
  Sendable, CustomDebugStringConvertible
{
  public let type: ResolvedType
  public let syntax: Attached<TypeLikeSyntax>

  @_spi(_QualifiedLookupTests)
  public init(
    type: ResolvedType,
    syntax: Attached<TypeLikeSyntax>,
  ) {
    self.type = type
    self.syntax = syntax
  }

  public var debugDescription: String {
    type.debugDescription
  }
}
/// The default resolved type syntax: a `NominalTypeRef` and the syntax that was resolved.
@_spi(_QualifiedLookup)
public typealias ResolvedTypeSyntax = GenericResolvedTypeSyntax<NominalTypeRef>

extension ResolvedTypeSyntax {
  /// Map from a `GlobalNominalTypeRef` to a `NominalTypeRef`
  init(globalTypeReference: GenericResolvedTypeSyntax<GlobalNominalTypeRef>) {
    self.init(
      type: NominalTypeRef(globalReference: globalTypeReference.type),
      syntax: globalTypeReference.syntax
    )
  }
}

extension GenericResolvedTypeSyntax where ResolvedType == NominalTypeRef {
  var _succinctDescription: String {
    switch type.storage {
    case .global(let global):
      return global.name.debugDescription
    case .local(let nominalDecl):
      return nominalDecl._memberlessDescription
    }
  }
}
