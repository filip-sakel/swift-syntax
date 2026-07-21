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

typealias IntroducingExtensionOrMainDecl = ExtensionDeclSyntax?
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

@_spi(_QualifiedLookupTests) public struct ExtensionDependency: Sendable {
  let dependencyExtension: ExtensionDeclSyntax, member: TypeMember
}

@_spi(_QualifiedLookupTests) public enum GenericBindingFailure<TypeName: Sendable>: Error {
  case typeResolutionFailure(TypeQualifier.Failure)
  case cannotFormCycle(ExtensionBindingCycle<TypeName>)
}
@_spi(_QualifiedLookupTests) public typealias BindingFailure = GenericBindingFailure<QualifiedTypeName>

@_spi(_QualifiedLookupTests) public struct GenericExtensionState<TypeName: Sendable>: Sendable {
  // TODO: Assumes main decls don't introduce dependencies (see discussion below)
  // Invariant: The extensions listed must be valid and successfully bound to a type in `extensionsToState`
  @_spi(_QualifiedLookupTests) public fileprivate(set) var dependencies: [ExtensionDependency],
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
@_spi(_QualifiedLookupTests) public typealias ExtensionState = GenericExtensionState<QualifiedTypeName>

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
  struct TypeTable: Hashable {
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
      _ dependency: QualifiedLookupDependency<QualifiedTypeName>,
      whenBoundTo baseTypeName: QualifiedTypeName
    ) -> Bool {
      dependency.extendedTypeName == baseTypeName && typeMembersToDecls[dependency.member] != nil
    }
  }
  @_spi(_QualifiedLookupTests) public struct NominalType {
    /// Keeps track of mutations to assert data didn't change between calls
    fileprivate private(set) var version = 0

    /// Invariants: count >= 1; sorted by position in increasing order
    private var _mainDecls: [MappedDeclGroup<NominalTypeDeclSyntax>]

    private(set) var boundExtensions: [SymbolTable3.Module: [SourceFileRoot<ExtensionDeclSyntax>: TypeTable]]

    /// FIXME: Track dependencies so we invalidate when the underlying extension is invalidated
    ///
    /// Extensions dependending on qualified lookup of `member` on this type.
    ///
    /// This property is part of `NominalType` and not `ExtensionState` because
    /// any extension binding to this nominal type should see that it's invalidating
    /// other extensions.
    fileprivate(set) var dependents: [(typeMember: Identifier, dependentExtension: SourceFileRoot<ExtensionDeclSyntax>)]

    init(mainDecl: MappedDeclGroup<NominalTypeDeclSyntax>) {
      self._mainDecls = [mainDecl]
      self.boundExtensions = [:]
      self.dependents = []
    }

    var mainDecl: MappedDeclGroup<NominalTypeDeclSyntax> {
      // By invariant above that `_mainDecls.count >= 1`
      _mainDecls[0]
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
  }

  /// Updates when we register nominal types and bind extensions
  @_spi(_QualifiedLookupTests) public var namesToTypes: [QualifiedTypeName: NominalType]
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
@_spi(_QualifiedLookupTests) public typealias DependencyTracker = GenericDependencyTracker<QualifiedTypeName>

extension TypeMember {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeName>) {
    self.init(
      name: dependency.member,
      decls: dependency.typeDecls.map({
        TypeMemberDecl(introducingExtensionOrMainDecl: dependency.extensionDecl, typeDeclSyntax: $0)
      })
    )
  }
}

extension ExtensionDependency {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeName>) {
    self.dependencyExtension = dependency.extensionDecl
    self.member = TypeMember(_from: dependency)
  }
}

// TODO: Should we also have symbol-table _version
@_spi(_QualifiedLookupTests) public struct NominalTypeRef: Hashable, Sendable {
  @_spi(_QualifiedLookupTests) public let qualifiedName: QualifiedTypeName
  fileprivate let version: Int

  init(qualifiedName: QualifiedTypeName, nominal: __shared TypeDependencyGraph.NominalType) {
    self.qualifiedName = qualifiedName
    self.version = nominal.version
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
  func findTypeMember(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    origin: (typeSyntax: SourceFileRoot<TypeLikeSyntax>, module: SymbolTable3.Module),
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
    dependencyTracker: inout DependencyTracker
  ) -> Result<[TypeDeclSyntax], QualifiedTypeLookupFailure> {
    // Diagnose invalid base
    guard
      let registeredType = namesToTypes[baseType.qualifiedName],
      registeredType.version == baseType.version
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

    var typeDecls: [TypeDeclSyntax] = sortedDeclGroups.flatMap({ declGroup in
      declGroup.typeMap.typeMembersToDecls[memberTypeName]?.decls.map(\.typeDeclSyntax) ?? []
    })

    // Add the dependencies
    for declGroup in sortedDeclGroups {
      // Add the matching decls
      let introducedDecls = declGroup.typeMap.typeMembersToDecls[memberTypeName]?.decls.map(\.typeDeclSyntax) ?? []
      typeDecls.append(contentsOf: introducedDecls)

      // Save dependencies
      // TODO: According to assumption below, main decls don't have dependencies
      guard let introducingExtension = declGroup.declGroup.as(ExtensionDeclSyntax.self) else { continue }

      dependencyTracker.dependencies.append(
        QualifiedLookupDependency(
          extensionDecl: introducingExtension.node,
          extendedTypeName: baseType.qualifiedName,
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
    case parentNotRegistered(parentName: QualifiedTypeName)
  }

  /// Registers the given nominal-type reference or return the
  /// existing reference.
  mutating func registerNominalTypeReference(
    qualifiedName: QualifiedTypeName,
    mainDecl: SourceFileRoot<NominalTypeDeclSyntax>,
    configuredRegions: ConfiguredRegions?
  ) -> Result<NominalTypeRef, NominalRegistrationFailure> {
    // Check parent is registered
    if let (qualifiedBaseName, memberName: _) = qualifiedName.baseAndMemberName,
      namesToTypes[qualifiedBaseName] == nil
    {
      return .failure(NominalRegistrationFailure.parentNotRegistered(parentName: qualifiedBaseName))
    }

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
  // TODO: Check main decls actually don't have dependencies (with example in `TypeDependencyGraph` of main decl nested in dependency)
  let extensionDecl: ExtensionDeclSyntax
  let extendedTypeName: TypeName
  let member: Identifier
  let typeDecls: [TypeDeclSyntax]

  @_spi(_QualifiedLookupTests) public init(
    extensionDecl: ExtensionDeclSyntax,
    extendedTypeName: TypeName,
    member: Identifier,
    typeDecls: [TypeDeclSyntax]
  ) {
    self.extensionDecl = extensionDecl
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
      dependentExtension: ExtensionDeclSyntax,
      dependencyExtension: ExtensionDeclSyntax,
      dependencyExtensionState: ExtensionState?
    )
  }

  /// Parameters:
  /// - boundTypeName: The name of the type to which we're trying to bind this extension
  /// - introducedTypes: The type members we're trying to introduce
  private func _findCyclicalDependencyImplementation(
    boundTypeName: QualifiedTypeName,
    introducedTypeTable: TypeTable,
    currentExtensionDecl: ExtensionDeclSyntax,
    currentExtendedType: QualifiedTypeName,
    extensionDependencies: [QualifiedLookupDependency<QualifiedTypeName>],
    currentDependencyChain: inout [QualifiedLookupDependency<QualifiedTypeName>]
  ) -> Result<ExtensionBindingCycle<QualifiedTypeName>, CycleDetectionFailure>? {
    // Check for accidental cycles
    assert(
      !currentDependencyChain.contains(where: { $0.extensionDecl != currentExtensionDecl }),
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

      // Check transitive dependencies
      //
      // For something to be a dependency, it must be bound to a type
      guard
        let dependencyExtensionState = extensionsToState[dependency.extensionDecl],
        case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType
      else {
        return Result.failure(
          CycleDetectionFailure.unresolvedDependencyExtension(
            dependentExtension: currentExtensionDecl,
            dependencyExtension: dependency.extensionDecl,
            dependencyExtensionState: extensionsToState[dependency.extensionDecl]
          )
        )
      }
      // Map transitive dependencies to ``QualifiedLookupDependency``, getting their extended type
      var transitiveDependencies = [QualifiedLookupDependency<QualifiedTypeName>]()
      for transitiveDependency in dependencyExtensionState.dependencies {
        guard
          let transitiveDependencyExtensionState = extensionsToState[transitiveDependency.dependencyExtension],
          case .success(let transitiveDependencyExtendedType) = transitiveDependencyExtensionState.resolvedType
        else {
          return Result.failure(
            CycleDetectionFailure.unresolvedDependencyExtension(
              dependentExtension: dependency.extensionDecl,
              dependencyExtension: transitiveDependency.dependencyExtension,
              dependencyExtensionState: extensionsToState[transitiveDependency.dependencyExtension]
            )
          )
        }
        transitiveDependencies.append(
          QualifiedLookupDependency(
            extensionDecl: transitiveDependency.dependencyExtension,
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
        currentExtensionDecl: dependency.extensionDecl,
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

// MARK: Extension Binding

extension TypeDependencyGraph {
  typealias InvalidatedExtensions = [ExtensionState]
  @_spi(_QualifiedLookupTests) public enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }
  mutating func _admitExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    extensionDeclModule: SymbolTable3.Module,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<
      (qualifiedName: QualifiedTypeName, mainDecl: NominalTypeDeclSyntax),
      TypeQualifier.Failure
    >,
    dependencyTracker: DependencyTracker,
    configuredRegions: ConfiguredRegions?,
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
  ) -> Result<InvalidatedExtensions, ExtensionAdmissionFailure> {
    // Ensure extension isn't bound
    if let existingExtensionState = extensionsToState[extensionDecl.node] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Prepare to store extension state
    let mappedExtensionDecl = MappedDeclGroup.from(declGroup: extensionDecl, configuredRegions: configuredRegions)
    let dependencies = dependencyTracker.dependencies.map(ExtensionDependency.init(_from:))

    // Get the bound type name; if the result failed, save with dependencies (might get fixed later)
    let extendedTypeName: QualifiedTypeName
    // let mainDecl: NominalTypeDeclSyntax
    switch result {
    case .success(let success):
      // (extendedTypeName, mainDecl) = success
      extendedTypeName = success.qualifiedName
    case .failure(let failure):
      // Failed type resolution means no binding => no type members and no
      // dependents or dependencies to invalidate
      extensionsToState[extensionDecl.node] = ExtensionState(
        dependencies: dependencies,
        extensionDecl: extensionDecl.node,
        resolvedType: Result.failure(BindingFailure.typeResolutionFailure(failure)),
      )
      return .success([])
    }

    // Get the bound type
    guard let extendedType = namesToTypes[extendedTypeName] else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) bound to type \(extendedTypeName), which isn't in the graph."
      )
    }

    // To check admissability, ensure we don't get a cycle
    // TODO: Check if we can merge cycle detection with dependent-marking below
    var dependencyChain = [QualifiedLookupDependency<QualifiedTypeName>]()
    let cycleResult: Result<ExtensionBindingCycle<QualifiedTypeName>, CycleDetectionFailure>? =
      _findCyclicalDependencyImplementation(
        boundTypeName: extendedTypeName,
        introducedTypeTable: mappedExtensionDecl.typeMap,
        currentExtensionDecl: extensionDecl.node,
        currentExtendedType: extendedTypeName,
        extensionDependencies: dependencyTracker.dependencies,
        currentDependencyChain: &dependencyChain
      )
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
          "[SwiftLexicalLookup] Internal error: Extension \(dependentExtension._memberlessDescription) unexpectedly depends on non-resolved extension \(dependencyExtension._memberlessDescription) with state: \(String(reflecting: dependencyExtensionState))."
        )
      }
      return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: dependencyExtensionState))
    }

    // Now that we're admissable, tell predecessors we're dependent
    for dependency in dependencyTracker.dependencies {
      // Get the type name (only successfully bound extensions introduce type
      // members we can depend on)
      let optionalExtensionState = extensionsToState[extensionDecl.node]
      guard let extensionState = optionalExtensionState,
        case Result.success(let dependencyType) = extensionState.resolvedType
      else {
        return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: optionalExtensionState))
      }

      // Find the referenced type
      guard var nominalType = namesToTypes[dependencyType] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(dependency.extensionDecl._memberlessDescription) bound to type \(dependencyType), which isn't in the graph."
        )
      }

      // Mark the dependence
      assert(
        !nominalType.dependents.contains(where: { $0.dependentExtension.node == extensionDecl.node }),
        "[SwiftLexicalLookup] Internal error: Unexpectedly found not-yet-admitted extension \(extensionDecl.node._memberlessDescription) in dependents list of \(dependency.extensionDecl._memberlessDescription)."
      )
      nominalType.dependents.append((typeMember: dependency.member, dependentExtension: extensionDecl))
    }

    // Remove invalidated extensions
    //
    // Invalidate all extensions that depend on type members we've added
    var queue = [SourceFileRoot<ExtensionDeclSyntax>]()
    for dependent in extendedType.dependents {
      guard mappedExtensionDecl.typeMap.typeMembersToDecls[dependent.typeMember] != nil else { continue }
      queue.append(dependent.dependentExtension)
    }
    var invalidatedExtensions = [ExtensionState]()
    // TODO: Consider if this order of invalidating is fine
    while let invalidatedExtension = queue.popLast() {
      // Ensure extension has a known module (needed later)
      guard let invalidatedExtensionModule: SymbolTable3.Module = moduleMap[invalidatedExtension.fileRoot] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Found extension \(invalidatedExtension.node._memberlessDescription) from unbound module."
        )
      }

      // Get the to-be-invalidated extension's state
      guard let invalidatedExtensionState = extensionsToState[invalidatedExtension.node] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) referenced in \(extendedTypeName)'s dependents, but lacks a state entry."
        )
      }

      // Invalidate
      //
      // 1. Remove extension state
      extensionsToState[extensionDecl.node] = nil

      // 2. Update the extended type
      //
      // If the extension was invalid, it doesn't have children to invalidate
      // or a bound type to update, so we're done
      guard case .success(let invalidatedExtensionTypeName) = invalidatedExtensionState.resolvedType else {
        continue
      }
      // Remove the members from the extended type
      guard let invalidatedExtensionType = namesToTypes[extendedTypeName] else {
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
      namesToTypes[extendedTypeName] = newInvalidatedExtensionType

      // Collect invalidated extension
      invalidatedExtensions.append(invalidatedExtensionState)

      // 3. Add recursively invalidated transitive dependents
      for transitiveDependent in invalidatedExtensionType.dependents {
        guard invalidatedExtensionTypeTable.typeMembersToDecls[transitiveDependent.typeMember] != nil else { continue }
        queue.append(transitiveDependent.dependentExtension)
      }
    }

    // Save extension (newly bound extension doesn't add type dependents)
    extensionsToState[extensionDecl.node] = ExtensionState(
      dependencies: dependencies,
      extensionDecl: extensionDecl.node,
      resolvedType: Result.success(extendedTypeName)
    )
    // Bind to type
    guard let newExtendedType = extendedType._bindingExtension(mappedExtensionDecl, module: extensionDeclModule) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) has no existing state but is already bound to \(extendedType)."
      )
    }
    namesToTypes[extendedTypeName] = newExtendedType

    return .success(invalidatedExtensions)
  }
}

// MARK: Debugging

extension NominalTypeRef: CustomDebugStringConvertible {
  public var debugDescription: String {
    "NominalTypeRef(name: \(qualifiedName.debugDescription), version: \(version))"
  }
}

extension QualifiedLookupDependency: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    """
    QualifiedLookupDependency(
      extensionDecl: \(extensionDecl._memberlessDescription), extendedTypeName: \(extendedTypeName.debugDescription)
      member: \(member.name),
      typeDecls: \(typeDecls.map(\.trimmedDescription)))
    """
  }
}

extension ExtensionDependency: CustomDebugStringConvertible {
  public var debugDescription: String {
    "ExtensionDependency(dependencyExtension: \(dependencyExtension._memberlessDescription), member: \(member.name))"
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
