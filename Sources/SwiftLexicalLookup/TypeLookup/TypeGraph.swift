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
///       However, we also keep track of nominal types because they might be introduced by
///       extensions and we crucially resolve to them and need a unique reference to each.
///
/// Complexity
/// ==========
///
/// Notation:
/// - `h`:   cost of hashing a `GlobalTypeName`; grows with nesting depth
///          Every "O(1)" map access is O(h), but `h` is typically at most 3.
/// - `s`:   # member declarations in one declaration group (`_groupTypeMembers` input)
/// - `m`:   # type members of one declaration group (`TypeTable` entries)
/// - `E_T`: # extensions bound to type `T`
/// - `D_T`: # dependents of type `T`
/// - `d`:   # dependencies of one extension / `DependencyTracker`
///
/// Accesses:
/// 1. Type -> extensions, O(E_T)
///    For qualified lookup, which must see every declaration group of `T`.
/// 2. Extension -> state, O(h)
///    To know if an extension is already admitted; called once per extension
///    binding request, so it must not depend on graph size.
/// 3. Extension -> dependencies, O(d)
///    For cycle detection and for unregistering on removal.
/// 4. Type -> dependents, O(D_T)
///    For eviction when an extension adds/removes a type member of `T`.
/// 5. Extension -> resolved type, O(h)
///    Lookup within an extension almost always first resolves the extended
///    type so we can look for its members, e.g.
///    ```swift
///    struct A { struct B {} }
///    extension A {
///      func f(_: B) // <- Must quickly find that `A>B` is a valid member.
///    }
///    ```
///
/// Operations:
/// 1. `admitType`: O(s + h)
///    Groups the main declaration's members once; one map insert.
/// 2. `findMemberType`: O(E_T + d); O(d) if repeated with the same tracker
///    Scans the main declaration and every bound extension of the base type
///    (bucketed by file/module for shadowing), then de-duplicates against the
///    tracker with a linear scan (`d` is small). Local base types instead
///    regroup their members on every call, O(s).
/// 3. `getExtensionResolvedType`, `updateNominalTypeReference`: O(h)
///    Two map lookups.
/// 4. `admitExtension` (without eviction): O(s + C + E_T + Σ D_T)
///    - O(s): groups the extension's members.
///    - C: cycle detection; DFS over dependency *paths* without a visited set,
///      so exponential in the worst case (shared sub-chains are re-walked)
///      but linear in practice, since dependency chains are short.
///    - O(E_T): binding copies `T`'s `boundExtensions` (copy-on-write, since
///      the old value is still in `namesToTypes`).
///    - O(Σ D_T) over each dependency's type: duplicate check plus
///      copy-on-write of `dependents`.
/// 5. Eviction (`_evictDependents` on `T` with `k` conflicting dependents):
///    O(k · D_T) locally plus one `_evictExtension` per evicted extension
///    Each pop rescans `dependents`. An unbind costs O(m · h + Σ D_T + E_T):
///    it unbinds each member (recursing into nested types) and removes
///    itself from the dependents of each dependency. The cascade is
///    transitive, and evicted extensions are re-admitted later at full
///    admission cost, so one extension may be evicted repeatedly.
/// 6. Debug builds: every checked wrapper (`_x` -> `__x`) runs `_introspect`,
///    which is O(graph size), at each recursion level, so cascades become
///    quadratic.
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
  ///
  /// Invariants (see `TypeGraph.md` > Implementation):
  /// - *Registered file roots*: `symbolTable.getFileInfo(type.mainDecl.fileRoot) != nil`.
  /// - *Nested types have parents*: if `name.base != nil`, then `type.mainDecl` is in
  ///   the type table of either:
  ///   a. `namesToTypes[name.base!]?.mainDeclMembers` for the parent main declaration, xor
  ///   b. `namesToTypes[name.base!]?.boundExtensions[module]?[extensionDecl]` for
  ///      the parent extension `extensionDecl`.
  private(set) var namesToTypes: [TypeGraph.GlobalTypeName: NominalType]
  /// Invariant (see `TypeGraph.md` > Implementation):
  /// - *Registered file roots*: `symbolTable.getFileInfo(extensionDecl.fileRoot) != nil`.
  @_spi(_QualifiedLookupTests)
  public private(set) var extensionsToState: [Attached<ExtensionDeclSyntax>: ExtensionState]

  // TODO: Remove
  var logPrefix: [String] = [String]()

  init() {
    namesToTypes = [:]
    extensionsToState = [:]
  }

}

// MARK: TypeGraph.NominalType

extension TypeGraph {
  @_spi(_QualifiedLookupTests)
  public struct NominalType {
    /// Keeps track of mutations to assert data didn't change between calls
    internal private(set) var version = 0

    /// Invariant (see `TypeGraph.md` > Implementation):
    /// - *No readmission*: no other type in `TypeGraph/namesToTypes` has the
    ///   same `mainDecl`.
    fileprivate let mainDecl: Attached<NominalTypeDeclSyntax>
    /// The type members of `mainDecl`
    fileprivate let mainDeclMembers: TypeTable

    /// Invariant (see `TypeGraph.md` > Implementation):
    /// - *Bound extensions*: for the type named `typeName`,
    ///   `boundExtensions[module]?[extensionDecl] != nil` if and only if
    ///   `TypeGraph/extensionsToState[extensionDecl]?.resolvedType == .success(typeName)`,
    ///   where `module` is `extensionDecl`'s module.
    fileprivate(set) var boundExtensions: [ModuleName: [Attached<ExtensionDeclSyntax>: TypeTable]]

    /// Extensions dependending on qualified lookup of `member` on this type.
    ///
    /// This property is part of `NominalType` and not `ExtensionState` because
    /// any extension binding to this nominal type should see that it's evicting
    /// other extensions.
    ///
    /// Invariant (see `TypeGraph.md` > Implementation):
    /// - *Dependencies and dependents match*: for the type named `typeName`,
    ///   `dependents` contains `TypeDependent(memberType: member, dependentExtension: extensionDecl)`
    ///   if and only if
    ///   `TypeGraph/extensionsToState[extensionDecl]?.dependencies` contains a
    ///   dependency with `baseTypeName == typeName` on `member`.
    fileprivate(set) var dependents: [TypeDependent]

    init(mainDecl: Attached<NominalTypeDeclSyntax>, mainDeclMembers: TypeTable) {
      self.mainDecl = mainDecl
      self.mainDeclMembers = mainDeclMembers
      self.boundExtensions = [:]
      self.dependents = []
    }
  }
}

// MARK: TypeGraph.IntroducingExtensionOrMainDecl

@_spi(_QualifiedLookupTests)
public typealias IntroducingExtensionOrMainDecl = Attached<ExtensionDeclSyntax>?

// MARK: TypeGraph.TypeTable

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

// MARK: TypeGraph.TypeDependent

extension TypeGraph {
  struct TypeDependent: Sendable, Hashable, CustomDebugStringConvertible {
    let memberType: Identifier
    let dependentExtension: Attached<ExtensionDeclSyntax>

    public var debugDescription: String {
      "Self > '\(memberType.name)' => `\(dependentExtension.node._memberlessDescription)`"
    }
  }
}

// MARK: TypeGraph.ExtensionState

extension TypeGraph {
  /// The state of an admitted extension: what type it resolved to and the
  /// dependencies for that resolution result.
  ///
  /// Note: Extension state uses `GlobalTypeName` instead of `GlobalTypeRef`
  /// since the type graph already stores information about types in a
  /// different property.
  @_spi(_QualifiedLookupTests)
  public struct ExtensionState: Sendable {
    // See `ExtensionDependency` docstring for why these properties are *immutable*.

    /// Invariants (see `TypeGraph.md` > Implementation), for the extension `extensionDecl`:
    /// - *Dependencies and dependents match*: See `NominalType/dependents`.
    /// - *Extensions depend on type members*: each member's `decls` equal,
    ///   regardless of order, the declarations of that member in the base
    ///   type's main declaration and bound extensions.
    /// - *No cycles*: following the introducing extensions of `decls`
    ///   recursively never reaches a member with an identifier that
    ///   `extensionDecl` introduces into the resolved type.
    /// - *Extensions depend on type members*: there's at most one dependency
    ///   per base type.
    @_spi(_QualifiedLookupTests) public let dependencies: [ExtensionDependency]
    /// Invariant (see `TypeGraph.md` > Implementation):
    /// - *Bound extensions*: `resolvedType == .success(typeName)` if and only if
    ///   `TypeGraph/namesToTypes[typeName]?.boundExtensions[module]?[extensionDecl] != nil`,
    ///   where `module` is `extensionDecl`'s module.
    @_spi(_QualifiedLookupTests) public let resolvedType: Result<TypeGraph.GlobalTypeName, TypeResolver.Failure>

    @_spi(_QualifiedLookupTests) public init(
      _uncheckedDependencies dependencies: [ExtensionDependency],
      resolvedType: Result<TypeGraph.GlobalTypeName, TypeResolver.Failure>
    ) {
      self.dependencies = dependencies
      self.resolvedType = resolvedType
    }
  }
}

// MARK: TypeGraph.ExtensionDependency

extension TypeGraph {
  /// An extension dependency stores cached information such as what declaration
  /// group the given member was introduced. Normally, we don't store cached
  /// information for types stored in the `TypeGraph` since we must
  /// later update a lot of cached data when we bind/evict an extension.
  /// However, extension dependencies are different because if the dependency
  /// type changes, we necessarily have to evict and recompute the extensions.
  /// Hence, extension dependencies should be created at extension binding and not
  /// be modified (we simply evict the extension and destroy its state along
  /// with any dependencies).
  @_spi(_QualifiedLookupTests)
  public struct ExtensionDependency: Sendable {
    /// The base type on whose members we depend.
    fileprivate let baseTypeName: TypeGraph.GlobalTypeName

    /// The type members of base type on which we depend, in lookup order.
    ///
    /// This is an ordered list rather than a `[Identifier: ...]` dictionary,
    /// because want a deterministic order when evicting extensions to
    /// uphold `SymbolTable`'s determinism requirement.
    ///
    /// Invariant: `members` is nonempty
    fileprivate let members: [(name: Identifier, decls: [Member])]

    /// Precondition: `members` must be nonempty
    @_spi(_QualifiedLookupTests)
    public init(
      dependencyTypeName: TypeGraph.GlobalTypeName,
      members: [(name: Identifier, decls: [Member])]
    ) {
      TypeGraph.internalAssert(!members.isEmpty, .emptyDependencyMembers)

      self.baseTypeName = dependencyTypeName
      self.members = members
    }
  }
}

// MARK: TypeGraph.ExtensionDependency.Member

extension TypeGraph.ExtensionDependency {
  /// One declaration contributing to a dependency's member, together with
  /// the declaration group that introduced it.
  ///
  /// A member can have more than one contributing declaration when it's
  /// ambiguous. For instance, a type alias declared both in a type's own
  /// body and again in one of its extensions.
  @_spi(_QualifiedLookupTests)
  public struct Member: Hashable, Sendable {
    /// The extension that introduced `typeDecl`, or `nil` if `typeDecl`
    /// was declared in the nominal-type declaration.
    ///
    /// Note: We care about extensions and not nominal-type declarations,
    /// because cycles can only form between extensions.
    @_spi(_QualifiedLookupTests)
    public let introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl
    @_spi(_QualifiedLookupTests)
    public let typeDecl: Attached<TypeDeclSyntax>

    @_spi(_QualifiedLookupTests)
    public init(
      introducingExtensionOrMainDecl: IntroducingExtensionOrMainDecl,
      typeDecl: Attached<TypeDeclSyntax>
    ) {
      self.introducingExtensionOrMainDecl = introducingExtensionOrMainDecl
      self.typeDecl = typeDecl
    }
  }
}

// MARK: TypeGraph.QualifiedLookupDependency

extension TypeGraph {
  // TODO: Can we merge with other dependency types?
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
}

extension TypeGraph.ExtensionState {
  // TODO: Explain why necessary to have a complex init
  fileprivate init(
    dependencies: [TypeGraph.QualifiedLookupDependency],
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
      // Note: We can assign directly because ``DependencyTracker/dependencies`` guarantees
      // that type/member-name pairs have just a single entry.
      groupedDependencies[_key: dependency.extendedTypeName, default: []][_key: dependency.member, default: []]
        .append(
          contentsOf: dependency.typeDecls
        )
    }

    // Map to `ExtensionDependency`
    // Satisfies invariant of one dependency per type
    let orderedGroupedDependencies: [TypeGraph.ExtensionDependency] = groupedDependencies.map({ (typeName, members) in
      // Note: `members` is nonempty by construction, satisfying the `ExtensionDependency.init` precondition.
      TypeGraph.ExtensionDependency(
        dependencyTypeName: typeName,
        members: members.map({ (name, typeDecls) in
          (
            name: name,
            decls: typeDecls.map({ typeDecl in
              TypeGraph.ExtensionDependency.Member(
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

// MARK: TypeGraph.DependencyTracker

extension TypeGraph {
  @_spi(_QualifiedLookupTests)
  public struct DependencyTracker {
    /// Invariant: There's at most one dependency for the same type/member-name pair.
    @_spi(_QualifiedLookupTests)
    public private(set) var dependencies: [QualifiedLookupDependency]

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
}

// MARK: Invariants

extension TypeGraph {
  /// The first cases are spec invariants (see `_firstInvariantViolation`); the
  /// rest are cheap, targeted mutation-primitive preconditions that pinpoint the failing caller.
  @_spi(_QualifiedLookupTests)
  public enum GraphFailure {
    /// A nominal-type declaration is admitted under more than one name.
    case duplicateMainDecl
    /// An admitted `Attached<NominalTypeDeclSyntax>` or `Attached<ExtensionDeclSyntax>`
    /// has a file root not registered in the SymbolTable. I.e., `SymbolTable/getFileInfo`
    /// returns nil.
    case noFileInfo
    /// A resolved extension points to a non-admitted type
    case danglingExtension
    /// An extension resolved to a type that doesn't bind it (under the
    /// extension's module).
    case unboundExtension
    /// A type binds an extension whose state doesn't resolve to that type.
    case misboundExtension
    /// An extension has more than one dependency on the same base type.
    case duplicateDependency
    /// A dependency points to a non-admitted type
    case danglingDependency
    /// An extension depends on a type's member, but the type doesn't record
    /// the extension as a dependent.
    case missingDependent
    /// A type records a dependent extension that isn't admitted or doesn't
    /// depend on that member.
    case missingDependency
    /// A dependency's declarations don't match the declarations the type's
    /// main declaration and bound extensions currently introduce for that
    /// member.
    case staleDependency
    /// A nested type isn't a member of its parent type's main declaration or
    /// bound extensions (or the parent isn't admitted).
    case parentlessType
    /// A bound extension's recursive dependencies rely on a member that the
    /// extension introduces.
    case dependencyCycle

    /// In `_addType`, the given type is already admitted.
    case typeReadmission
    /// In `_addType`, the given type declaration isn't in the `SymbolTable`.
    case unknownTypeFile
    /// In `_addType`, the base declaration group is invalid. One of the
    /// following happened:
    /// 1. We have a nested name but `baseDeclGroup == nil`
    /// 2. The base declaratin group is a nominal type that's not admitted.
    /// 3. The base declaration group is an extension that's not admitted
    ///    or not bound to the base type name.
    case invalidBaseDeclGroup

    /// In `_removeType`, the given type isn't admitted.
    case invalidType
    /// In `_removeType`, the given type still has bound extensions.
    case remainingTypeExtensions
    /// In `_removeType`, the given type still has dependents.
    case remainingTypeDependents
    /// In `_removeType`, the given type still has admitted nominal member types.
    case remainingTypeMembers
    /// In `_removeType`, the extracted file info for `nominalDecl` doesn't match
    /// the type's main decl.
    case invalidFileInfo

    /// In `_addExtension`, the given extension is already admitted.
    case extensionReadmission
    /// In `_addExtension`, the given extension declaration isn't in the
    /// `SymbolTable`.
    case unknownExtensionFile
    /// In `_addExtension`, the extension's resolved type isn't admitted.
    case invalidExtendedType
    /// In `_addExtension`, `QualifiedLookupDependency/extendedTypeName` refers to an unadmitted type.
    case invalidDependencyType

    /// In `_removeExtension`, the extension isn't admitted.
    case invalidExtension
    /// In `_removeExtension`, the given extension is already non-admitted.
    case extensionReeviction
    /// In `_removeExtension`, the given extension's type members still have dependents.
    case remainingExtensionDependents
    /// In `_removeExtension`, the given extension still has admitted nominal member types.
    case remainingExtensionMembers

    /// In `_evictDependents`, `dependencyTypeName` isn't admitted.
    case evictedDependencyType

    /// In `_CycleDetectorFrame/push`, the frame pushes an extension
    /// right after a descent without advancing the index.
    ///
    /// Explanation: Without advancing, we'll infinitely descend into the same decl.
    case cycleDetectorRedescent

    // In `ExtensionDependency.init(dependencyTypeName:members:)`, the given
    // `members` is empty.
    case emptyDependencyMembers
  }

  private static func internalAssert(
    _ condition: @autoclosure () -> Bool,
    _ error: GraphFailure,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    #if DEBUG
    if !condition() {
      Self.internalError(error, resultType: Never.self, file: file, line: line)
    }
    #endif
  }

  private static func internalError<T>(
    _ error: GraphFailure,
    resultType: T.Type = T.self,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    fatalError("[SwiftLexicalLookup] Internal error: \(error)", file: file, line: line)
  }
}

extension TypeGraph {
  /// Crashes in DEBUG if the graph breaks an invariant (see
  /// `_firstInvariantViolation`).
  fileprivate func _assertInvariants(
    symbolTable: SymbolTable,
    file: StaticString = #file,
    line: UInt = #line,
    function: StaticString = #function
  ) {
    #if DEBUG
    if let violation = _firstInvariantViolation(symbolTable: symbolTable) {
      Self.internalError(violation, resultType: Never.self, file: file, line: line)
    }
    #endif
  }

  /// Returns the first broken invariant (see TypeGraph.md), or `nil` if the
  /// graph is valid.
  ///
  /// Invariants are checked one at a time across the whole graph, so the
  /// returned failure doesn't depend on dictionary order. Later checks assume
  /// earlier ones passed.
  @_spi(_QualifiedLookupTests)
  public func _firstInvariantViolation(symbolTable: SymbolTable) -> GraphFailure? {
    // Each main decl is admitted under one name
    var mainDecls = Set<Attached<NominalTypeDeclSyntax>>()
    for type in namesToTypes.values {
      guard mainDecls.insert(type.mainDecl).inserted else { return .duplicateMainDecl }
    }

    // Admitted types and extensions have registered file roots
    for type in namesToTypes.values {
      guard symbolTable.getFileInfo(type.mainDecl.fileRoot) != nil else { return .noFileInfo }
    }
    for extensionDecl in extensionsToState.keys {
      guard symbolTable.getFileInfo(extensionDecl.fileRoot) != nil else { return .noFileInfo }
    }

    // Extensions resolve to a type iff that type binds them
    for (extensionDecl, state) in extensionsToState {
      guard case .success(let typeName) = state.resolvedType else { continue }
      guard let type = namesToTypes[typeName] else { return .danglingExtension }
      // Force-unwrap by file-root test above.
      let module = symbolTable.getFileInfo(extensionDecl.fileRoot)!.module
      guard type.boundExtensions[module]?[extensionDecl] != nil else { return .unboundExtension }
    }
    for (typeName, type) in namesToTypes {
      for extensionDecl in type.boundExtensions.values.flatMap(\.keys) {
        guard case .success(typeName) = extensionsToState[extensionDecl]?.resolvedType else {
          return .misboundExtension
        }
      }
    }

    // Each extension has at most one dependency per base type
    for state in extensionsToState.values {
      var baseTypeNames = Set<GlobalTypeName>()
      for dependency in state.dependencies {
        guard baseTypeNames.insert(dependency.baseTypeName).inserted else { return .duplicateDependency }
      }
    }

    // Dependencies and dependents match
    for (extensionDecl, state) in extensionsToState {
      for dependency in state.dependencies {
        guard let type = namesToTypes[dependency.baseTypeName] else { return .danglingDependency }
        for member in dependency.members {
          let dependent = TypeDependent(memberType: member.name, dependentExtension: extensionDecl)
          guard type.dependents.contains(dependent) else { return .missingDependent }
        }
      }
    }
    for (typeName, type) in namesToTypes {
      for dependent in type.dependents {
        let dependsOnMember = extensionsToState[dependent.dependentExtension]?.dependencies.contains(where: {
          $0.baseTypeName == typeName && $0.members.contains(where: { $0.name == dependent.memberType })
        })
        guard dependsOnMember == true else { return .missingDependency }
      }
    }

    // Dependencies match the type members in the graph
    for state in extensionsToState.values {
      for dependency in state.dependencies {
        // Force-unwrap because we checked `dependency.baseTypeName`
        // is valid in the previous step.
        let type = namesToTypes[dependency.baseTypeName]!
        for member in dependency.members {
          var currentDecls = (type.mainDeclMembers.typeMembersToDecls[member.name] ?? []).map({
            ExtensionDependency.Member(introducingExtensionOrMainDecl: nil, typeDecl: $0)
          })
          for (extensionDecl, typeTable) in type.boundExtensions.values.joined() {
            currentDecls += (typeTable.typeMembersToDecls[member.name] ?? []).map({
              ExtensionDependency.Member(introducingExtensionOrMainDecl: extensionDecl, typeDecl: $0)
            })
          }
          // Lookup order depends on where the lookup happened, so compare
          // the declarations regardless of order.
          guard member.decls.count == currentDecls.count, Set(member.decls) == Set(currentDecls) else {
            return .staleDependency
          }
        }
      }
    }

    // Nested types are members of their parent's main decl or bound extensions
    //
    // Also, collect parented/nested types for next check.
    var parentedTypes = Set<GlobalTypeName>()
    for (typeName, type) in namesToTypes {
      // Collect the type's main-type & extension declaration groups and type tables.
      let declGroups =
        [(declGroup: Attached<DeclGroupSyntaxType>(type.mainDecl), typeTable: type.mainDeclMembers)]
        + type.boundExtensions.values.joined().map({
          (declGroup: Attached<DeclGroupSyntaxType>($0.key), typeTable: $0.value)
        })
      for (declGroup, typeTable) in declGroups {
        // Force-unwrap by file-root test above.
        let declGroupFileInfo = symbolTable.getFileInfo(declGroup.fileRoot)!
        for (memberName, memberDecls) in typeTable.typeMembersToDecls {
          let memberTypeName = typeName.addingComponent(
            GlobalTypeName.Component(
              name: memberName,
              file: declGroup.fileRoot,
              fileInfo: declGroupFileInfo,
              symbolTable: symbolTable
            )
          )
          guard
            let memberType = namesToTypes[memberTypeName],
            memberDecls.contains(where: { $0.as(NominalTypeDeclSyntax.self) == memberType.mainDecl })
          else { continue }
          parentedTypes.insert(memberTypeName)
        }
      }
    }
    // Diagnose parentless nested types.
    for typeName in namesToTypes.keys where typeName.base != nil {
      guard parentedTypes.contains(typeName) else { return .parentlessType }
    }

    // No bound extension recursively depends on a member it introduces
    for (extensionDecl, state) in extensionsToState {
      // Get the extended-type name and the extension-decl module
      guard case .success(let typeName) = state.resolvedType else { continue }
      // Force-unwrap by file-root and bound-extension checks above.
      let extensionModule = symbolTable.getFileInfo(extensionDecl.fileRoot)!.module
      let cycle = _firstCycle(
        extensionDecl: extensionDecl,
        extensionState: state,
        // Force-unwrap by `dependency.baseTypeName` check above
        extensionMembers: namesToTypes[typeName]!.boundExtensions[extensionModule]![extensionDecl]!
      )
      guard cycle == nil else { return .dependencyCycle }
    }

    return nil
  }
}

// MARK: Mutation Primitives

extension TypeGraph {
  /// Add the given extension state and register its dependents.
  ///
  /// Preconditions:
  /// 1. The graph is valid
  /// 2. If bound, the extended type is valid and has no dependents on the introduced
  ///    members
  /// 3. The given dependencies reference valid types
  private mutating func _addExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionMembers: TypeTable,
    extensionModule: ModuleName,
    dependencies: [QualifiedLookupDependency],
    resolvedType: Result<GlobalTypeName, TypeResolver.Failure>,
    symbolTable: SymbolTable
  ) {
    // Asserts
    _assertInvariants(symbolTable: symbolTable)
    // _assertInvariants will trap if:
    // 1. The extension, once bound, recursively depends on a member it introduces (`.dependencyCycle`).
    // 2. `dependencies` don't match the graph's type members, or another extension depends on a member
    //    the extension introduces (`.staleDependency`).
    defer { _assertInvariants(symbolTable: symbolTable) }
    // Assert extension isn't already admitted
    Self.internalAssert(extensionsToState[extensionDecl] == nil, .extensionReadmission)
    // Assert extension is in symbol table.
    Self.internalAssert(symbolTable.getFileInfo(extensionDecl.fileRoot) != nil, .unknownExtensionFile)
    // Assert type has no conflicting dependents
    if case .success(let typeName) = resolvedType {
      Self.internalAssert(
        namesToTypes[typeName, default: Self.internalError(.invalidExtendedType)].dependents.allSatisfy({
          dependent in
          dependent.dependentExtension != extensionDecl
            || extensionMembers.typeMembersToDecls[dependent.memberType] == nil
        }),
        .remainingExtensionDependents
      )
    }

    // Save extension
    let extensionState = ExtensionState(
      dependencies: dependencies,
      resolvedType: resolvedType
    )
    extensionsToState[extensionDecl] = extensionState

    // Set dependents to match dependencies
    for dependency in extensionState.dependencies {
      // Collect dependents
      let dependents = dependency.members.map({ member in
        TypeDependent(
          memberType: member.name,
          dependentExtension: extensionDecl
        )
      })
      // Add dependents
      namesToTypes[dependency.baseTypeName, default: Self.internalError(.invalidDependencyType)].dependents.append(
        contentsOf: dependents
      )
    }

    // Bind to type, if resolved
    if case .success(let typeName) = resolvedType {
      namesToTypes[typeName, default: Self.internalError(.invalidExtendedType)]
        .boundExtensions[
          extensionModule,
          default: [:]
        ][extensionDecl] = extensionMembers
    }
  }

  /// Removes extension maintaining all invariants.
  /// The extension must be bound, its type members must have no
  /// dependents and must be unregistered.
  private mutating func _removeExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionFileInfo: FileInfo,
    symbolTable: SymbolTable
  ) {
    // Asserts
    _assertInvariants(symbolTable: symbolTable)
    // _assertInvariants only traps if this primitive is wrong; the asserts below cover the preconditions.
    defer { _assertInvariants(symbolTable: symbolTable) }

    // Remove state
    let extensionState = extensionsToState.removeValue(forKey: extensionDecl) ?? Self.internalError(.invalidExtension)

    // Ensure we don't have dependents/members if bound
    if case .success(let extendedTypeName) = extensionState.resolvedType {
      // TODO: Shouldn't it suffice to check that we simply have no members (if we keep assett)
      // (Because if there are no registered members, we can't have any dependents on our members -- vacuously)
      //
      // Answer: Maybe it's because type member != nominal type (i.e., someone cud still depend on our type aliases,
      // even if we've evicted all member nominal types)

      // Get the type
      let extendedType = namesToTypes[extendedTypeName, default: Self.internalError(.danglingExtension)]

      // Check for dependents
      //
      // Get the extension members and the type with the extension unbound
      let extensionMembers = extendedType.boundExtensions[extensionFileInfo.module, default: [:]][
        extensionDecl,
        default: Self.internalError(.extensionReeviction) as TypeTable
      ]
      // Ensure no one depends on our members
      Self.internalAssert(
        extendedType.dependents.allSatisfy({
          extensionMembers.typeMembersToDecls[$0.memberType] == nil
        }),
        .remainingExtensionDependents
      )
      // Ensure all members are unregistered (only happens with nominal-type declarations)
      Self.internalAssert(
        _firstRegisteredMemberName(
          declGroup: Attached<DeclGroupSyntaxType>(extensionDecl),
          declGroupFileInfo: extensionFileInfo,
          declGroupTypeName: extendedTypeName,
          members: extensionMembers,
          symbolTable: symbolTable
        ) == nil,
        .remainingExtensionMembers
      )
    }

    // Remove dependents
    for dependency in extensionState.dependencies {
      // Get dependency type
      namesToTypes[dependency.baseTypeName, default: Self.internalError(.danglingDependency)]
        .dependents.removeAll(where: { dependent in
          dependent.dependentExtension == extensionDecl
        })
    }

    // Unbind from type, if resolved
    if case .success(let typeName) = extensionState.resolvedType {
      namesToTypes[typeName, default: Self.internalError(.invalidExtendedType)]
        .boundExtensions[
          extensionFileInfo.module,
          default: [:]
        ][extensionDecl] = nil
    }
  }
}

extension TypeGraph {
  fileprivate mutating func _addType(
    mainDecl: Attached<NominalTypeDeclSyntax>,
    typeMembers: TypeTable,
    typeName: TypeGraph.GlobalTypeName,
    symbolTable: SymbolTable
  ) -> NominalType {
    // Asserts
    _assertInvariants(symbolTable: symbolTable)
    // _assertInvariants will trap if:
    // 1. The type is nested but parentless (`.parentlessType`).
    // 2. `mainDecl` is already admitted under a different name (`.duplicateMainDecl`).
    defer { _assertInvariants(symbolTable: symbolTable) }
    // Assert we're not readmitting
    Self.internalAssert(namesToTypes[typeName] == nil, .typeReadmission)
    // Assert file info exists
    Self.internalAssert(symbolTable.getFileInfo(mainDecl.fileRoot) != nil, .unknownTypeFile)

    // Create a new type
    let type = NominalType(
      mainDecl: mainDecl,
      mainDeclMembers: typeMembers
    )

    namesToTypes[typeName] = type

    return type
  }

  /// Removes the given type. Requires that the type have no bound extensions,
  /// no dependents, and that `nominalDecl` matches the expected
  private mutating func _removeType(
    nominalDeclFileInfo: FileInfo,
    typeName: GlobalTypeName,
    symbolTable: SymbolTable
  ) {
    // Get the state
    let type = namesToTypes[typeName, default: Self.internalError(.invalidType)]

    // Asserts
    _assertInvariants(symbolTable: symbolTable)
    // _assertInvariants only traps if this primitive is wrong; the asserts below cover the preconditions.
    defer { _assertInvariants(symbolTable: symbolTable) }
    // Ensure we have no bound extensions (if we have redeclarations,
    // the type is ambiguous so not extensions should have resolved to
    // us; if we have just one main declaration, we'll remove the type and
    // lingering extensions be bound to an unregistered type)
    //
    // Here, we check that each module has an empty list.
    Self.internalAssert(
      type.boundExtensions.allSatisfy(\.value.isEmpty),
      .remainingTypeExtensions
    )
    // Ensure we have no dependents (similar reasoning with above)
    Self.internalAssert(
      type.dependents.isEmpty,
      .remainingTypeDependents
    )

    // Ensure we have no member types (if originally bound)
    //
    // Since we checked there are no bound extensions, the only
    // place where we could get a member type is the main decl.
    //
    // Note: If there were redeclarations, then we shouldn't have been able to
    // register any member types (checked by ``admitType``).
    // if type.mainDecl == nominalDecl {
    // Since the new type is `nil`, the decl used to be `type.mainDecl`
    let memberTypeName: GlobalTypeName? = _firstRegisteredMemberName(
      declGroup: Attached<DeclGroupSyntaxType>(type.mainDecl),
      declGroupFileInfo: nominalDeclFileInfo,
      declGroupTypeName: typeName,
      members: type.mainDeclMembers,
      symbolTable: symbolTable
    )
    Self.internalAssert(memberTypeName == nil, .remainingTypeMembers)

    namesToTypes[typeName] = nil
  }

}

// MARK: - Cycle Detection

extension TypeGraph {
  /// Minimal data structure for DFS on extension dependencies
  fileprivate struct _CycleDetectorFrame {
    /// Identifies a specific dependency type declaration as:
    /// ```
    /// state.dependencies[index.dependency]
    ///       .members[index.member]
    ///       .decls[index.decl]
    /// ```
    typealias Index = (dependency: Int, member: Int, decl: Int)

    let firstExtensionState: ExtensionState
    /// The path to currently visited extension dependency. Note: `idx`
    /// is initialized to `(0,0,0)`.
    ///
    /// Invariant: For all extensions, `extensionsToState[ext]?.dependents`
    /// exists and is nonempty.
    var stack: [(ext: Attached<ExtensionDeclSyntax>, idx: Index)]
    private var descended: Bool = false
  }
}

extension TypeGraph._CycleDetectorFrame {
  fileprivate mutating func advance(newIndex: Index?) {
    if let newIndex {
      stack[stack.count - 1].idx = newIndex
      descended = false
    } else {
      stack.removeLast()
      descended = true
    }
  }
  fileprivate mutating func push(_ extensionDecl: Attached<ExtensionDeclSyntax>, index: Index) {
    TypeGraph.internalAssert(!descended, .cycleDetectorRedescent)
    stack.append((extensionDecl, index))
  }

  /// Finds next dependency member given the `descended` and `stack` state.
  ///
  /// Returns: `nil` if no items are left, `Optional(nil)` if we just finished a descent and
  /// need to skip, otherwise returns the next dependency member.
  fileprivate mutating func nextDependencyMember(
    graph: borrowing TypeGraph
  ) -> (
    index: Index?,
    dependency: TypeGraph.ExtensionDependency, memberID: Identifier,
    isFirstDecl: Bool, decl: TypeGraph.ExtensionDependency.Member?
  )?? {
    guard let (extensionDecl, index) = stack.last else { return nil }

    // Use `firstExtensionState` for first stack entry, if provided
    // Pushed extensions introduce a dependency's declaration, so they must be admitted
    let state =
      stack.count == 1
      ? firstExtensionState
      : graph.extensionsToState[extensionDecl, default: TypeGraph.internalError(.staleDependency)]
    // Note: The initial access at index `(0,0,0)` is safe because `members` is
    // nonempty according to `ExtensionDependency`, and `dependencies`
    // is nonempty by the `stack` invariant. However, `decls` can be empty
    // (we may depend on the type declarations being empty)
    let dependency = state.dependencies[index.dependency]
    let member = dependency.members[index.member]
    let decl = member.decls.isEmpty ? nil : member.decls[index.decl]

    let newIndex: Index?
    if index.decl + 1 < member.decls.count {
      // If available, move to next decl in the member
      newIndex = (index.dependency, index.member, index.decl + 1)
    } else if index.member + 1 < dependency.members.count {
      // Else, move to next member in the dependency
      newIndex = (index.dependency, index.member + 1, 0)
    } else if index.dependency + 1 < state.dependencies.count {
      // Else, move to next dependency in the extension
      newIndex = (index.dependency + 1, 0, 0)
    } else {
      // Otherwise, we're done with the extension
      newIndex = nil
    }

    // Advance we descended and just came back (we've already visited `memberDecl`)
    guard !descended else {
      advance(newIndex: newIndex)
      return Optional(nil)
    }

    return (newIndex, dependency, member.name, index.decl == 0, decl)
  }

  fileprivate consuming func toCycle(
    graph: borrowing TypeGraph
  ) -> TypeResolver.ExtensionCycle {
    var dependencyPath: [TypeResolver.ExtensionCycleElement] = []
    // First extension is entrypoint; it only introduces the next element
    var previousState = firstExtensionState
    var previousIndex = stack[0].idx
    for (ext, idx) in stack.dropFirst() {
      // Extensions introducing a dependency's declarations must be admitted and bound
      let state = graph.extensionsToState[ext, default: TypeGraph.internalError(.staleDependency)]
      guard case .success(let extendedType) = state.resolvedType else {
        TypeGraph.internalError(.staleDependency, resultType: Never.self)
      }
      // The previous extension's current decl introduced this extension (so it exists)
      let introducingDecl = previousState.dependencies[previousIndex.dependency].members[previousIndex.member]
        .decls[previousIndex.decl]
      dependencyPath.append(
        TypeResolver.ExtensionCycleElement(
          introducingTypeDecl: introducingDecl.typeDecl.node,
          extensionDecl: ext.node,
          boundType: graph.getGlobalNominalTypeReference(name: extendedType)
            ?? TypeGraph.internalError(.danglingExtension)
        )
      )
      (previousState, previousIndex) = (state, idx)
    }

    return TypeResolver.ExtensionCycle(
      dependencyPath: dependencyPath,
      // The last extension's current member conflicts with the entrypoint's members
      dependencyMember: previousState.dependencies[previousIndex.dependency].members[previousIndex.member].name
    )
  }
}

extension TypeGraph {
  /// Returns the dependency path through which `extensionDecl` with
  /// state `extensionState`, recursively depends on one of `extensionMembers`.
  /// Otherwise, returns `nil` (*No cycles*, see `TypeGraph.md` > Implementation).
  ///
  /// Used both before binding an extension (`admitExtension`) and to check
  /// bound extensions (`_firstInvariantViolation`).
  ///
  /// Parameters:
  /// - extensionState: The state to use for the given extension (admitted or
  ///   about to be admitted).
  /// Preconditions:
  /// - Every extension introducing a member of `dependencies` recursively,
  ///   is admitted and bound (*Extensions depend on type members*)
  fileprivate func _firstCycle(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionState: ExtensionState,
    extensionMembers: TypeTable,
  ) -> TypeResolver.ExtensionCycle? {
    // Extensions without dependencies or that aren't bound, don't introduce cycles
    guard !extensionState.dependencies.isEmpty,
      case .success(let extendedTypeName) = extensionState.resolvedType
    else {
      return nil
    }

    // Track path to each dependency
    // We checked `!dependencies.isEmpty` above, so the index `(0,0,0)` is valid.
    var frame = _CycleDetectorFrame(firstExtensionState: extensionState, stack: [(extensionDecl, (0, 0, 0))])
    var visitedExtensions: Set<Attached<ExtensionDeclSyntax>> = [extensionDecl]

    // Visit next transitive dependency
    while let next = frame.nextDependencyMember(
      graph: self
    ) {
      // Skip if `nil` (i.e., when we just finished a descent and we had to call `frame.advance`)
      guard let (newIndex, dependency, memberID, isFirstDecl, memberDecl) = next else { continue }

      // Check if this dependency introduces a cycle
      if isFirstDecl,  // Check only once per member (not every decl)
        extendedTypeName == dependency.baseTypeName,
        extensionMembers.typeMembersToDecls[memberID] != nil
      {
        // Map to the debug-friendly `ExtensionCycle` type
        return frame.toCycle(graph: self)
      }

      // Then, find transitive dependencies
      guard
        // Nominal-type declarations don't introduce dependencies (though,
        // their enclosing extensions might)
        let dependencyExtension = memberDecl?.introducingExtensionOrMainDecl,
        // Stop if we already have a cycle
        visitedExtensions.insert(dependencyExtension).inserted,
        // Skip if it has no dependencies
        !extensionsToState[dependencyExtension, default: Self.internalError(.staleDependency)]
          .dependencies.isEmpty
      else {
        // No transitive dependencies; just advance
        frame.advance(newIndex: newIndex)
        continue
      }

      // Push transitively depended-on extension
      // We can assign `(0,0,0)` because we just checked `!dependencies.isEmpty`
      frame.push(dependencyExtension, index: (0, 0, 0))
    }

    return nil
  }
}

// MARK: Type Admission

extension TypeGraph.GlobalTypeRef {
  init(
    name: TypeGraph.GlobalTypeName,
    nominal: __shared TypeGraph.NominalType
  ) {
    self.init(name: name, mainDecl: nominal.mainDecl, _version: nominal.version)
  }
}

extension TypeGraph {
  enum TypeAdmissionFailure: Error {
    /// We don't allow admitting redeclarations. The type resolver should diagnose
    /// redeclarations and not request admitting them to the graph.
    case cannotAdmitRedeclaration
  }

  // Top-scope (local or global)
  mutating func admitType(
    topScopeMainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileInfo: FileInfo,
    isGlobal: Bool,
    symbolTable: borrowing SymbolTable
  ) -> Result<TypeRef, TypeAdmissionFailure> {
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

    // If already registered, ensure we have no redeclaration (see
    // `.cannotAdmitRedeclaration` docstring for why)
    if let existingType = namesToTypes[globalName] {
      guard existingType.mainDecl == mainDecl else {
        return .failure(TypeAdmissionFailure.cannotAdmitRedeclaration)
      }
      return .success(.global(GlobalTypeRef(name: globalName, nominal: existingType)))
    }

    let type = _addType(
      mainDecl: mainDecl,
      typeMembers: TypeTable(
        typeMembersToDecls: mainDecl._groupTypeMembers(configuredRegions: declFileInfo.configuredRegions)
      ),
      typeName: globalName,
      symbolTable: symbolTable
    )
    return .success(.global(GlobalTypeRef(name: globalName, nominal: type)))
  }
}

extension TypeGraph {
  enum NestedTypeAdmissionFailure: Error {
    case other(TypeAdmissionFailure)

    /// The given decl group syntax unexpectedly isn't registered to the given
    /// base type reference.
    case invalidBaseDeclGroup
    /// The given `baseDeclGroup` must be admitted and match the given `baseType`.
    case invalidBaseType
  }

  // Nested (local or global)
  mutating func admitType(
    nestedMainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileInfo: FileInfo,
    baseDeclGroup: Attached<DeclGroupSyntaxType>,
    baseType: TypeRef,
    symbolTable: borrowing SymbolTable
  ) -> Result<TypeRef, NestedTypeAdmissionFailure> {
    // Check this is the right decl group: it must contain the main decl and
    // be able to declare a nominal type that we can admit.
    //
    // TODO: This check is too broad: it accepts types nested deeper than a
    // direct member (e.g., in a function body or an inactive `#if` region),
    // which removing `baseDeclGroup` wouldn't visit. Return
    // `.invalidBaseDeclGroup` unless `baseDeclGroup`'s `TypeTable` contains
    // `mainDecl` under `declName`.
    guard
      baseDeclGroup.fileRoot == mainDecl.fileRoot,
      baseDeclGroup.node.range.contains(mainDecl.node.range)
    else {
      return .failure(NestedTypeAdmissionFailure.invalidBaseDeclGroup)
    }

    // Get the global reference, or return the local
    let globalParent: TypeGraph.GlobalTypeRef
    switch baseType {
    case .global(let globalReference):
      globalParent = globalReference
    case .local(let parentDecl):
      guard DeclGroupSyntaxType(parentDecl.node) == baseDeclGroup.node else {
        return .failure(NestedTypeAdmissionFailure.invalidBaseType)
      }

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
      return .failure(NestedTypeAdmissionFailure.invalidBaseType)
    }

    // Check base decl group is actually bound to baseType
    if let parentExtension = baseDeclGroup.as(ExtensionDeclSyntax.self) {
      guard case .success(globalParent.name) = extensionsToState[parentExtension]?.resolvedType else {
        return .failure(NestedTypeAdmissionFailure.invalidBaseType)
      }
    } else if let baseTypeDecl = baseDeclGroup.as(NominalTypeDeclSyntax.self) {
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
      //
      // The decl group is a nominal type (checked above).
      guard baseTypeDecl == baseType.mainDecl else {
        return .failure(NestedTypeAdmissionFailure.invalidBaseType)
      }
    }

    // If already registered, ensure we have no redeclaration (see
    // `.cannotAdmitRedeclaration` docstring for why)
    if let existingType = namesToTypes[globalName] {
      guard existingType.mainDecl == mainDecl else {
        return .failure(NestedTypeAdmissionFailure.other(.cannotAdmitRedeclaration))
      }
      return .success(.global(GlobalTypeRef(name: globalName, nominal: existingType)))
    }

    let type = _addType(
      mainDecl: mainDecl,
      typeMembers: TypeTable(
        typeMembersToDecls: mainDecl._groupTypeMembers(configuredRegions: declFileInfo.configuredRegions)
      ),
      typeName: globalName,
      symbolTable: symbolTable
    )
    return .success(.global(GlobalTypeRef(name: globalName, nominal: type)))
  }
}

// MARK: - Extension Eviction

extension TypeGraph {
  fileprivate func _firstRegisteredMemberName(
    declGroup: Attached<DeclGroupSyntaxType>,
    declGroupFileInfo: FileInfo,
    declGroupTypeName: TypeGraph.GlobalTypeName,
    members: TypeTable,
    symbolTable: SymbolTable
  ) -> TypeGraph.GlobalTypeName? {
    // TODO: Maybe assert `declGroup` is bound.

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

      // TODO: When would this happen tho?? We derived `potentialMemberTypeName` from
      // `memberName`, so clearly a member like that lives inside the decl group.
      // The decl group should be bound, so the member is either:
      // 1. lazily admitted (i.e., cud be admitted, but no one requested => `namesToTypes[...]==nil` => no work for us)
      // 2. not aditted due to redecl (`memberType` doesn't exist => no work for us)
      // 3. actually admitted (`memberType` exists => we have to remove)
      // 4. admitted despite redeclarations? (shouldn't happen right? maybe in case of private decls or sm?)
      //
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

  mutating func _evictMemberType(
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
      dependencyTypeName: baseTypeName,
      dependencyMembers: TypeTable(typeMembersToDecls: [memberName: memberDecls]),
      evictedExtensions: &evictedExtensions,
      symbolTable: symbolTable
    )

    // TODO: Why is this after evicting dependent extensions??
    // TODO: Could this construction/guard-let be merged with `_firstRegisteredMemberName`?
    //
    // If there's no registered nominal type our name, we're done
    let memberTypeName = baseTypeName.addingComponent(
      GlobalTypeName.Component(
        name: memberName,
        file: baseTypeDecl.fileRoot,
        fileInfo: baseTypeFileInfo,
        symbolTable: symbolTable
      )
    )
    guard let memberNominal = namesToTypes[memberTypeName] else { return }

    // Ensure the extension contains the main declaration
    // TODO: Why do we need this tho?
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
    guard memberDecls.contains(Attached<TypeDeclSyntax>(memberNominal.mainDecl)) else { return }

    // Assert we don't have any nominal-type *re*declarations (checked in `admitType`)
    // TODO: Substitute with `internalAssert`
    precondition(
      memberDecls.compactMap({ $0.as(NominalTypeDeclSyntax.self) }) == [memberNominal.mainDecl],
      "[SwiftLexicalLookup] Internal error: Expected nominal type '\(memberTypeName.debugDescription)' to have the main decl `\(memberNominal.mainDecl._memberlessDescription)`"
    )

    // Remove all nested member types
    for (nestedMemberName, nestedMemberDecls) in memberNominal.mainDeclMembers.typeMembersToDecls {
      _evictMemberType(
        baseTypeName: memberTypeName,
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
    //
    // TODO: Why didn't this fail a test before?? Write a proper test
    // Note: `memberNominal` is stale here but since extension eviction doesn't
    // bind dependencies, this will always be a superset of the currently bound
    // extensions. Further, if an extension was already evicted, `_evictExtension`
    // will just skip it.
    for moduleExtensions in memberNominal.boundExtensions.values {
      for (extensionDecl, _) in moduleExtensions {
        _evictExtension(
          extensionDecl,
          evictedExtensions: &evictedExtensions,
          symbolTable: symbolTable
        )
      }
    }

    // Unregister Nominal
    //
    // We handle preconditions by ensuring all dependents, extensions
    // and member types were evicted.
    _removeType(
      // Same file info since this is a nested type
      nominalDeclFileInfo: baseTypeFileInfo,
      typeName: memberTypeName,
      symbolTable: symbolTable
    )
  }

  mutating func _evictExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) {
    // TODO: Find right error
    let extensionState = extensionsToState[extensionDecl, default: Self.internalError(.danglingExtension)]
    // TODO: Find right error
    let extensionFileInfo = symbolTable.getFileInfo(extensionDecl.fileRoot) ?? Self.internalError(.danglingExtension)

    // If bound, remove members
    if case .success(let extendedTypeName) = extensionState.resolvedType {
      // Get the extended-type name
      let extendedType = namesToTypes[extendedTypeName, default: Self.internalError(.danglingExtension)]

      // Find the members
      // TODO: Find right error
      let extensionMembers = extendedType.boundExtensions[extensionFileInfo.module, default: [:]][
        extensionDecl,
        default: Self.internalError(.danglingExtension)
      ]

      for (memberName, memberDecls) in extensionMembers.typeMembersToDecls {
        _evictMemberType(
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
    //
    // We satisfy the preconditions as we removed all dependents & type members.
    _removeExtension(extensionDecl, extensionFileInfo: extensionFileInfo, symbolTable: symbolTable)

    // Record eviction
    evictedExtensions.append(extensionDecl)
  }

  /// Evicts the extensions dependent on the given `dependencyMembers` of
  /// `dependencyTypeName`.
  ///
  /// Complexity: The worst case is when `nextConflictingDependent` has to go to the end of
  /// the `dependents` array to find a conflict, resulting in O(D_T^2)` complexity where
  /// `D_T` is the number of the type's dependents. However, `D_T` is generally small.
  ///
  /// ### Example
  ///
  /// For instance, imagine our graph currently admits:
  /// ```
  /// struct A { struct B {}; struct C {} }
  /// extension A.B {}
  /// extension A.C {}
  /// ```
  /// Suppose we want to admit `extension A { struct C {} }`. Then, our type
  /// `_(MyFile.swift)::A` should evict only extensions that are dependent
  /// on the introduced member `C`. Thus, we leave `extension A.B` admitted
  /// and only evict `extension A.C`
  fileprivate mutating func _evictDependents(
    dependencyTypeName: GlobalTypeName,
    dependencyMembers: TypeTable,
    evictedExtensions: inout [Attached<ExtensionDeclSyntax>],
    symbolTable: borrowing SymbolTable
  ) {
    // Each iteration, evict the next conflicting extension dependent on
    // `dependencyMembers` until there are no conflicting dependents.
    //
    // Note: We use a `while` loop because `_evictExtension` is recursive and can,
    // thus, change `namesToTypes[...].dependents` between iterations.
    while let dependent = namesToTypes[dependencyTypeName, default: Self.internalError(.evictedDependencyType)]
      .dependents
      .last(where: { dependent in
        dependencyMembers.typeMembersToDecls[dependent.memberType] != nil
      })
    {
      log("Found conflict \(dependent.debugDescription)")
      _evictExtension(
        dependent.dependentExtension,
        evictedExtensions: &evictedExtensions,
        symbolTable: symbolTable
      )
    }
  }
}

// MARK: Extension Admission

extension TypeGraph {
  // TODO: Clarify who uses these

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

  mutating func admitExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    extensionFileInfo: FileInfo,
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
    log(
      "Admitting `\(extensionDecl)` as '\((try? rawResult.get().qualifiedName.debugDescription) ?? "<error>")'"
    )

    // Prepare to store extension state
    let extensionMembers = TypeTable(
      typeMembersToDecls: extensionDecl._groupTypeMembers(configuredRegions: extensionFileInfo.configuredRegions)
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

      log(
        "Checking cycles if introducing `\(extensionDecl._memberlessDescription)` with members '\(extendedTypeRef.debugDescription)' > \(extensionMembers.typeMembersToDecls.map(\.key.name))"
      )
      let cycle = _firstCycle(
        extensionDecl: extensionDecl,
        extensionState: ExtensionState(
          dependencies: dependencyTracker.dependencies,
          resolvedType: .success(extendedTypeRef.name)
        ),
        extensionMembers: extensionMembers
      )

      if let cycle {
        // Found cycle, turn success into failure
        result = .failure(TypeResolver.Failure.cyclicalExtensionDependency(cycle))
      } else {
        // No cycle, keep success
        result = .success((extendedTypeRef, mainDecl))
      }
    case .failure(let failure):
      // Failed extensions remain failures (they are unbound => no member
      // types that can cause cycles).
      result = .failure(failure)
    }

    // === Evict Dependents & Bind ===
    let evictedExtensions: [Attached<ExtensionDeclSyntax>]
    // If there's no cycle, we may have type members so we need to evict
    switch result {
    case .success(let (extendedTypeRef, _)):
      let extendedTypeName: GlobalTypeName = extendedTypeRef.name

      var evictedExtensionsTmp: [Attached<ExtensionDeclSyntax>] = []
      _assertInvariants(symbolTable: symbolTable)
      _evictDependents(
        dependencyTypeName: extendedTypeName,
        dependencyMembers: extensionMembers,
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
        // An extension must be `extensionDecl` (about to be registered) or
        // currently registered.
        assert(
          dependent.dependentExtension == extensionDecl || extensionsToState[dependent.dependentExtension] != nil,
          "[SwiftLexicalLookup] Internal error: Tried updating dependents of '\(extendedTypeName)' but found unregistered extension `\(dependent.dependentExtension._memberlessDescription)`."
        )
      }
      evictedExtensions = evictedExtensionsTmp

      namesToTypes[extendedTypeName] = evictedDependentsType
    case .failure:
      // Extensions that aren't bound to a type, don't introduce new type
      // members so they can't have any dependent.
      evictedExtensions = []
    }

    _addExtension(
      extensionDecl,
      extensionMembers: extensionMembers,
      extensionModule: extensionFileInfo.module,
      dependencies: dependencyTracker.dependencies,
      resolvedType: result.map(\.globalReference.name),
      symbolTable: symbolTable
    )

    return .success((result, evictedExtensions))
  }
}

// MARK: Lookup

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

// MARK: Test Hooks

extension TypeGraph {
  /// Creates a mock graph without checking for invariants; only use for tests.
  @_spi(_QualifiedLookupTests)
  public init(
    _uncheckedNamesToTypes namesToTypes: [TypeGraph.GlobalTypeName: NominalType],
    extensionsToState: [Attached<ExtensionDeclSyntax>: ExtensionState]
  ) {
    self.namesToTypes = namesToTypes
    self.extensionsToState = extensionsToState
  }
}

extension TypeGraph.NominalType {
  /// Creates a mock nominal type without checking for invariants; only use
  /// for tests.
  ///
  /// Note: Type tables ignore `#if` configurations.
  @_spi(_QualifiedLookupTests)
  public init(
    _uncheckedMainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    boundExtensions: [ModuleName: [Attached<ExtensionDeclSyntax>]],
    dependents: [(memberType: Identifier, dependentExtension: Attached<ExtensionDeclSyntax>)]
  ) {
    self.mainDecl = mainDecl
    self.mainDeclMembers = TypeGraph.TypeTable(typeMembersToDecls: mainDecl._groupTypeMembers(configuredRegions: nil))
    self.boundExtensions = boundExtensions.mapValues({ extensions in
      Dictionary(
        uniqueKeysWithValues: extensions.map({
          ($0, TypeGraph.TypeTable(typeMembersToDecls: $0._groupTypeMembers(configuredRegions: nil)))
        })
      )
    })
    self.dependents = dependents.map({
      TypeGraph.TypeDependent(memberType: $0.memberType, dependentExtension: $0.dependentExtension)
    })
  }
}

// MARK: Debug

@_spi(_QualifiedLookupTests)
extension TypeGraph.QualifiedLookupDependency: CustomDebugStringConvertible {
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
