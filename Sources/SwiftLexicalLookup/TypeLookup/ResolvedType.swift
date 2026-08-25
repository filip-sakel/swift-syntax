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

// MARK: [Global]ResolvedTypeSyntax

extension TypeResolver {
  /// A `GlobalNominalTypeRef` and the syntax that was resolved.
  @_spi(_QualifiedLookupTests)
  public struct GloballyResolvedTypeSyntax: CustomDebugStringConvertible, Sendable {
    public let type: TypeGraph.GlobalNominalTypeRef
    public let syntax: Attached<TypeLikeSyntax>

    public var debugDescription: String {
      type.debugDescription
    }
  }

  /// A `NominalTypeRef` and the syntax that was resolved.
  @_spi(_QualifiedLookupTests)
  public struct ResolvedTypeSyntax: CustomDebugStringConvertible, Sendable {
    public let type: TypeGraph.NominalTypeRef
    public let syntax: Attached<TypeLikeSyntax>

    public var debugDescription: String {
      type.debugDescription
    }
    var _succinctDescription: String {
      switch type.storage {
      case .global(let global):
        return global.name.debugDescription
      case .local(let nominalDecl):
        return nominalDecl._memberlessDescription
      }
    }
  }
}

extension TypeResolver.ResolvedTypeSyntax {
  /// Map from a `GlobalNominalTypeRef` to a `NominalTypeRef`
  init(global: TypeResolver.GloballyResolvedTypeSyntax) {
    self.init(
      type: TypeGraph.NominalTypeRef(globalReference: global.type),
      syntax: global.syntax
    )
  }
}

// MARK: ResolvedType

extension TypeResolver {
  @_spi(_QualifiedLookupTests)
  public typealias TypeResult = GenericTypeResult<ResolvedTypeSyntax>

  @_spi(_QualifiedLookupTests)
  public typealias TestTypeResult = GenericTypeResult<Character>

  /// The type result of structural type resolution. `Result`
  /// represents a nominal type.
  @_spi(_QualifiedLookupTests)
  public indirect enum GenericTypeResult<NominalType: CustomDebugStringConvertible & Sendable>: Sendable {
    /// E.g. `(A) -> ()`
    case function(argumentCount: Int)
    /// E.g. `(a: A, _: B)`
    case tuple(labels: [Identifier?])
    /// Either a single type or a composition of protocols/classes.
    case nominalTypes([NominalType])
    /// `Any` or suppressed types like `~Copyable`
    case anyType
    /// E.g. `A.Type`, `((A, B).Type).Type`
    case metatype(base: GenericTypeResult)
    // E.g. no type `A` in scope
    case failure(TypeResolver.GenericFailure<NominalType>)

    /// Maps the nominal types in `nominalTypes`.
    public func mapNominals<NewNominalType>(
      _ transform: (NominalType) -> NewNominalType
    ) -> GenericTypeResult<NewNominalType> {
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
      case .failure(let failure):
        return .failure(failure._map(mapNominal: transform))
      }
    }
  }
}

// MARK: Debug Description

extension TypeResolver.GenericTypeResult where NominalType == String {
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
    case .failure(let failure):
      return ".failure(\(failure._debugDescription))"
    }
  }
}

@_spi(_QualifiedLookupTests)
extension TypeResolver.GenericTypeResult: CustomDebugStringConvertible {
  public var debugDescription: String {
    mapNominals(\.debugDescription)._debugDescription
  }
}
