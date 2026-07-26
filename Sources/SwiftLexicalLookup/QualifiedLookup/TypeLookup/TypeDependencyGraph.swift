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

@_spi(_QualifiedLookupTests) public typealias IntroducingExtensionOrMainDecl = ExtensionDeclSyntax?
@_spi(_QualifiedLookupTests) public struct TypeMemberDecl: Hashable, Sendable {
  let introducingExtensionOrMainDecl: ExtensionDeclSyntax?
  let typeDeclSyntax: TypeDeclSyntax
}
@_spi(_QualifiedLookupTests) public struct TypeMember: Hashable, Sendable {
  /// Parent type or `nil` for top-level in file scope (top-level type)
  /// or other sequential scope (e.g. non-nested local decl)
  // let parentType: QualifiedTypeName
  let name: Identifier
  fileprivate(set) var decls: [TypeMemberDecl]
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
@_spi(_QualifiedLookupTests) public struct ExtensionDependency: Sendable {
  /// Similar to `QualifiedLookupDependency`
  let dependencyExtensionOrMainDecl: IntroducingExtensionOrMainDecl
  /// TODO: Consider if this is actually necessary
  let dependencyTypeName: QualifiedTypeNameGlobalType
  let member: TypeMember

  // TODO: Remove
  // let baseTypeName: QualifiedTypeNameGlobalType
  // let memberName: Identifier
}

@_spi(_QualifiedLookupTests) public enum GenericBindingFailure<TypeName: Sendable>: Error {
  case typeResolutionFailure(TypeQualifier.Failure)
  case cannotFormCycle(ExtensionBindingCycle<TypeName>)
}
@_spi(_QualifiedLookupTests) public typealias BindingFailure = GenericBindingFailure<QualifiedTypeNameGlobalType>

@_spi(_QualifiedLookupTests) public struct GenericExtensionState<TypeName: Sendable>: Sendable {
  // TODO: Assumes main decls don't introduce dependencies (see discussion below)
  // Invariant: The extensions listed must be valid and successfully bound to a type in `extensionsToState`
  //
  // See `ExtensionDependency` docstring for why these properties are *immutable*.
  @_spi(_QualifiedLookupTests) public let dependencies: [ExtensionDependency],
    // TODO: Remove this property
    extensionDecl: ExtensionDeclSyntax,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>

  @_spi(_QualifiedLookupTests) public init(
    dependencies: [ExtensionDependency],
    extensionDecl: ExtensionDeclSyntax,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>
  ) {
    self.dependencies = dependencies
    self.extensionDecl = extensionDecl
    self.resolvedType = resolvedType
  }
}
@_spi(_QualifiedLookupTests) public typealias ExtensionState = GenericExtensionState<QualifiedTypeNameGlobalType>

@_spi(_QualifiedLookupTests) public struct TypeTable: Hashable {
  fileprivate(set) var typeMembersToDecls: [Identifier: TypeMember]

  init(
    from namesToDecls: [Identifier: [TypeDeclSyntax]],
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
  @_spi(_QualifiedLookupTests) public struct TypeDependent {
    @_spi(_QualifiedLookupTests) public let memberType: Identifier
    @_spi(_QualifiedLookupTests) public let dependentExtension: SourceFileRoot<ExtensionDeclSyntax>
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
      extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
      onMemberType memberType: Identifier
    ) -> NominalType? {
      var copy = self
      // TODO: Maybe make debug-only assert
      #if DEBUG
      guard !copy.dependents.contains(where: { $0.dependentExtension.node == extensionDecl.node }) else {
        return nil
      }
      #endif
      copy.dependents.append(TypeDependent(memberType: memberType, dependentExtension: extensionDecl))
      return copy
    }
  }

  /// Updates when we register nominal types and bind extensions
  @_spi(_QualifiedLookupTests) public var namesToTypes: [QualifiedTypeNameGlobalType: NominalType]
  // /// Updates when we register nominal types and bind extensions
  // var parentsToTypeMembers: [QualifiedTypeName: TypeTable]
  @_spi(_QualifiedLookupTests) public var extensionsToState: [ExtensionDeclSyntax: ExtensionState]

  init() {
    namesToTypes = [:]
    extensionsToState = [:]
  }
}

// MARK: Lookup

@_spi(_QualifiedLookupTests) public struct GenericDependencyTracker<TypeName: Sendable> {
  /// Note: We don't guarantee that dependencies are unique.
  var dependencies: [QualifiedLookupDependency<TypeName>]

  @_spi(_QualifiedLookupTests) public init(dependencies: [QualifiedLookupDependency<TypeName>] = []) {
    self.dependencies = dependencies
  }
}
@_spi(_QualifiedLookupTests) public typealias DependencyTracker = GenericDependencyTracker<QualifiedTypeNameGlobalType>

extension TypeMember {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeNameGlobalType>) {
    self.init(
      name: dependency.member,
      decls: dependency.typeDecls.map({
        TypeMemberDecl(introducingExtensionOrMainDecl: dependency.introducingExtensionOrMainDecl, typeDeclSyntax: $0)
      })
    )
  }
}

extension ExtensionDependency {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeNameGlobalType>) {
    // TODO: Remove
    // self.baseTypeName = dependency.extendedTypeName
    // self.memberName = dependency.member
    self.dependencyExtensionOrMainDecl = dependency.introducingExtensionOrMainDecl
    self.dependencyTypeName = dependency.extendedTypeName
    self.member = TypeMember(_from: dependency)
  }
}

// TODO: Should we also have symbol-table _version
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

    // TODO: Remove
    // case memberLookupFailure(TypeDependencyGraph.NominalType.MemberLookupFailure)
    // enum MemberLookupFailure: Error {
    //   case fileNotInModuleMap(SourceFileSyntax)
    //   case declNotAttachedToSourceFile(DeclGroupSyntaxType)
    //   case selectedNonImportedModule(selectedModule: Identifier)
    // }
  }
  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    origin: (typeSyntax: SourceFileRoot<TypeLikeSyntax>, module: SymbolTable3.Module),
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
    dependencyTracker: inout DependencyTracker,
    configuredRegions: ConfiguredRegions?
  ) -> Result<[TypeDeclSyntax], QualifiedTypeLookupFailure> {
    // Get global nominal reference
    let (baseTypeName, baseTypeVersion): (QualifiedTypeNameGlobalType, Int)
    switch baseType.storage {
    case .globalReference(let name, let version):
      (baseTypeName, baseTypeVersion) = (name, version)
    case .local(let nominalTypeDecl):
      // Local decls don't have extensions (=> no dependencies generated); just
      // look into the main declaration.
      let typeMembers = nominalTypeDecl.node._groupTypeMembers(configuredRegions: configuredRegions).flatMap(\.value)
      return .success(typeMembers)
    }

    // Diagnose invalid base
    guard
      let registeredType = namesToTypes[baseTypeName],
      registeredType.version == baseTypeVersion
    else {
      return .failure(QualifiedTypeLookupFailure.invalidBase)
    }

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

    // // TODO: Remove
    // let nominal: NominalType = NominalType(
    //   qualifiedName: baseTypeName,
    //   mainDecl: registeredType.mainDecl,
    //   redeclarations: [],
    //   extensions: registeredType.boundExtensions.mapValues(OrderedSet.init(_:))
    // )
    // let typeMembersResult: Result<[(ExtensionDeclSyntax?, [TypeDeclSyntax])], NominalType.MemberLookupFailure> =
    //   nominal.findMemberTypes(
    //     component: ImplicitTypeReferenceComponent(name: memberTypeName, introducingSyntax: origin.typeSyntax),
    //     lookupPosition: (file: origin.file, position: origin.typeSyntax.position),
    //  )
    //
    // // Extract result or throw
    // let typeMembers: [(introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl, typeDecls: [TypeDeclSyntax])]
    // switch typeMembersResult {
    // case .success(let declarationContextAndMemberTypes):
    //   typeMembers = declarationContextAndMemberTypes
    // case .failure(let failure):
    //   return .failure(QualifiedTypeLookupFailure.memberLookupFailure(failure))
    // }
    let sortedDeclGroups = fileDecls + otherInternalDecls + externalDecls

    // Add members from each decl group and register the dependencies
    var typeDecls = [TypeDeclSyntax]()
    for declGroup in sortedDeclGroups {
      // Add the matching decls
      let introducedDecls = declGroup.typeMap.typeMembersToDecls[memberTypeName]?.decls.map(\.typeDeclSyntax) ?? []
      typeDecls.append(contentsOf: introducedDecls)

      // Save dependencies
      dependencyTracker.dependencies.append(
        QualifiedLookupDependency(
          // The introducing extension, or `nil` for the main (nominal-type) declaration
          introducingExtensionOrMainDecl: declGroup.declGroup.as(ExtensionDeclSyntax.self),
          extendedTypeName: baseTypeName,
          member: memberTypeName,
          typeDecls: typeDecls
        )
      )
    }

    return .success(typeDecls)
  }
}

extension TypeDependencyGraph {
  enum NominalRegistrationFailure: Error {
    // case unexpectedReregistration(existingMainDecl: NominalTypeDeclSyntax)

    // TODO: Remove if we remove this invariant.
    // case parentNotRegistered(parentName: QualifiedTypeNameGlobalType)
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

    // TODO: Remove if we remove this invariant.
    //
    // // Check parent is registered
    // if let (qualifiedBaseName, member: _) = qualifiedName.baseAndMember,
    //   namesToTypes[qualifiedBaseName] == nil
    // {
    //   return .failure(NominalRegistrationFailure.parentNotRegistered(parentName: qualifiedBaseName))
    // }

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
  /// TODO: Check main decls actually don't have dependencies (with example in `TypeDependencyGraph` of main decl nested in dependency)
  /// We need to save dependencies to the main nominal-type declaration,
  /// which we represent as `nil`.
  ///
  /// For instance, suppose we have `struct A {}` and we bind:
  /// ```swift
  /// extension A.B {}
  /// ```
  /// This extension depends on the member type 'B' of '(MyFile.swift)::A'.
  /// Currently, no extensions introduce this member type but we need to record
  /// the dependency in case another extension introduces
  /// '(MyFile.swift)::A' > 'B'. Hence, we say the introducing decl is `nil` (the
  /// main declaration.)
  let introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
  let extendedTypeName: TypeName
  let member: Identifier
  let typeDecls: [TypeDeclSyntax]

  @_spi(_QualifiedLookupTests) public init(
    introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
    extendedTypeName: TypeName,
    member: Identifier,
    typeDecls: [TypeDeclSyntax]
  ) {
    self.introducingExtensionOrMainDecl = introducingExtensionOrMainDecl
    self.extendedTypeName = extendedTypeName
    self.member = member
    self.typeDecls = typeDecls
  }
}

@_spi(_QualifiedLookupTests) public struct ExtensionBindingCycle<TypeName: Sendable>: Sendable {
  @_spi(_QualifiedLookupTests) public typealias Dependency = QualifiedLookupDependency<TypeName>
  let dependencyChain: [Dependency]

  @_spi(_QualifiedLookupTests) public init(dependencyChain: [Dependency]) {
    self.dependencyChain = dependencyChain
  }
}

extension TypeDependencyGraph {
  enum CycleDetectionFailure: Error {
    case unresolvedDependencyExtension(
      dependentExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionState: ExtensionState?
    )
  }

  /// Parameters:
  /// - boundTypeName: The name of the type to which we're trying to bind this extension
  /// - introducedTypes: The type members we're trying to introduce
  /// TODO: Consider simplifying by getting ExtensionDependency/dependencyTypeName
  private func _findCyclicalDependencyImplementation(
    boundTypeName: QualifiedTypeNameGlobalType,
    introducedTypeTable: TypeTable,
    currentExtensionDecl: ExtensionDeclSyntax,
    currentExtendedType: QualifiedTypeNameGlobalType,
    extensionDependencies: [QualifiedLookupDependency<QualifiedTypeNameGlobalType>],
    currentDependencyChain: inout [QualifiedLookupDependency<QualifiedTypeNameGlobalType>]
  ) -> Result<ExtensionBindingCycle<QualifiedTypeNameGlobalType>, CycleDetectionFailure>? {
    // Check for accidental cycles
    assert(
      !currentDependencyChain.contains(where: { $0.introducingExtensionOrMainDecl != currentExtensionDecl }),
      "[SwiftLexicalLookup] Internal error: Unexpectedly found cycle in existing extension-dependency graph."
    )

    // Check each dependency for conflicts
    for dependency in extensionDependencies {
      // Check dependency itself
      guard !introducedTypeTable.collidesWithDependency(dependency, whenBoundTo: currentExtendedType) else {
        // Note: We return immediately and diagnose only one cycle for simplicity since
        // extension-binding cycles are rare.
        return .success(ExtensionBindingCycle(dependencyChain: currentDependencyChain))
      }

      // Get the introducing extension to check for dependencies.
      guard let dependencyExtension = dependency.introducingExtensionOrMainDecl else {
        // If we depend on a main decl, we shoud just add ourselves as a dependent
        // to that type.
        // However, even if the type was introduced in an extension,
        // that dependence is handled through another qualified-lookup request.
        // TODO: Prove this latter point.
        continue
      }

      // Check transitive dependencies
      //
      // For something to be a dependency, it must be bound to a type
      guard
        let dependencyExtensionState = extensionsToState[dependencyExtension],
        case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType
      else {
        return Result.failure(
          CycleDetectionFailure.unresolvedDependencyExtension(
            dependentExtensionOrMainDecl: currentExtensionDecl,
            dependencyExtensionOrMainDecl: dependencyExtension,
            dependencyExtensionState: extensionsToState[dependencyExtension]
          )
        )
      }
      // Map transitive dependencies to ``QualifiedLookupDependency``, getting their extended type
      var transitiveDependencies = [QualifiedLookupDependency<QualifiedTypeNameGlobalType>]()
      for transitiveDependency in dependencyExtensionState.dependencies {
        guard
          // Reasoning for main declarations similar to above.
          let transitiveDependencyExtension = transitiveDependency.dependencyExtensionOrMainDecl,
          let transitiveDependencyExtensionState = extensionsToState[transitiveDependencyExtension],
          case .success(let transitiveDependencyExtendedType) = transitiveDependencyExtensionState.resolvedType
        else {
          return Result.failure(
            CycleDetectionFailure.unresolvedDependencyExtension(
              dependentExtensionOrMainDecl: dependencyExtension,
              dependencyExtensionOrMainDecl: transitiveDependency.dependencyExtensionOrMainDecl,
              dependencyExtensionState: transitiveDependency.dependencyExtensionOrMainDecl.flatMap({
                extensionsToState[$0]
              })
            )
          )
        }
        transitiveDependencies.append(
          QualifiedLookupDependency(
            introducingExtensionOrMainDecl: transitiveDependencyExtension,
            extendedTypeName: transitiveDependencyExtendedType,
            member: transitiveDependency.member.name,
            typeDecls: transitiveDependency.member.decls.compactMap(\.typeDeclSyntax)
          )
        )
      }
      // Recurse, updating the dependency chain
      currentDependencyChain.append(dependency)
      if let cycle = _findCyclicalDependencyImplementation(
        boundTypeName: boundTypeName,
        introducedTypeTable: introducedTypeTable,
        currentExtensionDecl: dependencyExtension,
        currentExtendedType: dependencyExtendedType,
        extensionDependencies: transitiveDependencies,
        currentDependencyChain: &currentDependencyChain
      ) {
        // Find just one cycle, like above
        return cycle
      }
      currentDependencyChain.removeLast()
    }
    return nil
  }
}

extension TypeDependencyGraph {
  /// Recursively invalidate all of a type's dependents that rely on any
  /// types introduced in `dependencyMembers`.
  ///
  /// Parameters:
  /// - modifiedTypeName: The type that changed and requires invalidating dependent
  ///   extensions.
  /// - modifiedMembers: The direct dependents (extensions) of the `modifiedType` type.
  /// - invalidatedExtensions: A list of unspecified order containg the invalidated
  ///   extensions.
  ///
  /// Returns: The new dependent extensions after removing the invalidated ones.
  /// TODO: Make recursive
  fileprivate mutating func _invalidateDependents(
    modifiedTypeName: QualifiedTypeNameGlobalType,
    modifiedMembers: TypeTable,
    directDependents: [TypeDependent],
    invalidatedExtensions: inout [ExtensionState],
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
  ) -> [TypeDependent] {
    // For each dependent extension, either invalidate or keep it in the
    // new-dependents list.
    var newDependents = [TypeDependent]()

    // TODO: Verify that this order of invalidating is fine
    for dependent in directDependents {
      // Get the invalidated extension (or retain dependent)
      guard modifiedMembers.typeMembersToDecls[dependent.memberType] != nil else {
        newDependents.append(dependent)
        continue
      }
      let invalidatedExtension = dependent.dependentExtension

      // Ensure extension has a known module (needed later)
      guard let invalidatedExtensionModule: SymbolTable3.Module = moduleMap[invalidatedExtension.fileRoot] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Found extension \(invalidatedExtension.node._memberlessDescription) from unbound module."
        )
      }

      // Get the to-be-invalidated extension's state
      guard let invalidatedExtensionState = extensionsToState[invalidatedExtension.node] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) referenced in `\(modifiedTypeName)`'s dependents, but lacks a state entry."
        )
      }

      // Invalidate
      //
      // 1. Remove extension state & record invalidated extension
      extensionsToState[invalidatedExtension.node] = nil
      invalidatedExtensions.append(invalidatedExtensionState)

      // 2. Update the extended type
      //
      // If the extension was unbound, we don't have any children to invalidate
      // or a bound type to update, so we're done
      guard case .success(let invalidatedExtensionTypeName) = invalidatedExtensionState.resolvedType else {
        continue
      }
      // FIXME: Remove the dependents from the invalidated type

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
      let newTransitiveDependents = _invalidateDependents(
        modifiedTypeName: invalidatedExtensionTypeName,
        modifiedMembers: invalidatedExtensionTypeTable,
        directDependents: invalidatedExtensionType.dependents,
        invalidatedExtensions: &invalidatedExtensions,
        moduleMap: moduleMap
      )
      let finalInvalidatedExtensionType = newInvalidatedExtensionType._updatingDependents(newTransitiveDependents)

      // Update
      namesToTypes[invalidatedExtensionTypeName] = finalInvalidatedExtensionType

      // 3. Remove extension's introduced types
      for (typeMember, _) in invalidatedExtensionTypeTable.typeMembersToDecls {
        let potentialNominalType = invalidatedExtensionTypeName.addingComponents([
          QualifiedTypeNameGlobalType.Component(
            // TODO: Might be internal module!!
            qualifier: .external(moduleName: invalidatedExtensionModule),
            name: typeMember
          )
        ])
        guard let removedTypeState = namesToTypes.removeValue(forKey: potentialNominalType) else { continue }
        // Since the type goes missing, its extensions are invalidated
        for (_, removedTypeExtensions) in removedTypeState.boundExtensions {
          for (removedTypeExtension, _) in removedTypeExtensions {
            guard let oldState = extensionsToState.removeValue(forKey: removedTypeExtension.node) else {
              // TODO: Complain about non-upheld invariant
              fatalError("")
            }
            invalidatedExtensions.append(oldState)
          }
        }
        // FIXME: Need to also remove the type's dependents!!
      }

    }

    return newDependents
  }
}

// MARK: Extension Binding

extension TypeDependencyGraph {
  typealias InvalidatedExtensions = [ExtensionState]
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
    to result: Result<
      (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: NominalTypeDeclSyntax),
      TypeQualifier.Failure
    >,
    dependencyTracker: DependencyTracker,
    configuredRegions: ConfiguredRegions?,
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
  ) -> Result<InvalidatedExtensions, ExtensionAdmissionFailure> {
    // Ensure extension isn't already bound
    if let existingExtensionState = extensionsToState[extensionDecl.node] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Prepare to store extension state
    let mappedExtensionDecl = MappedDeclGroup.from(declGroup: extensionDecl, configuredRegions: configuredRegions)
    let dependencies = dependencyTracker.dependencies.map(ExtensionDependency.init(_from:))

    // === Diagnose Dependency Cycles ===

    // To check admissability, ensure we don't get a cycle
    //
    // First, compute a cycle (or `nil` for no cycles)
    // FIXME: Even cyclical extensions should be registered b/c they might be fixed
    //        with additional extensions
    var dependencyChain = [QualifiedLookupDependency<QualifiedTypeNameGlobalType>]()
    let cycleResult: Result<ExtensionBindingCycle<QualifiedTypeNameGlobalType>, CycleDetectionFailure>?
    switch result {
    case .success(let (extendedTypeName, _)):
      cycleResult = _findCyclicalDependencyImplementation(
        boundTypeName: extendedTypeName,
        introducedTypeTable: mappedExtensionDecl.typeMap,
        currentExtensionDecl: extensionDecl.node,
        currentExtendedType: extendedTypeName,
        extensionDependencies: dependencyTracker.dependencies,
        currentDependencyChain: &dependencyChain
      )
    case .failure:
      // Failed extensions are unbound, so they don't admit member types
      // that can cause cycles.
      cycleResult = nil
    }
    // Handle cycle
    switch cycleResult {
    case nil:
      // No cycles
      break
    case .success(let cycle):
      // Failed binding => no type members and no dependents
      extensionsToState[extensionDecl.node] = ExtensionState(
        dependencies: dependencyTracker.dependencies.map(ExtensionDependency.init(_from:)),
        extensionDecl: extensionDecl.node,
        resolvedType: Result.failure(BindingFailure.cannotFormCycle(cycle)),
      )
    case .failure(
      .unresolvedDependencyExtension(
        let dependentExtension,
        let dependencyExtension,
        let dependencyExtensionState
      )
    ):
      // TODO: Rewrite so that we only throw here, _findCyclicalDependencyImplementation traps,
      // and we just get an optional cycle.
      //
      // If the invalid dependency occurs at the extension we're trying to
      // admit, this might be the caller's fault since they provide
      // ``DependencyTracker``
      guard dependentExtension == extensionDecl.node else {
        // Graph invariant was broken
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \((dependentExtension?._memberlessDescription).debugDescription) unexpectedly depends on non-resolved extension \((dependencyExtension?._memberlessDescription).debugDescription) with state: \(String(reflecting: dependencyExtensionState))."
        )
      }
      return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: dependencyExtensionState))
    }

    // === Register as Dependent ===

    // Now that we're admissable, tell predecessors we're dependent
    for dependency in dependencyTracker.dependencies {
      // TODO: Make into debug-only assertion
      if let dependencyExtension = dependency.introducingExtensionOrMainDecl {
        guard
          let dependencyExtensionState = extensionsToState[dependencyExtension],
          case Result.success(dependency.extendedTypeName) = dependencyExtensionState.resolvedType
        else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Expected dependency's extension `\(dependencyExtension._memberlessDescription)` to resolve to '\(dependency.extendedTypeName)'; instead, resolved to \(extensionsToState[dependencyExtension].debugDescription)"
          )
        }
      }

      // Find the referenced type
      guard let nominalType = namesToTypes[dependency.extendedTypeName] else {
        // TODO: Throw error for client instead of trapping
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \((dependency.introducingExtensionOrMainDecl?._memberlessDescription).debugDescription) bound to type '\(dependency.extendedTypeName)', which isn't in the graph."
        )
      }

      // Mark the dependence
      guard
        let nominalWithDependents = nominalType.addingDependentExtension(
          extensionDecl: extensionDecl,
          onMemberType: dependency.member
        )
      else {
        // Ensure we don't register a dependent twice (debug-only)
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly found not-yet-admitted extension `\(extensionDecl.node._memberlessDescription)` in dependents list of '\(dependency.extendedTypeName)'."
        )
      }
      namesToTypes[dependency.extendedTypeName] = nominalWithDependents
    }

    // === Invalidate Dependents & Bind ===
    let invalidatedExtensions: [ExtensionState]
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
        directDependents: extendedType.dependents,
        invalidatedExtensions: &invalidatedExtensionsTmp,
        moduleMap: moduleMap
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
    extensionsToState[extensionDecl.node] = ExtensionState(
      dependencies: dependencies,
      extensionDecl: extensionDecl.node,
      resolvedType: result.map(\.qualifiedName).mapError(BindingFailure.typeResolutionFailure)
    )

    return .success(invalidatedExtensions)
  }
}

// MARK: Debugging

extension NominalTypeRef: CustomDebugStringConvertible {
  @_spi(_QualifiedLookupTests) public func _describe(describeTypeName: (QualifiedTypeName) -> String) -> String {
    switch storage {
    case .globalReference(let qualifiedName, let version):
      let nameDescription = describeTypeName(QualifiedTypeName.topLevel(qualifiedName))
      return "\(nameDescription) (v\(version))"
    case .local(let nominalDecl):
      return "\(nominalDecl.node._memberlessDescription) (local)"
    }
  }

  public var debugDescription: String {
    _describe(describeTypeName: \.debugDescription)
  }
}

extension QualifiedLookupDependency: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    """
    QualifiedLookupDependency(
      introducingExtensionOrMainDecl: \((introducingExtensionOrMainDecl?._memberlessDescription).debugDescription),
      extendedTypeName: \(extendedTypeName.debugDescription)
      member: \(member.name),
      typeDecls: \(typeDecls.map(\.trimmedDescription)))
    """
  }
}

extension ExtensionDependency: CustomDebugStringConvertible {
  public var debugDescription: String {
    "ExtensionDependency(dependencyExtension: \((dependencyExtensionOrMainDecl?._memberlessDescription).debugDescription), member: \(member.name))"
  }
}

extension GenericBindingFailure {
  @_spi(_QualifiedLookupTests) public func _describe(
    describeTypeName: (TypeName) -> String
  ) -> String {
    switch self {
    case .typeResolutionFailure(let failure):
      return failure.debugDescription
    case .cannotFormCycle(let cycle):
      return cycle._describe(describeTypeName: describeTypeName)
    }
  }
}
extension GenericBindingFailure: CustomDebugStringConvertible where TypeName == QualifiedTypeName {
  public var debugDescription: String {
    _describe(describeTypeName: \.debugDescription)
  }
}

extension Result {
  @_spi(_QualifiedLookupTests) public func _describe(
    describeTypeName: (Success) -> String
  ) -> String
  where Failure == GenericBindingFailure<Success> {
    switch self {
    case .success(let success):
      return "Result.success(\(describeTypeName(success)))"
    case .failure(let failure):
      return "Result.failure(\(failure._describe(describeTypeName: describeTypeName)))"
    }
  }
}

extension GenericExtensionState {
  @_spi(_QualifiedLookupTests) public func _describe(
    describeTypeName: (TypeName) -> String
  ) -> String {
    """
    GenericExtensionState(
      dependencies: \(dependencies.map(\.debugDescription)),
      resolvedType: \(resolvedType._describe(describeTypeName: describeTypeName))
    )
    """
  }
}
extension GenericExtensionState: CustomDebugStringConvertible where TypeName == QualifiedTypeName {
  public var debugDescription: String {
    _describe(describeTypeName: \.debugDescription)
  }
}

// TypeDependencyGraph description

private struct _DependencyGraphDiagnostic: DiagnosticMessage {
  let message: String
  let severity: DiagnosticSeverity

  var diagnosticID: MessageID { MessageID(domain: "SwiftLexicalLookup", id: "TypeDependencyGraphDiagnostic") }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public func _describeWithDiagnostics(
    describeTypeName: (QualifiedTypeNameGlobalType) -> String
  ) -> [Diagnostic] {
    var diagnostics = [Diagnostic]()
    /// Attach a note to the given node.
    func _attachNote(to node: some SyntaxProtocol, message: String) {
      diagnostics.append(
        Diagnostic(node: node, message: _DependencyGraphDiagnostic(message: message, severity: .note))
      )
    }
    /// Attach an error to the given node.
    func _attachError(to node: some SyntaxProtocol, message: String) {
      diagnostics.append(
        Diagnostic(node: node, message: _DependencyGraphDiagnostic(message: message, severity: .error))
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
    var extensionsToType = [ExtensionDeclSyntax: (boundTypeName: QualifiedTypeNameGlobalType, typeTable: TypeTable)]()
    for (typeName, type) in namesToTypes {
      let typeNameDescription = describeTypeName(typeName)

      // Check each main decl mapped to exactly one visited type
      let mainDecls = [type.mainDecl] + type.redeclarations
      for (index, nominalTypeDecl) in mainDecls.enumerated() {
        // User-friendly description
        let declLabel = index == 0 ? "Main decl" : "Redeclaration #\(index)"

        // Ensure this type decl is mapped to only one name
        guard visitedTypes.updateValue(typeName, forKey: nominalTypeDecl.node) == nil else {
          // This nominal-type declaration was already registered under a different name
          _attachError(to: nominalTypeDecl.node, message: "\(declLabel) also registered under '\(typeNameDescription)'")
          continue
        }

        // Show the registered name
        _attachNote(
          to: nominalTypeDecl.node,
          message: "\(declLabel) registered '\(typeNameDescription)' (v\(type.version))"
        )

        // Mark each member in the type table
        _markMemberTypes(baseTypeName: typeNameDescription, typeTable: nominalTypeDecl.typeMap)
      }

      // Add dependent extensions (to main declaration)
      for dependentExtension in type.dependents {
        _attachNote(
          to: type.mainDecl.node,
          message:
            "Member type '\(typeNameDescription)' > '\(dependentExtension.memberType.name)' depended on by `\(dependentExtension.dependentExtension.node._memberlessDescription)`"
        )
      }

      // Check bound-extension state points to us as the resolved type
      for (boundExtension, typeTable) in type.boundExtensions.flatMap(\.value) {
        // Ensure bound extension has a state
        guard extensionsToState[boundExtension.node] != nil else {
          _attachError(
            to: boundExtension.node,
            message: "Extension bound to '\(typeNameDescription)' but has no state."
          )
          continue
        }
        extensionsToType[boundExtension.node] = (boundTypeName: typeName, typeTable: typeTable)

        continue
      }
    }

    // Mark all extensions, whether bound (in `extensionsToState`) or failed
    for (extensionDecl, extensionState) in extensionsToState {
      // Print extension state with respect to whether it's bound type
      let boundState = extensionsToType[extensionDecl]
      switch (extensionState.resolvedType, boundState) {
      case (.success(let resolvedTypeName), let (boundTypeName, typeTable)?):
        let boundTypeDescription = describeTypeName(boundTypeName)

        // Ensure the extension's resolved type and nominal type's name agree
        // (skips to next iteration)
        guard resolvedTypeName == boundTypeName else {
          _attachError(
            to: extensionDecl,
            message:
              "Extension bound to '\(boundTypeDescription)', but its state says it resolved to '\(describeTypeName(resolvedTypeName))'"
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
          message: "Extension binding failed: \(failure._describe(describeTypeName: describeTypeName))"
        )

      // Diagnose invalid graph state (these switch cases skip to the next iteration)
      case (.failure(let failure), let (boundTypeName, _)?):
        // Failed extension shouldn't be bound
        _attachError(
          to: extensionDecl,
          message:
            "Extension bound to '\(describeTypeName(boundTypeName))', but its state says it failed to resolve: \(failure._describe(describeTypeName: describeTypeName))"
        )
        continue
      case (.success(let resolvedTypeName), nil):
        // Successfully resolved extensions should be bound to a `NominalType`
        let resolvedNameDescription = describeTypeName(resolvedTypeName)
        _attachError(
          to: extensionDecl,
          message: "Extension successfully resolved to but didn't bind to '\(resolvedNameDescription)'."
        )
        continue
      }

      // Mark dependencies
      for dependency in extensionState.dependencies {
        let memberName = dependency.member.name.name
        // Ensure extension dependency matches extension state
        if let dependencyExtension = dependency.dependencyExtensionOrMainDecl {
          guard
            case .success(let dependencyExtendedType)? = extensionsToState[dependencyExtension]?.resolvedType,
            dependency.dependencyTypeName == dependencyExtendedType
          else {
            let expectedTypeDescription = describeTypeName(dependency.dependencyTypeName)
            let actualTypeDescription = extensionsToState[dependencyExtension]?.resolvedType.map(describeTypeName)
            _attachError(
              to: extensionDecl.extendedType,
              message:
                "Extension depends on '\(expectedTypeDescription)' > '\(memberName)' declared in `\(dependencyExtension._memberlessDescription)`, but the extension state resolved to '\(actualTypeDescription.debugDescription)'."
            )
            continue
          }
        }

        // Add dependency
        let dependencyTypeDescription = describeTypeName(dependency.dependencyTypeName)
        _attachNote(
          to: extensionDecl.extendedType,
          message: "Depends on '\(dependencyTypeDescription)' > '\(memberName)'"
        )
      }

    }

    return diagnostics
  }
}
