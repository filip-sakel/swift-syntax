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

import SwiftDiagnostics
import SwiftIfConfig
import SwiftSyntax

extension Array {
  /// Appends if the array has no duplicates using the given key
  private mutating func _indexAfterInsertingUnique<Key: Equatable, Value>(
    key: Key,
    default defaultValue: Value
  ) -> Int where Element == (key: Key, value: Value) {
    if let existingIndex = firstIndex(where: { $0.key == key }) {
      return existingIndex
    } else {
      let newIndex = count
      append((key, defaultValue))
      return newIndex
    }
  }
  /// Similar to dictionary's `subscript(_:default:)`.
  ///
  /// Only use for small array's and/or when it's important to maintain insertion order.
  fileprivate subscript<Key: Equatable, Value>(
    _key key: Key,
    default defaultValue: Value
  ) -> Value where Element == (key: Key, value: Value) {
    get {
      first(where: { $0.key == key })?.value ?? defaultValue
    }
    _modify {
      let index: Int
      if let existingIndex = firstIndex(where: { $0.key == key }) {
        index = existingIndex
      } else {
        let newIndex = count
        append((key, defaultValue))
        index = newIndex
      }

      yield &self[index].value
    }
  }
}

@_spi(_QualifiedLookupTests) public typealias IntroducingExtensionOrMainDecl = SourceFileRoot<ExtensionDeclSyntax>?
@_spi(_QualifiedLookupTests) public struct TypeMemberDecl: Hashable, Sendable {
  let introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
  let typeDeclSyntax: SourceFileRoot<TypeDeclSyntax>
}
@_spi(_QualifiedLookupTests) public struct TypeMember: Hashable, Sendable {
  let name: Identifier
  fileprivate(set) var decls: [TypeMemberDecl]

  @_spi(_QualifiedLookupTests) public init(name: Identifier, decls: [TypeMemberDecl]) {
    self.name = name
    self.decls = decls
  }
}

/// An extension dependency stores cached information such as what declaration
/// group the given member was introduced. Normally, we don't store cached
/// information for types stored in the `TypeDependencyGraph` since we must
/// later update a lot of cached data when we bind/invalidate an extension.
/// However, extension dependencies are different because if the dependency
/// type changes, we necessarily have to invalidate and recompute the extensions.
/// Hence, extension dependencies should be created at extension binding and not
/// be modified (we simply invalidate the extension and destroy its state along
/// with any dependencies).
@_spi(_QualifiedLookupTests) public struct GenericExtensionDependency<TypeName: Sendable>: Sendable {
  let dependencyTypeName: TypeName
  fileprivate(set) var members: [TypeMember]

  @_spi(_QualifiedLookupTests) public init(
    dependencyTypeName: TypeName,
    members: [TypeMember]
  ) {
    self.dependencyTypeName = dependencyTypeName
    self.members = members
  }
}

@_spi(_QualifiedLookupTests) public typealias ExtensionDependency = GenericExtensionDependency<
  QualifiedTypeNameGlobalType
>

@_spi(_QualifiedLookupTests) public typealias GenericBindingFailure<
  TypeName: Sendable & Hashable & CustomDebugStringConvertible
> = TypeQualifierFailure<
  TypeName, ResolvedNominalTypeReference, NominalTypeRef
>
@_spi(_QualifiedLookupTests) public typealias InvalidatedExtensions = [ExtensionState]
@_spi(_QualifiedLookupTests) public typealias BindingFailure = GenericBindingFailure<QualifiedTypeNameGlobalType>

@_spi(_QualifiedLookupTests) public typealias BindingResult = (
  resolvedTypeName: Result<
    (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
    BindingFailure
  >,
  invalidatedExtensions: InvalidatedExtensions
)

@_spi(_QualifiedLookupTests)
public struct GenericExtensionState<TypeName: Sendable & Hashable & CustomDebugStringConvertible>: Sendable {
  // Invariant: The extensions listed must be valid and successfully bound to a type in `extensionsToState`
  // Invariant: There's only one dependency per type.
  //
  // See `ExtensionDependency` docstring for why these properties are *immutable*.
  @_spi(_QualifiedLookupTests) public let dependencies: [GenericExtensionDependency<TypeName>],
    // TODO: Remove this property
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    /// The resolved type must be valid in `namesToTypes`
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>

  @_spi(_QualifiedLookupTests) public init(
    _uncheckedDependencies dependencies: [GenericExtensionDependency<TypeName>],
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>
  ) {
    self.dependencies = dependencies
    self.extensionDecl = extensionDecl
    self.resolvedType = resolvedType
  }

  @_spi(_QualifiedLookupTests) public init(
    dependencies: [QualifiedLookupDependency<QualifiedTypeNameGlobalType>],
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>
  ) where TypeName == QualifiedTypeNameGlobalType {
    // Group dependencies by base type and member name, while maintaing order
    var groupedDependencies =
      [
        (
          key: QualifiedTypeNameGlobalType,
          value: [(key: Identifier, value: [(IntroducingExtensionOrMainDecl, SourceFileRoot<TypeDeclSyntax>)])]
        )
      ]()

    for dependency in dependencies {
      // TODO: Clarify comment
      // Note: We can assign directly because ``DependencyTracker/dependencies`` guarantees
      // that type/member-name pairs have just a single entry.
      groupedDependencies[_key: dependency.extendedTypeName, default: []][_key: dependency.member, default: []].append(
        contentsOf: dependency.typeDecls
      )
    }

    // Map to `ExtensionDependency`
    // Satisfies invariant of one dependency per type
    let orderedGroupedDependencies: [ExtensionDependency] = groupedDependencies.map({ (typeName, members) in
      ExtensionDependency(
        dependencyTypeName: typeName,
        members: members.map({ (name, typeDecls) in
          TypeMember(
            name: name,
            decls: typeDecls.map({ TypeMemberDecl(introducingExtensionOrMainDecl: $0.0, typeDeclSyntax: $0.1) })
          )
        })
      )
    })

    self.init(
      _uncheckedDependencies: orderedGroupedDependencies,
      extensionDecl: extensionDecl,
      resolvedType: resolvedType
    )
  }
}
@_spi(_QualifiedLookupTests) public typealias ExtensionState = GenericExtensionState<QualifiedTypeNameGlobalType>

@_spi(_QualifiedLookupTests) public struct TypeTable: Hashable {
  fileprivate(set) var typeMembersToDecls: [Identifier: TypeMember]

  init(
    from namesToDecls: [Identifier: [SourceFileRoot<TypeDeclSyntax>]],
    introducedIn introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
  ) {
    typeMembersToDecls = [:]
    for (name, typeDecls) in namesToDecls {
      typeMembersToDecls[name] = TypeMember(
        name: name,
        decls: typeDecls.map({
          TypeMemberDecl(introducingExtensionOrMainDecl: introducingExtensionOrMainDecl, typeDeclSyntax: $0)
        })
      )
    }
  }
  func collidesWithDependency(
    _ dependency: QualifiedLookupDependency<QualifiedTypeNameGlobalType>,
    whenBoundTo baseTypeName: QualifiedTypeNameGlobalType
  ) -> Bool {
    dependency.extendedTypeName == baseTypeName && typeMembersToDecls[dependency.member] != nil
  }
}

// TODO: Consider optimization where we don't issue module-lookup requests when looking
//       for type members of internal types (external modules can't depend on internal types)
// TODO: Think about making lookup lazy (what are the actual places where we *need* to find
//       redeclarations)
/// A directed acyclic graph where types are nodes and extensions are edges.
///
///
/// Note: This graph is complex because extension binding depends on type members, e.g.
///       ResolvedType>TypeMember because the resolved type might be invalid or on alias.
///       However, we also keep track of nominal types b/c they might be introduced by
///       extensions and we crucially resolve to them and need a unique reference to each.
///
/// Features:
/// 0. Iterating type->extensions, O(# of exts)
///    a. For quick qualified lookup
/// 0. Access extension->state, O(1)
///    a. To know if extension is already resolved
///    b. Constant time since we have to bind a lot of extensions
/// 0. Access extension->dependencies, O(# of dependencies)
///    a. For cycle detection when adding a dependency
/// 0. Access nominal type->dependents (extensions+types), O(# of dependents)
///    a. For invalidation when adding any extension that adds/removes a type member.
/// 0. Access extension->resolved type, O(1)
///    a. Lookup within an extension almost always triggers a request
///       to resolve the extended type so we can look for its members
///       e.g.
///       struct A { struct B {} }
///       extension A {
///         func f(_: B) // <- Look up here needs to quickly
///                      //    find that `A>B` is a valid member.
///       }
@_spi(_QualifiedLookupTests)
public struct TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public struct TypeDependent: Hashable, CustomDebugStringConvertible {
    @_spi(_QualifiedLookupTests) public let memberType: Identifier
    @_spi(_QualifiedLookupTests) public let dependentExtension: SourceFileRoot<ExtensionDeclSyntax>

    public var debugDescription: String {
      "`\(dependentExtension.node._memberlessDescription)` depends on Self > '\(memberType.name)'"
    }
  }

  @_spi(_QualifiedLookupTests) public struct NominalType {
    /// Keeps track of mutations to assert data didn't change between calls
    internal private(set) var version = 0

    /// Invariants: count >= 1; sorted by position in increasing order
    private var _mainDecls: [MappedDeclGroup<NominalTypeDeclSyntax>]

    private(set) var boundExtensions: [SymbolTable3.Module: [SourceFileRoot<ExtensionDeclSyntax>: TypeTable]]

    /// Extensions dependending on qualified lookup of `member` on this type.
    ///
    /// This property is part of `NominalType` and not `ExtensionState` because
    /// any extension binding to this nominal type should see that it's invalidating
    /// other extensions.
    fileprivate(set) var dependents: [TypeDependent]

    init(mainDecl: MappedDeclGroup<NominalTypeDeclSyntax>) {
      self._mainDecls = [mainDecl]
      self.boundExtensions = [:]
      self.dependents = []
    }

    var mainDecl: MappedDeclGroup<NominalTypeDeclSyntax> {
      // By invariant above that `_mainDecls.count >= 1`
      _mainDecls[0]
    }
    var redeclarations: [MappedDeclGroup<NominalTypeDeclSyntax>] {
      // By invariant above that `_mainDecls.count >= 1`
      Array(_mainDecls[1...])
    }

    /// Returns a new version of the extended type, adding the given extension.
    /// Returns `nil`  if extension is already bound.
    fileprivate consuming func _bindingExtension(
      _ mappedExtensionDecl: MappedDeclGroup<ExtensionDeclSyntax>,
      module: SymbolTable3.Module
    ) -> NominalType? {
      var copy = self
      let oldValue = copy.boundExtensions[module, default: [:]].updateValue(
        mappedExtensionDecl.typeMap,
        forKey: mappedExtensionDecl.declGroup
      )
      guard oldValue == nil else { return nil }
      copy.version &+= 1
      return copy
    }

    fileprivate consuming func _unbindingExtension(
      _ boundExtension: SourceFileRoot<ExtensionDeclSyntax>,
      module: SymbolTable3.Module
    ) -> (newNominal: NominalType, extensionTypeTable: TypeTable)? {
      var copy = self
      let extensionTypeTable = copy.boundExtensions[module, default: [:]].removeValue(forKey: boundExtension)
      guard let extensionTypeTable else { return nil }
      copy.version &+= 1
      return (newNominal: copy, extensionTypeTable)
    }
    fileprivate consuming func _updatingDependents(
      _ newDependents: [TypeDependent]
    ) -> NominalType {
      var copy = self
      copy.dependents = newDependents
      return copy
    }

    /// Unbinds the given nominal-type declaration. If the nominal-type
    /// declaration is a redeclaration, we remove it. If the nominal-type
    /// declaration is the main declaration, replace by the first redeclaration
    /// (if available). If this is the main declaration and there are no
    /// redeclarations, returns `nil`.
    fileprivate consuming func _unbindingNominalDecl(
      _ nominalTypeDecl: SourceFileRoot<NominalTypeDeclSyntax>
    ) -> NominalType? {
      var copy = self

      // Remove the declaration (keeping count)
      let originalDecls = copy._mainDecls
      copy._mainDecls.removeAll(where: { $0.declGroup == nominalTypeDecl })

      // Ensure the declaration was actually bound and we removed it
      precondition(
        copy._mainDecls.count == originalDecls.count - 1,
        "[SwiftLexicalLookup] Internal error: Tried to unbind nominal-type declaration `\(nominalTypeDecl._memberlessDescription)` a type it's not bound to (original: \(originalDecls.map(\.declGroup._memberlessDescription)))."
      )

      // Return `nil` if no nominal-type declaration is left (maintains invariant)
      guard !copy._mainDecls.isEmpty else { return nil }

      return copy
    }

    /// Adds the given type as a redeclaration if not already added.
    func addingRedeclaration(_ mainDecl: MappedDeclGroup<NominalTypeDeclSyntax>) -> NominalType {
      // This check takes linear time w.r.t. `_mainDecls`; however, we don't
      // expect to have many redeclarations for the same type.
      guard !_mainDecls.contains(mainDecl) else { return self }

      var copy = self
      copy.version &+= 1
      // We add and sort, maintaining `_mainDecls` invariants
      copy._mainDecls.append(mainDecl)
      copy._mainDecls.sort(by: { $0.declGroup.position < $1.declGroup.position })
      return copy
    }

    /// Adds the given dependent extension, or returns `nil` in DEBUG if
    /// there's already such a dependent extension.
    consuming func addingDependentExtension(
      _ dependent: TypeDependent
        // extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
        // onMemberType memberType: Identifier
    ) -> NominalType? {
      var copy = self
      // TODO: Refine (maybe convert `dependents` to a set? but it could be overkill/slower)
      #if DEBUG
      guard !copy.dependents.contains(dependent) else {
        return nil
      }
      #endif
      copy.dependents.append(dependent)
      return copy
    }
  }

  /// Updates when we register nominal types and bind extensions
  @_spi(_QualifiedLookupTests) public var namesToTypes: [QualifiedTypeNameGlobalType: NominalType]
  // /// Updates when we register nominal types and bind extensions
  // var parentsToTypeMembers: [QualifiedTypeName: TypeTable]
  @_spi(_QualifiedLookupTests) public var extensionsToState: [SourceFileRoot<ExtensionDeclSyntax>: ExtensionState]

  init() {
    namesToTypes = [:]
    extensionsToState = [:]
  }
}

// MARK: Lookup

@_spi(_QualifiedLookupTests) public struct GenericDependencyTracker<TypeName: Sendable> {
  /// Invariant: There's at most one dependency for the same type/member-name pair.
  private(set) var dependencies: [QualifiedLookupDependency<TypeName>]

  @_spi(_QualifiedLookupTests) public init(
    _uncheckedDependencies dependencies: [QualifiedLookupDependency<TypeName>] = []
  ) {
    self.dependencies = dependencies
  }

  /// Add the given dependency, maintainign unique dependencies
  fileprivate mutating func _addLookupDependency(
    baseTypeName: QualifiedTypeNameGlobalType,
    memberTypeName: Identifier,
    performLookup: (QualifiedTypeNameGlobalType, Identifier) -> QualifiedLookupDependency<TypeName>
  ) -> QualifiedLookupDependency<TypeName> where TypeName == QualifiedTypeNameGlobalType {
    // Try to find existing request
    //
    // Note: Although this takes O(n) time where `n` is the number of dependencies,
    // we shouldn't have that many dependencies and small arrays are fast
    // at linear search.
    if let existingResult = dependencies.first(where: {
      $0.extendedTypeName == baseTypeName && $0.member == memberTypeName
    }) {
      return existingResult
    }

    // Otherwise, compute and add
    let result = performLookup(baseTypeName, memberTypeName)
    dependencies.append(result)
    return result
  }
}
@_spi(_QualifiedLookupTests) public typealias DependencyTracker = GenericDependencyTracker<QualifiedTypeNameGlobalType>

// FIXME: Move to _global_ symbol-table _version
@_spi(_QualifiedLookupTests) public struct NominalTypeRef: Hashable, Sendable {
  @_spi(_QualifiedLookupTests) public enum Storage: Hashable, Sendable {
    /// Local nominal types cannot be extended
    case local(SourceFileRoot<NominalTypeDeclSyntax>)
    case globalReference(QualifiedTypeNameGlobalType, _version: Int)
  }

  @_spi(_QualifiedLookupTests) public let storage: Storage

  init(qualifiedName: QualifiedTypeNameGlobalType, nominal: __shared TypeDependencyGraph.NominalType) {
    storage = .globalReference(qualifiedName, _version: nominal.version)
  }
  init(localNominalType: SourceFileRoot<NominalTypeDeclSyntax>) {
    storage = .local(localNominalType)
  }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public enum QualifiedTypeLookupFailure: Error {
    case invalidBase
  }
  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    origin: (typeSyntax: SourceFileRoot<TypeLikeSyntax>, module: SymbolTable3.Module),
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
    dependencyTracker: inout DependencyTracker,
    configuredRegions: ConfiguredRegions?
  ) -> Result<[SourceFileRoot<TypeDeclSyntax>], QualifiedTypeLookupFailure> {
    // Get global nominal reference
    let (baseTypeName, baseTypeVersion): (QualifiedTypeNameGlobalType, Int)
    switch baseType.storage {
    case .globalReference(let name, let version):
      (baseTypeName, baseTypeVersion) = (name, version)
    case .local(let nominalTypeDecl):
      // Local decls don't have extensions (=> no dependencies generated); just
      // look into the main declaration.
      let typeMembers = nominalTypeDecl._groupTypeMembers(configuredRegions: configuredRegions).flatMap(\.value)
      return .success(typeMembers)
    }

    // Diagnose invalid base
    guard
      let registeredType = namesToTypes[baseTypeName],
      registeredType.version == baseTypeVersion
    else {
      return .failure(QualifiedTypeLookupFailure.invalidBase)
    }
    // FIXME: Ensure reference's symbol-table version also matches

    func directLookup(
      baseTypeName: QualifiedTypeNameGlobalType,
      memberTypeName: Identifier
    ) -> QualifiedLookupDependency<QualifiedTypeNameGlobalType> {
      // Organize declaration groups into buckets
      var fileDecls = [MappedDeclGroup<DeclGroupSyntaxType>]()
      var otherInternalDecls = [MappedDeclGroup<DeclGroupSyntaxType>]()
      // TODO: Check file's imported modules & check
      // TODO: Sort by module order (for shadowing) and handle case where we import
      // specific types, perhaps interleaved types between modules, e.g., import A from Module1,
      // import B from Module2, import C from Module1, import A from Module2 (how is `A` shadowed?)
      var externalDecls = [MappedDeclGroup<DeclGroupSyntaxType>]()

      func organizeDeclGroup(_ declGroup: MappedDeclGroup<DeclGroupSyntaxType>) {
        if declGroup.fileRoot == origin.typeSyntax.fileRoot {
          fileDecls.append(declGroup)
        } else if moduleMap[declGroup.fileRoot] == origin.module {
          otherInternalDecls.append(declGroup)
        } else {
          externalDecls.append(declGroup)
        }
      }

      // Add main decl and bound extensions
      organizeDeclGroup(registeredType.mainDecl.erased())
      for (_, extensionDecls) in registeredType.boundExtensions {
        for (extensionDecl, typeTable) in extensionDecls {
          organizeDeclGroup(MappedDeclGroup(declGroup: extensionDecl, typeMap: typeTable).erased())
        }
      }

      let sortedDeclGroups = fileDecls + otherInternalDecls + externalDecls

      // Add members from each decl group and register the dependencies
      var typeDecls = [(IntroducingExtensionOrMainDecl, SourceFileRoot<TypeDeclSyntax>)]()
      for declGroup in sortedDeclGroups {
        // Add the matching decls
        let introducedDecls =
          declGroup.typeMap.typeMembersToDecls[memberTypeName]?.decls.map({
            (declGroup.declGroup.as(ExtensionDeclSyntax.self), $0.typeDeclSyntax)
          }) ?? []
        typeDecls.append(contentsOf: introducedDecls)

      }
      return QualifiedLookupDependency(extendedTypeName: baseTypeName, member: memberTypeName, typeDecls: typeDecls)
    }

    // Add to the dependency tracker or get existing value
    let result = dependencyTracker._addLookupDependency(
      baseTypeName: baseTypeName,
      memberTypeName: memberTypeName,
      performLookup: directLookup(baseTypeName:memberTypeName:)
    )

    // Distill to type declarations (throw away declaration groups)
    return .success(result.typeDecls.map(\.1))
  }
}

extension TypeDependencyGraph {
  enum NominalRegistrationFailure: Error {
  }

  /// Registers the given nominal-type reference or return the
  /// existing reference.
  ///
  /// Parameters:
  /// - rawQualifiedName: Any qualified name, local or global
  mutating func registerNominalTypeReference(
    rawQualifiedName: QualifiedTypeName,
    mainDecl: SourceFileRoot<NominalTypeDeclSyntax>,
    configuredRegions: ConfiguredRegions?
  ) -> Result<NominalTypeRef, NominalRegistrationFailure> {
    // Get the global name
    let qualifiedName: QualifiedTypeNameGlobalType
    switch rawQualifiedName {
    case .topLevel(let name):
      qualifiedName = name
    case .nestedScope:
      return .success(NominalTypeRef(localNominalType: mainDecl))
    }

    // FIXME: SOS: Ensure we're not admitted child of redeclaration.
    // E.g.
    // struct A {
    //   struct B {}
    //   struct B {
    //     struct C {}
    //   }
    // }
    //
    // Here, we shouldn't be able to register `C`!!
    // I.e. admitted type's parent should be file scope or *the* main decl
    // of a registered type.

    // TODO: Remove if we remove this invariant.
    //
    // // Check parent is registered
    // if let (qualifiedBaseName, member: _) = qualifiedName.baseAndMember,
    //   namesToTypes[qualifiedBaseName] == nil
    // {
    //   return .failure(NominalRegistrationFailure.parentNotRegistered(parentName: qualifiedBaseName))
    // }

    // TODO: Add an assertion when registering an extension-dependent nominal, that
    //       the extension is registered

    // Map out the type
    let mappedMainDecl = MappedDeclGroup.from(declGroup: mainDecl, configuredRegions: configuredRegions)

    // If this type is new, just register and return
    // TODO: Test following, e.g. struct A { struct B {} }; extension A { struct B {} }
    guard let existingType = namesToTypes[qualifiedName] else {
      let freshNominal = NominalType(mainDecl: mappedMainDecl)
      namesToTypes[qualifiedName] = freshNominal
      return .success(NominalTypeRef(qualifiedName: qualifiedName, nominal: freshNominal))
    }

    // Add the redeclaration (or ignore if the decl is already added)
    let typeWithRedeclaration = existingType.addingRedeclaration(mappedMainDecl)
    namesToTypes[qualifiedName] = typeWithRedeclaration

    return .success(NominalTypeRef(qualifiedName: qualifiedName, nominal: typeWithRedeclaration))
  }
}

// MARK: - Extension Dependencies

// TODO: Look into whether we can use the existing ExtensionBindingResult/Dependency type
@_spi(_QualifiedLookupTests) public struct QualifiedLookupDependency<TypeName: Sendable>: Sendable {
  let extendedTypeName: TypeName
  let member: Identifier
  let typeDecls:
    [(introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl, typeDecl: SourceFileRoot<TypeDeclSyntax>)]

  // TODO: Clean up
  @_spi(_QualifiedLookupTests) public init(
    // introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
    extendedTypeName: TypeName,
    member: Identifier,
    // typeDecls: [TypeDeclSyntax]
    typeDecls: [(IntroducingExtensionOrMainDecl, SourceFileRoot<TypeDeclSyntax>)]
  ) {
    // self.introducingExtensionOrMainDecl = introducingExtensionOrMainDecl
    self.extendedTypeName = extendedTypeName
    self.member = member
    // self.typeDecls = typeDecls
    self.typeDecls = typeDecls
  }
}

@_spi(_QualifiedLookupTests) public struct GenericDependencyCycleElement<TypeName: Sendable>: Sendable {
  @_spi(_QualifiedLookupTests) public let introducingTypeDecl: TypeDeclSyntax?
  @_spi(_QualifiedLookupTests) public let extensionDecl: ExtensionDeclSyntax
  @_spi(_QualifiedLookupTests) public let boundType: TypeName

  @_spi(_QualifiedLookupTests) public init(
    introducingTypeDecl: TypeDeclSyntax?,
    extensionDecl: ExtensionDeclSyntax,
    boundType: TypeName
  ) {
    self.introducingTypeDecl = introducingTypeDecl
    self.extensionDecl = extensionDecl
    self.boundType = boundType
  }
}
@_spi(_QualifiedLookupTests) public typealias DependencyCycleElement = GenericDependencyCycleElement<
  QualifiedTypeNameGlobalType
>

@_spi(_QualifiedLookupTests) public struct GenericExtensionBindingCycle<TypeName: Sendable>: Sendable {
  @_spi(_QualifiedLookupTests) public let dependencyPath: [GenericDependencyCycleElement<TypeName>]
  @_spi(_QualifiedLookupTests) public let dependencyMember: Identifier

  @_spi(_QualifiedLookupTests) public init(
    dependencyPath: [GenericDependencyCycleElement<TypeName>],
    dependencyMember: Identifier
  ) {
    self.dependencyPath = dependencyPath
    self.dependencyMember = dependencyMember
  }
}

@_spi(_QualifiedLookupTests) public typealias ExtensionBindingCycle = GenericExtensionBindingCycle<
  QualifiedTypeNameGlobalType
>

extension TypeDependencyGraph {
  enum CycleDetectionFailure: Error {
    case unresolvedDependencyExtension(
      dependentExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionState: ExtensionState?
    )
  }

  struct DependencyPathElement: CustomDebugStringConvertible {
    let introducingMemberType: TypeMemberDecl?
    let boundType: QualifiedTypeNameGlobalType
    let extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
    let state: ExtensionState

    var debugDescription: String {
      "\(introducingMemberType?.typeDeclSyntax._memberlessDescription ?? "nil") introduced \(extensionDecl._memberlessDescription) (bound to \(boundType.debugDescription))"
    }
  }
  /// Calls visit with the current dependency path until it
  /// returns a (non-nil) `T` result, which we forward to the caller.
  ///
  /// Parameters:
  /// - path: External (non-recursive) callers should just provide the starter element
  ///   with a `DependencyPathElement/introducingMemberType` of `nil`.
  /// - visit: The path provided will only have `introducingMemberType == nil` in
  ///   the first element.
  fileprivate func _findFirstDependency<T>(
    path: [DependencyPathElement],
    where visit: (_ dependency: ExtensionDependency, _ path: [DependencyPathElement]) -> T?
  ) -> T? {
    // We'll visit the last extension in the chain
    guard let extensionInfo = path.last else { return nil }

    for dependency in extensionInfo.state.dependencies {
      // First, visit the extension's dependency
      if let result = visit(dependency, path) { return result }

      // Then, find transitive dependencies (by visiting the extensions
      // referenced by this dependency)
      for member in dependency.members {
        for typeMemberDecl in member.decls {
          // We assume nominal-type declarations can't introduce dependencies
          // TODO: Justify
          guard let dependencyExtension = typeMemberDecl.introducingExtensionOrMainDecl else { continue }

          // Get "transitive extension" information
          guard
            let dependencyExtensionState = extensionsToState[dependencyExtension],
            case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType
          else {
            // TODO: Find actual error message (but still use fatal error since this breaks an invariant)
            fatalError("TODO: Actual error message")
          }

          let newPath: [DependencyPathElement] =
            path + [
              DependencyPathElement(
                introducingMemberType: typeMemberDecl,
                boundType: dependencyExtendedType,
                extensionDecl: dependencyExtension,
                state: dependencyExtensionState
              )
            ]
          if let result = _findFirstDependency(path: newPath, where: visit) { return result }
        }
      }
    }

    return nil
  }

  fileprivate func _findFirstCycleWhenBinding(
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    extensionMembers: TypeTable,
    to boundTypeName: QualifiedTypeNameGlobalType,
    extensionDependencies: [QualifiedLookupDependency<QualifiedTypeNameGlobalType>],
  ) -> Result<GenericExtensionBindingCycle<QualifiedTypeNameGlobalType>, CycleDetectionFailure>? {
    let boundExtensionInfo = [
      DependencyPathElement(
        introducingMemberType: nil,
        boundType: boundTypeName,
        extensionDecl: extensionDecl,
        state: ExtensionState(
          dependencies: extensionDependencies,
          extensionDecl: extensionDecl,
          resolvedType: .success(boundTypeName)
        )
      )
    ]

    // TODO: Check that `extensionDependencies` have states and resolved to a type or throw an error

    print(
      "Checking cycles if introducing `\(extensionDecl._memberlessDescription)` with members '\(boundTypeName.debugDescription)' > \(extensionMembers.typeMembersToDecls.map(\.key.name))"
    )

    // Check recursive dependencies
    let cycleResult: ExtensionBindingCycle? = _findFirstDependency(
      path: boundExtensionInfo,
      where: { (dependency, path) -> ExtensionBindingCycle? in
        // TODO: Factor out to or remove `collidesWithDependency` helper above.
        // Check if dependency collides with introduces `boundTypeName` > `extensionMembers`.
        // Collisions require that the base type match and that members share a name.
        print("Visiting `\(dependency._declarationlessDescription)` [path \(path)]")
        guard
          boundTypeName == dependency.dependencyTypeName,
          let firstConflictingMember = dependency.members.first(where: { member in
            extensionMembers.typeMembersToDecls[member.name] != nil
          })
        else {
          return nil
        }

        let mappedPath: [DependencyCycleElement] = path.dropFirst().map({ chainElement in
          DependencyCycleElement(
            // Only the first element has `nil` by `_findFirstDependency` invariant.
            introducingTypeDecl: chainElement.introducingMemberType!.typeDeclSyntax.node,
            extensionDecl: chainElement.extensionDecl.node,
            boundType: chainElement.boundType,
          )
        })

        return ExtensionBindingCycle(dependencyPath: mappedPath, dependencyMember: firstConflictingMember.name)
      }
    )

    return cycleResult.map(Result.success)
  }
}

extension TypeDependencyGraph {
  mutating func _unbindMemberType(
    baseTypeName: QualifiedTypeNameGlobalType,
    baseTypeDecl: SourceFileRoot<DeclGroupSyntaxType>,
    baseTypeModule: Identifier,
    baseType: NominalType,
    memberName: Identifier,
    memberTypeDecl: SourceFileRoot<TypeDeclSyntax>,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: SymbolTable3
  ) {
    // If a registered nominal, check its own member types and finally remove this declaration
    let potentialNominalName = baseTypeName.addingComponents([
      QualifiedTypeNameGlobalType.Component(
        name: memberName,
        file: baseTypeDecl.fileRoot,
        module: baseTypeModule,
        symbolTable: symbolTable
      )
    ])
    if let memberNominalDecl = memberTypeDecl.as(NominalTypeDeclSyntax.self),
      let memberNominal: NominalType = namesToTypes[potentialNominalName]
    {
      let memberNominalTypeName = potentialNominalName

      // If it's the main decl, unbind its own type members
      if memberNominal.mainDecl.declGroup == memberNominalDecl {
        let flattenedRecursiveMembers = memberNominal.mainDecl.typeMap.typeMembersToDecls.flatMap({
          (name, member) in member.decls.map({ (name, $0.typeDeclSyntax) })
        })
        for (recursiveMember, recursiveMemberTypeDecl) in flattenedRecursiveMembers {
          _unbindMemberType(
            baseTypeName: memberNominalTypeName,
            baseTypeDecl: SourceFileRoot<DeclGroupSyntaxType>(memberNominalDecl),
            baseTypeModule: baseTypeModule,
            baseType: memberNominal,
            memberName: recursiveMember,
            memberTypeDecl: recursiveMemberTypeDecl,
            invalidatedExtensions: &invalidatedExtensions,
            symbolTable: symbolTable
          )
        }
      }

      // `nil` means there was no other main declaration
      namesToTypes[potentialNominalName] = memberNominal._unbindingNominalDecl(memberNominalDecl)
    }

    // Invalidate dependent extensions
    let newBaseDependents = _invalidateDependents(
      modifiedTypeName: baseTypeName,
      modifiedMembers: TypeTable(
        from: [memberName: [memberTypeDecl]],
        introducedIn: baseTypeDecl.as(ExtensionDeclSyntax.self)
      ),
      modifiedExtensionModule: baseTypeModule,
      directDependents: baseType.dependents,
      invalidatedExtensions: &invalidatedExtensions,
      symbolTable: symbolTable
    )

    namesToTypes[baseTypeName] = baseType._updatingDependents(newBaseDependents)
    // for dependent in baseType.dependents {
    //   // Invalidate only when the extension is dependent on this specific member
    //   guard dependent.memberType == memberName else { continue }
    //
    //   _unbindExtension(dependent.dependentExtension, ifDependentOn: nil, symbolTable: symbolTable)
    // }
  }

  mutating func _unbindExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    extensionDeclModule: SymbolTable3.Module,
    ifDependentOn _: (typeName: QualifiedTypeNameGlobalType, memberName: Identifier)?,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable3
  ) -> ExtensionState {
    guard let extensionState = extensionsToState[extensionDecl] else {
      // TODO: Remove
      // print(
      //   "[SwiftLexicalLookup] Internal error: Unexpectedly asked to unbind unregistered extension `\(extensionDecl._memberlessDescription)`."
      // )
      // return ExtensionState(
      //   _uncheckedDependencies: [],
      //   extensionDecl: extensionDecl,
      //   resolvedType: .failure(.extensionNotBoundYet)
      // )
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly asked to unbind unregistered extension `\(extensionDecl._memberlessDescription)`."
      )
    }
    // Get the extended-type name (or just erase the extension state if unbound)
    guard case .success(let extendedTypeName) = extensionState.resolvedType else {
      extensionsToState[extensionDecl] = nil
      return extensionState
    }
    guard let extendedTypeState: NominalType = namesToTypes[extendedTypeName] else {
      // TODO: Remove
      // print(
      //   "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` bound to unregistered type '\(extendedTypeName)'."
      // )
      // return ExtensionState(
      //   _uncheckedDependencies: [],
      //   extensionDecl: extensionDecl,
      //   resolvedType: .failure(.extensionNotBoundYet)
      // )
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` bound to unregistered type '\(extendedTypeName)'."
      )
    }

    // Don't apply invalidatedExtensionTypeTable YET
    guard
      let (newExtendedType, invalidatedExtensionTypeTable) = extendedTypeState._unbindingExtension(
        extensionDecl,
        module: extensionDeclModule
      )
    else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Tried to unbind extension `\(extensionDecl._memberlessDescription)` from type '\(extendedTypeName)', which says it's not bound."
      )
    }
    let flattenedMembers = invalidatedExtensionTypeTable.typeMembersToDecls.flatMap({
      (name, member) in member.decls.map({ (name, $0.typeDeclSyntax) })
    })
    for (member, typeMember) in flattenedMembers {
      _unbindMemberType(
        baseTypeName: extendedTypeName,
        baseTypeDecl: SourceFileRoot<DeclGroupSyntaxType>(extensionDecl),
        baseTypeModule: extensionDeclModule,
        baseType: extendedTypeState,
        memberName: member,
        memberTypeDecl: typeMember,
        invalidatedExtensions: &invalidatedExtensions,
        symbolTable: symbolTable
      )
    }

    // Unbind from type and remove extension state
    extensionsToState[extensionDecl] = nil
    namesToTypes[extendedTypeName] = newExtendedType

    return extensionState
  }

  fileprivate mutating func _invalidateDependents(
    modifiedTypeName: QualifiedTypeNameGlobalType,
    modifiedMembers: TypeTable,
    modifiedExtensionModule: SymbolTable3.Module,
    directDependents: [TypeDependent],
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable3
  ) -> [TypeDependent] {
    var newDependents = [TypeDependent]()
    for dependent in directDependents {
      // Only unbind conflicting (otherwise add to new dependents)
      guard modifiedMembers.typeMembersToDecls[dependent.memberType] != nil else {
        newDependents.append(dependent)
        continue
      }

      let invalidatedExtensionState = _unbindExtension(
        dependent.dependentExtension,
        extensionDeclModule: modifiedExtensionModule,
        ifDependentOn: nil,
        invalidatedExtensions: &invalidatedExtensions,
        symbolTable: symbolTable
      )
      invalidatedExtensions.append(invalidatedExtensionState)
    }
    print("-> Invalidated dependents of '\(modifiedTypeName)': \(directDependents); new dependents: \(newDependents)")
    return newDependents
  }

  // /// Find a declaration group's recursively nested types
  // ///
  // /// Parameters
  // /// - declGroupTypeName: The type that this `declGroup` is a part of. The extended type
  // ///   for extensions or the main declaration for nominal types.
  // mutating func _visitRecursivelyNestedTypes(
  //   declGroup: SourceFileRoot<DeclGroupSyntaxType>,
  //   declGroupModule: Identifier,
  //   declGroupTypeName: QualifiedTypeNameGlobalType,
  //   typeTable: TypeTable,
  //   symbolTable: SymbolTable3,
  //   invalidatedExtensions: inout [ExtensionState]
  // ) -> [TypeDependent] {
  //   /// Given a valid base name, appends the given member name to get the name of
  //   /// a potentially registered nominal type.
  //   ///
  //   /// Important: The member must be nested within `declGroup` (to guarantee
  //   /// it's in same file and module).
  //   func makePotentialName(validBase: QualifiedTypeNameGlobalType, member: Identifier) -> QualifiedTypeNameGlobalType {
  //     let newComponent = QualifiedTypeNameGlobalType.Component(
  //       name: member,
  //       file: declGroup.fileRoot,
  //       module: declGroupModule,
  //       symbolTable: symbolTable
  //     )
  //     return validBase.addingComponents([newComponent])
  //   }
  //
  //   for (nestedTypeName, _) in typeTable.typeMembersToDecls {
  //     let potentialTypeName = makePotentialName(validBase: declGroupTypeName, member: Identifier)
  //     // Get the state if valid
  //     guard let removedTypeState = namesToTypes.removeValue(forKey: potentialTypeName) else { continue }
  //     // We know this is a valid name
  //     let typeName = potentialTypeName
  //   }
  //
  //   // A stack keeping track of potential nominal-type names we need to visit
  //   // and remove. All names should point to types nested under `declGroup`
  //   // and `declGroupType`
  //   var potentialTypeNames = typeTable.typeMembersToDecls.map({ (nestedTypeName, _) in
  //     makePotentialName(validBase: declGroupType, member: nestedTypeName)
  //   })
  //
  //   while let potentialTypeName = potentialTypeNames.popLast() {
  //     // Get the state if valid
  //     guard let removedTypeState = namesToTypes.removeValue(forKey: potentialTypeName) else { continue }
  //     // We know this is a valid name
  //     let typeName = potentialTypeName
  //
  //     // Check recursively nested member types in main decl
  //     potentialTypeNames.append(
  //       contentsOf: removedTypeState.mainDecl.typeMap.typeMembersToDecls.map({ (recursivelyNestedTypeName, _) in
  //         makePotentialName(validBase: typeName, member: recursivelyNestedTypeName)
  //       })
  //     )
  //
  //     // Invalidate all extensions (should handle nested types in dependent extensions)
  //     for (_, removedTypeExtensions) in removedTypeState.boundExtensions {
  //       for (removedTypeExtension, _) in removedTypeExtensions {
  //         guard let oldState = extensionsToState.removeValue(forKey: removedTypeExtension) else {
  //           // TODO: Complain about non-upheld invariant
  //           fatalError("")
  //         }
  //         invalidatedExtensions.append(oldState)
  //       }
  //     }
  //
  //     // TODO: Should destroy nested type's nested types, e.g.
  //     // ```swift
  //     // struct A { typealias B = A }
  //     // extension A.B {
  //     //  struct C {
  //     //    struct D {}
  //     //  }
  //     // }
  //     // extension A.B.C.D { struct E {} }
  //     // extension A { struct A {} }
  //     // ```
  //     // TODO: Check for correctrness
  //     // Remove all the dependents of the nested types (to be removed)
  //     let newDependents = _invalidateDependents(
  //       modifiedTypeName: modifiedTypeName,
  //       modifiedMembers: nil,
  //       directDependents: removedTypeState.dependents,
  //       invalidatedExtensions: &invalidatedExtensions,
  //       symbolTable: symbolTable
  //     )
  //     assert(
  //       newDependents == [],
  //       "[SwiftLexicalLookup] Internal error: `modifiedMembers == nil` should have removed all dependencies from type to be removed."
  //     )
  //   }
  // }

  /// Recursively invalidate all of a type's dependents that rely on any
  /// types introduced in `dependencyMembers`.
  ///
  /// Parameters:
  /// - modifiedTypeName: The type that changed and requires invalidating dependent
  ///   extensions.
  /// - modifiedMembers: The type members modified (getting added/remove) from the type.
  ///   `nil` if the entire type is getting removed.
  /// - directDependents: The direct dependents (extensions) of the `modifiedType` type.
  /// - invalidatedExtensions: A list of unspecified order containg the invalidated
  ///   extensions.
  ///
  /// Returns: The new dependent extensions after removing the invalidated ones.
  /// TODO: Make
  fileprivate mutating func _invalidateDependents__OLD(
    modifiedTypeName: QualifiedTypeNameGlobalType,
    modifiedMembers: TypeTable?,
    directDependents: [TypeDependent],
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable3
  ) -> [TypeDependent] {
    // For each dependent extension, either invalidate or keep it in the
    // new-dependents list.
    var newDependents = [TypeDependent]()

    // TODO: Verify that this order of invalidating is fine
    for dependent in directDependents {
      // Get the invalidated extension (or retain dependent if the extension
      // doesn't depend on `modifiedMembers`)
      if let modifiedMembers,
        modifiedMembers.typeMembersToDecls[dependent.memberType] == nil
      {
        newDependents.append(dependent)
        continue
      }
      let invalidatedExtension = dependent.dependentExtension

      // Ensure extension has a known module (needed later)
      guard let invalidatedExtensionModule: SymbolTable3.Module = symbolTable.moduleMap[invalidatedExtension.fileRoot]
      else {
        // TODO: Clarify where we make this assertion
        fatalError(
          "[SwiftLexicalLookup] Internal error: Found extension \(invalidatedExtension._memberlessDescription) from unbound module."
        )
      }

      // Get the to-be-invalidated extension's state
      guard let invalidatedExtensionState = extensionsToState[invalidatedExtension] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension._memberlessDescription) referenced in `\(modifiedTypeName)`'s dependents, but lacks a state entry."
        )
      }

      // Invalidate
      //
      // 1. Remove extension state & record invalidated extension
      extensionsToState[invalidatedExtension] = nil
      invalidatedExtensions.append(invalidatedExtensionState)

      // 2. Update the extended type
      //
      // If the extension was unbound, we don't have any children to invalidate
      // or a bound type to update, so we're done
      guard case .success(let invalidatedExtensionTypeName) = invalidatedExtensionState.resolvedType else {
        continue
      }

      // Remove the members from the extended type
      guard let invalidatedExtensionType = namesToTypes[invalidatedExtensionTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) resolved to \(invalidatedExtensionTypeName) but the type isn't in the graph."
        )
      }
      guard
        let (newInvalidatedExtensionType, invalidatedExtensionTypeTable) = invalidatedExtensionType._unbindingExtension(
          invalidatedExtension,
          module: invalidatedExtensionModule
        )
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) unexpectedly not in `boundExtensions` of \(invalidatedExtensionType)."
        )
      }

      // Recursively invalidate the invalidate extension's dependents
      let newTransitiveDependents = _invalidateDependents__OLD(
        modifiedTypeName: invalidatedExtensionTypeName,
        modifiedMembers: invalidatedExtensionTypeTable,
        directDependents: invalidatedExtensionType.dependents,
        invalidatedExtensions: &invalidatedExtensions,
        symbolTable: symbolTable
      )
      let finalInvalidatedExtensionType = newInvalidatedExtensionType._updatingDependents(newTransitiveDependents)

      // Update
      namesToTypes[invalidatedExtensionTypeName] = finalInvalidatedExtensionType

      // 3. Remove extension's introduced types
      // var potentialNominalTypes = []
      for (typeMember, _) in invalidatedExtensionTypeTable.typeMembersToDecls {
        let potentialNominalType = invalidatedExtensionTypeName.addingComponents([
          QualifiedTypeNameGlobalType.Component(
            name: typeMember,
            file: invalidatedExtension.fileRoot,
            module: invalidatedExtensionModule,
            symbolTable: symbolTable
          )
        ])
        guard let removedTypeState = namesToTypes.removeValue(forKey: potentialNominalType) else { continue }
        // Since the type goes missing, its extensions are invalidated
        for (_, removedTypeExtensions) in removedTypeState.boundExtensions {
          for (removedTypeExtension, _) in removedTypeExtensions {
            guard let oldState = extensionsToState.removeValue(forKey: removedTypeExtension) else {
              // TODO: Complain about non-upheld invariant
              fatalError("")
            }
            invalidatedExtensions.append(oldState)
          }
        }
        // TODO: Should destroy nested type's nested types, e.g.
        // ```swift
        // struct A { typealias B = A }
        // extension A.B {
        //  struct C {
        //    struct D {}
        //  }
        // }
        // extension A.B.C.D { struct E {} }
        // extension A { struct A {} }
        // ```
        // TODO: Check for correctrness
        // Remove all the dependents of the nested types (to be removed)
        let newDependents = _invalidateDependents__OLD(
          modifiedTypeName: modifiedTypeName,
          modifiedMembers: nil,
          directDependents: removedTypeState.dependents,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
        assert(
          newDependents == [],
          "[SwiftLexicalLookup] Internal error: `modifiedMembers == nil` should have removed all dependencies from type to be removed."
        )
      }

    }

    return newDependents
  }
}

// MARK: Extension Binding

extension Array {
  fileprivate func _removingDuplicates<ID: Hashable>(key: (Element) -> ID) -> [Element] {
    var added: Set<ID> = []
    return self.filter({ added.insert(key($0)).inserted })
  }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }
  // TODO: Consider if any early error returns break invariants (lead to an
  // invalid graph state)
  mutating func _admitExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    extensionDeclModule: SymbolTable3.Module,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to rawResult: Result<
      (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
      TypeQualifier.Failure
    >,
    dependencyTracker: DependencyTracker,
    configuredRegions: ConfiguredRegions?,
    symbolTable: borrowing SymbolTable3
  ) -> Result<BindingResult, ExtensionAdmissionFailure> {
    // Ensure extension isn't already bound
    if let existingExtensionState = extensionsToState[extensionDecl] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Prepare to store extension state
    let mappedExtensionDecl = MappedDeclGroup.from(declGroup: extensionDecl, configuredRegions: configuredRegions)

    // === Diagnose Dependency Cycles ===

    // We create a new type-resolution result that converts successful type
    // resolutions into failures if they cause a cycle.
    let result:
      Result<
        (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
        TypeQualifier.Failure
      >
    switch rawResult {
    case .success(let (extendedTypeName, mainDecl)):
      let cycleResult =
        _findFirstCycleWhenBinding(
          extensionDecl: extensionDecl,
          extensionMembers: mappedExtensionDecl.typeMap,
          to: extendedTypeName,
          extensionDependencies: dependencyTracker.dependencies
        ) as Result<GenericExtensionBindingCycle<QualifiedTypeNameGlobalType>, CycleDetectionFailure>?

      // Map result
      switch cycleResult {
      case nil:
        // No cycle, keep success
        result = .success((extendedTypeName, mainDecl))
      case .success(let cycle):
        // Found cycle, turn success into failure
        result = .failure(TypeQualifier.Failure.cyclicalExtensionDependency(cycle))
      case .failure(
        .unresolvedDependencyExtension(
          let dependentExtension,
          let dependencyExtension,
          let dependencyExtensionState
        )
      ):
        // Failure computing cycle

        // TODO: Rewrite so that we only throw here, _findCyclicalDependencyImplementation traps,
        // and we just get an optional cycle.
        //
        // If the invalid dependency occurs at the extension we're trying to
        // admit, this might be the caller's fault since they provide
        // ``DependencyTracker``
        guard dependentExtension == extensionDecl else {
          // Graph invariant was broken
          fatalError(
            "[SwiftLexicalLookup] Internal error: Extension \((dependentExtension?._memberlessDescription).debugDescription) unexpectedly depends on non-resolved extension \((dependencyExtension?._memberlessDescription).debugDescription) with state: \(String(reflecting: dependencyExtensionState))."
          )
        }
        return .failure(
          ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: dependencyExtensionState)
        )
      }
    case .failure(let failure):
      // Failed extensions stay failures (they are unbound => no member
      // types that can cause cycles).
      result = .failure(failure)
    }

    // === Register as Dependent ===

    // Now that we're admissable, tell predecessors we're dependent
    for dependency in dependencyTracker.dependencies {
      // Find the referenced type
      guard let nominalType = namesToTypes[dependency.extendedTypeName] else {
        // TODO: Throw error for client instead of trapping
        fatalError(
          "[SwiftLexicalLookup] Internal error: While admitting `\(extensionDecl.node._memberlessDescription)`, found dependency with non-registered type '\(dependency.extendedTypeName)'."
        )
      }

      // Mark the dependence
      guard
        let nominalWithDependents = nominalType.addingDependentExtension(
          TypeDependent(memberType: dependency.member, dependentExtension: extensionDecl)
        )
      else {
        // Ensure we don't register a dependent twice (debug-only)
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly found not-yet-admitted extension `\(extensionDecl._memberlessDescription)` in dependents list of '\(dependency.extendedTypeName)': \(nominalType.dependents)."
        )
      }
      namesToTypes[dependency.extendedTypeName] = nominalWithDependents
    }

    // === Invalidate Dependents & Bind ===
    let invalidatedExtensions: [ExtensionState]
    // If there's no cycle, we may type members so we need to invalidate
    switch result {
    case .success(let (extendedTypeName, _)):
      // Get the bound type
      guard let extendedType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) bound to type '\(extendedTypeName)', which isn't in the graph."
        )
      }

      var invalidatedExtensionsTmp = [ExtensionState]()
      let newTypeDependents = _invalidateDependents(
        modifiedTypeName: extendedTypeName,
        modifiedMembers: mappedExtensionDecl.typeMap,
        modifiedExtensionModule: extensionDeclModule,
        directDependents: extendedType.dependents,
        invalidatedExtensions: &invalidatedExtensionsTmp,
        symbolTable: symbolTable
      )
      invalidatedExtensions = invalidatedExtensionsTmp

      // Bind to type
      guard
        let newExtendedType = extendedType._bindingExtension(mappedExtensionDecl, module: extensionDeclModule)
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) has no existing state but is already bound to '\(extendedType)'."
        )
      }
      let finalExtendedType = newExtendedType._updatingDependents(newTypeDependents)
      namesToTypes[extendedTypeName] = finalExtendedType
    case .failure:
      // Extensions that aren't bound to a type, don't introduce new type
      // members so they can't have any dependent.
      invalidatedExtensions = []
    }

    // === Save Extension ===

    // Save extension (newly bound extension doesn't add type dependents)
    extensionsToState[extensionDecl] = ExtensionState(
      dependencies: dependencyTracker.dependencies,
      extensionDecl: extensionDecl,
      // Only keep the qualified name (we store the main decl in `namesToTypes`)
      resolvedType: result.map(\.qualifiedName)
    )

    return .success((result, invalidatedExtensions))
  }
}

// MARK: Debugging

@_spi(_QualifiedLookupTests)
extension NominalTypeRef: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch storage {
    case .globalReference(let qualifiedName, let version):
      return "\(qualifiedName.debugDescription) (v\(version))"
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription) (local)"
    }
  }
}

@_spi(_QualifiedLookupTests)
extension QualifiedLookupDependency: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  @_spi(_QualifiedLookupTests) public var _succinctDescription: String {
    let declGroupSources = typeDecls.map({ $0.0?._memberlessDescription ?? "nil" })
    return """
      '\(extendedTypeName.debugDescription)' > '\(member.name)' [from \(declGroupSources)]
      """
  }

  public var debugDescription: String {
    let typeDeclDescriptions = typeDecls.map({ (introducingExtensionOrMainDecl, typeDecl) in
      "`\(introducingExtensionOrMainDecl?._memberlessDescription ?? "nil")`: `\(typeDecl._memberlessDescription)`"
    }).joined(separator: ", ")

    return
      "QualifiedLookupDependency(extendedTypeName: \(extendedTypeName.debugDescription), member: '\(member.name)', typeDecls: [\(typeDeclDescriptions)])"
  }
}

@_spi(_QualifiedLookupTests)
extension GenericExtensionDependency: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  private func _describe(includeMemberDecls: Bool) -> String {
    let membersDescriptions = members.map({ member in
      let declDescriptions = member.decls.map({
        "`\($0.introducingExtensionOrMainDecl?._memberlessDescription ?? "nil")`"
      })
      let declDescription = " [in \(declDescriptions.isEmpty ? "<none>" : declDescriptions.joined(separator: ", "))]"
      return "'\(member.name.name)'\(includeMemberDecls ? declDescription : "")"
    }).joined(separator: ", ")
    return
      "ExtensionDependency(dependencyTypeName: '\(dependencyTypeName.debugDescription)', members: [\(membersDescriptions)])"
  }

  /// Debug description but removes the `TypeDeclSyntax` from `TypeMember` for easier testing.
  fileprivate var _declarationlessDescription: String {
    _describe(includeMemberDecls: false)
  }

  public var debugDescription: String {
    _describe(includeMemberDecls: true)
  }
}

@_spi(_QualifiedLookupTests)
extension GenericExtensionState: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    let dependenciesDescriptions = dependencies.map(\._declarationlessDescription).joined(separator: ",\n    ")
    return """
      GenericExtensionState(
        dependencies: [
          \(dependenciesDescriptions)
        ],
        resolvedType: \(resolvedType._debugDescription.replacing("\n", with: "\n  "))
      )
      """
  }
}

// TypeDependencyGraph description

private struct _DependencyGraphDiagnostic: DiagnosticMessage {
  let message: String
  let severity: DiagnosticSeverity

  var diagnosticID: MessageID { MessageID(domain: "SwiftLexicalLookup", id: "TypeDependencyGraphDiagnostic") }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests)
  public func _describeWithDiagnostics() -> [Diagnostic] {
    var diagnostics = [Diagnostic]()
    /// Attach a note to the given node.
    func _attachNote<S: SyntaxProtocol>(to syntax: SourceFileRoot<S>, message: String) {
      diagnostics.append(
        Diagnostic(node: syntax.node, message: _DependencyGraphDiagnostic(message: message, severity: .note))
      )
    }
    /// Attach an error to the given node.
    func _attachError<S: SyntaxProtocol>(to syntax: SourceFileRoot<S>, message: String) {
      diagnostics.append(
        Diagnostic(node: syntax.node, message: _DependencyGraphDiagnostic(message: message, severity: .error))
      )
    }
    /// Annotate each member type declaration in the `typeTable`
    /// of the type named `baseTypeName`.
    ///
    /// E.g. The type alias in 'struct A { typealias B = Int }' gets
    /// annotated `Type member '_(MyFile.swift)::A' > 'B'`.
    func _markMemberTypes(baseTypeName: String, typeTable: TypeTable) {
      for (memberName, member) in typeTable.typeMembersToDecls {
        for memberDecl in member.decls {
          _attachNote(to: memberDecl.typeDeclSyntax, message: "Type member '\(baseTypeName)' > '\(memberName.name)'")
        }
      }
    }

    // Add all main decls and their extensions
    //
    // Keep track of visited types to diagnose types that are registered under different names.
    var visitedTypes = [NominalTypeDeclSyntax: QualifiedTypeNameGlobalType]()
    // Keep track of what types/maps we're expecting each bound extension to have.
    var extensionsToType = [
      SourceFileRoot<ExtensionDeclSyntax>: (boundTypeName: QualifiedTypeNameGlobalType, typeTable: TypeTable)
    ]()
    for (typeName, type) in namesToTypes {
      let typeNameDescription = typeName.debugDescription

      // Check each main decl mapped to exactly one visited type
      let mainDecls = [type.mainDecl] + type.redeclarations
      for (index, nominalTypeDecl) in mainDecls.enumerated() {
        // User-friendly description
        let declLabel = index == 0 ? "Main decl" : "Redeclaration #\(index)"

        // Ensure this type decl is mapped to only one name
        guard visitedTypes.updateValue(typeName, forKey: nominalTypeDecl.node) == nil else {
          // This nominal-type declaration was already registered under a different name
          _attachError(
            to: nominalTypeDecl.declGroup,
            message: "\(declLabel) also registered under '\(typeNameDescription)'"
          )
          continue
        }

        // Show the registered name
        _attachNote(
          to: nominalTypeDecl.declGroup,
          message: "\(declLabel) registered '\(typeNameDescription)' (v\(type.version))"
        )

        // Mark each member in the type table
        _markMemberTypes(baseTypeName: typeNameDescription, typeTable: nominalTypeDecl.typeMap)
      }

      // Add dependent extensions (to main declaration)
      for dependent in type.dependents {
        // Ensure there's a respective dependency
        //
        // First, get extension state
        guard let dependentExtensionState = extensionsToState[dependent.dependentExtension] else {
          _attachError(
            to: type.mainDecl.declGroup,
            message:
              "Member type '\(typeNameDescription)' > '\(dependent.memberType.name)' depended on by unregistered extension `\(dependent.dependentExtension.node._memberlessDescription)`."
          )
          continue
        }
        // The extension state must have a dependency to this type with the right type member.
        guard
          dependentExtensionState.dependencies.contains(where: { dependency in
            dependency.dependencyTypeName == typeName
              && dependency.members.contains(where: { member in member.name == dependent.memberType })
          })
        else {
          _attachError(
            to: type.mainDecl.declGroup,
            message:
              "Member type '\(typeNameDescription)' > '\(dependent.memberType.name)' supposedly depended on by `\(dependent.dependentExtension.node._memberlessDescription)`, but isn't in extension's dependencies: \(dependentExtensionState.dependencies.map(\.debugDescription))"
          )
          continue
        }

        _attachNote(
          to: type.mainDecl.declGroup,
          message:
            "Member type '\(typeNameDescription)' > '\(dependent.memberType.name)' depended on by `\(dependent.dependentExtension.node._memberlessDescription)`"
        )
      }

      // Check bound-extension state points to us as the resolved type
      for (boundExtension, typeTable) in type.boundExtensions.flatMap(\.value) {
        // Ensure bound extension has a state
        guard extensionsToState[boundExtension] != nil else {
          _attachError(
            to: boundExtension,
            message: "Extension bound to '\(typeNameDescription)' but has no state."
          )
          continue
        }
        extensionsToType[boundExtension] = (boundTypeName: typeName, typeTable: typeTable)

        continue
      }
    }

    // Mark all extensions, whether bound (in `extensionsToState`) or failed
    for (extensionDecl, extensionState) in extensionsToState {
      // Print extension state with respect to whether it's bound type
      let boundState = extensionsToType[extensionDecl]
      switch (extensionState.resolvedType, boundState) {
      case (.success(let resolvedTypeName), let (boundTypeName, typeTable)?):
        let boundTypeDescription = boundTypeName.debugDescription

        // Ensure the extension's resolved type and nominal type's name agree
        // (skips to next iteration)
        guard resolvedTypeName == boundTypeName else {
          _attachError(
            to: extensionDecl,
            message:
              "Extension bound to '\(boundTypeDescription)', but its state says it resolved to '\(resolvedTypeName.debugDescription)'"
          )
          continue
        }

        // Indicate the extension is bound to us
        _attachNote(to: extensionDecl, message: "Extension resolved and bound to '\(boundTypeDescription)'")

        // Mark each member in the type table
        _markMemberTypes(baseTypeName: boundTypeDescription, typeTable: typeTable)

      case (.failure(let failure), nil):
        _attachNote(
          to: extensionDecl,
          message: "Extension binding failed: \(failure)"
        )

      // Diagnose invalid graph state (these switch cases skip to the next iteration)
      case (.failure(let failure), let (boundTypeName, _)?):
        // Failed extension shouldn't be bound
        _attachError(
          to: extensionDecl,
          message:
            "Extension bound to '\(boundTypeName)', but its state says it failed to resolve: \(failure)"
        )
        continue
      case (.success(let resolvedTypeName), nil):
        // Successfully resolved extensions should be bound to a `NominalType`
        _attachError(
          to: extensionDecl,
          message: "Extension successfully resolved to but didn't bind to '\(resolvedTypeName)'."
        )
        continue
      }

      // Mark dependencies
      // TODO: Check if dependency<->dependent links are valid and acyclic (put check in loop below
      // and just keep track of (&diagnose) unmatched dependents)
      let flattenedDependencies: [(QualifiedTypeNameGlobalType, TypeMember, IntroducingExtensionOrMainDecl)] =
        extensionState
        .dependencies.flatMap({ dependency in
          dependency.members.flatMap({ member in
            // Empty decls are implicitly in `IntroducingExtensionOrMainDecl.none`
            // (main decl)
            guard !member.decls.isEmpty else {
              return [(dependency.dependencyTypeName, member, IntroducingExtensionOrMainDecl.none)]
            }
            return member.decls.map({ typeDecl in
              return (dependency.dependencyTypeName, member, typeDecl.introducingExtensionOrMainDecl)
            })
          })
        })
      for (dependencyTypeName, member, introducingExtensionOrMainDecl) in flattenedDependencies {
        let memberName = member.name.name

        // Ensure extension dependency matches extension state
        if let dependencyExtension = introducingExtensionOrMainDecl {
          guard
            case .success(let dependencyExtendedType)? = extensionsToState[dependencyExtension]?.resolvedType,
            dependencyTypeName == dependencyExtendedType
          else {
            let dependencyTypeNameDescription = dependencyTypeName.debugDescription
            let actualTypeDescription = extensionsToState[dependencyExtension]?.resolvedType.map(\.debugDescription)
            _attachError(
              to: extensionDecl.extendedType,
              message:
                "Extension depends on '\(dependencyTypeNameDescription)' > '\(memberName)' declared in `\(dependencyExtension._memberlessDescription)`, but the extension state resolved to '\(actualTypeDescription.debugDescription)'."
            )
            continue
          }
        }
        // Check extension dependency has a respective type dependent
        guard let dependencyType = namesToTypes[dependencyTypeName] else {
          _attachError(
            to: extensionDecl.extendedType,
            message:
              "Extension depends on '\(memberName)' unregistered type '\(dependencyTypeName.debugDescription)'."
          )
          continue
        }
        guard
          dependencyType.dependents.contains(
            TypeDependent(memberType: member.name, dependentExtension: extensionDecl)
          )
        else {
          _attachError(
            to: extensionDecl.extendedType,
            message:
              "Extension depends on '\(dependencyTypeName.debugDescription)' > '\(memberName)', a type which doesn't track this extension as a dependent."
          )
          continue
        }

        // Add dependency
        _attachNote(
          to: extensionDecl.extendedType,
          message: "Depends on '\(dependencyTypeName)' > '\(memberName)'"
        )
      }

    }

    return diagnostics
  }
}

extension TypeDependencyGraph {
  /// Gets the name and main decl of the type to which the extension is bound,
  /// or the binding the failure; returns `nil` for non-admitted extensions.
  func getExtensionResolvedType(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
  ) -> Result<
    (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
    BindingFailure
  >? {
    // Get the extension's state (or `nil` if unadmitted)
    guard let extensionState = extensionsToState[extensionDecl] else { return nil }

    // Extract the bound type (or return the failure)
    let boundTypeName: QualifiedTypeNameGlobalType
    switch extensionState.resolvedType {
    case .success(let success):
      boundTypeName = success
    case .failure(let failure):
      return .failure(failure)
    }

    // Get the type's main declaration (to form a `ResolvedNominalTypeReference`)
    guard let boundType = namesToTypes[boundTypeName] else {
      // By `extensionsToState` invariant.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` resolved to unregistered type `\(boundTypeName)`."
      )
    }

    return Result.success((qualifiedName: boundTypeName, mainDecl: boundType.mainDecl.declGroup))
  }
}

@_spi(_QualifiedLookupTests)
extension GenericDependencyCycleElement: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    "DependencyCycleElement(introducingTypeDecl: `\(introducingTypeDecl?._memberlessDescription ?? "nil")`, extensionDecl: `\(extensionDecl._memberlessDescription)`, boundType: '\(boundType.debugDescription)'"
  }
}

@_spi(_QualifiedLookupTests)
extension GenericExtensionBindingCycle: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    let pathDescriptions = dependencyPath.map(\.debugDescription).joined(separator: ",\n    ")
    return """
      ExtensionBindingCycle(
        dependencyPath: [
          \(pathDescriptions)
        ],
        dependencyMember: '\(dependencyMember.name)'
      )"
      """
  }
}
