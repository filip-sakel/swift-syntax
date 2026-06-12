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
public struct QualifiedTypeNameGlobalType: CustomDebugStringConvertible {
  public enum Qualifier {
    case `internal`(fileID: String)
    case external(moduleName: Identifier)
  }
  /// A component of a qualified type name, external or internal. For instance,
  /// `Swift::Int` (external) and `_(FileA.swift)::MyType` (internal).
  public typealias Component = (qualifier: Qualifier, name: Identifier)

  public let components: [Component]

  public init(components: [Component]) {
    precondition(
      !components.isEmpty,
      "[SwiftLexicalLookup] Internal error: Cannot have qualified type name with no components"
    )
    self.components = components
  }

  public var debugDescription: String {
    func describeQualifier(_ qualifier: Qualifier) -> String {
      switch qualifier {
      case .internal(let fileID):
        return "_(\(fileID))"
      case .external(let moduleName):
        return moduleName.name
      }
    }
    func describeComponent(_ component: Component) -> String {
      "\(describeQualifier(component.qualifier))::\(component.name.name)"
    }

    return components.map(describeComponent).joined(separator: ".")
  }
}

// Array of identifiers, e.g., `A.B.C`
public indirect enum QualifiedTypeNameNestedType: CustomDebugStringConvertible {
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

  public var debugDescription: String {
    _components.map(\.name).joined(separator: ".")
  }
}

// TODO: Copy relevant comments from `ResolvedScope` and `ResolvedTypeName`
@_spi(_QualifiedName) public enum QualifiedTypeName {
  /// Specifies top-level type: a collection of internal and external components
  case topLevel(QualifiedTypeNameGlobalType)
  // Specifies an (internal) nested-level scope and a dot-separated sequence of identifiers.
  case nestedScope(scope: CodeBlockItemListSyntax, type: QualifiedTypeNameNestedType)
}
