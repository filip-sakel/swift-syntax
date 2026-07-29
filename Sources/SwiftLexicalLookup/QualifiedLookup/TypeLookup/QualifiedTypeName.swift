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
@_spi(_QualifiedLookup) public struct QualifiedTypeNameGlobalType: Sendable, Hashable, CustomDebugStringConvertible {
  public enum Qualifier: Sendable, Hashable, CustomDebugStringConvertible {
    case `internal`(fileID: SyntaxIdentifier)
    case external(moduleName: Identifier)

    public func describe(describeFileID: (SyntaxIdentifier) -> String) -> String {
      switch self {
      case .internal(let fileID):
        "_(\(describeFileID(fileID)))"
      case .external(let moduleName):
        "\(moduleName.name)"
      }
    }

    public var debugDescription: String {
      describe(describeFileID: \.hashValue.description)
    }
  }
  /// A component of a qualified type name, external or internal. For instance,
  /// `Swift::Int` (external) and `_(FileA.swift)::MyType` (internal).
  public struct Component: Sendable, Hashable, CustomDebugStringConvertible {
    // TODO: Consider using the module identifier instead and just always
    // keep track of the file? But is that actually useful in the compilation model?
    // I.e. Would we be performing lookup on a different module?
    let qualifier: Qualifier
    let name: Identifier
    let debugFileMap: DebugFileMap

    // @_spi(_QualifiedLookup) public init(qualifier: QualifiedTypeNameGlobalType.Qualifier, name: Identifier) {
    //   self.qualifier = qualifier
    //   self.name = name
    // }

    @_spi(_QualifiedLookup) public init?(
      file: SourceFileSyntax,
      name: Identifier,
      symbolTable: borrowing SymbolTable3
    ) {
      // TODO: Maybe improve diagnostics for when file isn't in the table

      guard let moduleName = symbolTable.moduleMap[file] else {
        return nil
      }

      // Compute the qualifier
      if moduleName == symbolTable.moduleName {
        self.qualifier = Qualifier.internal(fileID: file.id)
      } else {
        self.qualifier = Qualifier.external(moduleName: moduleName)
      }

      self.name = name
      self.debugFileMap = DebugFileMap(symbolTable: symbolTable)
    }

    @_spi(_QualifiedLookup) public func _describe(describeFileID: (SyntaxIdentifier) -> String) -> String {
      return "\(qualifier.describe(describeFileID: describeFileID))::\(name.name)"
    }

    public var debugDescription: String {
      let qualifierDescription = qualifier.describe(describeFileID: debugFileMap.describeFileID(_:))
      return "\(qualifierDescription)::\(name.name)"
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

  var baseComponent: Component {
    // Asserted at init
    components.first!
  }
  /// If this is not a top-level type, break it up into a base and member.
  var baseAndMember: (base: QualifiedTypeNameGlobalType, member: Component)? {
    var baseComponents = components
    // We have at least one component according to initializer precondition
    let member = baseComponents.popLast()!
    guard let base = QualifiedTypeNameGlobalType(components: baseComponents) else {
      return nil
    }
    return (base, member)
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

  @_spi(_QualifiedLookup) public func _describe(describeFileID: (SyntaxIdentifier) -> String) -> String {
    return components.map({ $0._describe(describeFileID: describeFileID) }).joined(separator: ".")
  }

  public var debugDescription: String {
    _describe(describeFileID: \.hashValue.description)
  }
}

// Array of identifiers, e.g., `A.B.C`
@_spi(_QualifiedLookup)
public indirect enum QualifiedTypeNameNestedType: Sendable, Hashable, CustomDebugStringConvertible {
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

  /// If this is not a top-level type, break it up into a base and member.
  var baseAndMembers: (base: QualifiedTypeNameNestedType, member: Identifier)? {
    switch self {
    case .base:
      return nil
    case .member(let base, let member):
      return (base, member)
    }
    // var baseComponents = _components
    // // We have at least one component according to initializer precondition
    // let member = baseComponents.popLast()!
    // guard let base = QualifiedTypeNameGlobalType(components: baseComponents) else {
    //   return nil
    // }
    // return (base, member)
  }

  public var debugDescription: String {
    _components.map(\.name).joined(separator: ".")
  }
}

// TODO: Copy relevant comments from `ResolvedScope` and `ResolvedTypeName`
@_spi(_QualifiedLookup) public enum QualifiedTypeName: Sendable, Hashable, CustomDebugStringConvertible {
  /// Specifies top-level type: a collection of internal and external components
  case topLevel(QualifiedTypeNameGlobalType)
  // Specifies an (internal) nested-level scope and a dot-separated sequence of identifiers.
  case nestedScope(scope: CodeBlockItemListSyntax, type: QualifiedTypeNameNestedType)

  @_spi(_QualifiedLookup) public func _describe(describeFileID: (SyntaxIdentifier) -> String) -> String {
    switch self {
    case .topLevel(let globalType):
      return globalType._describe(describeFileID: describeFileID)
    case .nestedScope(let scope, let nestedType):
      return "\(scope.id.hashValue)>\(nestedType.debugDescription)"
    }
  }

  var baseAndMemberName: (base: QualifiedTypeName, memberName: Identifier)? {
    switch self {
    case .topLevel(let topLevelName):
      guard let (topLevelBaseName, memberComponent) = topLevelName.baseAndMember else { return nil }
      return (QualifiedTypeName.topLevel(topLevelBaseName), memberComponent.name)
    case .nestedScope(let scope, let nestedName):
      guard let (nestedBaseName, memberName) = nestedName.baseAndMembers else { return nil }
      return (QualifiedTypeName.nestedScope(scope: scope, type: nestedBaseName), memberName)
    }
  }

  public var debugDescription: String {
    _describe(describeFileID: \.hashValue.description)
  }
}
