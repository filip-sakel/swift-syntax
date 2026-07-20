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

    func getDependencyExtensionDecls() -> [ExtensionDeclSyntax] {
      decls.compactMap(\.introducingExtensionOrMainDecl)
    }
  }
  struct TypeTable: Hashable {
    let typeMembersToDecls: [Identifier: TypeMember]
  }
  enum BindingFailure: Error {
    case typeResolutionFailure(TypeQualifier.Failure)
    case cannotFormCycle(ExtensionBindingCycle<QualifiedTypeName>)
  }
  struct ExtensionState {
    fileprivate(set) var dependencies: [(IntroducingExtensionOrMainDecl, TypeMember)],
      extensionDecl: ExtensionDeclSyntax,
      resolvedType: Result<QualifiedTypeName, BindingFailure>
  }
  struct ExtendedType {
    let mainDecl: NominalTypeDeclSyntax
    let typeMembers: TypeTable
    /// Extensions dependending on qualified lookup on this extended type
    fileprivate(set) var dependents: [(ExtensionDeclSyntax, TypeMember)]
  }

  /// Updates when we register nominal types and bind extensions
  var namesToTypes: [QualifiedTypeName: ExtendedType]
  // /// Updates when we register nominal types and bind extensions
  // var parentsToTypeMembers: [QualifiedTypeName: TypeTable]
  var extensionDeclsToState: [ExtensionDeclSyntax: ExtensionState]

  init() {
    // self.types = [:]
    // self.extensions = [:]
  }
}

// MARK: Lookup

struct DependencyTracker {
  /// It's not certain dependencies are unique.
  var dependencies:
    [(
      introducingExtensionOrMainDecl: TypeDependencyGraph.IntroducingExtensionOrMainDecl,
      member: TypeDependencyGraph.TypeMember
    )]
}

extension TypeDependencyGraph {
  enum QualifiedTypeLookupFailure: Error {
    case invalidBase
  }
  func findTypeMember(
    baseTypeName: QualifiedTypeName,
    memberTypeName: Identifier,
    dependencyTracker: inout DependencyTracker
  ) -> Result<[TypeDeclSyntax], QualifiedTypeLookupFailure> {
    // Diagnose invalid base
    guard let registeredType = namesToTypes[baseTypeName] else {
      return .failure(QualifiedTypeLookupFailure.invalidBase)
    }
    // Get the result (`nil` if type is resolved but have no members or not
    // that particular member)
    let optionalTypeMember: TypeMember? = registeredType.typeMembers.typeMembersToDecls[memberTypeName]
    let typeMember = TypeMember(name: memberTypeName, decls: optionalTypeMember?.decls ?? [])
    // Save dependency and return
    dependencyTracker.dependencies.append((nil, typeMember))
    return .success(typeMember.decls.map(\.typeDeclSyntax))
  }
}

extension TypeDependencyGraph {
  struct InvalidReadmissionFailure: Error {}
  /// Invalid types are types whose chain resolution produces a
  /// ``ChainResolution.resolved`` result. In other words, types
  /// whose resolution doesn't depend on binding an extension.
  mutating func admitIndependentTypeDecl(
    decl: TypeDeclSyntax,
    declName: Identifier,
    parentType: QualifiedTypeName?
  ) -> Result<Void, InvalidReadmissionFailure> {

  }

  enum NominalRegistrationFailure: Error {
    case invalidReregistration(existingMainDecl: NominalTypeDeclSyntax)
  }

  mutating func registerNominalTypeReference(
    qualifiedName: QualifiedTypeName,
    mainDecl: NominalTypeDeclSyntax
  ) -> Result<Void, NominalRegistrationFailure> {
    // Ensure we're not overwriting an existing declaration.
    if let existingType = namesToTypes[qualifiedName] {
      return .failure(NominalRegistrationFailure.invalidReregistration(existingMainDecl: existingType.mainDecl))
    }

    // Assert the parent contains us
    if let (baseTypeName, memberName) = qualifiedName.baseAndMemberName {
      // Ensure we're in the parent's type table
      let typeDecl = TypeDeclSyntax(mainDecl)
      assert(
        namesToTypes[baseTypeName]?.typeMembers.typeMembersToDecls[memberName]?.decls.contains(where: {
          $0.typeDeclSyntax == typeDecl
        }) != nil,
        "[SwiftLexicalLookup] Internal error: Registering \(qualifiedName) requires that we be registered in the parent's type-lookup table."
      )
    }

    // Gather the children
    // TODO: Explain why we update the LUT eagerly (1. extension binding is necessarily eager so this being lazy
    //    would needlessly complicate things, 2. we'd need to do this anyway when doing qualified lookup/resolving extensions
    //    to detect ambiguity)
    // Note: The following lookup resolves fine (but `typealias B`) is clearly wrong.
    // struct A {
    //   struct B {
    //     func f(_: Self) // <- Look up here
    //   }
    //   typealias B = Int
    // }
    // This would need to resolve `A` and then
    // TODO: configuredRegions
    var mainDeclTypeMembers = [Identifier: TypeMember]()
    mainDecl.visitDirectMembers(
      configuredRegions: nil,
      visit: { valueDecl in
        // Get only the types
        guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
        guard let typeName = Identifier(validating: typeDecl.name) else { return }
        let newMemberDecl = TypeMemberDecl(introducingExtensionOrMainDecl: nil, typeDeclSyntax: typeDecl)
        // Save
        mainDeclTypeMembers[typeName, default: TypeMember(name: typeName, decls: [])].decls.append(
          newMemberDecl
        )
      }
    )

    // Create the new type
    namesToTypes[qualifiedName] = ExtendedType(
      mainDecl: mainDecl,
      typeMembers: TypeTable(typeMembersToDecls: mainDeclTypeMembers),
      dependents: []
    )

    return .success(())
  }
}

// MARK: Extension Binding

extension TypeDependencyGraph {

  private func _findCyclicalDependencyImplementation(
    baseTypeName: QualifiedTypeName,
    typeMembers: [Identifier: [TypeDeclSyntax]],
    currentExtensionDecl: ExtensionDeclSyntax,
    currentExtendedType: QualifiedTypeName,
    currentDependencies: [ExtensionBindingResult.Dependency],
    dependencyChain: inout [(extensionDecl: ExtensionDeclSyntax, dependency: ExtensionBindingResult.Dependency)]
  ) -> SymbolTable3.ExtensionBindingCycle? {
    #if DEBUG
    guard !dependencyChain.contains(where: { $0.extensionDecl != currentExtensionDecl }) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly found cycle in existing extension-dependency graph."
      )
    }
    #endif

    // Check current dependencies
    for dependency in currentDependencies {
      // Check if any type member collides with this dependency
      for (typeMemberName, _) in typeMembers {
        // Collisions require the same name and type
        guard
          dependency.baseTypeName == baseTypeName,
          dependency.typeMemberName == typeMemberName
        else {
          continue
        }

        // This dependency collided; return
        dependencyChain.append((currentExtensionDecl, dependency))
        return ExtensionBindingCycle(
          dependencyChain: dependencyChain.map({ (extensionDecl, dependency) in
            return ExtensionBindingCycle.Dependency(
              extensionDecl: extensionDecl,
              resolvedType: currentExtendedType,
              dependentMember: dependency.typeMemberName
            )
          })
        )
      }

      // Find recursive dependencies through depth-first search
      for (introducingExtensionOrMainDecl, _) in dependency.resolvedDecls {
        // If the extension is resolved, get its dependencies
        guard
          let introducingExtension = introducingExtensionOrMainDecl,
          case .resolved(let introducingExtensionResult) = extensionState[introducingExtension],
          // Only successfully resolved extensions can introduce type members.
          case .success(let resolvedType) = introducingExtensionResult.resolution
        else { continue }

        // Update the dependency chain and check for cycles
        dependencyChain.append((currentExtensionDecl, dependency))
        // Note: We stop at the first cycle. Though, there could theoretically
        // be multiple cycles that we should diagnose in one step, this error
        // is quite rare. Hence, we stop early for simplicity and speed.
        if let cycle = _findCyclicalDependencyImplementation(
          baseTypeName: baseTypeName,
          typeMembers: typeMembers,
          currentExtensionDecl: introducingExtension,
          currentExtendedType: resolvedType,
          currentDependencies: introducingExtensionResult.dependencies,
          dependencyChain: &dependencyChain
        ) {
          return cycle
        }
        // Restore the original dependency chain for the next extensions
        dependencyChain.removeLast()
      }
    }

    // No cycle found
    return nil
  }
}

extension TypeDependencyGraph {
  typealias InvalidatedExtensions = [ExtensionState]
  enum ExtensionAdmissionFailure: Error {
    case cannotReadmit(existingState: ExtensionState)
    case invalidDependencyExtension(extensionState: ExtensionState?)
  }
  fileprivate mutating func _admitExtension(
    _ extensionDecl: ExtensionDeclSyntax,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<
      (qualifiedName: QualifiedTypeName, mainDecl: NominalTypeDeclSyntax),
      TypeQualifier.Failure
    >,
    dependencyTracker: DependencyTracker
  ) -> Result<InvalidatedExtensions, ExtensionAdmissionFailure> {
    // Ensure extension isn't bound
    if let existingExtensionState = extensionDeclsToState[extensionDecl] {
      return .failure(.cannotReadmit(existingState: existingExtensionState))
    }

    // Get the bound type name; if the result failed, save with dependencies (might get fixed later)
    let extendedTypeName: QualifiedTypeName
    // let mainDecl: NominalTypeDeclSyntax
    switch result {
    case .success(let success):
      // (extendedTypeName, mainDecl) = success
      extendedTypeName = success.qualifiedName
    case .failure(let failure):
      // Failed type resolution means no binding => no type members and no dependents
      extensionDeclsToState[extensionDecl] = ExtensionState(
        dependencies: dependencyTracker.dependencies,
        extensionDecl: extensionDecl,
        resolvedType: Result.failure(BindingFailure.typeResolutionFailure(failure)),
      )
    }

    // Get the bound type
    guard var extendedType = namesToTypes[extendedTypeName] else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) bound to type \(extendedTypeName), which isn't in the graph."
      )
    }

    // Ensure we don't form a cycle
    var dependencyChain = [ExtensionBindingResult.Dependency]()
    if let cycle = _findCyclicalDependencyImplementation(
      baseTypeName: extendedTypeName,
      typeMembers: [Identifier: [TypeDeclSyntax]],
      currentExtensionDecl: extensionDecl,
      currentExtendedType: extendedTypeName,
      currentDependencies: dependencyTracker.dependencies,
      dependencyChain: &dependencyChain
    ) {
      // Failed binding => no type members and no dependents
      extensionDeclsToState[extensionDecl] = ExtensionState(
        dependencies: dependencyTracker.dependencies,
        extensionDecl: extensionDecl,
        resolvedType: Result.failure(BindingFailure.cannotFormCycle(cycle)),
      )
    }

    // Tell dependencies we're dependent
    for dependencyMember in dependencyTracker.dependencies {
      for dependencyExtension in dependencyMember.member.getDependencyExtensionDecls() {
        // Get the type name (only successfully bound extensions introduce type
        // members we can depend on)
        let optionalExtensionState = extensionDeclsToState[extensionDecl]
        guard let extensionState = optionalExtensionState,
          case Result.success(let dependencyType) = extensionState.resolvedType
        else {
          return .failure(ExtensionAdmissionFailure.invalidDependencyExtension(extensionState: optionalExtensionState))
        }

        // Find the referenced type
        guard var extendedType = namesToTypes[dependencyType] else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Extension \(dependencyExtension._memberlessDescription) bound to type \(dependencyType), which isn't in the graph."
          )
        }

        // Mark the dependence
        assert(
          !extendedType.dependents.contains(where: { $0.0 == extensionDecl }),
          "[SwiftLexicalLookup] Internal error: Unexpectedly found not-yet-admitted extension \(extensionDecl._memberlessDescription) in dependents list of \(dependencyExtension._memberlessDescription)."
        )
        extendedType.dependents.append((extensionDecl, dependencyMember.member))
      }
    }

    // Remove invalidated extensions
    var queue: [ExtensionDeclSyntax] = extendedType.dependents.map(\.0)
    var invalidatedExtensions = [ExtensionState]()
    // TODO: Consider if this order of invalidating is fine
    while let invalidatedExtension = queue.popLast() {
      // Get the invalidated extension's state
      guard let invalidatedExtensionState = extensionDeclsToState[invalidatedExtension] else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(invalidatedExtension._memberlessDescription) referenced in \(extendedTypeName)'s dependents, but lacks a state entry."
        )
      }
      // Invalidate
      extensionDeclsToState[extensionDecl] = nil

      // Invalidate the children and save the old state
      queue.append(contentsOf: invalidatedExtensionState.dependencies.compactMap(\.0))
      invalidatedExtensions.append(invalidatedExtensionState)
    }

    // Save extension (newly bound extension doesn't add type dependents)
    extensionDeclsToState[extensionDecl] = ExtensionState(
      dependencies: dependencyTracker.dependencies,
      extensionDecl: extensionDecl,
      resolvedType: Result.success(extendedTypeName)
    )

    return .success(invalidatedExtensions)
  }
}
