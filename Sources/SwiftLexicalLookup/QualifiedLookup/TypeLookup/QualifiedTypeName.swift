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
  public enum Qualifier: Sendable, Hashable {
    case `internal`(fileID: SyntaxIdentifier)
    case external(moduleName: Identifier)

    fileprivate init(file: SourceFileSyntax, module: Identifier, internalModule: Identifier) {
      if module == internalModule {
        self = QualifiedTypeNameGlobalType.Qualifier.internal(fileID: file.id)
      } else {
        self = QualifiedTypeNameGlobalType.Qualifier.external(moduleName: module)
      }
    }

    fileprivate func _describe(describeFileID: (SyntaxIdentifier) -> String) -> String {
      switch self {
      case .internal(let fileID):
        "_(\(describeFileID(fileID)))"
      case .external(let moduleName):
        "\(moduleName.name)"
      }
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

    fileprivate init(
      _uncheckedQualifier qualifier: QualifiedTypeNameGlobalType.Qualifier,
      name: Identifier,
      debugFileMap: DebugFileMap
    ) {
      self.qualifier = qualifier
      self.name = name
      self.debugFileMap = debugFileMap
    }

    /// Creates a component named `name` in the file `file` in the module `module`
    /// with respect to the given symbol table.
    ///
    /// Important: The file and module must be mapped as such in the symbol table.
    @_spi(_QualifiedLookup) public init(
      name: Identifier,
      file: SourceFileSyntax,
      module: SymbolTable3.Module,
      symbolTable: borrowing SymbolTable3
    ) {
      assert(
        symbolTable.moduleMap[file] == module,
        "[SwiftLexicalLookup] Internal error: File registered under '\(symbolTable.moduleMap[file]?.name ?? "nil")', and not the given module '\(module.name)'"
      )

      self.init(
        _uncheckedQualifier: QualifiedTypeNameGlobalType.Qualifier(
          file: file,
          module: module,
          internalModule: symbolTable.moduleName
        ),
        name: name,
        debugFileMap: DebugFileMap(symbolTable: symbolTable)
      )
    }

    public var debugDescription: String {
      let qualifierDescription = qualifier._describe(describeFileID: debugFileMap.describeFileID(_:))
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

  public var debugDescription: String {
    return components.map(\.debugDescription).joined(separator: ".")
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
  case nestedScope(scope: SourceFileRoot<CodeBlockItemListSyntax>, type: QualifiedTypeNameNestedType)

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
    switch self {
    case .topLevel(let globalType):
      return globalType.debugDescription
    case .nestedScope(let scope, let nestedType):
      return "\(scope.node.id.hashValue)>\(nestedType.debugDescription)"
    }
  }
}
