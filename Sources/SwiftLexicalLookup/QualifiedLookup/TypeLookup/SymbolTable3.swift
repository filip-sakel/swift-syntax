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

// TODO: Maybe move to testing
import SwiftDiagnostics
import SwiftIfConfig
import SwiftSyntax

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
///
/// Here's an example of a cycle:
/// ```swift
/// struct A {}
/// extension A.B { struct A {} }
/// extension A { typealias B = A }
/// ```
/// 1. Start with `extension A.B`
///    a. We resolve `A` to '_(MyFile.swift)::A'
///    b. Currently, `A` has no type members, so `A.B` doesn't exist; we
///       note this dependence
/// 2. Go to `extension A`
///    a. We resolve `A` so we bind `extension A` to '_(MyFile.swift)::A'
///    b. Now that we have a type member `B`, we re-evaluate `extension A.B`
///    c. Then, `A.B` resolves to '_(MyFile.swift)::A' with a dependence
///       on '_(MyFile.swift)::A' having no type member `A`
///    d. So we try to bind `A.B` to '_(MyFile.swift)::A'
///    e. However, adding the type member `struct A` to '_(MyFile.swift)::A'
///       would violate our dependence
///    f. So we diagnose the cycle that `extension A.B` can only be resolved
///       using `typealias B = A`, which requires that `A` have no member types,
///       but `extension A.B` introduces a member type `struct A`
///
/// TODO: Implement above only for extensions when looking up type members in
///       direct-lookup essentially where we call `bindExtensions` (don't think
///       about caching regular syntax yet; try to get MVP).
///       For now, to avoid cycles, assume that if we add an extension, and update dependents,
///       those dependents cannot update the extension we added.
///
/// TODO: (Future) Should I also handle top-level decls changing (to diagnose ambiguities
///       IF we're using cached/incremental approach):
///       E.g.
///         struct A {}
///         extension A {} // Great, we bind to `_(FileA.swift)::A`
///       We then bring in `FileB.swift`:
///         struct A {} // <- Redeclaration
///       So we have to invalidate the extension?
///
///  E.g. We bring external module
///  decls in first, before internal module; or we import another module that shadows previous top-level decl.
/// TODO: (Future) Is there a situation where updating dependent extensions can cause cycles?
///       Or rather, is it possible that we add a dependent extension, that adds
///       members that require updating other dependent extensions, which in turn
///       updates the dependent extension we added? (without causing a cycle)
@_spi(_QualifiedLookup) public struct ExtensionBindingResult: Sendable {
  // public enum ResolutionState {
  //   /// We're in the process of resolving this extension. Helps catch cycles.
  //   case resolving
  //   case resolved(
  //     dependencies: [Identifier: Result<MemberLookupResult<QualifiedTypeName>, TypeQualifier.Failure>],
  //     // TODO: How do we handle redeclarations in the same decl group
  //     assumedResolution: Result<QualifiedTypeName, TypeQualifier.Failure>
  //   )
  // }

  /// A dependency states that this extension was resolved by
  /// supposing that the ``resolvedType``'s ``typeMember`` member
  /// would resolve to the given type declarations.
  ///
  /// An assumption of no declarations, means there were no such types
  /// at the time the declaration was made. A single type declaration,
  /// means the type member can resolve properly. More than one types,
  /// on the other hand, give us ambiguities.
  @_spi(_QualifiedLookup) public struct Dependency: Sendable {
    let baseTypeName: QualifiedTypeName
    let typeMemberName: Identifier
    /// The resolved type declarations and the extensions in which they
    /// were declared (nil for main declaration)
    var resolvedDecls: [ExtensionDeclSyntax?: [TypeDeclSyntax]]
  }
  /// An array of dependencies
  ///
  /// We may have multiple dependencies, e.g.:
  /// ```swift
  /// struct A {}
  /// extension A.B.C {}
  /// extension A.B { typealias C = A }
  /// extension A { typealias B = A }
  /// ```
  /// Adding either the following:
  /// ```swift
  /// extension A { typealias B = Int } // Redeclaration
  /// ```
  /// Or an alias for `C` invalidates `extension A.B.C`.
  var dependencies: [Dependency]
  var dependents: Set<ExtensionDeclSyntax>
  var resolution: Result<QualifiedTypeName, TypeQualifier.Failure>
  // var typeMemberAssumptions: [PartiallyResolvedTypeIdentifier.Component: ResolvedNominalTypeReference]
  // var dependentExtensionsStack: [PartiallyResolvedTypeIdentifier.Component: [ExtensionDeclSyntax]]
}

@_spi(_QualifiedLookup) public enum ExtensionBindingState<TypeName: Sendable>: Sendable {
  /// Resolved to the given result
  case resolved(ExtensionBindingResult)
  /// Invalidated after we evaluated another extension that
  /// introduced conflicting type members.
  case invalidated(
    invalidatedResult: ExtensionBindingResult,
    invalidatingExtension: ExtensionDeclSyntax,
    invalidatingType: TypeName,
    formerDependencies: [ExtensionBindingResult.Dependency]
      // firstConflictingDependency: ExtensionBindingResult.Dependency,
      // firstConflictingTypeDecls: [TypeDeclSyntax]
  )
  case cannotDependOnIntroducedMembers(cycle: GenericExtensionBindingCycle<TypeName>)
}

@_spi(_QualifiedLookup) public final class SymbolTable3 {
  @_spi(_QualifiedLookupTests)
  public typealias ExtensionBindingState = SwiftLexicalLookup.ExtensionBindingState<
    QualifiedTypeName
  >

  public typealias Module = Identifier
  /// Invariant: moduleToSources[moduleName] != nil
  @_spi(_QualifiedLookupTests) public let moduleName: Module
  @_spi(_QualifiedLookupTests) public let moduleToSources: [Module: [String: SourceFileSyntax]]
  let configuredRegions: ConfiguredRegions?

  // internal private(set) var typeState: [QualifiedTypeName: NominalType] = [:]
  // @_spi(_QualifiedLookupTests) public private(set) var extensionState: [ExtensionDeclSyntax: ExtensionBindingState] =
  //   [:]
  @_spi(_QualifiedLookupTests) public private(set) lazy var unresolvedExtensions:
    [SourceFileSyntax: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>>] = {
      var result = [SourceFileSyntax: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>>]()
      for (module, files) in moduleToSources {
        for (_, file) in files {
          // TODO: Implement configuredRegions
          result[file] = file.findExtensions(configuredRegions: nil)
        }
      }
      return result
    }()
  @_spi(_QualifiedLookupTests) public private(set) var dependencyGraph = TypeDependencyGraph()

  public init?(
    moduleName: Module,
    moduleToSources: [Module: [String: SourceFileSyntax]],
    configuredRegions: ConfiguredRegions?
  ) {
    guard moduleToSources[moduleName] != nil else { return nil }

    self.moduleName = moduleName
    self.moduleToSources = moduleToSources
    self.configuredRegions = configuredRegions
  }

  var internalSources: [String: SourceFileSyntax] {
    // By `moduleName` invariant
    moduleToSources[moduleName]!
  }

  var internalFileMap: [SyntaxIdentifier: (fileName: String, file: SourceFileSyntax)] {
    // TODO: Check during init that each thing in the module map is a unique source file syntax
    // and add as invariant.
    Dictionary(
      uniqueKeysWithValues: internalSources.map({ (fileName, file) in
        (key: file.id, value: (fileName, file))
      })
    )
  }

  private(set) lazy var moduleMap: [SourceFileSyntax: Module] = {
    var result = [SourceFileSyntax: Module]()
    for (module, sources) in moduleToSources {
      for source in sources.values {
        result[source] = module
      }
    }
    return result
  }()
}

// MARK: Cycle Detection

extension SymbolTable3 {
  typealias ExtensionBindingCycle = SwiftLexicalLookup.GenericExtensionBindingCycle<QualifiedTypeName>
  // fileprivate func _findCyclicalDependency(
  //   baseTypeName: QualifiedTypeName,
  //   typeMembers: [Identifier: [TypeDeclSyntax]],
  //   currentExtensionDecl: ExtensionDeclSyntax,
  //   currentExtendedType: QualifiedTypeName,
  //   currentDependencies: [ExtensionBindingResult.Dependency],
  // ) -> ExtensionBindingCycle? {
  //   var dependencyChain = [(extensionDecl: ExtensionDeclSyntax, dependency: ExtensionBindingResult.Dependency)]()
  //   return _findCyclicalDependencyImplementation(
  //     baseTypeName: baseTypeName,
  //     typeMembers: typeMembers,
  //     currentExtensionDecl: currentExtensionDecl,
  //     currentExtendedType: currentExtendedType,
  //     currentDependencies: currentDependencies,
  //     dependencyChain: &dependencyChain
  //   )
  // }

  // /// See if the `baseTypeName` > `typeMembers` collide with the given
  // /// extension and its calculated dependencies.
  // ///
  // /// Parameters:
  // /// - dependencyChain: The path of extensions that make us depend on `currentExtensionDecl`.
  // private func _findCyclicalDependencyImplementation(
  //   baseTypeName: QualifiedTypeName,
  //   typeMembers: [Identifier: [TypeDeclSyntax]],
  //   currentExtensionDecl: ExtensionDeclSyntax,
  //   currentExtendedType: QualifiedTypeName,
  //   currentDependencies: [ExtensionBindingResult.Dependency],
  //   dependencyChain: inout [(extensionDecl: ExtensionDeclSyntax, dependency: ExtensionBindingResult.Dependency)]
  // ) -> ExtensionBindingCycle? {
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
  //     // Check if any type member collides with this dependency
  //     for (typeMemberName, _) in typeMembers {
  //       // Collisions require the same name and type
  //       guard
  //         dependency.baseTypeName == baseTypeName,
  //         dependency.typeMemberName == typeMemberName
  //       else {
  //         continue
  //       }
  //
  //       // This dependency collided; return
  //       dependencyChain.append((currentExtensionDecl, dependency))
  //       return ExtensionBindingCycle(
  //         dependencyChain: dependencyChain.map({ (extensionDecl, dependency) in
  //           return ExtensionBindingCycle.Dependency(
  //             extensionDecl: extensionDecl,
  //             extendedTypeName: currentExtendedType,
  //             member: dependency.typeMemberName,
  //             typeDecls: []
  //           )
  //         })
  //       )
  //     }
  //
  //     // Find recursive dependencies through depth-first search
  //     for (introducingExtensionOrMainDecl, _) in dependency.resolvedDecls {
  //       // If the extension is resolved, get its dependencies
  //       guard
  //         let introducingExtension = introducingExtensionOrMainDecl,
  //         case .resolved(let introducingExtensionResult) = extensionState[introducingExtension],
  //         // Only successfully resolved extensions can introduce type members.
  //         case .success(let resolvedType) = introducingExtensionResult.resolution
  //       else { continue }
  //
  //       // Update the dependency chain and check for cycles
  //       dependencyChain.append((currentExtensionDecl, dependency))
  //       // Note: We stop at the first cycle. Though, there could theoretically
  //       // be multiple cycles that we should diagnose in one step, this error
  //       // is quite rare. Hence, we stop early for simplicity and speed.
  //       if let cycle = _findCyclicalDependencyImplementation(
  //         baseTypeName: baseTypeName,
  //         typeMembers: typeMembers,
  //         currentExtensionDecl: introducingExtension,
  //         currentExtendedType: resolvedType,
  //         currentDependencies: introducingExtensionResult.dependencies,
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

// MARK: Extension Dependents

extension SymbolTable3 {
  // fileprivate func _visitTransitiveDependents(
  //   extensionDecl: ExtensionDeclSyntax,
  //   visit: (
  //     _ dependentExtension: ExtensionDeclSyntax, _ dependentExtensionResult: ExtensionBindingResult,
  //     _ state: inout ExtensionBindingState?
  //   ) -> Void
  // ) {
  //   guard case .resolved(let extensionResolution) = extensionState[extensionDecl] else { return }
  //   for dependent in extensionResolution.dependents {
  //     visit(dependent, extensionResolution, &extensionState[extensionDecl])
  //   }
  // }
}

// MARK: Registering Nominal

extension SymbolTable3 {
  // TODO: Could be a struct.
  enum NominalRegistrationFailure: Error {
    case invalidReregistration(existingMainDecl: NominalTypeDeclSyntax)
  }

  /// Register the given qualified name with the given main declaration.
  func registerNominalTypeReference(
    qualifiedName: QualifiedTypeName,
    mainDecl: SourceFileRoot<NominalTypeDeclSyntax>
  ) -> Result<NominalTypeRef, TypeDependencyGraph.NominalRegistrationFailure> {
    return dependencyGraph.registerNominalTypeReference(
      rawQualifiedName: qualifiedName,
      mainDecl: mainDecl,
      configuredRegions: configuredRegions
    )
    // let newNominal: NominalType
    // if let existingNominal = typeState[qualifiedName], existingNominal.mainDecl != mainDecl {
    //   // Type already exists with different main decl; this is a redeclaration
    //   return .failure(
    //     NominalRegistrationFailure.invalidReregistration(existingMainDecl: existingNominal.mainDecl)
    //   )
    // } else if let existingNominal = typeState[qualifiedName] {
    //   // Main declaration matches existing type; don't modify
    //   newNominal = existingNominal
    // } else {
    //   // Create new type
    //   newNominal = NominalType(
    //     qualifiedName: qualifiedName,
    //     mainDecl: mainDecl,
    //     redeclarations: [],
    //     extensions: [:]
    //   )
    // }
    //
    // // Register and return
    // typeState[qualifiedName] = newNominal
    // return .success(newNominal)
  }
}

@_spi(_QualifiedLookupTests) public enum ExtensionBindingFailure<TypeName: Sendable>: Error {
  /// Either root isn't a source file, or said source file isn't registered
  case nonRegisteredSyntaxRoot

  case admissionFailure(TypeDependencyGraph.ExtensionAdmissionFailure)

  // case alreadyResolved(ExtensionBindingResult)
  // case cannotBindInvalidated
  // case cannotFixNonInvalidated

  // case boundToUnresolvedName

  // /// Same as NominalRegistrationFailure.invalidReregistration
  // case invalidReregistration(existingMainDecl: NominalTypeDeclSyntax)
  //
  // // See todo comment below
  // case bindingBeforeFixingInvalidatedExtensions(invalidatedExtension: ExtensionDeclSyntax)
  //
  // // Depends on extension with non-resolved state
  // case invalidDependenceOnNonResolvedExtension(
  //   extensionDecl: ExtensionDeclSyntax,
  //   nonResolvedState: ExtensionBindingState<TypeName>?
  // )
}

// MARK: Nominal + Extension Binding
extension SymbolTable3 {

  typealias InvalidatedExtensions = OrderedSet<ExtensionDeclSyntax>
  typealias ExtensionBindingFailure = SwiftLexicalLookup.ExtensionBindingFailure<QualifiedTypeName>

  // /// Inserts the given extension moving it from `unresolvedExtensions` to `extensions`
  // /// and updating the nominal type's lookup table and extensions.
  // fileprivate func _insertExtension(extensionDecl: ExtensionDeclSyntax)

  /// Add extension to the symbol table and, if possible, bind it
  /// to the resolved nominal type. Cannot run on invalidated extensions.
  /// All invalidated extensions must be fixed before calling `bindExtension`
  /// again.
  ///
  /// Handles failed resolutions and resolutions that cause cycles.
  ///
  /// Returns: Broken extensions or binding failure.
  func bindExtensionAndRegisterExtended(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    to result: Result<
      (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
      TypeQualifier.Failure
    >,
    // dependencies: [ExtensionBindingResult.Dependency]
    dependencies: DependencyTracker
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // TODO: Refactor; super ugly (perhaps the caller should have this responsibility;
    // also we get back a NominalTypeRef only to discard it)
    if case .success(let (qualifiedName, mainDecl)) = result {
      let nominalRegistrationResult = dependencyGraph.registerNominalTypeReference(
        rawQualifiedName: QualifiedTypeName.topLevel(qualifiedName),
        mainDecl: mainDecl,
        configuredRegions: configuredRegions
      )

      // Ensure we succeed (guards against future cases)
      switch nominalRegistrationResult {
      case .success(_): break
      }
    }
    return _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: false,
      to: result,
      dependencies: dependencies
    )
  }

  /// Gets the final nominal-type reference with the given qualified name
  /// using the current graph.
  ///
  /// Useful for getting the final version of a nominal type after binding extensions.
  func getNominalTypeReference(name: QualifiedTypeNameGlobalType) -> NominalTypeRef? {
    dependencyGraph.namesToTypes[name].map({ NominalTypeRef(qualifiedName: name, nominal: $0) })
  }

  /// Similar to `bindExtension` but for the extensions that were invalidated.
  /// All invalidated extensions should be fixed before calling `bindExtension`
  /// again.
  func fixInvalidatedExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    to result: Result<
      (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
      TypeQualifier.Failure
    >,
    // dependencies: [ExtensionBindingResult.Dependency]
    dependencies: DependencyTracker
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: true,
      to: result,
      dependencies: dependencies
    )
  }

  /// Helper for `bindExtension` and `fixInvalidatedExtension`.
  fileprivate func _admitExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<
      (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>),
      TypeQualifier.Failure
    >,
    // dependencies: [ExtensionBindingResult.Dependency]
    dependencies: DependencyTracker
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // Get extension and module
    guard let module = moduleMap[extensionDecl.fileRoot] else {
      return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    }
    let admissionResult = dependencyGraph._admitExtension(
      extensionDecl,
      extensionDeclModule: module,
      isUpdatingInvalidating: isFixingInvalidating,
      to: result,
      dependencyTracker: dependencies,
      configuredRegions: configuredRegions,
      symbolTable: self
    )

    // Log results
    //
    // TODO: Add behind verbose flag
    //
    // Whether we're binding or fixing invalidated
    let actionVerb = isFixingInvalidating ? "rebinding invalidated" : "binding"
    // Describe dependencies
    let dependencyDescription = "[\(dependencies.dependencies.map(\.debugDescription).joined(separator: ", "))]"
    // Describe result
    let admissionResultDescriptions = admissionResult.map({ results in
      results.invalidatedExtensions.map({ result in
        "\(result.extensionDecl._memberlessDescription) -> \(result.resolvedType)"
      }).joined(separator: ", ")
    })
    // New graph description
    let dependencyGraphDescription = _describeDependencyGraph()
    print(String(repeating: "-", count: 80))
    print(
      "After \(actionVerb) extension `\(extensionDecl._memberlessDescription)` to \(result.map(\.qualifiedName.debugDescription)) with dependencies: \(dependencyDescription); admission result: \(admissionResultDescriptions), new dependency graph is:"
    )
    print(dependencyGraphDescription)
    print(String(repeating: "-", count: 80) + "\n")

    switch admissionResult {
    case .success(let success):
      // If successfully bound, remove from `unresolvedExtensions`
      unresolvedExtensions[extensionDecl.fileRoot]?.remove(extensionDecl)

      return .success(success)
    case .failure(let admissionFailure):
      return .failure(ExtensionBindingFailure.admissionFailure(admissionFailure))
    }
    // // Get file and module
    // guard
    //   let sourceFile = extensionDecl.root.as(SourceFileSyntax.self),
    //   let module = moduleMap[sourceFile]
    // else {
    //   return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    // }
    //
    // // Ensure we haven't already bound
    // if case ExtensionBindingState.resolved(let bindingResult)? = extensionState[extensionDecl] {
    //   return .failure(ExtensionBindingFailure.alreadyResolved(bindingResult))
    // }
    // switch (isFixingInvalidating, extensionState[extensionDecl]) {
    // case (false, nil), (true, .invalidated):
    //   break
    // case (true, nil):
    //   return .failure(ExtensionBindingFailure.cannotFixNonInvalidated)
    // case (false, .invalidated):
    //   return .failure(ExtensionBindingFailure.cannotFixNonInvalidated)
    // case (_, let resolvedExtension?) /* .cannotDependOnIntroducedMembers, .resolved */:
    //   assertionFailure(
    //     "[SwiftLexicalLookup] Internal error: Unexpectedly found extension state despite `unresolvedExtensions` indicating the extension hasn't been bound: \(resolvedExtension)."
    //   )
    // }
    //
    // // TODO: This might not be necessary if we change the model,
    // // but we should check that all invalidated extensions
    // // have been handled.
    //
    // // Compute the new extension state and what old extensions we've broken
    // let newExtensionState: ExtensionBindingState
    // let invalidatedExtensions: OrderedSet<ExtensionDeclSyntax>
    // switch result {
    // case .success(let (qualifiedName, mainDecl)):
    //   // Get nominal type
    //   let currentNominal: NominalType
    //   switch registerNominalTypeReference(qualifiedName: qualifiedName, mainDecl: mainDecl) {
    //   case .success(let success):
    //     currentNominal = success
    //   case .failure(.invalidReregistration(let existingMainDecl)):
    //     return .failure(ExtensionBindingFailure.invalidReregistration(existingMainDecl: existingMainDecl))
    //   }
    //   // Find introduced type members
    //   // TODO: configuredRegions
    //   let introducedTypeMembers: [Identifier: [TypeDeclSyntax]] = extensionDecl._groupTypeMembers(
    //     configuredRegions: configuredRegions
    //   )
    //
    //   // Ensure type member validity:
    //   // // TODO: Factor these checks out
    //   // var dependencies = dependencies
    //   // for dependency in dependencies {
    //   //   // TODO: Keep track of cycles precisely (and perhaps visited decls just to be safe)
    //   //   //
    //   //   // Identify type members conflicting with this dependency
    //   //   for (introducedTypeName, _) in introducedTypeMembers {
    //   //     guard dependency.baseTypeName == qualifiedName else { continue }
    //   //     guard dependency.typeMember == introducedTypeName else { continue }
    //   //     // TODO: Add to cycle diagnostic
    //   //   }
    //   //
    //   //   // Add transitive dependencies
    //   //   for (introducingExtension, _) in dependency.resolvedDecls {
    //   //     // Main declaration has no dependencies
    //   //     guard let introducingExtension else { continue }
    //   //
    //   //     // Ensure we don't invalidate the extension introducing the type
    //   //     // members we depend on
    //   //     guard case .resolved(let introducingExtensionResult) = extensionState[introducingExtension] else {
    //   //       // TODO: Make the required checks to justify this being a fatalError
    //   //       fatalError(
    //   //         "[SwiftLexicalLookup] Internal error: While trying to bind extension to '\(qualifiedName)', found dependency to type member `\(dependency.typeMember.name)` originating from a non-resolved/invalidated extension: \(String(reflecting: extensionState[introducingExtension]))."
    //   //       )
    //   //     }
    //   //
    //   //     dependencies.append(contentsOf: introducingExtensionResult.dependencies)
    //   //   }
    //   // }
    //   // // 1. Can't introduce members we depend on (without a cycle)
    //   // if let (_, recursiveTypeMembers) = dependencies._firstMatchingTypeMembers(
    //   //   resolvedTypeName: qualifiedName,
    //   //   typeMembers: introducedTypeMembers
    //   // ) {
    //   //   newExtensionState = ExtensionBindingState.cannotDependOnIntroducedMembers(
    //   //     typeMembers: recursiveTypeMembers
    //   //   )
    //   //   // This extension is invalid (its definition depends on at least one
    //   //   // of its type members), so we act like it doesn't introduce any
    //   //   // members.
    //   //   invalidatedExtensions = []
    //   //   break
    //   // }
    //   // // 2. Can't introduce members our dependencies' declaration contexts
    //   // //    depend on (without a cycle)
    //   // // TODO: Either prove this is sufficient or recursively search for dependencies (see
    //   // // relevant documentation in NominalType.swift)
    //   // var allRecursiveTypeMembers = [TypeDeclSyntax]()
    //   // for dependency in dependencies {
    //   //   // We can't invalidate any of the extensions that introduced our the types
    //   //   // we depend on; otherwise, we risk a cycle.
    //   //   for (introducingExtension, _) in dependency.resolvedDecls {
    //   //     // Main declaration has no dependencies
    //   //     guard let introducingExtension = introducingExtension else { continue }
    //   //
    //   //     // Ensure we don't invalidate the extension introducing the type
    //   //     // members we depend on
    //   //     guard case .resolved(let introducingExtensionResult) = extensionState[introducingExtension] else {
    //   //       // TODO: Make the required checks to justify this being a fatalError
    //   //       fatalError(
    //   //         "[SwiftLexicalLookup] Internal error: While trying to bind extension to '\(qualifiedName)', found dependency to type member `\(dependency.typeMember.name)` originating from a non-resolved/invalidated extension: \(String(reflecting: extensionState[introducingExtension]))."
    //   //       )
    //   //     }
    //   //
    //   //     // Continue if there are no conflicts
    //   //     guard
    //   //       let (_, recursiveTypeMembers) = introducingExtensionResult.dependencies._firstMatchingTypeMembers(
    //   //         resolvedTypeName: qualifiedName,
    //   //         typeMembers: introducedTypeMembers
    //   //       )
    //   //     else {
    //   //       continue
    //   //     }
    //   //
    //   //     // Record recursive members
    //   //     allRecursiveTypeMembers.append(contentsOf: recursiveTypeMembers)
    //   //   }
    //   // }
    //   // guard allRecursiveTypeMembers.isEmpty else {
    //   //   // This extension is invalid (its definition depends on at least one
    //   //   // of its type members), so we act like it doesn't introduce any
    //   //   // members.
    //   //   newExtensionState = ExtensionBindingState.cannotDependOnIntroducedMembers(typeMembers: allRecursiveTypeMembers)
    //   //   invalidatedExtensions = []
    //   //   break
    //   // }
    //
    //   // 3. Invalidate extension-binding results depending on the type members
    //   //    we're adding
    //   // TODO: Find more efficient way to do this
    //   // var invalidatedExtensionDecls = OrderedSet<ExtensionDeclSyntax>()
    //   // for (invalidatedExtensionDecl, invalidatedExtensionState) in extensionState {
    //   //   // We can only break resolved extensions
    //   //   let extensionBindingResult: ExtensionBindingResult
    //   //   switch invalidatedExtensionState {
    //   //   case ExtensionBindingState.resolved(let result):
    //   //     extensionBindingResult = result
    //   //   case ExtensionBindingState.invalidated(_, let invalidatedExtension, _, _, _):
    //   //     // TODO: DECIDE: We've introduced an extension that invalidated another
    //   //     // extension, and now we're trying to bind a new extension entirely.
    //   //     // Is this allowed? I.e., do we want to allow binding new extension before we finished
    //   //     // fixing invalidated ones? For now, we throw an error
    //   //     return .failure(
    //   //       ExtensionBindingFailure.bindingBeforeFixingInvalidatedExtensions(
    //   //         invalidatedExtension: invalidatedExtension
    //   //       )
    //   //     )
    //   //   case ExtensionBindingState.cannotDependOnIntroducedMembers:
    //   //     // Skip invalid, self-referential extensions
    //   //     continue
    //   //   }
    //   //
    //   //   // Get the conflict (otherwise, skip)
    //   //   guard
    //   //     let (firstConflictingDependency, firstConflictingTypeDecls) = extensionBindingResult.dependencies
    //   //       ._firstMatchingTypeMembers(
    //   //         resolvedTypeName: qualifiedName,
    //   //         typeMembers: introducedTypeMembers
    //   //       )
    //   //   else { continue }
    //   //
    //   //   // Invalidate extension and add to results
    //   //   self.extensionState[invalidatedExtensionDecl] = ExtensionBindingState.invalidated(
    //   //     invalidatedResult: extensionBindingResult,
    //   //     // We're the ones doing the invalidating
    //   //     invalidatingExtension: invalidatedExtensionDecl,
    //   //     invalidatingType: qualifiedName,
    //   //     // Record conflict
    //   //     firstConflictingDependency: firstConflictingDependency,
    //   //     firstConflictingTypeDecls: firstConflictingTypeDecls
    //   //   )
    //   //   invalidatedExtensionDecls.append(invalidatedExtensionDecl)
    //   // }
    //
    //   // Check for cycles
    //   if let cycle = _findCyclicalDependency(
    //     baseTypeName: qualifiedName,
    //     typeMembers: introducedTypeMembers,
    //     currentExtensionDecl: extensionDecl,
    //     currentExtendedType: qualifiedName,
    //     currentDependencies: dependencies
    //   ) {
    //     // Diagnose cycle; since binding failed, we refuse to admit the extension,
    //     // so there are no invalidations.
    //     newExtensionState = ExtensionBindingState.cannotDependOnIntroducedMembers(cycle: cycle)
    //     invalidatedExtensions = []
    //     break
    //   }
    //
    //   // Invalidate children
    //   var invalidatedExtensionDecls = [ExtensionDeclSyntax]()
    //   _visitTransitiveDependents(
    //     extensionDecl: extensionDecl,
    //     visit: { (dependentExtension, dependentExtensionResult, state) in
    //       print(
    //         "Binding \(extensionDecl._memberlessDescription): Invalidating \(dependentExtension._memberlessDescription)"
    //       )
    //       invalidatedExtensionDecls.append(dependentExtension)
    //
    //       state = ExtensionBindingState.invalidated(
    //         invalidatedResult: dependentExtensionResult,
    //         // We're the ones doing the invalidating
    //         invalidatingExtension: extensionDecl,
    //         invalidatingType: qualifiedName,
    //         formerDependencies: dependencies
    //       )
    //     }
    //   )
    //
    //   fatalError(
    //     "Binding \(extensionDecl._memberlessDescription): Deps: \(dependencies)"
    //   )
    //
    //   // Attach to parents (so that they or other ancestors can invalidate us)
    //   for dependency in dependencies {
    //     for (introducingExtensionDecl, _) in dependency.resolvedDecls {
    //       guard let introducingExtensionDecl else { continue }
    //       fatalError(
    //         "Binding \(extensionDecl._memberlessDescription): Registering as dependent of \(introducingExtensionDecl)"
    //       )
    //       let state = extensionState[introducingExtensionDecl]
    //
    //       // Add us a dependent (throw if the state's invalid)
    //       guard case .resolved(var extensionResolution) = state else {
    //         return .failure(
    //           ExtensionBindingFailure.invalidDependenceOnNonResolvedExtension(
    //             extensionDecl: introducingExtensionDecl,
    //             nonResolvedState: state
    //           )
    //         )
    //       }
    //       extensionResolution.dependents.insert(extensionDecl)
    //       extensionState[introducingExtensionDecl] = ExtensionBindingState.resolved(extensionResolution)
    //     }
    //   }
    //
    //   // Save extension-binding results.
    //   // Note: We don't have dependents since we just invalidated them
    //   newExtensionState = ExtensionBindingState.resolved(
    //     ExtensionBindingResult(dependencies: dependencies, dependents: [], resolution: .success(qualifiedName))
    //   )
    //   invalidatedExtensions = OrderedSet(invalidatedExtensionDecls)
    //
    //   // Update ``NominalType``
    //   var newNominal: NominalType = currentNominal
    //   // Add extension
    //   let insertResult = newNominal.extensions[module, default: []].append(extensionDecl)
    //   assert(
    //     insertResult.inserted,
    //     "[SwiftLexicalLookup] Internal error: Extension was already in `extensions` despite appearing in `unresolvedExtensions"
    //   )
    //   // Update lookup table
    //   typeState[qualifiedName] = newNominal
    // case .failure(let failure):
    //   // Otherwise just save the failure
    //   // Note: Since this extension failed, it doesn't introduce types and --hence-- can't
    //   // have dependents.
    //   newExtensionState = ExtensionBindingState.resolved(
    //     ExtensionBindingResult(dependencies: dependencies, dependents: [], resolution: .failure(failure))
    //   )
    //   // Can't break a type's extensions since we didn't bind to one
    //   invalidatedExtensions = []
    // }
    //
    // // Invalidate the extensions depending on the type members that this
    // // extension introduces.
    // //
    // // Each extension `x`'s type-resolution results depend on one or more
    // // type-member results. E.g.,
    // //   struct A { typealias B = C  }
    // //   typealias B = A.B
    // //   struct C {}
    // //
    // //   extension B.C {}
    // // Here, `extension B.C` depends on `(File.swift)::A>B == [typealias B = C]` (because of `typealias B = A.B`)
    // // and `(File.swift)::A>C == []` so that `typealias B = C` resolves to `(File.swift)::C`.
    // // We denote these dependencies of an extension `x` as the list `dependencies(x)`
    // // where the dependencies appear in the order in which they appear during type resolution.
    // // Each element of the list is a tuple of the qualified type, the type identifier, and the set
    // // of type declarations to which they refer.
    // // So in the above example, `dependencies(x)={
    // //   [`(File.swift)::A`, `B`, (`typealias B = C`)],
    // //   [`(File.swift)::A`, `C`, ()]
    // // }
    // //
    // // So we define the `invalidates(x,y)` function which, given an extension `x` that
    // // successfully evaluated to qualified name `τ_χ`, it checks if it
    // // invalidates an extension `y`'s type resolution. Namely, it returns true iff
    // // `x` introduces a type member μ such that `dependencies(y)` contains
    // // `(τ_x, identifier(μ), (μ_1, ..., μ_n))` so that `μ_i!=μ` for all `i=1,...,n`.
    // //
    // // Based on `invalidates(x,y)`, we define `recursivelyInvalidates(x,y)` to handle
    // // something like
    // //
    // // ```swift
    // // struct A {}
    // // struct B {}
    // //
    // // extension A { typealias C = B }
    // // //        |- Depends on : `()`
    // // //        |- Resolves to: `(File.swift)::A`
    // // //        `- Introduces : `(File.swift)::A>C`
    // //
    // // extension A.C { typealias D = A }
    // // //        |- Depends on : `(File.swift)::A>C`, `(File.swift)::A>B`
    // // //        |- Resolves to: `(File.swift)::B`
    // // //        `- Introduces : `(File.swift)::B>D`
    // //
    // // extension B { typealias E = D }
    // // //        |- Depends on : ()
    // // //        |- Resolves to: `(File.swift)::B`
    // // //        `- Introduces : `(File.swift)::B>E`
    // //
    // // extension B.E { struct B {} }
    // // //       |- Depends on : `(File.swift)::B>E`, `(File.swift)::B>D`, `(File.swift)::B>A`
    // // //       |- Resolves to: `(File.swift)::A`
    // // //       `- Introduces : `(File.swift)::A>B
    // // ```
    // // TODO: This example doesn't provide an example where we need recursive invalidation.
    // //
    // // To avoid cycles, we stipulate that to bind an extension `x` (that resolved
    // // successfully), each currently bound extension `y` (also successfully evaluated)
    // // must satisfy that `invalidates(y, x) = false`.
    // // This is an example of why transitive dependencies matter:
    // // TODO: Do we need recursive invalidation?
    // //
    // // Note that this doesn't form a cycle. Extension `x` with type members τ_{x, 1}, ..., τ_{x,n}
    // // (with repetition allowed) invalidates extensions `y_j` from `j=1,..., m` when
    // // `dependencies(y_j)\cap \set{τ_{x, 1}, ..., τ_{x,n}}\ne \varnothing`. So for some `y_j`
    // // to invalidate `x`, it or one of the extensions it invalidates must contain a type member
    // // `τ_{y_j, k}=τ_{x, i}` for some k and i.
    // //
    // // That's because for a cycle to form,
    // // the extensions we invalidate must then invalidate us (this extension).
    // // For the invalidated extensions to invalidate us, we must be relying on
    // // type members
    // // Note that invalidating extensions that depend on this extension's type
    // // members doesn't form a cycle because we checked that this extension doesn't
    // // transitively depend on said members. TODO: Refine wording
    //
    // // Save extension
    // extensionState[extensionDecl] = newExtensionState
    // // Remove from unresovled
    // unresolvedExtensions[sourceFile, default: []].remove(extensionDecl)
    //
    // // Return which extensions broke
    // return .success(invalidatedExtensions)
  }
}

// MARK: Qualified Type Lookup

extension SymbolTable3 {
  @_spi(_QualifiedLookupTests) public enum QualifiedTypeLookupFailure: Error {
    /// Type syntax doesn't have source-file root or source-file root isn't in
    /// module map.
    case unregisteredSourceRoot

    case lookupFailure(TypeDependencyGraph.QualifiedTypeLookupFailure)
  }

  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    introducingTypeSyntax: SourceFileRoot<TypeLikeSyntax>,
    introducingModule: Module,
    dependencyTracker: inout DependencyTracker,
  ) -> Result<[SourceFileRoot<TypeDeclSyntax>], QualifiedTypeLookupFailure> {
    assert(
      moduleMap[introducingTypeSyntax.fileRoot] == introducingModule,
      "[SwiftLexicalLookup] Internal error: Caller passed wrong module for `\(introducingTypeSyntax.trimmedDescription)`: got '\(introducingModule.name)' but expected \(moduleMap[introducingTypeSyntax.fileRoot].debugDescription)"
    )

    // TODO: Remove
    print(
      "Finding member \(baseType) > \(memberTypeName.name)"
    )
    defer {
      print(
        "New deps for member-type lookup: \(dependencyTracker.dependencies)"
      )
    }

    return dependencyGraph.findMemberType(
      baseType: baseType,
      memberTypeName: memberTypeName,
      origin: (typeSyntax: introducingTypeSyntax, module: introducingModule),
      moduleMap: moduleMap,
      dependencyTracker: &dependencyTracker,
      configuredRegions: configuredRegions
    ).mapError(QualifiedTypeLookupFailure.lookupFailure)
  }
}

// MARK: Debug Print

// extension SymbolTable3: CustomDebugStringConvertible {
//   public var debugDescription: String {
//     let typesDescription = typeState.values.map(\.debugDescription)
//     let extensionsDescription = extensionState.map({ (extensionDecl, extensionState) in
//       "\(extensionDecl._memberlessDescription): \(extensionState)"
//     })
//     return "SymbolTable3(types: \(typesDescription), extensionState: \(extensionsDescription)"
//   }
// }

extension ExtensionBindingResult.Dependency: CustomDebugStringConvertible {
  public var debugDescription: String {
    let flattenedDeclDescriptions = resolvedDecls.flatMap({ (declGroup, typeDecls) in
      typeDecls.map({ typeDecl in
        let declGroupDescription = declGroup?._memberlessDescription ?? "main decl"
        return "`\(typeDecl)` [from `\(declGroupDescription)`]"
      })
    })
    let declsDescription: String
    if flattenedDeclDescriptions.isEmpty {
      declsDescription = "[]"
    } else {
      declsDescription = flattenedDeclDescriptions.joined(separator: ", ")
    }
    return "\(baseTypeName.debugDescription)/\(typeMemberName.name) == \(declsDescription)"
  }
}

@_spi(_QualifiedLookupTests)
extension ExtensionBindingState: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    switch self {
    case .resolved(let bindingResult):
      return "ExtensionBindingState.resolved(\(bindingResult))"
    case .invalidated(let invalidatedResult, let invalidatingExtension, let invalidatingType, let formerDependencies):
      return
        "ExtensionBindingState.invalidated(invalidatedResult: \(invalidatedResult), invalidatingExtension: \(invalidatingExtension._memberlessDescription), invalidatingType: \(invalidatingType), formerDependencies: \(formerDependencies))"
    case .cannotDependOnIntroducedMembers(let cycle):
      return "ExtensionBindingState.cannotDependOnIntroducedMembers(\(cycle.debugDescription))"
    }
  }
}

// Debug Type State

extension SymbolTable3 {
  @_spi(_QualifiedLookupTests) public func _describeDependencyGraph() -> String {
    var result = ""
    var group = GroupedDiagnostics()

    // Add all registered files
    var addedNames = Set<String>()
    for (moduleIdentifier, moduleFiles) in moduleToSources {
      for (fileName, fileSyntax) in moduleFiles {
        let fileIdentifier = "\(moduleIdentifier.name)/\(fileName)"
        // Don't readmit duplicate file names
        // TODO: Should handle modules
        guard addedNames.insert(fileIdentifier).inserted else {
          result += "Duplicate file identifier \(fileIdentifier)\n"
          continue
        }

        group.addSourceFile(tree: fileSyntax, displayName: fileIdentifier)
      }
    }

    // Add dependency-graph diagnostics
    let diagnostics = dependencyGraph._describeWithDiagnostics()
    for diagnostic in diagnostics {
      group.addDiagnostic(diagnostic)
    }

    // Print to result
    result += DiagnosticsFormatter(colorize: true).annotateSources(in: group)

    return result
  }
}
