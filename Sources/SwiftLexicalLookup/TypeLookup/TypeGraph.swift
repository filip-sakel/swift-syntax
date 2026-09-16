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

// TODO: Remove Glibc import
@preconcurrency import Glibc
import SwiftIfConfig
import SwiftSyntax

#if compiler(>=6)
private import SwiftDiagnostics
#else
import SwiftDiagnostics
#endif

/// A directed acyclic graph where types are nodes and extensions are edges.
///
///
/// Note: This graph is complex because extension binding depends on type members, e.g.
///       ResolvedType>TypeMember because the resolved type might be invalid or on alias.
///       However, we also keep track of nominal types b/c they might be introduced by
///       extensions and we crucially resolve to them and need a unique reference to each.
///
/// Features: (TODO: Rework)
/// 0. Iterating type->extensions, O(# of exts)
///    a. For quick qualified lookup
/// 0. Access extension->state, O(1)
///    a. To know if extension is already resolved
///    b. Constant time since we have to bind a lot of extensions
/// 0. Access extension->dependencies, O(# of dependencies)
///    a. For cycle detection when adding a dependency
/// 0. Access nominal type->dependents (extensions+types), O(# of dependents)
///    a. For eviction when adding any extension that adds/removes a type member.
/// 0. Access extension->resolved type, O(1)
///    a. Lookup within an extension almost always triggers a request
///       to resolve the extended type so we can look for its members
///       e.g.
///       struct A { struct B {} }
///       extension A {
///         func f(_: B) // <- Look up here needs to quickly
///                      //    find that `A>B` is a valid member.
///       }
///
/// Extension binding is challenging because it's incremental, i.e., we process
/// one extension at a time. Hence, we process just one extension at a time
/// using just current lookup results, keeping track of dependencies. This
/// approach allows us to remain in a consistent state. When we add other
/// extensions --and eventually all accessible extensions-- we use those
/// dependencies and the new lookup state to update old results.
///
/// Extension binding is incremental because:
/// 1. Extensions may depend on other extensions, e.g.:
///    ```swift
///    struct A {}
///    extension A.Inner {} // <- Resolving this extension requires finding 'Inner' in `A`
///    extension A { typealias Inner = A }
///    ```
/// 2. We might get a module's extensions later in compilation
///
/// Here's how this would play out in the above example if we wanted to
/// bind all of A's extensions:
/// 1. We start with `extension A.Inner`
///    a. We resolve `A` to '_(MyFile.swift)::A'
///    b. Currently, `A` has no type members, so `A.Inner` doesn't exist
///       This is the desired result, because if our program was just
///         struct A {}; extension A.Inner {}`
///       that's the exact error we'd expect.
///    c. So we mark `extension A.Inner` as invalid and record this result's dependence
///       on the fact that `A` has not memebr `Inner`
/// 2. We look at `extension A`
///    a. We resolve `A` to '_(MyFile.swift)::A' and bind the extension to '_(MyFile.swift)::A'
///    b. Now, `A` gains a type member `Inner`
///    c. We find `extension A.Inner` depended on this member so we recompute
///       it
///    d. Now, `extension A.Inner` resolves to '_(MyFile.swift)::A' depending on
///       the fact that '_(MyFile.swift)::A' has no type member `A`
///       * This dependence comes from resolving `typealias Inner = A`
///    e. Finally, we bind `extension A.Inner` to '_(MyFile.swift)::A'
@_spi(_QualifiedLookupTests)
public struct TypeGraph {
  /// Updates when we register nominal types and bind extensions
  var namesToTypes: [TypeGraph.GlobalTypeName: NominalType]
  @_spi(_QualifiedLookupTests)
  public var extensionsToState: [Attached<ExtensionDeclSyntax>: ExtensionState]

  // TODO: Remove
  var logPrefix: [String] = [String]()

  init() {
    namesToTypes = [:]
    extensionsToState = [:]
  }
}

// MARK: NominalType

extension TypeGraph {
  struct NominalType {
    /// Keeps track of mutations to assert data didn't change between calls
    internal private(set) var version = 0

    /// Invariants: count >= 1; sorted by position in increasing order
    fileprivate let mainDecl: Attached<NominalTypeDeclSyntax>
    /// The type members of `mainDecl`
    fileprivate let mainDeclMembers: TypeTable

    private(set) var boundExtensions: [ModuleName: [Attached<ExtensionDeclSyntax>: TypeTable]]

    /// Extensions dependending on qualified lookup of `member` on this type.
    ///
    /// This property is part of `NominalType` and not `ExtensionState` because
    /// any extension binding to this nominal type should see that it's evicting
    /// other extensions.
    fileprivate(set) var dependents: [TypeDependent]

    init(mainDecl: Attached<NominalTypeDeclSyntax>, mainDeclMembers: TypeTable) {
      self.mainDecl = mainDecl
      self.mainDeclMembers = mainDeclMembers
      self.boundExtensions = [:]
      self.dependents = []
    }

    /// Returns a new version of the extended type, adding the given extension.
    /// Returns `nil`  if extension is already bound.
    fileprivate consuming func _bindingExtension(
      _ extensionDecl: Attached<ExtensionDeclSyntax>,
      extensionMembers: TypeTable,
      module: ModuleName
    ) -> NominalType? {
      var copy = self
      let oldValue = copy.boundExtensions[module, default: [:]].updateValue(
        extensionMembers,
        forKey: extensionDecl
      )
      guard oldValue == nil else { return nil }
      copy.version &+= 1
      return copy
    }

    fileprivate consuming func _unbindingExtension(
      _ boundExtension: Attached<ExtensionDeclSyntax>,
      module: ModuleName
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

    enum NominalUnbindingFailure: Error {
      case nominalTypeNotAMainDecl
      case remainingBoundExtensions
      case remainingDependents
    }

    /// Unbinds the given nominal-type declaration. If the nominal-type
    /// declaration is a redeclaration, we remove it. If the nominal-type
    /// declaration is the main declaration, replace by the first redeclaration
    /// (if available). If this is the main declaration and there are no
    /// redeclarations, returns `nil`.
    fileprivate consuming func _removingNominalDecl(
      _ nominalTypeDecl: Attached<NominalTypeDeclSyntax>
    ) -> Result<Void, NominalUnbindingFailure> {
      // Ensure we have no bound extensions (if we have redeclarations,
      // the type is ambiguous so not extensions should have resolved to
      // us; if we have just one main declaration, we'll remove the type and
      // lingering extensions be bound to an unregistered type)
      //
      // Here, we check that each module has an empty list.
      guard boundExtensions.allSatisfy(\.value.isEmpty) else {
        return .failure(NominalUnbindingFailure.remainingBoundExtensions)
      }
      // Ensure we have no dependents (similar reasoning with above)
      guard dependents.isEmpty else {
        return .failure(NominalUnbindingFailure.remainingDependents)
      }

      // Ensure the declaration was actually bound and we removed it
      guard mainDecl == nominalTypeDecl else {
        return .failure(NominalUnbindingFailure.nominalTypeNotAMainDecl)
      }

      return .success(())
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
}

// MARK: IntroducingExtensionOrMainDecl

@_spi(_QualifiedLookupTests)
public typealias IntroducingExtensionOrMainDecl = Attached<ExtensionDeclSyntax>?

// MARK: TypeTable

extension TypeGraph {
  /// The direct type members declared by a *single* declaration group (nominal
  /// type or extension).
  struct TypeTable {
    /// Maps each member's name to every declaration introducing it in this
    /// declaration group. More than one declaration for the same name means
    /// the member is ambiguous (redeclared) within this one declaration group.
    ///
    /// Note: This is a `Dictionary`, so it must generally not be iterated to
    /// uphold `SymbolTable`'s determinism requirement.
    fileprivate(set) var typeMembersToDecls: [Identifier: [Attached<TypeDeclSyntax>]]
  }
}

// MARK: TypeDependent

extension TypeGraph {
  struct TypeDependent: Sendable, Hashable, CustomDebugStringConvertible {
    let memberType: Identifier
    let dependentExtension: Attached<ExtensionDeclSyntax>

    public var debugDescription: String {
      "Self > '\(memberType.name)' => `\(dependentExtension.node._memberlessDescription)`"
    }
  }
}

// MARK: ExtensionState

extension TypeGraph {
  /// The state of an admitted extension: what type it resolved to and the
  /// dependencies for that resolution result.
  ///
  /// Note: Extension state uses `GlobalTypeName` instead of `GlobalTypeRef`
  /// since the type graph already stores information about types in a
  /// different property.
  @_spi(_QualifiedLookupTests)
  public struct ExtensionState: Sendable {
    // Invariant: The extensions listed must be valid and successfully bound to a type in `extensionsToState`
    // Invariant: There's only one dependency per type.
    //
    // See `ExtensionDependency` docstring for why these properties are *immutable*.
    @_spi(_QualifiedLookupTests) public let dependencies: [ExtensionDependency],
      /// The resolved type must be valid in `namesToTypes`
      resolvedType: Result<TypeGraph.GlobalTypeName, TypeResolver.Failure>

    @_spi(_QualifiedLookupTests) public init(
      _uncheckedDependencies dependencies: [ExtensionDependency],
      resolvedType: Result<TypeGraph.GlobalTypeName, TypeResolver.Failure>
    ) {
      self.dependencies = dependencies
      self.resolvedType = resolvedType
    }

    init(
      dependencies: [QualifiedLookupDependency],
      resolvedType: Result<TypeGraph.GlobalTypeName, TypeResolver.Failure>
    ) {
      // Group dependencies by base type and member name, while maintaing order
      var groupedDependencies =
        [
          (
            key: TypeGraph.GlobalTypeName,
            value: [(key: Identifier, value: [(Attached<DeclGroupSyntaxType>, Attached<TypeDeclSyntax>)])]
          )
        ]()

      for dependency in dependencies {
        // TODO: Clarify comment
        // Note: We can assign directly because ``DependencyTracker/dependencies`` guarantees
        // that type/member-name pairs have just a single entry.
        groupedDependencies[_key: dependency.extendedTypeName, default: []][_key: dependency.member, default: []]
          .append(
            contentsOf: dependency.typeDecls
          )
      }

      // Map to `ExtensionDependency`
      // Satisfies invariant of one dependency per type
      let orderedGroupedDependencies: [ExtensionDependency] = groupedDependencies.map({ (typeName, members) in
        ExtensionDependency(
          dependencyTypeName: typeName,
          members: members.map({ (name, typeDecls) in
            (
              name: name,
              decls: typeDecls.map({ typeDecl in
                ExtensionDependency.Member(
                  introducingExtensionOrMainDecl: typeDecl.0.as(ExtensionDeclSyntax.self),
                  typeDecl: typeDecl.1
                )
              })
            )
          })
        )
      })

      self.init(
        _uncheckedDependencies: orderedGroupedDependencies,
        resolvedType: resolvedType
      )
    }
  }
}

// MARK: ExtensionDependency

/// An extension dependency stores cached information such as what declaration
/// group the given member was introduced. Normally, we don't store cached
/// information for types stored in the `TypeGraph` since we must
/// later update a lot of cached data when we bind/evict an extension.
/// However, extension dependencies are different because if the dependency
/// type changes, we necessarily have to evict and recompute the extensions.
/// Hence, extension dependencies should be created at extension binding and not
/// be modified (we simply evict the extension and destroy its state along
/// with any dependencies).
extension TypeGraph {
  @_spi(_QualifiedLookupTests)
  public struct ExtensionDependency: Sendable {
    /// The base type on whose members we depend.
    let baseTypeName: TypeGraph.GlobalTypeName

    /// The type members of base type on which we depend, in lookup order.
    ///
    /// This is an ordered list rather than a `[Identifier: ...]` dictionary,
    /// because want a deterministic order when evicting extensions to
    /// uphold `SymbolTable`'s determinism requirement.
    fileprivate(set) var members: [(name: Identifier, decls: [Member])]

    @_spi(_QualifiedLookupTests) public init(
      dependencyTypeName: TypeGraph.GlobalTypeName,
      members: [(name: Identifier, decls: [Member])]
    ) {
      self.baseTypeName = dependencyTypeName
      self.members = members
    }
  }
}

// MARK: ExtensionDependency.Member

extension TypeGraph.ExtensionDependency {
  /// One declaration contributing to a dependency's member, together with
  /// the declaration group that introduced it.
  ///
  /// A member can have more than one contributing declaration when it's
  /// ambiguous. For instance, a type alias declared both in a type's own
  /// body and again in one of its extensions.
  @_spi(_QualifiedLookupTests) public struct Member: Hashable, Sendable {
    /// The extension that introduced `typeDecl`, or `nil` if `typeDecl`
    /// was declared in the nominal-type declaration.
    ///
    /// Note: We care about extensions and not nominal-type declarations,
    /// because cycles can only form between extensions.
    @_spi(_QualifiedLookupTests) public let introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
    @_spi(_QualifiedLookupTests) public let typeDecl: Attached<TypeDeclSyntax>
  }
}

// MARK: Lookup

@_spi(_QualifiedLookupTests)
public struct DependencyTracker {
  /// Invariant: There's at most one dependency for the same type/member-name pair.
  private(set) var dependencies: [QualifiedLookupDependency]

  @_spi(_QualifiedLookupTests)
  public init(
    _uncheckedDependencies dependencies: [QualifiedLookupDependency] = []
  ) {
    self.dependencies = dependencies
  }

  /// Add the given dependency, maintainign unique dependencies
  fileprivate mutating func _addLookupDependency(
    baseTypeName: TypeGraph.GlobalTypeName,
    memberTypeName: Identifier,
    performLookup: (TypeGraph.GlobalTypeName, Identifier) -> QualifiedLookupDependency
  ) -> QualifiedLookupDependency {
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

extension TypeGraph.GlobalTypeRef {
  init(
    name: TypeGraph.GlobalTypeName,
    nominal: __shared TypeGraph.NominalType
  ) {
    self.init(name: name, mainDecl: nominal.mainDecl, _version: nominal.version)
  }
}

extension TypeGraph {
  enum QualifiedTypeLookupFailure: Error {
    /// References non-registered base type
    case invalidBase
    case unregisteredFileRoot(SourceFileSyntax)
  }
  func findMemberType(
    baseType: TypeRef,
    memberTypeName: Identifier,
    origin: (typeSyntax: Attached<TypeLikeSyntax>, module: ModuleName),
    dependencyTracker: inout DependencyTracker,
    symbolTable: borrowing SymbolTable
  ) -> Result<
    [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)],
    QualifiedTypeLookupFailure
  > {
    // Get global nominal reference
    let baseTypeReference: TypeGraph.GlobalTypeRef
    switch baseType {
    case .global(let globalReference):
      baseTypeReference = globalReference
    case .local(let nominalTypeDecl):
      guard let declFileInfo = symbolTable.getFileInfo(nominalTypeDecl.fileRoot) else {
        return .failure(QualifiedTypeLookupFailure.unregisteredFileRoot(nominalTypeDecl.fileRoot))
      }
      // TODO: Directly collect members, rather than building hash map & then getting specific member
      //
      // Local decls don't have extensions (=> no dependencies generated); just
      // look into the main declaration.
      let groupedTypeMembers = nominalTypeDecl._groupTypeMembers(configuredRegions: declFileInfo.configuredRegions)
      let typeMembers = groupedTypeMembers[memberTypeName, default: []]
      return .success(
        typeMembers.map({ (declGroupParent: Attached<DeclGroupSyntaxType>(nominalTypeDecl), typeDecl: $0) })
      )
    }

    // Diagnose invalid base
    guard
      let registeredType = namesToTypes[baseTypeReference.name],
      registeredType.version == baseTypeReference._version
    else {
      return .failure(QualifiedTypeLookupFailure.invalidBase)
    }
    // FIXME: Ensure reference's symbol-table version also matches

    // TODO: Consider pre-sorting extensions to make lookup faster
    func directLookup(
      baseTypeName: TypeGraph.GlobalTypeName,
      memberTypeName: Identifier
    ) -> QualifiedLookupDependency {
      // Organize declaration groups into buckets
      typealias DeclGroupAndMembers = (declGroup: Attached<DeclGroupSyntaxType>, typeMap: TypeTable)
      var fileDecls = [DeclGroupAndMembers]()
      var otherInternalDecls = [DeclGroupAndMembers]()
      // TODO: Check file's imported modules & check
      // TODO: Sort by module order (for shadowing) and handle case where we import
      // specific types, perhaps interleaved types between modules, e.g., import A from Module1,
      // import B from Module2, import C from Module1, import A from Module2 (how is `A` shadowed?)
      var externalDecls = [DeclGroupAndMembers]()

      func organizeDeclGroup(_ entry: DeclGroupAndMembers) {
        if entry.declGroup.fileRoot == origin.typeSyntax.fileRoot {
          fileDecls.append(entry)
        } else if symbolTable.getFileInfo(entry.declGroup.fileRoot)?.module == origin.module {
          otherInternalDecls.append(entry)
        } else {
          externalDecls.append(entry)
        }
      }

      // Add main decl and bound extensions
      organizeDeclGroup(
        (declGroup: Attached<DeclGroupSyntaxType>(registeredType.mainDecl), typeMap: registeredType.mainDeclMembers)
      )
      for (_, extensionDecls) in registeredType.boundExtensions {
        for (extensionDecl, typeTable) in extensionDecls {
          organizeDeclGroup((declGroup: Attached<DeclGroupSyntaxType>(extensionDecl), typeMap: typeTable))
        }
      }

      let sortedDeclGroups = fileDecls + otherInternalDecls + externalDecls

      // Add members from each decl group and register the dependencies
      var typeDecls = [(Attached<DeclGroupSyntaxType>, Attached<TypeDeclSyntax>)]()
      for (declGroup, declGroupMembers) in sortedDeclGroups {
        // Add the matching decls
        let introducedDecls =
          declGroupMembers.typeMembersToDecls[memberTypeName]?.map({
            (declGroup, $0)
          }) ?? []
        typeDecls.append(contentsOf: introducedDecls)
      }
      return QualifiedLookupDependency(extendedTypeName: baseTypeName, member: memberTypeName, typeDecls: typeDecls)
    }

    // Add to the dependency tracker or get existing value
    let result = dependencyTracker._addLookupDependency(
      baseTypeName: baseTypeReference.name,
      memberTypeName: memberTypeName,
      performLookup: directLookup(baseTypeName:memberTypeName:)
    )

    // Distill to type declarations (throw away declaration groups)
    return .success(result.typeDecls)
  }
}

extension TypeGraph {
  enum NominalRegistrationFailure: Error {
    /// We don't allow registering redeclarations. Redeclarations should be
    /// diagnosed as ambiguities.
    ///
    /// For instance:
    /// ```swift
    /// struct A {}
    /// typealias A = ()
    /// let _: A // <- 'A' is ambiguous
    ///
    /// extension A {
    ///   struct B {}
    ///   typealias B = ()
    /// }
    /// let _: A.B // 'A.B' is ambiguous
    /// ```
    /// It's possible that we discover ambiguities after binding extensions.
    /// So, to keep the graph consistent, extensions track their extensions:
    /// if member that an extension depends on becomes ambiguous, we evict
    /// the extension. Further, in both unqualified and qualified lookup, all
    /// possible declarations should be returned; if we can't disambiguate,
    /// we diagnose an ambiguity error before attempting to register a type
    /// in the graph.
    case cannotRegisterRedeclaration
  }

  // Top-scope (local or global)
  mutating func registerNominalType(
    topScopeMainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileInfo: FileInfo,
    isGlobal: Bool,
    symbolTable: borrowing SymbolTable
  ) -> Result<TypeRef, NominalRegistrationFailure> {
    // Local types don't have extensions, so we can just return a reference.
    guard isGlobal else {
      return .success(TypeRef.local(mainDecl))
    }

    let globalName = TypeGraph.GlobalTypeName(
      component: TypeGraph.GlobalTypeName.Component(
        name: declName,
        file: mainDecl.fileRoot,
        fileInfo: declFileInfo,
        symbolTable: symbolTable
      )
    )

    return _admitNominalType(
      globalDecl: mainDecl,
      declFileConfiguredRegions: declFileInfo.configuredRegions,
      globalTypeName: globalName
    )
  }

  enum NestedNominalRegistrationFailure: Error {
    case other(NominalRegistrationFailure)

    /// In order to register a nested type, its parent must be registered.
    case baseNotRegistered(parentTypeName: TypeGraph.GlobalTypeName)
    /// Decl group unexpectedly isn't registered to the given base type.
    case baseDeclGroupUnbound(Attached<DeclGroupSyntaxType>)
  }
  // Nested (local or global)
  mutating func registerNominalType(
    nestedMainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileInfo: FileInfo,
    baseDeclGroup: Attached<DeclGroupSyntaxType>,
    baseType: TypeRef,
    symbolTable: borrowing SymbolTable
  ) -> Result<TypeRef, NestedNominalRegistrationFailure> {
    // Check this is the right decl group
    assert(
      baseDeclGroup.fileRoot == mainDecl.fileRoot && baseDeclGroup.node.range.contains(mainDecl.node.range),
      "[SwiftLexicalLookup] Internal error: Unexpectedly tried to register nested type `\(mainDecl._memberlessDescription)` under non-base decl group `\(baseDeclGroup._memberlessDescription)`."
    )

    // Get the global reference, or return the local
    let globalParent: TypeGraph.GlobalTypeRef
    switch baseType {
    case .global(let globalReference):
      globalParent = globalReference
    case .local(let parentDecl):
      assert(
        DeclGroupSyntaxType(parentDecl.node) == baseDeclGroup.node,
        "[SwiftLexicalLookup] Internal error: Local type's declaration group parent doesn't match NominalTypeRef parent."
      )

      // We can't extend local types; just return a reference.
      return .success(TypeRef.local(mainDecl))
    }

    let globalName = globalParent.name.addingComponent(
      TypeGraph.GlobalTypeName.Component(
        name: declName,
        file: mainDecl.fileRoot,
        fileInfo: declFileInfo,
        symbolTable: symbolTable
      )
    )

    // The parent must be bound
    guard let baseType = namesToTypes[globalParent.name] else {
      return .failure(NestedNominalRegistrationFailure.baseNotRegistered(parentTypeName: globalParent.name))
    }

    // Check base decl group is actually bound to baseType
    if let parentExtension = baseDeclGroup.as(ExtensionDeclSyntax.self),
      let parentExtensionState = extensionsToState[parentExtension],
      case .success(let extendedTypeName) = parentExtensionState.resolvedType,
      extendedTypeName != globalParent.name
    {
      return .failure(
        NestedNominalRegistrationFailure.baseDeclGroupUnbound(Attached<DeclGroupSyntaxType>(parentExtension))
      )
    } else if let parentNominal = baseDeclGroup.as(NominalTypeDeclSyntax.self),
      baseType.mainDecl != parentNominal
    {
      // Note that we still register even if there are redeclarations. E.g.,
      // in the following, we still register '_(File.swift)::A._(File.swift)::B',
      // despite the parent '_(File.swift)::A' having redeclarations.
      // struct A {
      //     struct B {
      //         func f(_: B) {} // ✅
      //         func f(_: C) {} // ❌ error: No type 'C' in scope
      //     }
      // }
      // struct A {} // ❌ error: Invalid redeclaration of 'A'
      return .failure(
        NestedNominalRegistrationFailure.baseDeclGroupUnbound(Attached<DeclGroupSyntaxType>(parentNominal))
      )
    }

    return _admitNominalType(
      globalDecl: mainDecl,
      declFileConfiguredRegions: declFileInfo.configuredRegions,
      globalTypeName: globalName
    ).mapError(NestedNominalRegistrationFailure.other)
  }

  /// Admits the given (global) nominal-type into the graph or returns the
  /// existing reference.
  ///
  /// Important: Callers must validate the inputs
  fileprivate mutating func _admitNominalType(
    globalDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    declFileConfiguredRegions: ConfiguredRegions?,
    globalTypeName: TypeGraph.GlobalTypeName
  ) -> Result<TypeRef, NominalRegistrationFailure> {
    // If already registered, ensure we have no redeclaration
    let type: NominalType
    if let existingType = namesToTypes[globalTypeName] {
      // We don't allow redeclarations (see `.cannotRegisterRedeclaration`
      // docstring for why)
      guard existingType.mainDecl == mainDecl else {
        return .failure(NominalRegistrationFailure.cannotRegisterRedeclaration)
      }
      // Return the existing type
      type = existingType
    }
    // Otherwise, register
    else {
      // Create a new type
      let freshNominal = NominalType(
        mainDecl: mainDecl,
        mainDeclMembers: TypeTable(
          typeMembersToDecls: mainDecl._groupTypeMembers(configuredRegions: declFileConfiguredRegions)
        )
      )
      namesToTypes[globalTypeName] = freshNominal
      type = freshNominal
    }

    return .success(
      TypeRef.global(TypeGraph.GlobalTypeRef(name: globalTypeName, nominal: type))
    )
  }

  enum NominalTypeRefUpdateFailure: Error {
    /// This type is no longer in the symbol table
    case removed
  }
  func updateNominalTypeReference(oldReference: TypeRef) -> Result<TypeRef, NominalTypeRefUpdateFailure> {
    // Extract global reference; return local reference as is
    let globalReference: TypeGraph.GlobalTypeRef
    switch oldReference {
    case .global(let reference):
      globalReference = reference
    case .local:
      return .success(oldReference)
    }

    // Get the type state
    guard let typeState = namesToTypes[globalReference.name] else {
      return .failure(NominalTypeRefUpdateFailure.removed)
    }

    return .success(
      TypeRef.global(
        TypeGraph.GlobalTypeRef(name: globalReference.name, nominal: typeState)
      )
    )
  }
}

// MARK: - Extension Dependencies

@_spi(_QualifiedLookupTests)
public struct QualifiedLookupDependency: Sendable {
  let extendedTypeName: TypeGraph.GlobalTypeName
  let member: Identifier
  let typeDecls: [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)]

  @_spi(_QualifiedLookupTests)
  public init(
    extendedTypeName: TypeGraph.GlobalTypeName,
    member: Identifier,
    typeDecls: [(Attached<DeclGroupSyntaxType>, Attached<TypeDeclSyntax>)]
  ) {
    self.extendedTypeName = extendedTypeName
    self.member = member
    self.typeDecls = typeDecls
  }
}

extension TypeGraph {
  enum CycleDetectionFailure: Error {
    case unresolvedDependencyExtension(
      dependentExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      dependencyExtensionState: ExtensionState?
    )
  }

  struct DependencyPathElement: CustomDebugStringConvertible {
    let introducingMemberType: ExtensionDependency.Member?
    let boundType: TypeGraph.GlobalTypeRef
    let extensionDecl: Attached<ExtensionDeclSyntax>
    let state: ExtensionState

    var debugDescription: String {
      "\(introducingMemberType?.typeDecl._memberlessDescription ?? "nil") introduced \(extensionDecl._memberlessDescription) (bound to \(boundType.debugDescription))"
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
            case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType,
            let dependencyExtendedTypeRef = getGlobalNominalTypeReference(name: dependencyExtendedType)
          else {
            // TODO: Find actual error message (but still use fatal error since this breaks an invariant)
            fatalError("TODO: Actual error message")
          }

          let newPath: [DependencyPathElement] =
            path + [
              DependencyPathElement(
                introducingMemberType: typeMemberDecl,
                boundType: dependencyExtendedTypeRef,
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

  fileprivate mutating func _findFirstCycleWhenBinding(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionMembers: TypeTable,
    to boundTypeRef: TypeGraph.GlobalTypeRef,
    extensionDependencies: [QualifiedLookupDependency],
  ) -> Result<TypeResolver.ExtensionCycle, CycleDetectionFailure>? {
    let boundExtensionInfo = [
      DependencyPathElement(
        introducingMemberType: nil,
        boundType: boundTypeRef,
        extensionDecl: extensionDecl,
        state: ExtensionState(
          dependencies: extensionDependencies,
          resolvedType: .success(boundTypeRef.name)
        )
      )
    ]

    // TODO: Check that `extensionDependencies` have states and resolved to a type or throw an error

    log(
      "Checking cycles if introducing `\(extensionDecl._memberlessDescription)` with members '\(boundTypeRef.debugDescription)' > \(extensionMembers.typeMembersToDecls.map(\.key.name))"
    )

    // Check recursive dependencies
    let cycleResult: TypeResolver.ExtensionCycle? = _findFirstDependency(
      path: boundExtensionInfo,
      where: { (dependency, path) -> TypeResolver.ExtensionCycle? in
        // Check if dependency collides with introduces `boundTypeName` > `extensionMembers`.
        // Collisions require that the base type match and that members share a name.
        log("Visiting `\(dependency._declarationlessDescription)` [path \(path)]")
        guard
          boundTypeRef.name == dependency.baseTypeName,
          let firstConflictingMember = dependency.members.first(where: { member in
            extensionMembers.typeMembersToDecls[member.name] != nil
          })
        else {
          return nil
        }

        let mappedPath: [TypeResolver.ExtensionCycleElement] = path.dropFirst().map({ chainElement in
          TypeResolver.ExtensionCycleElement(
            // Only the first element has `nil` by `_findFirstDependency` invariant.
            introducingTypeDecl: chainElement.introducingMemberType!.typeDecl.node,
            extensionDecl: chainElement.extensionDecl.node,
            boundType: chainElement.boundType,
          )
        })

        return TypeResolver.ExtensionCycle(
          dependencyPath: mappedPath,
          dependencyMember: firstConflictingMember.name
        )
      }
    )

    return cycleResult.map(Result.success)
  }
}

extension TypeGraph {
  fileprivate func _firstRegisteredMemberName(
    declGroup: Attached<DeclGroupSyntaxType>,
    declGroupFileInfo: FileInfo,
    declGroupTypeName: TypeGraph.GlobalTypeName,
    members: TypeTable,
    symbolTable: SymbolTable
  ) -> TypeGraph.GlobalTypeName? {
    for (memberName, memberDecls) in members.typeMembersToDecls {
      // Construct the type the member would have
      let potentialMemberTypeName = declGroupTypeName.addingComponent(
        TypeGraph.GlobalTypeName.Component(
          name: memberName,
          file: declGroup.fileRoot,
          fileInfo: declGroupFileInfo,
          symbolTable: symbolTable
        )
      )

      // Get the registered type and name, if it exists
      guard let memberType = namesToTypes[potentialMemberTypeName] else { continue }
      let memberTypeName = potentialMemberTypeName

      // If we get a type, we need to check if any of the member declarations are registered
      // in the type.
      //
      // Note: The complexity of the following check is O(n*m) where `n` is the number of `_mainDecls`
      // and `m` the number of decls named `memberName` in the given extension. But we usually have a
      // single main declaration and single same-name declaration in an nominal-type/extension decl.
      let memberIsRegistered = memberDecls.contains(where: {
        $0.as(NominalTypeDeclSyntax.self) == memberType.mainDecl
      })

      guard memberIsRegistered else { continue }
      return memberTypeName
    }

    return nil
  }

  enum ExtensionRemovalFailure: Error {
    /// Extension has no registered state
    case unregistered
    // case notBound(failureOrUnregistered: TypeQualifier.Failure?)
    case resolvedToUnregistered(typeName: TypeGraph.GlobalTypeName)
    case resolvedButUnbound(typeName: TypeGraph.GlobalTypeName)
    case dependencyToUnregistered(dependencyTpeName: TypeGraph.GlobalTypeName)
    /// We have a dependency to a type that doesn't know we're dependent
    case notInDependentsList(dependencyTypeName: TypeGraph.GlobalTypeName)
    case remainingDependents(
      typeName: TypeGraph.GlobalTypeName,
      // TODO: Change to `Identifier`
      extensionMembers: [String],
      dependents: [TypeDependent]
    )
    case remainingRegistredMemberType(memberTypeName: TypeGraph.GlobalTypeName)
  }

  fileprivate mutating func _removeExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionFileInfo: FileInfo,
    symbolTable: SymbolTable
  ) -> Result<Void, ExtensionRemovalFailure> {
    return withLogging(
      request: "Removing `\(extensionDecl._memberlessDescription)`",
      describe: { _ in "" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true) }
        return self.__removeExtension(
          extensionDecl,
          extensionFileInfo: extensionFileInfo,
          symbolTable: symbolTable
        )
      }
    )
  }
  /// Removes extension maintaining all invariants.
  /// The extension must be bound, its type members must have no
  /// dependents.
  fileprivate mutating func __removeExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionFileInfo: FileInfo,
    symbolTable: SymbolTable
  ) -> Result<Void, ExtensionRemovalFailure> {
    // Get state
    guard let extensionState = extensionsToState[extensionDecl] else {
      return .failure(ExtensionRemovalFailure.unregistered)
    }

    // Ensure we don't have dependents/members if bound
    switch extensionState.resolvedType {
    case .success(let extendedTypeName):
      // Get the type
      guard let extendedType = namesToTypes[extendedTypeName] else {
        return .failure(ExtensionRemovalFailure.resolvedToUnregistered(typeName: extendedTypeName))
      }

      // Check for dependents
      //
      // Get the extension members and the type with the extension unbound
      guard
        let extensionMembers = extendedType.boundExtensions[extensionFileInfo.module, default: [:]][extensionDecl]
      else {
        return .failure(ExtensionRemovalFailure.resolvedButUnbound(typeName: extendedTypeName))
      }
      // Ensure no one depends on our members
      let hasDependents = extendedType.dependents.contains(where: {
        extensionMembers.typeMembersToDecls[$0.memberType] != nil
      })
      guard !hasDependents else {
        return .failure(
          ExtensionRemovalFailure.remainingDependents(
            typeName: extendedTypeName,
            extensionMembers: extensionMembers.typeMembersToDecls.map(\.key.name),
            dependents: extendedType.dependents
          )
        )
      }
      // Ensure all members are unregistered (only happens with nominal-type declarations)
      let memberTypeName: TypeGraph.GlobalTypeName? = _firstRegisteredMemberName(
        declGroup: Attached<DeclGroupSyntaxType>(extensionDecl),
        declGroupFileInfo: extensionFileInfo,
        declGroupTypeName: extendedTypeName,
        members: extensionMembers,
        symbolTable: symbolTable
      )
      if let memberTypeName {
        return .failure(ExtensionRemovalFailure.remainingRegistredMemberType(memberTypeName: memberTypeName))
      }
    case .failure:
      // Failed extensions don't introduce types => no dependents
      break
    }

    // Unregister as a dependent from all our dependencies
    for dependency in extensionState.dependencies {
      // Get dependency type
      guard let dependencyType = namesToTypes[dependency.baseTypeName] else {
        return .failure(
          ExtensionRemovalFailure.dependencyToUnregistered(dependencyTpeName: dependency.baseTypeName)
        )
      }

      // Remove ourselves as the dependency
      let originalDependentsCount = dependencyType.dependents.count
      var newDependents = dependencyType.dependents
      newDependents.removeAll(where: { $0.dependentExtension == extensionDecl })
      log("New dependents for '\(dependency.baseTypeName)': \(newDependents)")
      guard newDependents.count < originalDependentsCount else {
        return .failure(ExtensionRemovalFailure.notInDependentsList(dependencyTypeName: dependency.baseTypeName))
      }

      // Update dependency type
      namesToTypes[dependency.baseTypeName] = dependencyType._updatingDependents(newDependents)
    }

    // Unbind from type (if bound)
    //
    // We don't use `extendedType` because it might have changed after removing
    // ourselves as a dependent from our dependencies. For instance, in
    // `struct A { typealias B = A }; extension A.B {}`, `extension A.B`
    // is bound to '_(MyFile.swift)::A' and it also depends on
    // '_(MyFile.swift)::A' > ['B', 'A'].
    switch extensionState.resolvedType {
    case .success(let extendedTypeName):
      guard
        let newExtendedType = namesToTypes[extendedTypeName],
        let (unboundExtendedType, _) = newExtendedType._unbindingExtension(
          extensionDecl,
          module: extensionFileInfo.module
        )
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type somehow went missing and/or extension was unbound."
        )
      }
      namesToTypes[extendedTypeName] = unboundExtendedType
      log(
        "Updating '\(extendedTypeName.debugDescription)' with new extensions: [\(unboundExtendedType.boundExtensions[extensionFileInfo.module, default: [:]].map(\.key._memberlessDescription).joined(separator: ", "))]"
      )
    case .failure:
      break
    }
    // Remove extension state
    extensionsToState[extensionDecl] = nil

    return .success(())
  }

  enum NominalRemovalFailure: Error {
    case unregisteredName(TypeGraph.GlobalTypeName)
    case nominalNotInRegisteredType(
      typeName: TypeGraph.GlobalTypeName,
      actualMainDecl: Attached<NominalTypeDeclSyntax>
    )
    /// The type still has extensions bound to it.
    case remainingBoundExtensions
    case remainingDependents(dependents: [TypeDependent])
    case remainingRegistredMemberType(memberTypeName: GlobalTypeName)
  }

  /// Removes registered nominal-type declaration maintaining all invariants.
  /// The type must be registered and contain this nominal-type declaration
  /// as a main declaration. If this is the main declaration, must have all
  /// extensions unbound and no registered subtypes.
  fileprivate mutating func __removeNominalTypeDeclaration(
    _ nominalDecl: Attached<NominalTypeDeclSyntax>,
    nominalDeclFileInfo: FileInfo,
    typeName: GlobalTypeName,
    symbolTable: SymbolTable
  ) -> Result<Void, NominalRemovalFailure> {
    // Get the state
    guard let type: NominalType = namesToTypes[typeName] else {
      return .failure(NominalRemovalFailure.unregisteredName(typeName))
    }

    // Remove the declaration, or throw
    switch type._removingNominalDecl(nominalDecl) {
    case .success(()):
      break
    case .failure(NominalType.NominalUnbindingFailure.nominalTypeNotAMainDecl):
      return .failure(
        NominalRemovalFailure.nominalNotInRegisteredType(
          typeName: typeName,
          actualMainDecl: type.mainDecl
        )
      )
    case .failure(NominalType.NominalUnbindingFailure.remainingDependents):
      return .failure(NominalRemovalFailure.remainingDependents(dependents: type.dependents))
    case .failure(NominalType.NominalUnbindingFailure.remainingBoundExtensions):
      return .failure(NominalRemovalFailure.remainingBoundExtensions)
    }

    // Ensure we have no member types (if originally bound)
    //
    // Since we checked there are no bound extensions, the only
    // place where we could get a member type is the main decl.
    //
    // Note: If there were redeclarations, then we shouldn't have been able to
    // register any member types (checked by ``registerNominalTypeReference``).
    if type.mainDecl == nominalDecl {
      // Since the new type is `nil`, the decl used to be `type.mainDecl`
      let memberTypeName: GlobalTypeName? = _firstRegisteredMemberName(
        declGroup: Attached<DeclGroupSyntaxType>(nominalDecl),
        declGroupFileInfo: nominalDeclFileInfo,
        declGroupTypeName: typeName,
        members: type.mainDeclMembers,
        symbolTable: symbolTable
      )
      if let memberTypeName {
        return .failure(NominalRemovalFailure.remainingRegistredMemberType(memberTypeName: memberTypeName))
      }
    }

    namesToTypes[typeName] = nil
    log("Removed nominal '\(typeName.debugDescription)'.")

    return .success(())
  }

  mutating func _unbindMemberType(
    baseTypeName: GlobalTypeName,
    baseTypeDecl: Attached<DeclGroupSyntaxType>,
    baseTypeFileInfo: FileInfo,
    baseType: NominalType,
    memberName: Identifier,
    memberDecls: [Attached<TypeDeclSyntax>],
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: SymbolTable
  ) {
    return withLogging(
      request: "Unbinding member type '\(baseTypeName.debugDescription)' > '\(memberName.name)'",
      describe: { "" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__unbindMemberType(
          baseTypeName: baseTypeName,
          baseTypeDecl: baseTypeDecl,
          baseTypeFileInfo: baseTypeFileInfo,
          baseType: baseType,
          memberName: memberName,
          memberDecls: memberDecls,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  mutating func __unbindMemberType(
    baseTypeName: GlobalTypeName,
    baseTypeDecl: Attached<DeclGroupSyntaxType>,
    baseTypeFileInfo: FileInfo,
    baseType: NominalType,
    memberName: Identifier,
    memberDecls: [Attached<TypeDeclSyntax>],
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: SymbolTable
  ) {
    // Evict dependent extensions
    _evictDependents(
      modifiedTypeName: baseTypeName,
      modifiedMembers: TypeTable(typeMembersToDecls: [memberName: memberDecls]),
      modifiedExtensionModule: baseTypeFileInfo.module,
      evictedExtensions: &evictedExtensions,
      symbolTable: symbolTable
    )

    // If there's no registered nominal type our name, we're done
    let memberNominalTypeName = baseTypeName.addingComponent(
      GlobalTypeName.Component(
        name: memberName,
        file: baseTypeDecl.fileRoot,
        fileInfo: baseTypeFileInfo,
        symbolTable: symbolTable
      )
    )
    guard let memberNominal: NominalType = namesToTypes[memberNominalTypeName] else {
      return
    }

    // Remove nested members and extensions
    //
    // We check that there are no redeclarations (cause then no extensions
    // could bind to the nominal type anyway), and that the member decls
    // actually contain the main nominal-type decls (they could just be
    // type aliases, e.g.,
    // ```swift
    // struct A {}
    // extension A {
    //   struct B {} // _(File.swift)::A._(File.swift)::B
    // }
    // extension A {        // <- Unbind this extension
    //  typealias B = (A)
    //  typealias B = (A, A)
    // }
    // ```
    // In this example, the main decl lives in the first extension. So, when
    // we're unbinding the second extension, we see members
    // '_(File.swift)::A' > 'B', and we find a type '_(File.swift)::A._(File.swift)::B',
    // but we don't have any nominal-type declaration to unbind.
    // TODO: Consider updating now that `NominalType/mainDecl` implies no redecls
    let memberNominalDecls: [Attached<NominalTypeDeclSyntax>] = memberDecls.compactMap({
      $0.as(NominalTypeDeclSyntax.self)
    })
    if memberNominalDecls.contains(memberNominal.mainDecl) {
      // Assert we don't have any nominal-type *re*declarations (checked in `registerNominalTypeReference`)
      precondition(
        memberNominalDecls == [memberNominal.mainDecl],
        "[SwiftLexicalLookup] Internal error: Expected nominal type '\(memberNominalTypeName.debugDescription)' to have the main decl `\(memberNominal.mainDecl._memberlessDescription)`, but instead got: \(memberNominalDecls.map(\._memberlessDescription).joined(separator: ", "))"
      )

      // Remove all nested member types
      log("Found main decl `\(memberNominal.mainDecl._memberlessDescription)`; removing member types.")
      for (nestedMemberName, nestedMemberDecls) in memberNominal.mainDeclMembers.typeMembersToDecls {
        log(
          "Visiting member type `\(memberNominal.mainDecl._memberlessDescription)` > '\(nestedMemberName.name)'"
        )
        _unbindMemberType(
          baseTypeName: memberNominalTypeName,
          baseTypeDecl: Attached<DeclGroupSyntaxType>(memberNominal.mainDecl),
          baseTypeFileInfo: baseTypeFileInfo,
          baseType: memberNominal,
          memberName: nestedMemberName,
          memberDecls: nestedMemberDecls,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }

      // Remove bound extensions
      // TODO: Why didn't this fail a test before?? Write a proper test
      // Note: `memberNominal` is stale here but since extension eviction doesn't
      // bind dependencies, this will always be a superset of the currently bound
      // extensions. Further, if an extension was already evicted, `_unbindExtension`
      // will just skip it.
      for moduleExtensions in memberNominal.boundExtensions.values {
        for (extensionDecl, _) in moduleExtensions {
          let evictedExtension = _unbindExtension(
            extensionDecl,
            evictedExtensions: &evictedExtensions,
            symbolTable: symbolTable
          )
          guard let evictedExtension else { continue }
          evictedExtensions.append(evictedExtension)
        }
      }
    }

    // === Unregister Nominals ===
    for memberNominalDecl in memberNominalDecls {
      let removalResult = __removeNominalTypeDeclaration(
        memberNominalDecl,
        // Same file info since this is a nested type
        nominalDeclFileInfo: baseTypeFileInfo,
        typeName: memberNominalTypeName,
        symbolTable: symbolTable
      )
      switch removalResult {
      case .success: break
      case .failure(let failure):
        switch failure {
        // FIXME: Decide if this is actually an error or allowed?
        case .nominalNotInRegisteredType: break
        case .unregisteredName:
          // This function messed up: We checked the name/type are registered above.
          fatalError("[SwiftLexicalLookup] Internal error: Unexpected failure: \(failure)")
        case .remainingDependents, .remainingBoundExtensions, .remainingRegistredMemberType:
          // Some other function messed up: not all dependents were evicted,
          // not all extensions unbound, or not all nested members removed.
          fatalError("[SwiftLexicalLookup] Internal error: Unexpected failure: \(failure)")
        }
      }
    }
  }

  fileprivate mutating func _introspect(
    symbolTable: SymbolTable,
    onlyLogIfCorrupted: Bool = false,
    file: StaticString = #file,
    line: UInt = #line,
    function: StaticString = #function
  ) {
    let (description, hasErrors) = _describe(symbolTable: symbolTable)
    if hasErrors || !onlyLogIfCorrupted {
      log(!description.isEmpty ? description : "<empty graph>")
    }
    guard !hasErrors else {
      sleep(1)
      fatalError(
        "[SwiftLexicalLookup] Internal error: Detected dependency-graph corruption after call to \(function).",
        file: file,
        line: line
      )
    }
  }

  mutating func _unbindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) -> Attached<ExtensionDeclSyntax>? {
    return withLogging(
      request: "Unbinding `\(extensionDecl._memberlessDescription)`",
      describe: \.debugDescription,
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__unbindExtension(
          extensionDecl,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  mutating func __unbindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) -> Attached<ExtensionDeclSyntax>? {
    guard let extensionState = extensionsToState[extensionDecl] else {
      assert(
        evictedExtensions.contains(extensionDecl),
        "Asked to unbind unregistered, non-evicted extension `\(extensionDecl._memberlessDescription)`."
      )
      log("Skipping already evicted extension `\(extensionDecl._memberlessDescription)`")
      return nil
    }
    guard let extensionFileInfo = symbolTable.getFileInfo(extensionDecl.fileRoot) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly found admitted extension `\(extensionDecl._memberlessDescription)` whose source file is unregistered in the symbol table."
      )
    }
    // If bound, remove members
    if case .success(let extendedTypeName) = extensionState.resolvedType {
      // Get the extended-type name
      guard let extendedType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` resolved to unregistered type '\(extendedTypeName)'"
        )
      }
      // Find the members
      guard let extensionMembers = extendedType.boundExtensions[extensionFileInfo.module, default: [:]][extensionDecl]
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` resolved to but isn't bound to type '\(extendedTypeName)'"
        )
      }

      for (memberName, memberDecls) in extensionMembers.typeMembersToDecls {
        _unbindMemberType(
          baseTypeName: extendedTypeName,
          baseTypeDecl: Attached<DeclGroupSyntaxType>(extensionDecl),
          baseTypeFileInfo: extensionFileInfo,
          baseType: extendedType,
          memberName: memberName,
          memberDecls: memberDecls,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }
    }

    // Now that the members are gone, remove
    let removalResult = _removeExtension(
      extensionDecl,
      extensionFileInfo: extensionFileInfo,
      symbolTable: symbolTable
    )
    switch removalResult {
    case .success: break
    case .failure(let failure):
      switch failure {
      case .unregistered, .resolvedButUnbound, .remainingDependents, .remainingRegistredMemberType:
        // This function messed up: we checked the extension is bound and resolved;
        // we should have removed all remaining dependents and registered types
        fatalError("[SwiftLexicalLookup] Internal error: Unexpected failure: \(failure)")
      case .notInDependentsList, .dependencyToUnregistered, .resolvedToUnregistered:
        // The graph is broken
        fatalError("[SwiftLexicalLookup] Internal error: Broken invariant: \(failure)")
      }
    }

    return extensionDecl
  }

  fileprivate mutating func _evictDependents(
    modifiedTypeName: GlobalTypeName,
    modifiedMembers: TypeTable,
    modifiedExtensionModule: ModuleName,
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) {  //-> [TypeDependent] {
    return withLogging(
      request:
        "Evicting dependents of '\(modifiedTypeName.debugDescription)' > \(modifiedMembers.typeMembersToDecls.map(\.key.name))",
      describe: { "\($0)" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__evictDependents(
          modifiedTypeName: modifiedTypeName,
          modifiedMembers: modifiedMembers,
          modifiedExtensionModule: modifiedExtensionModule,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  fileprivate mutating func __evictDependents(
    modifiedTypeName: GlobalTypeName,
    modifiedMembers: TypeTable,
    modifiedExtensionModule: ModuleName,
    // directDependents: [TypeDependent],
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) {  //-> [TypeDependent] {
    // TODO: Clean up if we go for immutable `get`
    func popLastConflictingDependent() -> TypeDependent? {
      // The base type must exist
      guard let baseType = namesToTypes[modifiedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly asked to evict unregistered type '\(modifiedTypeName.debugDescription)'."
        )
      }

      // Get the the next conflicting dependent
      guard
        let nextIndex = baseType.dependents.lastIndex(where: { dependent in
          modifiedMembers.typeMembersToDecls[dependent.memberType] != nil
        })
      else {
        return nil
      }
      let newDependents = baseType.dependents
      // let nextDependent = newDependents.remove(at: nextIndex)
      let nextDependent = newDependents[nextIndex]

      namesToTypes[modifiedTypeName] = baseType._updatingDependents(newDependents)

      return nextDependent
    }

    // var newDependents = [TypeDependent]()

    // TODO: We should track unbound extensions so different members don't evict different extensions
    // TODO: Get rid of force unwrap
    while let dependent = popLastConflictingDependent() {
      // // Only unbind conflicting (otherwise add to new dependents)
      // guard modifiedMembers.typeMembersToDecls[dependent.memberType] != nil else {
      //   newDependents.append(dependent)
      //   continue
      // }

      log("Found conflict \(dependent.debugDescription)")
      let evictedExtension = _unbindExtension(
        dependent.dependentExtension,
        evictedExtensions: &evictedExtensions,
        symbolTable: symbolTable
      )
      // Skip if we've already unbound
      // This can happen if an extension has multiple dependencies.
      // E.g. We introduce _(MyFile.swift)::A > ['B', 'C'] and an extension
      // is dependent on both type memmebrs. When evicting
      // _(MyFile.swift)::A > 'B', we'll unbind that extension but there's
      // no use updating _(MyFile.swift)::A's dependents
      guard let evictedExtension else { continue }

      // Update dependents
      namesToTypes[modifiedTypeName]!.dependents.removeAll(where: { thisDependent in
        thisDependent.memberType == dependent.memberType
          && thisDependent.dependentExtension == dependent.dependentExtension
      })

      // Record eviction
      evictedExtensions.append(evictedExtension)
    }

    // return newDependents
  }
}

// MARK: Extension Binding

extension TypeGraph {
  func getGlobalNominalTypeReference(name: GlobalTypeName) -> TypeGraph.GlobalTypeRef? {
    namesToTypes[name].map({
      TypeGraph.GlobalTypeRef(name: name, nominal: $0)
    })
  }

  /// Gets the final nominal-type reference with the given qualified name
  /// using the current graph.
  ///
  /// Useful for getting the final version of a nominal type after binding extensions.
  func getNominalTypeReference(name: GlobalTypeName) -> TypeRef? {
    getGlobalNominalTypeReference(name: name).map(TypeRef.global(_:))
  }
}

extension TypeGraph {
  enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }

  @_spi(_QualifiedLookupTests) public typealias BindingResult = (
    resolvedTypeName: Result<
      (globalReference: TypeGraph.GlobalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    evictedExtensions: [Attached<ExtensionDeclSyntax>]
  )

  // TODO: Consider if any early error returns break invariants (lead to an
  // invalid graph state)
  mutating func admitExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionDeclModule: ModuleName,
    extensionFileConfiguredRegions: ConfiguredRegions?,
    to rawResult: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencyTracker: DependencyTracker,
    symbolTable: borrowing SymbolTable
  ) -> Result<BindingResult, ExtensionAdmissionFailure> {
    // Ensure extension isn't already bound
    if let existingExtensionState = extensionsToState[extensionDecl] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Prepare to store extension state
    let extensionMembers = TypeTable(
      typeMembersToDecls: extensionDecl._groupTypeMembers(configuredRegions: extensionFileConfiguredRegions)
    )

    // === Diagnose Dependency Cycles ===

    // We create a new type-resolution result that converts successful type
    // resolutions into failures if they cause a cycle.
    let result:
      Result<
        (globalReference: TypeGraph.GlobalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
        TypeResolver.Failure
      >
    switch rawResult {
    case .success(let (extendedTypeName, mainDecl)):
      // TODO: Try to merge with cycleResult failures
      guard let extendedTypeRef: TypeGraph.GlobalTypeRef = getGlobalNominalTypeReference(name: extendedTypeName)
      else {
        return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: nil))
      }

      let cycleResult =
        _findFirstCycleWhenBinding(
          extensionDecl: extensionDecl,
          extensionMembers: extensionMembers,
          to: extendedTypeRef,
          extensionDependencies: dependencyTracker.dependencies
        ) as Result<TypeResolver.ExtensionCycle, CycleDetectionFailure>?

      // Map result
      switch cycleResult {
      case nil:
        // No cycle, keep success
        result = .success((extendedTypeRef, mainDecl))
      case .success(let cycle):
        // Found cycle, turn success into failure
        result = .failure(TypeResolver.Failure.cyclicalExtensionDependency(cycle))
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
      // Failed extensions remain failures (they are unbound => no member
      // types that can cause cycles).
      result = .failure(failure)
    }

    // === Evict Dependents & Bind ===
    let evictedExtensions: [Attached<ExtensionDeclSyntax>]
    // If there's no cycle, we may type members so we need to evict
    switch result {
    case .success(let (extendedTypeRef, _)):
      let extendedTypeName: GlobalTypeName = extendedTypeRef.name
      // Get the bound type
      guard let extendedType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) bound to type '\(extendedTypeName)', which isn't in the graph."
        )
      }

      var evictedExtensionsTmp: [Attached<ExtensionDeclSyntax>] = []
      //let newTypeDependents =
      _introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
      _evictDependents(
        modifiedTypeName: extendedTypeName,
        modifiedMembers: extensionMembers,
        modifiedExtensionModule: extensionDeclModule,
        evictedExtensions: &evictedExtensionsTmp,
        symbolTable: symbolTable
      )
      guard let evictedDependentsType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type '\(extendedTypeName.debugDescription)' unexpectedly removed while binding `\(extensionDecl._memberlessDescription)`."
        )
      }
      // Assert dependent extensions are valid
      for dependent in evictedDependentsType.dependents {
        // An extension must be `extensionDecl` (about to be regsitered) or
        // currently registered.
        assert(
          dependent.dependentExtension == extensionDecl || extensionsToState[dependent.dependentExtension] != nil,
          "[SwiftLexicalLookup] Internal error: Tried updating dependents of '\(extendedTypeName)' but found unregistered extension `\(dependent.dependentExtension._memberlessDescription)`."
        )
      }
      evictedExtensions = evictedExtensionsTmp

      // Bind to type
      guard
        let newExtendedType = evictedDependentsType._bindingExtension(
          extensionDecl,
          extensionMembers: extensionMembers,
          module: extensionDeclModule
        )
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) has no existing state but is already bound to '\(extendedType)'."
        )
      }
      namesToTypes[extendedTypeName] = newExtendedType
    case .failure:
      // Extensions that aren't bound to a type, don't introduce new type
      // members so they can't have any dependent.
      evictedExtensions = []
    }

    // === Register as Dependent ===

    // Now that we're admissable, tell predecessors we're dependent
    log("Registering as dependent for \(dependencyTracker.dependencies.map(\._succinctDescription))")
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

    // === Save Extension ===

    // Save extension (newly bound extension doesn't add type dependents)
    extensionsToState[extensionDecl] = ExtensionState(
      dependencies: dependencyTracker.dependencies,
      // Only keep the qualified name (we store the main decl in `namesToTypes`)
      resolvedType: result.map(\.globalReference.name)
    )

    return .success((result, evictedExtensions))
  }
}

// MARK: Debug

@_spi(_QualifiedLookupTests)
extension QualifiedLookupDependency: CustomDebugStringConvertible {
  @_spi(_QualifiedLookupTests) public var _succinctDescription: String {
    let declGroupSources = typeDecls.map({ $0.0._memberlessDescription })
    return """
      '\(extendedTypeName.debugDescription)' > '\(member.name)' [from \(declGroupSources)]
      """
  }

  public var debugDescription: String {
    let typeDeclDescriptions = typeDecls.map({ (introducingExtensionOrMainDecl, typeDecl) in
      "`\(introducingExtensionOrMainDecl._memberlessDescription)`: `\(typeDecl._memberlessDescription)`"
    }).joined(separator: ", ")

    return
      "QualifiedLookupDependency(extendedTypeName: \(extendedTypeName.debugDescription), member: '\(member.name)', typeDecls: [\(typeDeclDescriptions)])"
  }
}

@_spi(_QualifiedLookupTests)
extension TypeGraph.ExtensionDependency: CustomDebugStringConvertible {
  private func _describe(includeMemberDecls: Bool) -> String {
    let membersDescriptions = members.map({ member in
      let declDescriptions = member.decls.map({
        "`\($0.introducingExtensionOrMainDecl?._memberlessDescription ?? "nil")`"
      })
      let declDescription = " [in \(declDescriptions.isEmpty ? "<none>" : declDescriptions.joined(separator: ", "))]"
      return "'\(member.name.name)'\(includeMemberDecls ? declDescription : "")"
    }).joined(separator: ", ")
    return
      "ExtensionDependency(dependencyTypeName: '\(baseTypeName.debugDescription)', members: [\(membersDescriptions)])"
  }

  /// Debug description but removes the `TypeDeclSyntax` from each `Member` for easier testing.
  fileprivate var _declarationlessDescription: String {
    _describe(includeMemberDecls: false)
  }

  public var debugDescription: String {
    _describe(includeMemberDecls: true)
  }
}

@_spi(_QualifiedLookupTests)
extension TypeGraph.ExtensionState: CustomDebugStringConvertible {
  public var debugDescription: String {
    let dependenciesDescriptions = dependencies.map(\._declarationlessDescription).joined(separator: ",\n    ")
    // We don't use `String/replacing(_:with:)` because it's unavailable during
    // the compiler's bootstrapping step.
    let indentedTypeDescription = String(resolvedType._debugDescription.flatMap({ $0 == "\n" ? "\n  " : String($0) }))
    return """
      GenericExtensionState(
        dependencies: [
          \(dependenciesDescriptions)
        ],
        resolvedType: \(indentedTypeDescription))
      )
      """
  }
}
extension TypeGraph.ExtensionState {
  @_spi(_QualifiedLookupTests)
  public func _visitTypes(
    visitResolved: (TypeGraph.TypeRef) -> Void,
    visitName: (TypeGraph.GlobalTypeName) -> Void
  ) {
    for dependency in dependencies {
      visitName(dependency.baseTypeName)
    }
    switch resolvedType {
    case .success(let name):
      visitName(name)
    case .failure(let failure):
      failure._visitNominals(visitResolved)
    }
  }
}

// TypeGraph description

private struct _DependencyGraphDiagnostic: DiagnosticMessage {
  let message: String
  let severity: DiagnosticSeverity

  var diagnosticID: MessageID { MessageID(domain: "SwiftLexicalLookup", id: "TypeGraphDiagnostic") }
}

extension TypeGraph {
  fileprivate func _describeWithDiagnostics() -> (diagnostics: [Diagnostic], hasErrors: Bool) {
    var diagnostics = [Diagnostic]()
    /// Attach a note to the given node.
    func _attachNote<S: SyntaxProtocol>(to syntax: Attached<S>, message: String) {
      diagnostics.append(
        Diagnostic(node: syntax.node, message: _DependencyGraphDiagnostic(message: message, severity: .note))
      )
    }
    /// Attach an error to the given node.
    var hasErrors = false
    func _attachError<S: SyntaxProtocol>(to syntax: Attached<S>, message: String) {
      diagnostics.append(
        Diagnostic(node: syntax.node, message: _DependencyGraphDiagnostic(message: message, severity: .error))
      )
      hasErrors = true
    }
    /// Annotate each member type declaration in the `typeTable`
    /// of the type named `baseTypeName`.
    ///
    /// E.g. The type alias in 'struct A { typealias B = Int }' gets
    /// annotated `Type member '_(MyFile.swift)::A' > 'B'`.
    func _markMemberTypes(baseTypeName: String, baseTypeMembers: TypeTable) {
      for (memberName, memberDecls) in baseTypeMembers.typeMembersToDecls {
        for memberDecl in memberDecls {
          _attachNote(to: memberDecl, message: "Type member '\(baseTypeName)' > '\(memberName.name)'")
        }
      }
    }

    // Add all main decls and their extensions
    //
    // Keep track of visited types to diagnose types that are registered under different names.
    var visitedTypes = [NominalTypeDeclSyntax: GlobalTypeName]()
    // Keep track of what types/maps we're expecting each bound extension to have.
    var extensionsToType = [
      Attached<ExtensionDeclSyntax>: (boundTypeName: GlobalTypeName, typeTable: TypeTable)
    ]()
    for (typeName, type) in namesToTypes {
      let typeNameDescription = typeName.debugDescription

      // Check each main decl mapped to exactly one visited type
      // User-friendly description
      let declLabel = "Main decl"

      // Ensure this type decl is mapped to only one name
      guard visitedTypes.updateValue(typeName, forKey: type.mainDecl.node) == nil else {
        // This nominal-type declaration was already registered under a different name
        _attachError(
          to: type.mainDecl,
          message: "\(declLabel) also registered under '\(typeNameDescription)'"
        )
        continue
      }

      // Show the registered name
      _attachNote(
        to: type.mainDecl,
        message: "\(declLabel) registered '\(typeNameDescription)' (v\(type.version))"
      )

      // Mark each member in the type table
      _markMemberTypes(baseTypeName: typeNameDescription, baseTypeMembers: type.mainDeclMembers)

      // Add dependent extensions (to main declaration)
      for dependent in type.dependents {
        // Ensure there's a respective dependency
        //
        // First, get extension state
        guard let dependentExtensionState = extensionsToState[dependent.dependentExtension] else {
          _attachError(
            to: type.mainDecl,
            message:
              "Member type '\(typeNameDescription)' > '\(dependent.memberType.name)' depended on by unregistered extension `\(dependent.dependentExtension.node._memberlessDescription)`."
          )
          continue
        }
        // The extension state must have a dependency to this type with the right type member.
        guard
          dependentExtensionState.dependencies.contains(where: { dependency in
            dependency.baseTypeName == typeName
              && dependency.members.contains(where: { member in member.name == dependent.memberType })
          })
        else {
          _attachError(
            to: type.mainDecl,
            message:
              "Member type '\(typeNameDescription)' > '\(dependent.memberType.name)' supposedly depended on by `\(dependent.dependentExtension.node._memberlessDescription)`, but isn't in extension's dependencies: \(dependentExtensionState.dependencies.map(\.debugDescription))"
          )
          continue
        }

        _attachNote(
          to: type.mainDecl,
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
        _markMemberTypes(baseTypeName: boundTypeDescription, baseTypeMembers: typeTable)

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
      let flattenedDependencies:
        [(
          baseTypeName: GlobalTypeName, memberName: Identifier,
          introducingExtensionOrMainDecl: Attached<ExtensionDeclSyntax>?
        )] =
          extensionState
          .dependencies.flatMap({
            dependency in
            dependency.members.flatMap({
              member -> [(
                baseTypeName: GlobalTypeName, memberName: Identifier,
                introducingExtensionOrMainDecl: Attached<ExtensionDeclSyntax>?
              )] in
              // Empty decls are implicitly in `nil` (main decl)
              guard !member.decls.isEmpty else {
                return [(dependency.baseTypeName, member.name, nil)]
              }
              return member.decls.map({ typeDecl in
                return (dependency.baseTypeName, member.name, typeDecl.introducingExtensionOrMainDecl)
              })
            })
          })
      for (dependencyTypeName, memberName, introducingExtensionOrMainDecl) in flattenedDependencies {
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
            TypeDependent(memberType: memberName, dependentExtension: extensionDecl)
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

    return (diagnostics, hasErrors)
  }
}

extension TypeGraph {
  /// Gets the name and main decl of the type to which the extension is bound,
  /// or the binding the failure; returns `nil` for non-admitted extensions.
  func getExtensionResolvedType(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<
    (globalReference: TypeGraph.GlobalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
    TypeResolver.Failure
  >? {
    // Get the extension's state (or `nil` if unadmitted)
    guard let extensionState = extensionsToState[extensionDecl] else { return nil }

    // Extract the bound type (or return the failure)
    let boundTypeName: GlobalTypeName
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

    return Result.success(
      (
        globalReference: TypeGraph.GlobalTypeRef(name: boundTypeName, nominal: boundType),
        mainDecl: boundType.mainDecl
      )
    )
  }
}

extension TypeGraph {
  @_spi(_QualifiedLookupTests) public func _describe(
    symbolTable: SymbolTable
  ) -> (description: String, hasErrors: Bool) {
    var description = ""
    var group = GroupedDiagnostics()

    // Add all registered files
    var addedNames = Set<String>()
    for (moduleIdentifier, moduleFiles) in symbolTable.moduleToSources {
      for (fileName, fileSyntax) in moduleFiles {
        let fileIdentifier = "\(moduleIdentifier.name)/\(fileName)"
        // Don't readmit duplicate file names
        // TODO: Should handle modules
        guard addedNames.insert(fileIdentifier).inserted else {
          description += "Duplicate file identifier \(fileIdentifier)\n"
          continue
        }

        group.addSourceFile(tree: fileSyntax, displayName: fileIdentifier)
      }
    }

    // Add dependency-graph diagnostics
    let (diagnostics, hasErrors) = _describeWithDiagnostics()
    for diagnostic in diagnostics {
      group.addDiagnostic(diagnostic)
    }

    // Print to result
    description += DiagnosticsFormatter(colorize: true).annotateSources(in: group)

    return (description, hasErrors)
  }
}

// MARK: Logging

extension TypeGraph {
  var _verbose: Bool { false }
  /// The number of `withLogging` calls we can nest. Useful for debugging infinite loops
  /// that otherwise fill up standard output and become illegible.
  var _logNestingLimit: Int? { 50 }

  mutating func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // Keep log text separately
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    // logText += newLine + "\n"
    // Print new line
    print(newLine)
    // TODO: Remove
    fflush(stdout)
  }

  mutating func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: inout TypeGraph) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit {
      precondition(
        logPrefix.count < nestingLimit,
        "Exceeded log nesting limit, suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in ``TypeQualifier``"
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(&self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }
}

extension SymbolTable {
  var _verbose: Bool { false }
  var logPrefix: [String] {
    get { [] }
    set {}
  }
  var _logNestingLimit: Int? { nil }
  func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    #if DEBUG
    guard _verbose else { return }
    // Calculate log text
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    // Print new line
    print(newLine)
    // TODO: Remove
    fflush(stdout)
    #endif
  }

  func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: borrowing SymbolTable) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit, logPrefix.count >= nestingLimit {
      fatalError(
        "Exceeded log nesting limit of \(nestingLimit), suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in `TypeQualifier`."
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }
}

extension SymbolTable {
  /// Sorts results in increasing order by
  /// (a) Module name (alphabetically), (b) File id (alphabetically), and (c) File position (offset).
  ///
  /// Helps maintain deterministic outputs.
  // TODO: Remove
  func sortDeclarations(_ typeDecls: [Attached<TypeDeclSyntax>]) -> [Attached<TypeDeclSyntax>] {
    typeDecls.sorted(by: { a, b in
      // Compare modules
      let fileA = getFileInfo(a.fileRoot)!
      let fileB = getFileInfo(b.fileRoot)!
      guard fileA.module == fileA.module else {
        return fileA.module.name < fileA.module.name
      }

      // If modules are equal, compare file names
      guard fileA.name == fileB.name else {
        return fileA.name < fileB.name
      }

      // If file names are equal, compare positions
      return a.position < b.position
    })
  }
}

// MARK: Array Helpers

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
