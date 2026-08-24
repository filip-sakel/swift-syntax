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
/// Used by `TypeGraph` as unique identifier for types.
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
public struct GlobalTypeName: Sendable, Hashable {
  public enum Qualifier: Sendable, Hashable {
    case `internal`(fileID: SyntaxIdentifier)
    case external(moduleName: Identifier)
  }
  /// A component of a qualified type name, external or internal. For instance,
  /// `Swift::Int` (external) and `_(FileA.swift)::MyType` (internal).
  public struct Component: Sendable, Hashable {
    private let qualifier: Qualifier
    private let name: Identifier
    private let debugFileMap: DebugFileMap

    fileprivate init(_uncheckedQualifier qualifier: Qualifier, name: Identifier, debugFileMap: DebugFileMap) {
      self.qualifier = qualifier
      self.name = name
      self.debugFileMap = debugFileMap
    }
  }

  /// The type's components.
  /// Invariant: `components.count >= 1`
  public private(set) var components: [Component]

  /// Creates a a global type with the given components; returns `nil` if no
  /// components are provided
  private init?(_components: [Component]) {
    guard !_components.isEmpty else { return nil }
    self.components = _components
  }
}

// MARK: Name Construction

extension GlobalTypeName.Qualifier {
  fileprivate init(file: SourceFileSyntax, module: Identifier, internalModule: Identifier) {
    if module == internalModule {
      self = .internal(fileID: file.id)
    } else {
      self = .external(moduleName: module)
    }
  }
}

extension GlobalTypeName.Component {
  /// Creates a component named `name` in the file `file` in the module `module`
  /// with respect to the given symbol table.
  ///
  /// Important: The file and module must be mapped as such in the symbol table.
  init(
    name: Identifier,
    file: SourceFileSyntax,
    module: ModuleName,
    symbolTable: borrowing SymbolTable
  ) {
    assert(
      symbolTable.getFileInfo(file)?.module == module,
      "[SwiftLexicalLookup] Internal error: File registered under '\(symbolTable.getFileInfo(file)?.module.name ?? "nil")', and not the given module '\(module.name)'"
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
}

extension GlobalTypeName {
  /// Creates a a global type with the given component.
  init(component: Component) {
    // Upholds the invariant because we provide exactly one component
    self.components = [component]
  }

  /// Adds the given component to a type name to get the name of a nested type.
  public func addingComponent(_ tailComponent: Component) -> GlobalTypeName {
    var copy = self
    // Maintains the invariant, as we're just adding a component.
    copy.components.append(tailComponent)
    return copy
  }
}

// MARK: Name Deconstruction

extension GlobalTypeName {
  /// Break this name up into a base name and a member, if not a top-level type.
  var baseAndMember: (base: GlobalTypeName, member: Component)? {
    var baseComponents = components
    // We have at least one component according to initializer precondition
    let member = baseComponents.popLast()!
    guard let base = GlobalTypeName(_components: baseComponents) else {
      return nil
    }
    return (base, member)
  }
}

// MARK: Nominal-Type Ref

/// A reference to a resolved global nominal type vended by `TypeGraph`.
/// Contains the unique name and resolved main declaration.
@_spi(_QualifiedLookupTests)
public struct GlobalNominalTypeRef: Hashable, Sendable {
  let name: GlobalTypeName
  let mainDecl: Attached<NominalTypeDeclSyntax>
  let _version: Int

  internal init(name: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>, _version: Int) {
    self.name = name
    self.mainDecl = mainDecl
    self._version = _version
  }
}

/// A reference to a resolved nominal type (global or local) vended by
/// `TypeGraph`. Contains the unique name and resolved main declaration.
@_spi(_QualifiedLookupTests)
public struct NominalTypeRef: Hashable, Sendable {
  public enum Storage: Hashable, Sendable {
    /// Local nominal types cannot be extended
    case local(Attached<NominalTypeDeclSyntax>)
    case global(GlobalNominalTypeRef)
  }

  public let storage: Storage

  /// Important: Only `TypeGraph` should use this initializer.
  init(globalReference: GlobalNominalTypeRef) {
    storage = .global(globalReference)
  }
  /// Important: Only `TypeGraph` should use this initializer.
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

extension GlobalTypeName.Qualifier {
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

extension GlobalTypeName.Component: CustomDebugStringConvertible {
  /// E.g. '_(MyFile.swift)::MyType', 'ExternalModule::OtherType'
  public var debugDescription: String {
    let qualifierDescription = qualifier._describe(describeFileID: debugFileMap.describeFileID(_:))
    return "\(qualifierDescription)::\(name.name)"
  }
}

extension GlobalTypeName: CustomDebugStringConvertible {
  /// E.g. '_(MyFile.swift)::MyType.ExternalModule::OtherType'
  public var debugDescription: String {
    return components.map(\.debugDescription).joined(separator: ".")
  }
}

extension GlobalNominalTypeRef: CustomDebugStringConvertible {
  /// E.g. '_(InternalFile.swift)::MyType.ExternalModule::OtherType (v0, structDecl)'
  public var debugDescription: String {
    return "\(name.debugDescription) (v\(_version), \(mainDecl.kind))"
  }
}

@_spi(_QualifiedLookupTests)
extension NominalTypeRef: CustomDebugStringConvertible {
  /// E.g. 'struct LocalDecl {} (local)' or global
  /// '_(InternalFile.swift)::MyType.ExternalModule::OtherType (v0, structDecl)'
  public var debugDescription: String {
    switch storage {
    case .global(let globalReference):
      return globalReference.debugDescription
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription) (local)"
    }
  }

  /// E.g. a local 'struct LocalDecl {}' or global
  /// '_(InternalFile.swift)::MyType.ExternalModule::OtherType'
  public var _succinctDescription: String {
    switch storage {
    case .global(let globalReference):
      return globalReference.name.debugDescription
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription)"
    }
  }

  /// Extracts the global-type name if a global reference. Useful for testing.
  public var globalName: GlobalTypeName? {
    guard case .global(let globalReference) = storage else { return nil }

    return globalReference.name
  }
}
