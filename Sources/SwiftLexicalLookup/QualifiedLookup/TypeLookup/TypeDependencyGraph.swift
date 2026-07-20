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

struct MappedDeclGroup<DeclGroup: DeclGroupSyntax & SyntaxHashable>: Hashable {
  let declGroup: SourceFileRoot<DeclGroup>
  let typeMap: TypeDependencyGraph.TypeTable

  var node: DeclGroup { declGroup.node }
  var fileRoot: SourceFileSyntax { declGroup.fileRoot }

  func erased() -> MappedDeclGroup<DeclGroupSyntaxType> {
    // We're erasing so the source-file root will be retained
    MappedDeclGroup<_>(declGroup: SourceFileRoot(DeclGroupSyntaxType(declGroup))!, typeMap: typeMap)
  }

  static func == (a: Self, b: Self) -> Bool { a.declGroup == b.declGroup }
  func hash(into hasher: inout Hasher) {
    hasher.combine(declGroup)
  }
}

// TODO: Consider optimization where we don't issue module-lookup requests when looking
//       for type members of internal types (external modules can't depend on internal types)
// TODO: Think about making lookup lazy (what are the actual places where we *need* to find
//       redeclarations)
/// A directed acyclic graph where types are nodes and extensions are edges.
@_spi(_QualifiedLookupTests)
public struct TypeDependencyGraph {
  typealias IntroducingExtensionOrMainDecl = ExtensionDeclSyntax?
  struct TypeMemberDecl: Hashable {
    let introducingExtensionOrMainDecl: ExtensionDeclSyntax?
    let typeDeclSyntax: TypeDeclSyntax
  }
  struct TypeMember: Hashable {
    /// Parent type or `nil` for top-level in file scope (top-level type)
    /// or other sequential scope (e.g. non-nested local decl)
    // let parentType: QualifiedTypeName
    let name: Identifier
    fileprivate(set) var decls: [TypeMemberDecl]
  }

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
    // func collidesWithOther(
    //   _ otherTable: TypeTable,
    // ) -> Bool {
    //   otherTable.typeMembersToDecls.contains(where: { (otherMemberName, _) in
    //     typeMembersToDecls[otherMemberName] != nil
    //   })
    // }
  }
  enum BindingFailure: Error {
    case typeResolutionFailure(TypeQualifier.Failure)
    case cannotFormCycle(ExtensionBindingCycle<QualifiedTypeName>)
  }
  struct ExtensionDependency {
    let dependencyExtension: ExtensionDeclSyntax, member: TypeMember
  }
  struct ExtensionState {
    // TODO: Assumes main decls don't introduce dependencies (see discussion below)
    // Invariant: The extensions listed must be valid and successfully bound to a type in `extensionsToState`
    fileprivate(set) var dependencies: [ExtensionDependency],
      extensionDecl: ExtensionDeclSyntax,
      resolvedType: Result<QualifiedTypeName, BindingFailure>
  }
  struct ExtendedType {
    /// Invariants: count >= 1; sorted by position in increasing order
    private var _mainDecls: [MappedDeclGroup<NominalTypeDeclSyntax>]
    private(set) var boundExtensions: [SymbolTable3.Module: [MappedDeclGroup<ExtensionDeclSyntax>]]
    #if DEBUG
    private var _boundExtensionsSet: Set<ExtensionDeclSyntax>
    #endif

    /// Extensions dependending on qualified lookup on this extended type
    fileprivate(set) var dependents: [(ExtensionDeclSyntax, TypeMember)]

    // private init(
    //   _mainDecls: [NominalTypeDeclSyntax],
    //   boundExtensions: [SymbolTable3.Module: [ExtensionDeclSyntax]],
    //   dependents: [(ExtensionDeclSyntax, TypeMember)]
    // ) {
    //   self._mainDecls = mainDecl
    //   self.boundExtensions = boundExtensions
    //   self.dependents = dependents
    // }

    init(mainDecl: MappedDeclGroup<NominalTypeDeclSyntax>) {
      self._mainDecls = [mainDecl]
      self.boundExtensions = [:]
      #if DEBUG
      self._boundExtensionsSet = []
      #endif
      self.dependents = []
    }

    var mainDecl: MappedDeclGroup<NominalTypeDeclSyntax> {
      // By invariant above that `_mainDecls.count >= 1`
      _mainDecls[0]
    }

    /// Returns a new version of the extended type, adding the given extension.
    /// Returns `nil` in debug  if extension is already bound.
    fileprivate consuming func _bindingExtension(
      _ mappedExtensionDecl: MappedDeclGroup<ExtensionDeclSyntax>,
      module: SymbolTable3.Module
    ) -> ExtendedType? {
      var copy = self
      #if DEBUG
      guard copy._boundExtensionsSet.insert(mappedExtensionDecl.node).inserted else { return nil }
      #endif
      copy.boundExtensions[module, default: []].append(mappedExtensionDecl)
      return copy
    }

    func addingRedeclaration(_ mainDecl: MappedDeclGroup<NominalTypeDeclSyntax>) -> ExtendedType? {
      // This check takes linear time w.r.t. `_mainDecls`; however, we don't
      // expect to have many redeclarations for the same type.
      guard !_mainDecls.contains(mainDecl) else { return nil }

      var copy = self
      // We add and sort, maintaining `_mainDecls` invariants
      copy._mainDecls.append(mainDecl)
      copy._mainDecls.sort(by: { $0.declGroup.position < $1.declGroup.position })
      return copy
    }
  }

  /// Updates when we register nominal types and bind extensions
  var namesToTypes: [QualifiedTypeName: ExtendedType]
  // /// Updates when we register nominal types and bind extensions
  // var parentsToTypeMembers: [QualifiedTypeName: TypeTable]
  var extensionsToState: [ExtensionDeclSyntax: ExtensionState]

  init() {
    namesToTypes = [:]
    extensionsToState = [:]
  }
}

// MARK: Lookup

struct DependencyTracker {
  /// Note: We don't guarantee that dependencies are unique.
  var dependencies: [QualifiedLookupDependency<QualifiedTypeName>]
}

extension TypeDependencyGraph.TypeMember {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeName>) {
    self.init(
      name: dependency.member,
      decls: dependency.typeDecls.map({
        TypeDependencyGraph.TypeMemberDecl(introducingExtensionOrMainDecl: dependency.extensionDecl, typeDeclSyntax: $0)
      })
    )
  }
}

extension TypeDependencyGraph.ExtensionDependency {
  fileprivate init(_from dependency: QualifiedLookupDependency<QualifiedTypeName>) {
    self.dependencyExtension = dependency.extensionDecl
    self.member = TypeDependencyGraph.TypeMember(_from: dependency)
  }
}

extension TypeDependencyGraph {
  enum QualifiedTypeLookupFailure: Error {
    case invalidBase

    // TODO: Fold into this error type
    case memberLookupFailure(NominalType.MemberLookupFailure)
    // enum MemberLookupFailure: Error {
    //   case fileNotInModuleMap(SourceFileSyntax)
    //   case declNotAttachedToSourceFile(DeclGroupSyntaxType)
    //   case selectedNonImportedModule(selectedModule: Identifier)
    // }
  }
  func findTypeMember(
    baseTypeName: QualifiedTypeName,
    memberTypeName: Identifier,
    origin: (typeSyntax: SourceFileRoot<TypeLikeSyntax>, module: String),
    moduleMap: [SourceFileSyntax: SymbolTable3.Module],
    dependencyTracker: inout DependencyTracker
  ) -> Result<[TypeDeclSyntax], QualifiedTypeLookupFailure> {
    // Diagnose invalid base
    guard let registeredType = namesToTypes[baseTypeName] else {
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
      } else if moduleMap[declGroup.fileRoot] == moduleMap[origin.typeSyntax.fileRoot] {
        otherInternalDecls.append(declGroup)
      } else {
        externalDecls.append(declGroup)
      }
    }

    // Add main decl and bound extensions
    organizeDeclGroup(registeredType.mainDecl.erased())
    for (_, extensionDecls) in registeredType.boundExtensions {
      for extensionDecl in extensionDecls {
        organizeDeclGroup(extensionDecl.erased())
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
    case unexpectedReregistration(existingMainDecl: NominalTypeDeclSyntax)
    case parentNotRegistered(parentName: QualifiedTypeName)
  }

  mutating func registerNominalTypeReference(
    qualifiedName: QualifiedTypeName,
    mainDecl: SourceFileRoot<NominalTypeDeclSyntax>,
    configuredRegions: ConfiguredRegions?
  ) -> Result<Void, NominalRegistrationFailure> {
    // Check parent is registered
    if let (qualifiedBaseName, memberName: _) = qualifiedName.baseAndMemberName,
      namesToTypes[qualifiedBaseName] == nil
    {
      return .failure(NominalRegistrationFailure.parentNotRegistered(parentName: qualifiedBaseName))
    }

    // Map out the type
    let mappedMainDecl = MappedDeclGroup(
      declGroup: mainDecl,
      typeMap: TypeTable(
        from: mainDecl.node._groupTypeMembers(configuredRegions: configuredRegions),
        introducedIn: nil
      )
    )

    // If this type is new, just register and return
    // TODO: Test following, e.g. struct A { struct B {} }; extension A { struct B {} }
    guard let existingType = namesToTypes[qualifiedName] else {
      namesToTypes[qualifiedName] = ExtendedType(mainDecl: mappedMainDecl)
      return .success(())
    }
    // Ensures we don't have duplicate redeclaration (i.e. we can't register the same syntax node twice)
    guard let typeWithRedeclaration = existingType.addingRedeclaration(mappedMainDecl) else {
      return .failure(NominalRegistrationFailure.unexpectedReregistration(existingMainDecl: mainDecl.node))
    }
    namesToTypes[qualifiedName] = typeWithRedeclaration

    return .success(())

    // TODO: Delete assertion and collection for `typeMembers` approach
    //
    // // Assert the parent contains us
    // if let (baseTypeName, memberName) = qualifiedName.baseAndMemberName {
    //   // Ensure we're in the parent's type table
    //   let typeDecl = TypeDeclSyntax(mainDecl)
    //   assert(
    //     namesToTypes[baseTypeName]?.typeMembers.typeMembersToDecls[memberName]?.decls.contains(where: {
    //       $0.typeDeclSyntax == typeDecl
    //     }) != nil,
    //     "[SwiftLexicalLookup] Internal error: Registering \(qualifiedName) requires that we be registered in the parent's type-lookup table."
    //   )
    // }
    //
    // // Gather the children
    //
    // // TODO: configuredRegions
    //
    // var mainDeclTypeMembers = [Identifier: TypeMember]()
    // mainDecl.visitDirectMembers(
    //   configuredRegions: nil,
    //   visit: { valueDecl in
    //     // Get only the types
    //     guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
    //     guard let typeName = Identifier(validating: typeDecl.name) else { return }
    //     let newMemberDecl = TypeMemberDecl(introducingExtensionOrMainDecl: nil, typeDeclSyntax: typeDecl)
    //     // Save
    //     mainDeclTypeMembers[typeName, default: TypeMember(name: typeName, decls: [])].decls.append(
    //       newMemberDecl
    //     )
    //   }
    // )
  }
}

// MARK: Extension Binding

extension TypeDependencyGraph.ExtendedType {
  // For `typeMembers` approach:
  //
  // consuming fileprivate func _removingDeclGroupMembers(
  //   declGroup: DeclGroupSyntaxType
  // ) -> TypeDependencyGraph.ExtendedType {
  //   var copy = self
  //   // TODO: configuredRegions
  //   declGroup.visitDirectMembers(
  //     configuredRegions: nil,
  //     visit: { [] valueDecl in
  //       // Only types with valid name identifiers
  //       guard
  //         let typeDecl = valueDecl.as(TypeDeclSyntax.self),
  //         let typeDeclName = Identifier(validating: typeDecl.name)
  //       else { return }
  //
  //       // The type member must already be in the type table (because of eager loading)
  //       guard let typeMember = copy.typeMembers.typeMembersToDecls[typeDeclName] else {
  //         fatalError(
  //           "[SwiftLexicalLookup] Internal error: Didn't find declaraion group's \(declGroup._memberlessDescription) member \(typeDeclName.name) in extended type state."
  //         )
  //       }
  //
  //       // Remove the type
  //       var newTypeMember = typeMember
  //       newTypeMember.decls.removeAll(where: { $0.typeDeclSyntax == typeDecl })
  //       copy.typeMembers.typeMembersToDecls[typeDeclName] = newTypeMember
  //     }
  //   )
  //   return copy
  // }
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
      //
      // TODO: Remove
      // let extensionMembers = TypeTable(from: currentExtensionDecl._groupTypeMembers(configuredRegions: nil), introducedIn: currentExtensionDecl)
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

  // private func _findCyclicalDependencyImplementation(
  //   baseTypeName: QualifiedTypeName,
  //   typeMembers: [Identifier: [TypeDeclSyntax]],
  //   currentExtensionDecl: ExtensionDeclSyntax,
  //   currentExtendedType: QualifiedTypeName,
  //   currentDependencies: [QualifiedLookupDependency<QualifiedTypeName>],
  //   dependencyChain: inout [QualifiedLookupDependency<QualifiedTypeName>]
  // ) -> SymbolTable3.ExtensionBindingCycle? {
  //   #if DEBUG
  //   guard !dependencyChain.contains(where: { $0.extensionDecl != currentExtensionDecl }) else {
  //     fatalError(
  //       "[SwiftLexicalLookup] Internal error: Unexpectedly found cycle in existing extension-dependency graph."
  //     )
  //   }
  //   #endif
  //
  //   // Check current dependencies
  //   for dependency in currentDependencies {
  //     // // Get the extension state
  //     // guard let dependencyExtensionState = extensionDeclsToState[dependency.extensionDecl] else {
  //     //   fatalError(
  //     //     "[SwiftLexicalLookup] Internal error: Extension \(currentExtensionDecl._memberlessDescription) lists \(dependency.dependentMember) as a dependency, but the dependency extension \(dependency.extensionDecl._memberlessDescription) isn't in the graph."
  //     //   )
  //     // }
  //     // // Get the resolved type
  //     // guard case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType else {
  //     //   // Shouldn't be possible to depend on members of an unbound extension,
  //     //   // because unbound extension don't introduce type members.
  //     //   fatalError(
  //     //     "[SwiftLexicalLookup] Internal error: Extension \(currentExtensionDecl._memberlessDescription) unexpectedly depends on unbound extension \(dependency.extensionDecl._memberlessDescription)."
  //     //   )
  //     // }
  //     // Get the extension state
  //
  //     // Check if any type member collides with this dependency
  //     for (typeMemberName, _) in typeMembers {
  //       // Collisions require the same name and type
  //       guard
  //         dependency.extendedTypeName == baseTypeName,
  //         dependency.member == typeMemberName
  //       else {
  //         continue
  //       }
  //
  //       // This dependency collided; return
  //       dependencyChain.append(dependency)
  //       return ExtensionBindingCycle(dependencyChain: dependencyChain)
  //     }
  //
  //     // Get extension state to retrieve transitive dependencies
  //     guard let dependencyExtensionState = extensionsToState[dependency.extensionDecl] else {
  //       // TODO
  //       fatalError("TODO")
  //     }
  //
  //     // Find recursive dependencies through depth-first search
  //     for (transitiveDependencyExtensionOrMainDecl, transitiveDependencyMember) in dependencyExtensionState.dependencies {
  //       // Skip if it's the main declaration
  //       // TODO: Should main decls also have dependencies, e.g.?
  //       //    struct A {
  //       //      typealias B = A
  //       //    }
  //       //    extension A.B {
  //       //      struct C {
  //       //        typealias D = C
  //       //      } // does `A.C` depend on
  //       //    }
  //       //    extension A.C.D {}
  //       //    // Depends on `(MyFile.swift)::A>A == []`, `(MyFile.swift)::A>C == [struct C]`, `(MyFile.swift)::A.(MyFile.swift)::C>D`
  //       //    extension A { struct A {} }
  //       //    // Invalidates `extension A.B` -> changes `struct C` -> rewrites `QualifiedTypeName`
  //       //  -> Add test but I think the current system handles this
  //       //     TODO: Make sure there's no corner case
  //       guard let dependencyExtension = transitiveDependencyExtensionOrMainDecl else { continue }
  //       // Get the extension state
  //       guard let dependencyExtensionState = extensionsToState[dependencyExtension] else {
  //         fatalError(
  //           "[SwiftLexicalLookup] Internal error: Extension \(currentExtensionDecl._memberlessDescription) lists \(dependency) as a dependency, but the dependency extension isn't in the graph."
  //         )
  //       }
  //       // Get the resolved type
  //       guard case .success(let dependencyExtendedType) = dependencyExtensionState.resolvedType else {
  //         // Shouldn't be possible to depend on members of an unbound extension,
  //         // because unbound extension don't introduce type members.
  //         fatalError(
  //           "[SwiftLexicalLookup] Internal error: Extension \(currentExtensionDecl._memberlessDescription) unexpectedly depends on unbound extension \(dependencyExtension._memberlessDescription)."
  //         )
  //       }
  //
  //       // Update the dependency chain and check for transitive cycles
  //       dependencyChain.append(
  //         ExtensionBindingCycle<QualifiedTypeName>.Dependency(
  //           extensionDecl: currentExtensionDecl,
  //           baseTypeName: currentExtendedType,
  //           dependentMember: dependencyTypeMember.name
  //         )
  //       )
  //       // Note: We stop at the first cycle. Though, there could theoretically
  //       // be multiple cycles that we should diagnose in one step, this error
  //       // is quite rare. Hence, we stop early for simplicity and speed.
  //       if let cycle = _findCyclicalDependencyImplementation(
  //         baseTypeName: baseTypeName,
  //         typeMembers: typeMembers,
  //         currentExtensionDecl: dependencyExtension,
  //         currentExtendedType: dependencyExtendedType,
  //         // FIXME: Continue here
  //         currentDependencies: dependencyExtensionState.dependencies.map({ (, transitiveDependency) in
  //           QualifiedLookupDependency(
  //             extensionDecl: dependencyExtension,
  //             baseTypeName: dependencyExtendedType,
  //             dependentMember: transitiveDependency
  //           )
  //         }),
  //         dependencyChain: &dependencyChain
  //       ) {
  //         return cycle
  //       }
  //       // Restore the original dependency chain for the next extensions
  //       dependencyChain.removeLast()
  //     }
  //   }
  //
  //   // No cycle found
  //   return nil
  // }
}

extension TypeDependencyGraph {
  typealias InvalidatedExtensions = [ExtensionState]
  enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }
  fileprivate mutating func _admitExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    extensionDeclModule: SymbolTable3.Module,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<
      (qualifiedName: QualifiedTypeName, mainDecl: NominalTypeDeclSyntax),
      TypeQualifier.Failure
    >,
    dependencyTracker: DependencyTracker,
    configuredRegions: ConfiguredRegions?
  ) -> Result<InvalidatedExtensions, ExtensionAdmissionFailure> {
    // Ensure extension isn't bound
    if let existingExtensionState = extensionsToState[extensionDecl.node] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Prepare to store extension state
    let typeTable = TypeTable(
      from: extensionDecl.node._groupTypeMembers(configuredRegions: configuredRegions),
      introducedIn: extensionDecl.node
    )
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
        introducedTypeTable: typeTable,
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
      guard var extendedType = namesToTypes[dependencyType] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(dependency.extensionDecl._memberlessDescription) bound to type \(dependencyType), which isn't in the graph."
        )
      }

      // Mark the dependence
      assert(
        !extendedType.dependents.contains(where: { $0.0 == extensionDecl.node }),
        "[SwiftLexicalLookup] Internal error: Unexpectedly found not-yet-admitted extension \(extensionDecl.node._memberlessDescription) in dependents list of \(dependency.extensionDecl._memberlessDescription)."
      )
      // TODO: Refactor to avoid repeating this step which we already did in cycle detection
      extendedType.dependents.append((extensionDecl.node, TypeMember(_from: dependency)))
    }

    // Remove invalidated extensions
    var queue: [ExtensionDeclSyntax] = extendedType.dependents.map(\.0)
    var invalidatedExtensions = [ExtensionState]()
    // TODO: Consider if this order of invalidating is fine
    while let invalidatedExtension = queue.popLast() {
      // Get the invalidated extension's state
      guard let invalidatedExtensionState = extensionsToState[invalidatedExtension] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension._memberlessDescription) referenced in \(extendedTypeName)'s dependents, but lacks a state entry."
        )
      }
      // Invalidate
      extensionsToState[extensionDecl.node] = nil
      invalidatedExtensions.append(invalidatedExtensionState)

      // If the extension was invalid, it doesn't have children to invalidate
      // or a bound type to update, so we're done
      guard case .success(let invalidatedExtensionTypeName) = invalidatedExtensionState.resolvedType else {
        continue
      }

      // Remove the members from the extended type
      guard let invalidatedExtensionType = namesToTypes[extendedTypeName] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension._memberlessDescription) resolved to \(invalidatedExtensionTypeName) but the type isn't in the graph."
        )
      }
      // For `typeMembers` approach:
      //
      // namesToTypes[extendedTypeName] = invalidatedExtensionType._removingDeclGroupMembers(
      //   declGroup: DeclGroupSyntaxType(invalidatedExtension)
      // )

      // Add transitive dependents
      queue.append(contentsOf: invalidatedExtensionType.dependents.compactMap(\.0))
    }

    // Save extension (newly bound extension doesn't add type dependents)
    extensionsToState[extensionDecl.node] = ExtensionState(
      dependencies: dependencies,
      extensionDecl: extensionDecl.node,
      resolvedType: Result.success(extendedTypeName)
    )
    // Bind to type
    let mappedExtensionDecl = MappedDeclGroup(declGroup: extensionDecl, typeMap: typeTable)
    guard let newExtendedType = extendedType._bindingExtension(mappedExtensionDecl, module: extensionDeclModule) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl.node._memberlessDescription) has no existing state but is already bound to \(extendedType)."
      )
    }
    namesToTypes[extendedTypeName] = newExtendedType

    return .success(invalidatedExtensions)
  }
}
