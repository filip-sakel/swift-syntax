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

// MARK: GlobalTypeName

extension TypeGraph {
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
      // E.g. 'File.swift' or 'Subdirectory/OtherFile.swift'
      case `internal`(fileID: String)
      case external(moduleName: String)
    }
    /// A component of a qualified type name, external or internal. For instance,
    /// `Swift::Int` (external) and `_(FileA.swift)::MyType` (internal).
    public struct Component: Sendable, Hashable {
      private let qualifier: Qualifier
      private let name: String
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
}

// MARK: Name Construction

extension TypeGraph.GlobalTypeName.Qualifier {
  fileprivate init(file: SourceFileSyntax, fileInfo: FileInfo, internalModule: Identifier) {
    if fileInfo.module == internalModule {
      self = .internal(fileID: fileInfo.name)
    } else {
      self = .external(moduleName: fileInfo.module.name)
    }
  }
}

extension TypeGraph.GlobalTypeName.Component {
  /// Creates a component named `name` in the file `file` in the module `module`
  /// with respect to the given symbol table.
  ///
  /// Important: The file and module must be mapped as such in the symbol table.
  init(
    name: Identifier,
    file: SourceFileSyntax,
    fileInfo: FileInfo,
    symbolTable: borrowing SymbolTable
  ) {
    assert(
      symbolTable.getFileInfo(file)?.module == fileInfo.module,
      "[SwiftLexicalLookup] Internal error: File registered under '\(String(describing: symbolTable.getFileInfo(file)))', and not the given file info '\(fileInfo)'"
    )

    self.init(
      qualifier: TypeGraph.GlobalTypeName.Qualifier(
        file: file,
        fileInfo: fileInfo,
        internalModule: symbolTable.moduleName
      ),
      name: name.name
    )
  }
}

extension TypeGraph.GlobalTypeName {
  /// Creates a a global type with the given component.
  init(component: Component) {
    // Upholds the invariant because we provide exactly one component
    self.components = [component]
  }

  /// Adds the given component to a type name to get the name of a nested type.
  public func addingComponent(_ tailComponent: Component) -> TypeGraph.GlobalTypeName {
    var copy = self
    // Maintains the invariant, as we're just adding a component.
    copy.components.append(tailComponent)
    return copy
  }
}

// MARK: Name Deconstruction

extension TypeGraph.GlobalTypeName {
  /// Break this name up into a base name and a member, if not a top-level type.
  var baseAndMember: (base: TypeGraph.GlobalTypeName, member: Component)? {
    var baseComponents = components
    // We have at least one component according to initializer precondition
    let member = baseComponents.popLast()!
    guard let base = TypeGraph.GlobalTypeName(_components: baseComponents) else {
      return nil
    }
    return (base, member)
  }
}

extension TypeGraph.GlobalTypeName {
  /// Construct a `GlobalTypeName` whose `debugDescription` is the given string
  /// for testing. Any use outside of testing is unchecked and may result in
  /// crashes.
  @_spi(_QualifiedLookupTests)
  public init(_testName string: String, file: StaticString = #file, line: UInt = #line) {
    // This is very hacky but basically an external module + a type name will
    // print verbatim with a '::' between them. So, split the string at '::'
    // (which every global name has), and use the first part as the qualifier
    // and the tail as the "name".
    guard let firstQualifierSeparatorRange = string.firstRange(of: "::") else {
      fatalError("GlobalTypeName '\(string)' must have at least one qualifier separator '::'.")
    }
    let (firstQualifier, tail) = (
      string[..<firstQualifierSeparatorRange.lowerBound].description,
      string[firstQualifierSeparatorRange.upperBound...].description
    )
    self.init(component: Component(_testQualifier: Qualifier.external(moduleName: firstQualifier), name: tail))

    // Ensure we round-trip correctly
    precondition(
      self.debugDescription == string,
      "Unexpectedly parsed global type name '\(string)' wrong.",
      file: file,
      line: line
    )
  }
}

// MARK: Type Ref

extension TypeGraph {
  /// A reference to a resolved global nominal type vended by `TypeGraph`.
  /// Contains the unique name and resolved main declaration.
  @_spi(_QualifiedLookupTests)
  public struct GlobalTypeRef: Hashable, Sendable {
    let name: GlobalTypeName
    let mainDecl: Attached<NominalTypeDeclSyntax>
    let _version: Int

    internal init(name: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>, _version: Int) {
      self.name = name
      self.mainDecl = mainDecl
      self._version = _version
    }
  }
}

extension TypeGraph {
  /// A reference to a resolved nominal type (global or local) vended by
  /// `TypeGraph`. Contains the unique name and resolved main declaration.
  @_spi(_QualifiedLookupTests)
  public struct TypeRef: Hashable, Sendable {
    public enum Storage: Hashable, Sendable {
      /// Local nominal types cannot be extended
      case local(Attached<NominalTypeDeclSyntax>)
      case global(TypeGraph.GlobalTypeRef)
    }

    public let storage: Storage

    /// Important: Only `TypeGraph` should use this initializer.
    init(globalReference: TypeGraph.GlobalTypeRef) {
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
}

// MARK: Debug

extension TypeGraph.GlobalTypeName.Qualifier: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch self {
    case .internal(let fileID):
      "_(\(fileID))"
    case .external(let moduleName):
      "\(moduleName)"
    }
  }
}

extension TypeGraph.GlobalTypeName.Component: CustomDebugStringConvertible {
  /// E.g. '_(MyFile.swift)::MyType', 'ExternalModule::OtherType'
  public var debugDescription: String {
    "\(qualifier.debugDescription)::\(name)"
  }
}

extension TypeGraph.GlobalTypeName: CustomDebugStringConvertible {
  /// E.g. '_(MyFile.swift)::MyType.ExternalModule::OtherType'
  public var debugDescription: String {
    return components.map(\.debugDescription).joined(separator: ".")
  }
}

extension TypeGraph.GlobalTypeRef: CustomDebugStringConvertible {
  /// E.g. '_(InternalFile.swift)::MyType.ExternalModule::OtherType (v0, structDecl)'
  public var debugDescription: String {
    return "\(name.debugDescription) (v\(_version), \(mainDecl.kind))"
  }
}

@_spi(_QualifiedLookupTests)
extension TypeGraph.TypeRef: CustomDebugStringConvertible {
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
  public var globalName: TypeGraph.GlobalTypeName? {
    guard case .global(let globalReference) = storage else { return nil }

    return globalReference.name
  }
}

// MARK: Test Hooks

extension TypeGraph.GlobalTypeName.Component {
  @_spi(_QualifiedLookupTests)
  public init(_testQualifier qualifier: TypeGraph.GlobalTypeName.Qualifier, name: String) {
    self.init(
      qualifier: qualifier,
      name: name
    )
  }
}
