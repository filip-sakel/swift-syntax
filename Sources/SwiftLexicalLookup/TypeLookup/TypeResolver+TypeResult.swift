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

// MARK: GlobalResolvedTypeSyntax

extension TypeResolver {
  /// A `GlobalNominalTypeRef` and the syntax that was resolved.
  @_spi(_QualifiedLookupTests)
  public struct GloballyResolvedTypeSyntax: CustomDebugStringConvertible, Sendable {
    public let type: TypeGraph.GlobalTypeRef
    public let syntax: Attached<TypeLikeSyntax>

    public var debugDescription: String {
      type.debugDescription
    }
  }
}

// MARK: GlobalResolvedTypeSyntax

/// A type used by `GenericTypeResult` to represent nominal types.
/// SwiftLexicalLookup just uses `TypeResolver.ResolvedTypeSyntax`
/// and testing uses `Character` markers.
@_spi(_QualifiedLookupTests)
public protocol NominalTypeResultProtocol: CustomDebugStringConvertible, Sendable {}

extension TypeResolver {
  /// A `NominalTypeRef` and the syntax that was resolved.
  @_spi(_QualifiedLookupTests)
  public struct ResolvedTypeSyntax: NominalTypeResultProtocol {
    public let type: TypeGraph.TypeRef
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
      type: TypeGraph.TypeRef(globalReference: global.type),
      syntax: global.syntax
    )
  }
}

// MARK: ResolvedType

extension TypeResolver {
  @_spi(_QualifiedLookupTests)
  public typealias TypeResult = GenericTypeResult<ResolvedTypeSyntax>

  /// The type result of structural type resolution. `Result`
  /// represents a nominal type.
  @_spi(_QualifiedLookupTests)
  public indirect enum GenericTypeResult<NominalType: NominalTypeResultProtocol>: Sendable {
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

extension TypeResolver.GenericTypeResult: CustomDebugStringConvertible {
  @_spi(_QualifiedLookupTests)
  public var debugDescription: String {
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
      return ".nominalTypes([\(members.map(\.debugDescription).joined(separator: ", "))])"
    case .failure(let failure):
      return ".failure(\(failure.debugDescription))"
    }
  }
}
