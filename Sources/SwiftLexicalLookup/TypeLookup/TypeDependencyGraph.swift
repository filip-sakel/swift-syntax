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

@_spi(_QualifiedLookupTests) public typealias IntroducingExtensionOrMainDecl = Attached<ExtensionDeclSyntax>?
@_spi(_QualifiedLookupTests) public struct TypeMemberDecl: Hashable, Sendable {
  let introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
  let typeDeclSyntax: Attached<TypeDeclSyntax>
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
  GlobalTypeName
>

@_spi(_QualifiedLookupTests) public typealias GenericBindingFailure<
  TypeName: Sendable & Hashable & CustomDebugStringConvertible
> = TypeResolutionFailure<
  TypeName, ResolvedNominalTypeReference, NominalTypeRef
>
@_spi(_QualifiedLookupTests) public typealias InvalidatedExtensions = [ExtensionState]
@_spi(_QualifiedLookupTests) public typealias BindingFailure = GenericBindingFailure<GlobalTypeName>

@_spi(_QualifiedLookupTests) public typealias BindingResult = (
  resolvedTypeName: Result<
    (globalReference: GlobalNominalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
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
    extensionDecl: Attached<ExtensionDeclSyntax>,
    /// The resolved type must be valid in `namesToTypes`
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>

  @_spi(_QualifiedLookupTests) public init(
    _uncheckedDependencies dependencies: [GenericExtensionDependency<TypeName>],
    extensionDecl: Attached<ExtensionDeclSyntax>,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>
  ) {
    self.dependencies = dependencies
    self.extensionDecl = extensionDecl
    self.resolvedType = resolvedType
  }

  @_spi(_QualifiedLookupTests) public init(
    dependencies: [QualifiedLookupDependency<GlobalTypeName>],
    extensionDecl: Attached<ExtensionDeclSyntax>,
    resolvedType: Result<TypeName, GenericBindingFailure<TypeName>>
  ) where TypeName == GlobalTypeName {
    // Group dependencies by base type and member name, while maintaing order
    var groupedDependencies =
      [
        (
          key: GlobalTypeName,
          value: [(key: Identifier, value: [(IntroducingExtensionOrMainDecl, Attached<TypeDeclSyntax>)])]
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
@_spi(_QualifiedLookupTests) public typealias ExtensionState = GenericExtensionState<GlobalTypeName>

@_spi(_QualifiedLookupTests) public struct TypeTable: Hashable {
  fileprivate(set) var typeMembersToDecls: [Identifier: TypeMember]

  init(
    from namesToDecls: [Identifier: [Attached<TypeDeclSyntax>]],
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
    _ dependency: QualifiedLookupDependency<GlobalTypeName>,
    whenBoundTo baseTypeName: GlobalTypeName
  ) -> Bool {
    dependency.extendedTypeName == baseTypeName && typeMembersToDecls[dependency.member] != nil
  }
}

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
public struct TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public struct TypeDependent: Sendable, Hashable, CustomDebugStringConvertible {
    @_spi(_QualifiedLookupTests) public let memberType: Identifier
    @_spi(_QualifiedLookupTests) public let dependentExtension: Attached<ExtensionDeclSyntax>

    public var debugDescription: String {
      "Self > '\(memberType.name)' => `\(dependentExtension.node._memberlessDescription)`"
    }
  }

  @_spi(_QualifiedLookupTests) public struct NominalType {
    /// Keeps track of mutations to assert data didn't change between calls
    internal private(set) var version = 0

    /// Invariants: count >= 1; sorted by position in increasing order
    /// TODO: Should use an enum of `case mainDecl(MappedDeclGroup<NominalTypeDeclSyntax>)` or
    /// `case redeclarations([MappedDeclGroup<NominalTypeDeclSyntax>])`
    fileprivate private(set) var _mainDecls: [MappedDeclGroup<NominalTypeDeclSyntax>]

    private(set) var boundExtensions: [ModuleName: [Attached<ExtensionDeclSyntax>: TypeTable]]

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
      module: ModuleName
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
    fileprivate consuming func _unbindingNominalDecl(
      _ nominalTypeDecl: Attached<NominalTypeDeclSyntax>
    ) -> Result<NominalType?, NominalUnbindingFailure> {
      var copy = self

      // Ensure we have no bound extensions (if we have redeclarations,
      // the type is ambiguous so not extensions should have resolved to
      // us; if we have just one main declaration, we'll remove the type and
      // lingering extensions be bound to an unregistered type)
      //
      // Here, we check that each module has an empty list.
      guard copy.boundExtensions.allSatisfy(\.value.isEmpty) else {
        return .failure(NominalUnbindingFailure.remainingBoundExtensions)
      }
      // Ensure we have no dependents (similar reasoning with above)
      guard copy.dependents.isEmpty else {
        return .failure(NominalUnbindingFailure.remainingDependents)
      }

      // Remove the declaration (keeping count)
      let originalDecls = copy._mainDecls
      copy._mainDecls.removeAll(where: { $0.declGroup == nominalTypeDecl })

      // Ensure the declaration was actually bound and we removed it
      guard copy._mainDecls.count == originalDecls.count - 1 else {
        return .failure(NominalUnbindingFailure.nominalTypeNotAMainDecl)
      }

      // Return `nil` if no nominal-type declaration is left (maintains invariant)
      guard !copy._mainDecls.isEmpty else { return .success(nil) }

      return .success(copy)
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
      // Sort the main declarations by their position in the file.
      //
      // Sorting works because nominal types are tracked by file (so if we have
      // two structs `B` nested under a struct `A` in FileA.swift and FileB.swift,
      // we diagnose the ambiguity elsewhere but can have two independent nominals).
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
  @_spi(_QualifiedLookupTests) public var namesToTypes: [GlobalTypeName: NominalType]
  // /// Updates when we register nominal types and bind extensions
  // var parentsToTypeMembers: [QualifiedTypeName: TypeTable]
  @_spi(_QualifiedLookupTests) public var extensionsToState: [Attached<ExtensionDeclSyntax>: ExtensionState]

  var _verbose: Bool = false
  var logPrefix: [String] = [String]()
  /// The number of `withLogging` calls we can nest. Useful for debugging infinite loops
  /// that otherwise fill up standard output and become illegible.
  let _logNestingLimit: Int? = 50

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
    perform action: (_ mutableSelf: inout TypeDependencyGraph) -> T,
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
    baseTypeName: GlobalTypeName,
    memberTypeName: Identifier,
    performLookup: (GlobalTypeName, Identifier) -> QualifiedLookupDependency<TypeName>
  ) -> QualifiedLookupDependency<TypeName> where TypeName == GlobalTypeName {
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
@_spi(_QualifiedLookupTests) public typealias DependencyTracker = GenericDependencyTracker<GlobalTypeName>

@_spi(_QualifiedLookupTests) public struct GlobalNominalTypeRef: Hashable, Sendable, CustomDebugStringConvertible {
  let name: GlobalTypeName
  let _version: Int

  internal init(name: GlobalTypeName, _version: Int) {
    self.name = name
    self._version = _version
  }

  public var debugDescription: String {
    return "\(name.debugDescription) (v\(_version))"
  }
}

extension GlobalNominalTypeRef {
  init(qualifiedName: GlobalTypeName, nominal: __shared TypeDependencyGraph.NominalType) {
    self.init(name: qualifiedName, _version: nominal.version)
  }
}

// FIXME: Move to _global_ symbol-table _version
@_spi(_QualifiedLookupTests) public struct NominalTypeRef: Hashable, Sendable {
  @_spi(_QualifiedLookupTests) public enum Storage: Hashable, Sendable {
    /// Local nominal types cannot be extended
    case local(Attached<NominalTypeDeclSyntax>)
    case global(GlobalNominalTypeRef)
  }

  @_spi(_QualifiedLookupTests) public let storage: Storage

  init(globalReference: GlobalNominalTypeRef) {
    storage = .global(globalReference)
  }
  init(localNominalType: Attached<NominalTypeDeclSyntax>) {
    storage = .local(localNominalType)
  }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public enum QualifiedTypeLookupFailure: Error {
    /// References non-registered base type
    case invalidBase
    // TODO: Enable
    // /// There are multiple base declarations, making lookup ambiguous.
    // case ambiguousBase(possibleBases: [SourceFileRoot<NominalTypeDeclSyntax>])
  }
  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    origin: (typeSyntax: Attached<TypeLikeSyntax>, module: ModuleName),
    moduleMap: [SourceFileSyntax: ModuleName],
    dependencyTracker: inout DependencyTracker,
    configuredRegions: ConfiguredRegions?
  ) -> Result<[Attached<TypeDeclSyntax>], QualifiedTypeLookupFailure> {
    // Get global nominal reference
    let baseTypeReference: GlobalNominalTypeRef
    switch baseType.storage {
    case .global(let globalReference):
      baseTypeReference = globalReference
    case .local(let nominalTypeDecl):
      // Local decls don't have extensions (=> no dependencies generated); just
      // look into the main declaration.
      let typeMembers = nominalTypeDecl._groupTypeMembers(configuredRegions: configuredRegions).flatMap(\.value)
      return .success(typeMembers)
    }

    // Diagnose invalid base
    guard
      let registeredType = namesToTypes[baseTypeReference.name],
      registeredType.version == baseTypeReference._version
    else {
      return .failure(QualifiedTypeLookupFailure.invalidBase)
    }
    // FIXME: Ensure reference's symbol-table version also matches

    // Diagnose ambiguous base
    // FIXME: Enable check
    // guard registeredType.redeclarations.isEmpty else {
    //   return .failure(
    //     QualifiedTypeLookupFailure.ambiguousBase(possibleBases: registeredType._mainDecls.map(\.declGroup))
    //   )
    // }

    func directLookup(
      baseTypeName: GlobalTypeName,
      memberTypeName: Identifier
    ) -> QualifiedLookupDependency<GlobalTypeName> {
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
      var typeDecls = [(IntroducingExtensionOrMainDecl, Attached<TypeDeclSyntax>)]()
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
      baseTypeName: baseTypeReference.name,
      memberTypeName: memberTypeName,
      performLookup: directLookup(baseTypeName:memberTypeName:)
    )

    // Distill to type declarations (throw away declaration groups)
    return .success(result.typeDecls.map(\.1))
  }
}

extension TypeDependencyGraph {
  // TODO: Extract out to a better place
  //
  /// Get the declaration-group parent of the given node; returns `nil`
  /// if no such parent exists and for top-level/local declarations.
  fileprivate func _declGroupScope<S: SyntaxProtocol>(
    of node: Attached<S>
  ) -> Attached<DeclGroupSyntaxType>? {
    // Ensure we have parent
    guard let parent = node.parent else { return nil }

    // Return `nil` for local declarationns
    guard parent.kind != .codeBlockItemList else { return nil }

    // Get the parent or recurse
    guard let declGroupParent = parent.as(DeclGroupSyntaxType.self) else {
      return _declGroupScope(of: parent)
    }
    return declGroupParent
  }

  enum NominalRegistrationFailure: Error {
    // TODO: Enable
    case parentNotRegistered(parentTypeName: GlobalTypeName)
    /// Registering a global type with multiple components in its name implies a
    /// nested global nominal-type declaration.
    case noDeclGroupParent
    /// Can't register under a decl group that's a redeclaration.
    ///
    /// For instance, the following generates no error:
    /// ```swift
    /// struct A {
    ///     struct B {
    ///         func f(_: C) {}
    ///     }
    /// }
    /// extension A {
    ///     struct C {}
    /// }
    /// ```
    /// However, replacing the last extension with the following yields an error:
    /// ```swift
    /// struct A {
    ///     struct B {
    ///         func f(_: B) {} // ✅
    ///         func f(_: C) {} // ❌ error: Can't find `C`
    ///     }
    /// }
    /// struct A {
    ///     struct C {}
    /// }
    /// ```
    /// So, despite both `struct A`'s being nominal declarations for
    /// `_(File.swift)::A`, we can only register member type 'C' under
    /// the main declaration.
    case cannotRegisterUnderRedeclaration
    /// Cannot register type nested in extension that hasn't been registered yet.
    case parentExtensionUnbound(extensionDecl: Attached<ExtensionDeclSyntax>)
  }

  /// Registers the given nominal-type reference or return the
  /// existing reference.
  ///
  /// Parameters:
  /// - rawQualifiedName: Any qualified name, local or global
  ///
  /// Returns: An error if this is a redeclaration. Otherwise, assume the
  /// `NominalTypeRef` points to the given `mainDecl`.
  mutating func registerNominalTypeReference(
    rawQualifiedName: TypeName,
    mainDecl: Attached<NominalTypeDeclSyntax>,
    configuredRegions: ConfiguredRegions?
  ) -> Result<NominalTypeRef, NominalRegistrationFailure> {
    // Get the global name
    let qualifiedName: GlobalTypeName
    switch rawQualifiedName {
    case .global(let name):
      qualifiedName = name
    case .local:
      return .success(NominalTypeRef(localNominalType: mainDecl))
    }

    // FIXME: Invalidate extensions if we're introducing a redecl to an existing type

    // FIXME: Enable this check.
    //
    // Check parent is registered, if nested
    if let (qualifiedBaseName, member: _) = qualifiedName.baseAndMember {
      guard let baseType = namesToTypes[qualifiedBaseName] else {
        return .failure(NominalRegistrationFailure.parentNotRegistered(parentTypeName: qualifiedBaseName))
      }
      // At this point, we should get a declaration group
      guard let parentDeclGroup = _declGroupScope(of: mainDecl) else {
        return .failure(NominalRegistrationFailure.noDeclGroupParent)
      }
      // Check extension is bound
      if let parentExtension = parentDeclGroup.as(ExtensionDeclSyntax.self),
        let parentExtensionState = extensionsToState[parentExtension],
        case .success(let extendedTypeName) = parentExtensionState.resolvedType,
        extendedTypeName != qualifiedBaseName
      {
        return .failure(NominalRegistrationFailure.parentExtensionUnbound(extensionDecl: parentExtension))
      }
      // Check parent decl is the main decl
      if let parentNominal = parentDeclGroup.as(NominalTypeDeclSyntax.self),
        baseType.mainDecl.declGroup != parentNominal
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
        return .failure(NominalRegistrationFailure.cannotRegisterUnderRedeclaration)
      }
    } else {
      // Otherwise, a top-level declaration is fine
    }

    // TODO: Add an assertion when registering an extension-dependent nominal, that
    //       the extension is registered

    // Map out the type
    let mappedMainDecl = MappedDeclGroup.from(declGroup: mainDecl, configuredRegions: configuredRegions)

    // If this type is new, just register and return
    // TODO: Test following, e.g. struct A { struct B {} }; extension A { struct B {} }
    guard let existingType = namesToTypes[qualifiedName] else {
      let freshNominal = NominalType(mainDecl: mappedMainDecl)
      namesToTypes[qualifiedName] = freshNominal
      return .success(
        NominalTypeRef(globalReference: GlobalNominalTypeRef(qualifiedName: qualifiedName, nominal: freshNominal))
      )
    }

    // Add the redeclaration (or ignore if the decl is already added)
    let typeWithRedeclaration = existingType.addingRedeclaration(mappedMainDecl)
    namesToTypes[qualifiedName] = typeWithRedeclaration

    return .success(
      NominalTypeRef(
        globalReference: GlobalNominalTypeRef(qualifiedName: qualifiedName, nominal: typeWithRedeclaration)
      )
    )
  }

  enum NominalTypeRefUpdateFailure: Error {
    /// This type now has ambiguous redeclarations
    case redeclared(declarations: [Attached<NominalTypeDeclSyntax>])
    /// This type is no longer in the symbol table
    case removed
  }
  func updateNominalTypeReference(oldReference: NominalTypeRef) -> Result<NominalTypeRef, NominalTypeRefUpdateFailure> {
    // Extract global reference; return local reference as is
    let globalReference: GlobalNominalTypeRef
    switch oldReference.storage {
    case .global(let reference):
      globalReference = reference
    case .local:
      return .success(oldReference)
    }

    // Get the type state
    guard let typeState = namesToTypes[globalReference.name] else {
      return .failure(NominalTypeRefUpdateFailure.removed)
    }

    // Ensure no redeclarations
    guard typeState.redeclarations.isEmpty else {
      return .failure(NominalTypeRefUpdateFailure.redeclared(declarations: typeState._mainDecls.map(\.declGroup)))
    }

    return .success(
      NominalTypeRef(globalReference: GlobalNominalTypeRef(qualifiedName: globalReference.name, nominal: typeState))
    )
  }
}

// MARK: - Extension Dependencies

// TODO: Look into whether we can use the existing ExtensionBindingResult/Dependency type
@_spi(_QualifiedLookupTests) public struct QualifiedLookupDependency<TypeName: Sendable>: Sendable {
  let extendedTypeName: TypeName
  let member: Identifier
  let typeDecls: [(introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl, typeDecl: Attached<TypeDeclSyntax>)]

  // TODO: Clean up
  @_spi(_QualifiedLookupTests) public init(
    // introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
    extendedTypeName: TypeName,
    member: Identifier,
    // typeDecls: [TypeDeclSyntax]
    typeDecls: [(IntroducingExtensionOrMainDecl, Attached<TypeDeclSyntax>)]
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
  GlobalTypeName
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
  GlobalTypeName
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
    let boundType: GlobalTypeName
    let extensionDecl: Attached<ExtensionDeclSyntax>
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

  fileprivate mutating func _findFirstCycleWhenBinding(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionMembers: TypeTable,
    to boundTypeName: GlobalTypeName,
    extensionDependencies: [QualifiedLookupDependency<GlobalTypeName>],
  ) -> Result<GenericExtensionBindingCycle<GlobalTypeName>, CycleDetectionFailure>? {
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

    log(
      "Checking cycles if introducing `\(extensionDecl._memberlessDescription)` with members '\(boundTypeName.debugDescription)' > \(extensionMembers.typeMembersToDecls.map(\.key.name))"
    )

    // Check recursive dependencies
    let cycleResult: ExtensionBindingCycle? = _findFirstDependency(
      path: boundExtensionInfo,
      where: { (dependency, path) -> ExtensionBindingCycle? in
        // TODO: Factor out to or remove `collidesWithDependency` helper above.
        // Check if dependency collides with introduces `boundTypeName` > `extensionMembers`.
        // Collisions require that the base type match and that members share a name.
        log("Visiting `\(dependency._declarationlessDescription)` [path \(path)]")
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
  fileprivate func _firstRegisteredMemberName(
    declGroup: Attached<DeclGroupSyntaxType>,
    declGroupModule: ModuleName,
    declGroupTypeName: GlobalTypeName,
    members: TypeTable,
    symbolTable: SymbolTable
  ) -> GlobalTypeName? {
    for (memberName, member) in members.typeMembersToDecls {
      // Construct the type the member would have
      let potentialMemberTypeName = declGroupTypeName.addingComponents([
        GlobalTypeName.Component(
          name: memberName,
          file: declGroup.fileRoot,
          module: declGroupModule,
          symbolTable: symbolTable
        )
      ])

      // Get the registered type and name, if it exists
      guard let memberType = namesToTypes[potentialMemberTypeName] else { continue }
      let memberTypeName = potentialMemberTypeName

      // If we get a type, we need to check if any of the member declarations are registered
      // in the type.
      //
      // Note: The complexity of the following check is O(n*m) where `n` is the number of `_mainDecls`
      // and `m` the number of decls named `memberName` in the given extension. But we usually have a
      // single main declaration and single same-name declaration in an nominal-type/extension decl.
      let memberIsRegistered = memberType._mainDecls.contains(where: { nominalDecl in
        member.decls.contains(where: { $0.typeDeclSyntax.as(NominalTypeDeclSyntax.self) == nominalDecl.declGroup })
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
    case resolvedToUnregistered(typeName: GlobalTypeName)
    case resolvedButUnbound(typeName: GlobalTypeName)
    case dependencyToUnregistered(dependencyTpeName: GlobalTypeName)
    /// We have a dependency to a type that doesn't know we're dependent
    case notInDependentsList(dependencyTypeName: GlobalTypeName)
    case remainingDependents(
      typeName: GlobalTypeName,
      // TODO: Change to `Identifier`
      extensionMembers: [String],
      dependents: [TypeDependent]
    )
    case remainingRegistredMemberType(memberTypeName: GlobalTypeName)
  }

  fileprivate mutating func _removeExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionDeclModule: ModuleName,
    symbolTable: SymbolTable
  ) -> Result<ExtensionState, ExtensionRemovalFailure> {
    return withLogging(
      request: "Removing `\(extensionDecl._memberlessDescription)`",
      describe: { _ in "" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true) }
        return self.__removeExtension(
          extensionDecl,
          extensionDeclModule: extensionDeclModule,
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
    extensionDeclModule: ModuleName,
    symbolTable: SymbolTable
  ) -> Result<ExtensionState, ExtensionRemovalFailure> {
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
        let extensionMembers = extendedType.boundExtensions[extensionDeclModule, default: [:]][extensionDecl]
        // TODO: Remove
        // let (unboundType, extensionMembers) = extendedType._unbindingExtension(extensionDecl, module: extensionDeclModule)
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
      let memberTypeName: GlobalTypeName? = _firstRegisteredMemberName(
        declGroup: Attached<DeclGroupSyntaxType>(extensionDecl),
        declGroupModule: extensionDeclModule,
        declGroupTypeName: extendedTypeName,
        members: extensionMembers,
        symbolTable: symbolTable
      )
      if let memberTypeName {
        return .failure(ExtensionRemovalFailure.remainingRegistredMemberType(memberTypeName: memberTypeName))
      }
    // TODO: Remove
    // for (_, member) in extensionMembers.typeMembersToDecls {
    //   let potentialMemberTypeName = extendedTypeName.addingComponents([
    //     QualifiedTypeNameGlobalType.Component(
    //       name: memberName,
    //       file: extensionDecl.fileRoot,
    //       module: extensionDeclModule,
    //       symbolTable: symbolTable
    //     )
    //   ])
    //   // Ensure that if a type remains, none of the member declarations are still registered
    //   //
    //   // Note: The complexity of the following check is O(n*m) where `n` is the number of `_mainDecls`
    //   // and `m` the number of decls named `memberName` in the given extension. But we usually have a
    //   // single main declaration and single same-name declaration in an extension.
    //   if let memberType = namesToTypes[potentialMemberTypeName],
    //     memberType._mainDecls.contains(where: { nominalDecl in
    //       member.decls.contains(where: { $0.typeDeclSyntax.as(NominalTypeDeclSyntax.self) == nominalDecl.declGroup })
    //     })
    //   {
    //     return .failure(ExtensionRemovalFailure.remainingRegistredMemberType(memberTypeName: potentialMemberTypeName))
    //   }
    // }
    case .failure:
      // Failed extensions don't introduce types => no dependents
      break
    }

    // Unregister as a dependent from all our dependencies
    for dependency in extensionState.dependencies {
      // Get dependency type
      guard let dependencyType = namesToTypes[dependency.dependencyTypeName] else {
        return .failure(
          ExtensionRemovalFailure.dependencyToUnregistered(dependencyTpeName: dependency.dependencyTypeName)
        )
      }

      // Remove ourselves as the dependency
      let originalDependentsCount = dependencyType.dependents.count
      var newDependents = dependencyType.dependents
      newDependents.removeAll(where: { $0.dependentExtension == extensionDecl })
      log("New dependents for '\(dependency.dependencyTypeName)': \(newDependents)")
      guard newDependents.count < originalDependentsCount else {
        return .failure(ExtensionRemovalFailure.notInDependentsList(dependencyTypeName: dependency.dependencyTypeName))
      }

      // Update dependency type
      namesToTypes[dependency.dependencyTypeName] = dependencyType._updatingDependents(newDependents)
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
        let (unboundExtendedType, _) = newExtendedType._unbindingExtension(extensionDecl, module: extensionDeclModule)
      else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type somehow went missing and/or extension was unbound."
        )
      }
      namesToTypes[extendedTypeName] = unboundExtendedType
      log(
        "Updating '\(extendedTypeName.debugDescription)' with new extensions: [\(unboundExtendedType.boundExtensions[extensionDeclModule, default: [:]].map(\.key._memberlessDescription).joined(separator: ", "))]"
      )
    case .failure:
      break
    }
    // Remove extension state
    extensionsToState[extensionDecl] = nil

    return .success(extensionState)
  }

  enum NominalRemovalFailure: Error {
    case unregisteredName(GlobalTypeName)
    case nominalNotInRegisteredType(
      typeName: GlobalTypeName,
      actualMainDecls: [Attached<NominalTypeDeclSyntax>]
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
    nominalDeclModule: ModuleName,
    typeName: GlobalTypeName,
    symbolTable: SymbolTable
  ) -> Result<NominalType?, NominalRemovalFailure> {
    // Get the state
    guard let type: NominalType = namesToTypes[typeName] else {
      return .failure(NominalRemovalFailure.unregisteredName(typeName))
    }

    // Remove the declaration (we get back either a new nominal type if
    // there were multiple redeclarations, or `nil` if we removed the main
    // declaration)
    //
    // We handle errors, such as unbinding an unrelated nominal type decl,
    // having extensions still bound, or having dependents.
    let newType: NominalType?
    switch type._unbindingNominalDecl(nominalDecl) {
    case .success(let success):
      newType = success
    case .failure(NominalType.NominalUnbindingFailure.nominalTypeNotAMainDecl):
      return .failure(
        NominalRemovalFailure.nominalNotInRegisteredType(
          typeName: typeName,
          actualMainDecls: type._mainDecls.map(\.declGroup)
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
    if type.mainDecl.declGroup == nominalDecl {
      // Since the new type is `nil`, the decl used to be `type.mainDecl`
      let members = type.mainDecl.typeMap
      let memberTypeName: GlobalTypeName? = _firstRegisteredMemberName(
        declGroup: Attached<DeclGroupSyntaxType>(nominalDecl),
        declGroupModule: nominalDeclModule,
        declGroupTypeName: typeName,
        members: members,
        symbolTable: symbolTable
      )
      if let memberTypeName {
        return .failure(NominalRemovalFailure.remainingRegistredMemberType(memberTypeName: memberTypeName))
      }
    }

    // `nil` means there was no other main declaration
    namesToTypes[typeName] = newType
    log(
      "Updated nominal '\(typeName.debugDescription)' to new main decl: `\(newType?.mainDecl.declGroup._memberlessDescription ?? "<deleted>")`."
    )

    return .success(newType)
  }

  mutating func _unbindMemberType(
    baseTypeName: GlobalTypeName,
    baseTypeDecl: Attached<DeclGroupSyntaxType>,
    baseTypeModule: Identifier,
    baseType: NominalType,
    member: TypeMember,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: SymbolTable
  ) {
    return withLogging(
      request: "Unbinding member type '\(baseTypeName.debugDescription)' > '\(member.name.name)'",
      describe: { "" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__unbindMemberType(
          baseTypeName: baseTypeName,
          baseTypeDecl: baseTypeDecl,
          baseTypeModule: baseTypeModule,
          baseType: baseType,
          member: member,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  mutating func __unbindMemberType(
    baseTypeName: GlobalTypeName,
    baseTypeDecl: Attached<DeclGroupSyntaxType>,
    baseTypeModule: Identifier,
    baseType: NominalType,
    member: TypeMember,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: SymbolTable
  ) {
    // Invalidate dependent extensions
    _invalidateDependents(
      modifiedTypeName: baseTypeName,
      modifiedMembers: TypeTable(
        from: [member.name: member.decls.map(\.typeDeclSyntax)],
        introducedIn: baseTypeDecl.as(ExtensionDeclSyntax.self)
      ),
      modifiedExtensionModule: baseTypeModule,
      invalidatedExtensions: &invalidatedExtensions,
      symbolTable: symbolTable
    )

    // If there's no registered nominal type our name, we're done
    let memberNominalTypeName = baseTypeName.addingComponents([
      GlobalTypeName.Component(
        name: member.name,
        file: baseTypeDecl.fileRoot,
        module: baseTypeModule,
        symbolTable: symbolTable
      )
    ])
    guard var memberNominal: NominalType = namesToTypes[memberNominalTypeName] else {
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
    // TODO: Change when `NominalType/mainDecl` becomes an enum
    let memberNominalDecls: [Attached<NominalTypeDeclSyntax>] = member.decls.compactMap({
      $0.typeDeclSyntax.as(NominalTypeDeclSyntax.self)
    })
    if memberNominal.redeclarations.isEmpty, memberNominalDecls.contains(memberNominal.mainDecl.declGroup) {
      // Assert we don't have any nominal-type *re*declarations (checked in `registerNominalTypeReference`)
      precondition(
        memberNominalDecls == [memberNominal.mainDecl.declGroup],
        "[SwiftLexicalLookup] Internal error: Expected nominal type '\(memberNominalTypeName.debugDescription)' to have the main decl `\(memberNominal.mainDecl.declGroup._memberlessDescription)`, but instead got: \(memberNominalDecls.map(\._memberlessDescription).joined(separator: ", "))"
      )

      // Remove all nested member types
      log("Found main decl `\(memberNominal.mainDecl.declGroup._memberlessDescription)`; removing member types.")
      for (_, nestedMember) in memberNominal.mainDecl.typeMap.typeMembersToDecls {
        log(
          "Visiting member type `\(memberNominal.mainDecl.declGroup._memberlessDescription)` > '\(nestedMember.name.name)'"
        )
        _unbindMemberType(
          baseTypeName: memberNominalTypeName,
          baseTypeDecl: Attached<DeclGroupSyntaxType>(memberNominal.mainDecl.declGroup),
          baseTypeModule: baseTypeModule,
          baseType: memberNominal,
          member: nestedMember,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
      }

      // Remove bound extensions
      // TODO: Why didn't this fail a test before?? Write a proper test
      // Note: `memberNominal` is stale here but since extension invalidation doesn't
      // bind dependencies, this will always be a superset of the currently bound
      // extensions. Further, if an extension was already invalidated, `_unbindExtension`
      // will just skip it.
      for moduleExtensions in memberNominal.boundExtensions.values {
        for (extensionDecl, _) in moduleExtensions {
          let invalidatedExtension = _unbindExtension(
            extensionDecl,
            invalidatedExtensions: &invalidatedExtensions,
            symbolTable: symbolTable
          )
          guard let invalidatedExtension else { continue }
          invalidatedExtensions.append(invalidatedExtension)
        }
      }
    }

    // === Unregister Nominals ===
    for memberNominalDecl in memberNominalDecls {
      let removalResult = __removeNominalTypeDeclaration(
        memberNominalDecl,
        // Same module since this is a nested type
        nominalDeclModule: baseTypeModule,
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
          // Some other function messed up: not all dependents were invalidated,
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
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable
  ) -> ExtensionState? {
    return withLogging(
      request: "Unbinding `\(extensionDecl._memberlessDescription)`",
      describe: \.debugDescription,
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__unbindExtension(
          extensionDecl,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  mutating func __unbindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable
  ) -> ExtensionState? {
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
      assert(
        invalidatedExtensions.contains(where: { $0.extensionDecl == extensionDecl }),
        "Asked to unbind unregistered, non-invalidated extension `\(extensionDecl._memberlessDescription)`."
      )
      log("Skipping already invalidated extension `\(extensionDecl._memberlessDescription)`")
      return nil
    }
    guard let extensionDeclModule = symbolTable.moduleMap[extensionDecl.fileRoot] else {
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
      guard let extensionMembers = extendedType.boundExtensions[extensionDeclModule, default: [:]][extensionDecl] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension `\(extensionDecl._memberlessDescription)` resolved to but isn't bound to type '\(extendedTypeName)'"
        )
      }

      for (_, typeMember) in extensionMembers.typeMembersToDecls {
        _unbindMemberType(
          baseTypeName: extendedTypeName,
          baseTypeDecl: Attached<DeclGroupSyntaxType>(extensionDecl),
          baseTypeModule: extensionDeclModule,
          baseType: extendedType,
          member: typeMember,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
      }
    }

    // Now that the members are gone, remove
    let removalResult = _removeExtension(
      extensionDecl,
      extensionDeclModule: extensionDeclModule,
      symbolTable: symbolTable
    )
    let removedExtensionState: ExtensionState
    switch removalResult {
    case .success(let success):
      removedExtensionState = success
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

    return removedExtensionState
  }

  fileprivate mutating func _invalidateDependents(
    modifiedTypeName: GlobalTypeName,
    modifiedMembers: TypeTable,
    modifiedExtensionModule: ModuleName,
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable
  ) {  //-> [TypeDependent] {
    return withLogging(
      request:
        "Invalidating dependents of '\(modifiedTypeName.debugDescription)' > \(modifiedMembers.typeMembersToDecls.map(\.key.name))",
      describe: { "\($0)" },
      perform: { `self` in
        self._introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
        defer { self._introspect(symbolTable: symbolTable) }
        return self.__invalidateDependents(
          modifiedTypeName: modifiedTypeName,
          modifiedMembers: modifiedMembers,
          modifiedExtensionModule: modifiedExtensionModule,
          invalidatedExtensions: &invalidatedExtensions,
          symbolTable: symbolTable
        )
      }
    )
  }

  fileprivate mutating func __invalidateDependents(
    modifiedTypeName: GlobalTypeName,
    modifiedMembers: TypeTable,
    modifiedExtensionModule: ModuleName,
    // directDependents: [TypeDependent],
    invalidatedExtensions: inout [ExtensionState],
    symbolTable: borrowing SymbolTable
  ) {  //-> [TypeDependent] {
    // TODO: Clean up if we go for immutable `get`
    func popLastConflictingDependent() -> TypeDependent? {
      // The base type must exist
      guard let baseType = namesToTypes[modifiedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly asked to invalidate unregistered type '\(modifiedTypeName.debugDescription)'."
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
      var newDependents = baseType.dependents
      // let nextDependent = newDependents.remove(at: nextIndex)
      let nextDependent = newDependents[nextIndex]

      namesToTypes[modifiedTypeName] = baseType._updatingDependents(newDependents)

      return nextDependent
    }

    // var newDependents = [TypeDependent]()

    // TODO: We should track unbound extensions so different members don't invalidate different extensions
    // TODO: Get rid of force unwrap
    while let dependent = popLastConflictingDependent() {
      // // Only unbind conflicting (otherwise add to new dependents)
      // guard modifiedMembers.typeMembersToDecls[dependent.memberType] != nil else {
      //   newDependents.append(dependent)
      //   continue
      // }

      log("Found conflict \(dependent.debugDescription)")
      let invalidatedExtensionState = _unbindExtension(
        dependent.dependentExtension,
        invalidatedExtensions: &invalidatedExtensions,
        symbolTable: symbolTable
      )
      // Skip if we've already unbound
      // This can happen if an extension has multiple dependencies.
      // E.g. We introduce _(MyFile.swift)::A > ['B', 'C'] and an extension
      // is dependent on both type memmebrs. When invalidating
      // _(MyFile.swift)::A > 'B', we'll unbind that extension but there's
      // no use updating _(MyFile.swift)::A's dependents
      guard let invalidatedExtensionState else { continue }

      // Update dependents
      namesToTypes[modifiedTypeName]!.dependents.removeAll(where: { thisDependent in
        thisDependent.memberType == dependent.memberType
          && thisDependent.dependentExtension == dependent.dependentExtension
      })

      // Record invalidation
      invalidatedExtensions.append(invalidatedExtensionState)
    }

    // return newDependents
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
  /// TODO: Remove
  // fileprivate mutating func _invalidateDependents__OLD(
  //   modifiedTypeName: QualifiedTypeNameGlobalType,
  //   modifiedMembers: TypeTable?,
  //   directDependents: [TypeDependent],
  //   invalidatedExtensions: inout [ExtensionState],
  //   symbolTable: borrowing SymbolTable3
  // ) -> [TypeDependent] {
  //   // For each dependent extension, either invalidate or keep it in the
  //   // new-dependents list.
  //   var newDependents = [TypeDependent]()
  //
  //   // TODO: Verify that this order of invalidating is fine
  //   for dependent in directDependents {
  //     // Get the invalidated extension (or retain dependent if the extension
  //     // doesn't depend on `modifiedMembers`)
  //     if let modifiedMembers,
  //       modifiedMembers.typeMembersToDecls[dependent.memberType] == nil
  //     {
  //       newDependents.append(dependent)
  //       continue
  //     }
  //     let invalidatedExtension = dependent.dependentExtension
  //
  //     // Ensure extension has a known module (needed later)
  //     guard let invalidatedExtensionModule: SymbolTable3.Module = symbolTable.moduleMap[invalidatedExtension.fileRoot]
  //     else {
  //       // TODO: Clarify where we make this assertion
  //       fatalError(
  //         "[SwiftLexicalLookup] Internal error: Found extension \(invalidatedExtension._memberlessDescription) from unbound module."
  //       )
  //     }
  //
  //     // Get the to-be-invalidated extension's state
  //     guard let invalidatedExtensionState = extensionsToState[invalidatedExtension] else {
  //       fatalError(
  //         "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension._memberlessDescription) referenced in `\(modifiedTypeName)`'s dependents, but lacks a state entry."
  //       )
  //     }
  //
  //     // Invalidate
  //     //
  //     // 1. Remove extension state & record invalidated extension
  //     extensionsToState[invalidatedExtension] = nil
  //     invalidatedExtensions.append(invalidatedExtensionState)
  //
  //     // 2. Update the extended type
  //     //
  //     // If the extension was unbound, we don't have any children to invalidate
  //     // or a bound type to update, so we're done
  //     guard case .success(let invalidatedExtensionTypeName) = invalidatedExtensionState.resolvedType else {
  //       continue
  //     }
  //
  //     // Remove the members from the extended type
  //     guard let invalidatedExtensionType = namesToTypes[invalidatedExtensionTypeName] else {
  //       fatalError(
  //         "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) resolved to \(invalidatedExtensionTypeName) but the type isn't in the graph."
  //       )
  //     }
  //     guard
  //       let (newInvalidatedExtensionType, invalidatedExtensionTypeTable) = invalidatedExtensionType._unbindingExtension(
  //         invalidatedExtension,
  //         module: invalidatedExtensionModule
  //       )
  //     else {
  //       fatalError(
  //         "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension.node._memberlessDescription) unexpectedly not in `boundExtensions` of \(invalidatedExtensionType)."
  //       )
  //     }
  //
  //     // Recursively invalidate the invalidate extension's dependents
  //     let newTransitiveDependents = _invalidateDependents__OLD(
  //       modifiedTypeName: invalidatedExtensionTypeName,
  //       modifiedMembers: invalidatedExtensionTypeTable,
  //       directDependents: invalidatedExtensionType.dependents,
  //       invalidatedExtensions: &invalidatedExtensions,
  //       symbolTable: symbolTable
  //     )
  //     let finalInvalidatedExtensionType = newInvalidatedExtensionType._updatingDependents(newTransitiveDependents)
  //
  //     // Update
  //     namesToTypes[invalidatedExtensionTypeName] = finalInvalidatedExtensionType
  //
  //     // 3. Remove extension's introduced types
  //     // var potentialNominalTypes = []
  //     for (typeMember, _) in invalidatedExtensionTypeTable.typeMembersToDecls {
  //       let potentialNominalType = invalidatedExtensionTypeName.addingComponents([
  //         QualifiedTypeNameGlobalType.Component(
  //           name: typeMember,
  //           file: invalidatedExtension.fileRoot,
  //           module: invalidatedExtensionModule,
  //           symbolTable: symbolTable
  //         )
  //       ])
  //       guard let removedTypeState = namesToTypes.removeValue(forKey: potentialNominalType) else { continue }
  //       // Since the type goes missing, its extensions are invalidated
  //       for (_, removedTypeExtensions) in removedTypeState.boundExtensions {
  //         for (removedTypeExtension, _) in removedTypeExtensions {
  //           guard let oldState = extensionsToState.removeValue(forKey: removedTypeExtension) else {
  //             // TODO: Complain about non-upheld invariant
  //             fatalError("")
  //           }
  //           invalidatedExtensions.append(oldState)
  //         }
  //       }
  //       // TODO: Should destroy nested type's nested types, e.g.
  //       // ```swift
  //       // struct A { typealias B = A }
  //       // extension A.B {
  //       //  struct C {
  //       //    struct D {}
  //       //  }
  //       // }
  //       // extension A.B.C.D { struct E {} }
  //       // extension A { struct A {} }
  //       // ```
  //       // TODO: Check for correctrness
  //       // Remove all the dependents of the nested types (to be removed)
  //       let newDependents = _invalidateDependents__OLD(
  //         modifiedTypeName: modifiedTypeName,
  //         modifiedMembers: nil,
  //         directDependents: removedTypeState.dependents,
  //         invalidatedExtensions: &invalidatedExtensions,
  //         symbolTable: symbolTable
  //       )
  //       assert(
  //         newDependents == [],
  //         "[SwiftLexicalLookup] Internal error: `modifiedMembers == nil` should have removed all dependencies from type to be removed."
  //       )
  //     }
  //
  //   }
  //
  //   return newDependents
  // }
}

// MARK: Extension Binding

extension TypeDependencyGraph {
  func getGlobalNominalTypeReference(name: GlobalTypeName) -> GlobalNominalTypeRef? {
    namesToTypes[name].map({
      GlobalNominalTypeRef(qualifiedName: name, nominal: $0)
    })
  }

  /// Gets the final nominal-type reference with the given qualified name
  /// using the current graph.
  ///
  /// Useful for getting the final version of a nominal type after binding extensions.
  func getNominalTypeReference(name: GlobalTypeName) -> NominalTypeRef? {
    getGlobalNominalTypeReference(name: name).map(NominalTypeRef.init(globalReference:))
  }
}

extension TypeDependencyGraph {
  @_spi(_QualifiedLookupTests) public enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }
  // TODO: Consider if any early error returns break invariants (lead to an
  // invalid graph state)
  mutating func admitExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionDeclModule: ModuleName,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to rawResult: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencyTracker: DependencyTracker,
    configuredRegions: ConfiguredRegions?,
    symbolTable: borrowing SymbolTable
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
        (globalReference: GlobalNominalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
        TypeResolver.Failure
      >
    switch rawResult {
    case .success(let (extendedTypeName, mainDecl)):
      // TODO: Try to merge with cycleResult failures
      guard let extendedTypeRef: GlobalNominalTypeRef = getGlobalNominalTypeReference(name: extendedTypeName) else {
        return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: nil))
      }

      let cycleResult =
        _findFirstCycleWhenBinding(
          extensionDecl: extensionDecl,
          extensionMembers: mappedExtensionDecl.typeMap,
          to: extendedTypeName,
          extensionDependencies: dependencyTracker.dependencies
        ) as Result<GenericExtensionBindingCycle<GlobalTypeName>, CycleDetectionFailure>?

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

    // === Invalidate Dependents & Bind ===
    let invalidatedExtensions: [ExtensionState]
    // If there's no cycle, we may type members so we need to invalidate
    switch result {
    case .success(let (extendedTypeRef, _)):
      let extendedTypeName: GlobalTypeName = extendedTypeRef.name
      // Get the bound type
      guard let extendedType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) bound to type '\(extendedTypeName)', which isn't in the graph."
        )
      }

      var invalidatedExtensionsTmp = [ExtensionState]()
      //let newTypeDependents =
      _introspect(symbolTable: symbolTable, onlyLogIfCorrupted: true)
      _invalidateDependents(
        modifiedTypeName: extendedTypeName,
        modifiedMembers: mappedExtensionDecl.typeMap,
        modifiedExtensionModule: extensionDeclModule,
        invalidatedExtensions: &invalidatedExtensionsTmp,
        symbolTable: symbolTable
      )
      guard let invalidatedDependentsType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type '\(extendedTypeName.debugDescription)' unexpectedly removed while binding `\(extensionDecl._memberlessDescription)`."
        )
      }
      // Assert dependent extensions are valid
      for dependent in invalidatedDependentsType.dependents {
        // An extension must be `extensionDecl` (about to be regsitered) or
        // currently registered.
        assert(
          dependent.dependentExtension == extensionDecl || extensionsToState[dependent.dependentExtension] != nil,
          "[SwiftLexicalLookup] Internal error: Tried updating dependents of '\(extendedTypeName)' but found unregistered extension `\(dependent.dependentExtension._memberlessDescription)`."
        )
      }
      invalidatedExtensions = invalidatedExtensionsTmp

      // Bind to type
      guard
        let newExtendedType = invalidatedDependentsType._bindingExtension(
          mappedExtensionDecl,
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
      invalidatedExtensions = []
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
      extensionDecl: extensionDecl,
      // Only keep the qualified name (we store the main decl in `namesToTypes`)
      resolvedType: result.map(\.globalReference.name)
    )

    return .success((result, invalidatedExtensions))
  }
}

// MARK: Debugging

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
  public func _describeWithDiagnostics() -> (diagnostics: [Diagnostic], hasErrors: Bool) {
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
    var visitedTypes = [NominalTypeDeclSyntax: GlobalTypeName]()
    // Keep track of what types/maps we're expecting each bound extension to have.
    var extensionsToType = [
      Attached<ExtensionDeclSyntax>: (boundTypeName: GlobalTypeName, typeTable: TypeTable)
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
      let flattenedDependencies: [(GlobalTypeName, TypeMember, IntroducingExtensionOrMainDecl)] =
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

    return (diagnostics, hasErrors)
  }
}

extension TypeDependencyGraph {
  /// Gets the name and main decl of the type to which the extension is bound,
  /// or the binding the failure; returns `nil` for non-admitted extensions.
  func getExtensionResolvedType(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<
    (globalReference: GlobalNominalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>),
    BindingFailure
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
        globalReference: GlobalNominalTypeRef(qualifiedName: boundTypeName, nominal: boundType),
        mainDecl: boundType.mainDecl.declGroup
      )
    )
    // TODO: Remove
    // return Result.success((qualifiedName: boundTypeName, mainDecl: boundType.mainDecl.declGroup))
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

extension TypeDependencyGraph {
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
