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

import SwiftIfConfig
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

    /// Important: Only `TypeGraph` should use this initializer.
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
    /// Important:
    /// 1. The file and module must be mapped as such in the symbol table.
    /// 2. Only `TypeGraph` should use this initializer.
    init(
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
  private init?(_components: [Component]) {
    guard !_components.isEmpty else { return nil }
    self.components = _components
  }

  /// Creates a a global type with the given component.
  /// Important: Only `TypeGraph` should use this initializer.
  init(component: Component) {
    // Force unwrap because we provide non-empty components.
    self.init(_components: [component])!
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
    guard let base = GlobalTypeName(_components: baseComponents) else {
      return nil
    }
    return (base, member)
  }

  public func addingComponents(_ tailComponents: [Component]) -> GlobalTypeName {
    // Shouldn't return `nil` because `self.components` should be nonempty
    guard let newType = GlobalTypeName(_components: components + tailComponents) else {
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

@_spi(_QualifiedLookupTests)
public struct GlobalNominalTypeRef: Hashable, Sendable, CustomDebugStringConvertible {
  let name: GlobalTypeName
  let mainDecl: Attached<NominalTypeDeclSyntax>
  let _version: Int

  internal init(name: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>, _version: Int) {
    self.name = name
    self.mainDecl = mainDecl
    self._version = _version
  }

  public var debugDescription: String {
    return "\(name.debugDescription) (v\(_version), \(mainDecl.kind))"
  }
}

@_spi(_QualifiedLookupTests)
public struct NominalTypeRef: Hashable, Sendable {
  public enum Storage: Hashable, Sendable {
    /// Local nominal types cannot be extended
    case local(Attached<NominalTypeDeclSyntax>)
    case global(GlobalNominalTypeRef)
  }

  public let storage: Storage

  init(globalReference: GlobalNominalTypeRef) {
    storage = .global(globalReference)
  }
  init(localNominalType: Attached<NominalTypeDeclSyntax>) {
    storage = .local(localNominalType)
  }

  /// The main declaration of this nominal reference
  ///
  /// Note: The main declaration helps in three ways:
  /// 1. To detect if we have a class/protocol for compositions
  /// 2. To find generic parameters
  /// 3. Testing if the resovled type match the expected main decl
  public var mainDecl: Attached<NominalTypeDeclSyntax> {
    switch storage {
    case .global(let globalReference):
      return globalReference.mainDecl
    case .local(let localDecl):
      return localDecl
    }
  }
}

// MARK: Debug

@_spi(_QualifiedLookupTests)
extension NominalTypeRef: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch storage {
    case .global(let globalReference):
      return globalReference.debugDescription
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription) (local)"
    }
  }

  public var _succinctDescription: String {
    switch storage {
    case .global(let globalReference):
      return globalReference.name.debugDescription
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription)"
    }
  }

  public var globalName: GlobalTypeName? {
    guard case .global(let globalReference) = storage else { return nil }

    return globalReference.name
  }
}
