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

/// A global type name, `Swift::Int._(MyFileA.swift)::MyType`.
///
/// ### File-Name Specifier
///
/// We use the '_(FileName.swift)::MyType' notation to describe
/// an internal type declared in 'FileName.swift'. This notation
/// gives us an unambiguous way to refer to types of the same name
/// in our module. Types exposed as public/usable-from-inline
/// from an external module should have a unique name. Also, types
/// of the same name within the same file are invalid redeclarations.
@_spi(_QualifiedLookupTests)
public struct GlobalTypeName: Sendable, Hashable, CustomDebugStringConvertible {
  public enum Qualifier: Sendable, Hashable {
    case `internal`(fileID: SyntaxIdentifier)
    case external(moduleName: Identifier)

    fileprivate init(file: SourceFileSyntax, module: Identifier, internalModule: Identifier) {
      if module == internalModule {
        self = GlobalTypeName.Qualifier.internal(fileID: file.id)
      } else {
        self = GlobalTypeName.Qualifier.external(moduleName: module)
      }
    }

    /// Like `CustomDebugStringConvertible`'s `debugDescription` but accepts
    /// a `describeFileID` closure to get the file names.
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
      _uncheckedQualifier qualifier: GlobalTypeName.Qualifier,
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
    public init(
      name: Identifier,
      file: SourceFileSyntax,
      module: ModuleName,
      symbolTable: borrowing SymbolTable
    ) {
      assert(
        symbolTable.moduleMap[file] == module,
        "[SwiftLexicalLookup] Internal error: File registered under '\(symbolTable.moduleMap[file]?.name ?? "nil")', and not the given module '\(module.name)'"
      )

      self.init(
        _uncheckedQualifier: GlobalTypeName.Qualifier(
          file: file,
          module: module,
          internalModule: symbolTable.moduleName
        ),
        name: name,
        debugFileMap: symbolTable.debugFileMap
      )
    }

    public var debugDescription: String {
      let qualifierDescription = qualifier._describe(describeFileID: debugFileMap.describeFileID(_:))
      return "\(qualifierDescription)::\(name.name)"
    }
  }

  /// The type's components.
  /// Invariant: `components.count >= 1`
  public let components: [Component]

  /// Creates a a global type with the given components; returns `nil` if no
  /// components are provided
  public init?(components: [Component]) {
    guard !components.isEmpty else { return nil }
    self.components = components
  }

  var baseComponent: Component {
    // Asserted at init
    components.first!
  }
  /// If this is not a top-level type, break it up into a base and member.
  var baseAndMember: (base: GlobalTypeName, member: Component)? {
    var baseComponents = components
    // We have at least one component according to initializer precondition
    let member = baseComponents.popLast()!
    guard let base = GlobalTypeName(components: baseComponents) else {
      return nil
    }
    return (base, member)
  }

  public func addingComponents(_ tailComponents: [Component]) -> GlobalTypeName {
    // Shouldn't return `nil` because `self.components` should be nonempty
    guard let newType = GlobalTypeName(components: components + tailComponents) else {
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

/// A local type is a type declared within a `CodeBlockItemListSyntax`, e.g.,
/// in a while loop or function body.
///
/// Array of identifiers, e.g., `A.B.C` for
/// ```swift
/// func f() {
///   struct A { struct B { struct C {} } }
/// }
/// ```
@_spi(_QualifiedLookupTests)
public struct LocalTypeName: Sendable, Hashable, CustomDebugStringConvertible {
  /// The local scope at which this type is declared.
  let scope: Attached<CodeBlockItemListSyntax>
  /// The type's components
  /// Invariant: `components.count >= 1`
  private(set) var components: [Identifier]

  /// Creates a local-type name from the given components; returns `nil`
  /// if no components are provided.
  init?(scope: Attached<CodeBlockItemListSyntax>, components: [Identifier]) {
    // Upholds invariant
    guard !components.isEmpty else { return nil }

    self.scope = scope
    self.components = components
  }

  init(scope: Attached<CodeBlockItemListSyntax>, base: Identifier) {
    // We force unwrap because we provide a component
    self.init(scope: scope, components: [base])!
  }

  consuming func addingComponents(_ tailComponents: [Identifier]) -> LocalTypeName {
    var copy = self
    copy.components.append(contentsOf: tailComponents)
    return copy
  }

  /// The debug description is NOT deterministic (depends on the scope id's hash value)
  public var debugDescription: String {
    let componentsDescription = components.map(\.name).joined(separator: ".")
    return "\(scope.node.id.hashValue)>\(componentsDescription)"
  }
}

/// A globally unique type name. Either a global type (top-level type or nested
/// under another global type), or a local type (nested in a `CodeBlockItemListSyntax`
/// like a `while` loop or function body.)
@_spi(_QualifiedLookupTests)
public enum TypeName: Sendable, Hashable, CustomDebugStringConvertible {
  /// Specifies top-level type: a collection of internal and external components
  case global(GlobalTypeName)
  // Specifies an (internal) local scope and a dot-separated sequence of identifiers.
  case local(LocalTypeName)

  public var debugDescription: String {
    switch self {
    case .global(let globalType):
      return globalType.debugDescription
    case .local(let localType):
      return localType.debugDescription
    }
  }
}
