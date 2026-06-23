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

// A global type name, `Swift::Int._(MyFileA.swift)::MyType`.
public struct QualifiedTypeNameGlobalType: Hashable, CustomDebugStringConvertible {
  public enum Qualifier: Hashable, CustomDebugStringConvertible {
    case `internal`(fileID: SyntaxIdentifier)
    case external(moduleName: Identifier)

    public var debugDescription: String {
      switch self {
      case .internal(let fileID):
        "_(\(fileID.hashValue))"
      case .external(let moduleName):
        "\(moduleName.name)"
      }
    }
  }
  /// A component of a qualified type name, external or internal. For instance,
  /// `Swift::Int` (external) and `_(FileA.swift)::MyType` (internal).
  public struct Component: Hashable, CustomDebugStringConvertible {
    let qualifier: Qualifier
    let name: Identifier

    public var debugDescription: String {
      return "\(qualifier.debugDescription)::\(name.name)"
    }
  }

  /// The types components. Guaranteed to be non-empty
  public let components: [Component]

  /// Creates a a global type with the given components.
  /// - Returns: `nil` if no components are provided
  public init?(components: [Component]) {
    // precondition(
    //   !components.isEmpty,
    //   "[SwiftLexicalLookup] Internal error: Cannot have qualified type name with no components"
    // )
    guard !components.isEmpty else { return nil }
    self.components = components
  }

  public func addingComponents(_ tailComponents: [Component]) -> QualifiedTypeNameGlobalType {
    // Shouldn't return `nil` because `self.components` should be nonempty
    guard let newType = QualifiedTypeNameGlobalType(components: components + tailComponents) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly got `QualifiedTypeNameNestedType` instance with empty components."
      )
    }
    return newType
  }

  public var debugDescription: String {
    return components.map(\.debugDescription).joined(separator: ".")
  }
}

// Array of identifiers, e.g., `A.B.C`
public indirect enum QualifiedTypeNameNestedType: Hashable, CustomDebugStringConvertible {
  case base(Identifier)
  case member(base: QualifiedTypeNameNestedType, name: Identifier)

  private var _components: [Identifier] {
    switch self {
    case .base(let name):
      return [name]
    case .member(let base, let name):
      return base._components + [name]
    }
  }

  public init?(components: [Identifier]) {
    guard let first = components.first else { return nil }
    // TODO: Optimize
    self = QualifiedTypeNameNestedType.base(first).addingComponents(Array(components.dropFirst()))
  }

  // TODO: Make more efficient
  func addingComponents(_ tailComponents: [Identifier]) -> QualifiedTypeNameNestedType {
    tailComponents.reduce(
      self,
      { currentBase, tail in
        QualifiedTypeNameNestedType.member(base: currentBase, name: tail)
      }
    )
  }

  public var debugDescription: String {
    _components.map(\.name).joined(separator: ".")
  }
}

// TODO: Copy relevant comments from `ResolvedScope` and `ResolvedTypeName`
@_spi(_QualifiedLookup) public enum QualifiedTypeName: Hashable, CustomDebugStringConvertible {
  /// Specifies top-level type: a collection of internal and external components
  case topLevel(QualifiedTypeNameGlobalType)
  // Specifies an (internal) nested-level scope and a dot-separated sequence of identifiers.
  case nestedScope(scope: CodeBlockItemListSyntax, type: QualifiedTypeNameNestedType)

  public var debugDescription: String {
    switch self {
    case .topLevel(let globalType):
      return globalType.debugDescription
    case .nestedScope(let scope, let nestedType):
      return "\(scope.id.hashValue)>\(nestedType.debugDescription)"
    }
  }
}
