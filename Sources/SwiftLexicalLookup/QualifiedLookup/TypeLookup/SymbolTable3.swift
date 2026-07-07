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
@_spi(_QualifiedLookup) public struct ExtensionBindingResult {
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
  @_spi(_QualifiedLookup) public struct Dependency {
    let resolvedType: QualifiedTypeName
    let typeMember: Identifier
    /// The resolved type declarations and the extensions in which they
    /// were declared (nil for main declaration)
    var resolvedDecls: [ExtensionDeclSyntax?: TypeDeclSyntax]
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
  var resolution: Result<QualifiedTypeName, TypeQualifier.Failure>
  // var typeMemberAssumptions: [PartiallyResolvedTypeIdentifier.Component: ResolvedNominalTypeReference]
  // var dependentExtensionsStack: [PartiallyResolvedTypeIdentifier.Component: [ExtensionDeclSyntax]]
}

extension Collection where Element == ExtensionBindingResult.Dependency {
  fileprivate func _firstMatchingTypeMembers(
    resolvedType: QualifiedTypeName,
    typeMembers: [Identifier: [TypeDeclSyntax]]
  ) -> (ExtensionBindingResult.Dependency, [TypeDeclSyntax])? {
    for dependency in self {
      guard dependency.resolvedType == resolvedType else { continue }
      guard let matchingType = typeMembers[dependency.typeMember] else { continue }
      return (dependency, matchingType)
    }
    return nil
  }
}

@_spi(_QualifiedLookup) public enum ExtensionBindingState {
  /// Resolved to the given result
  case resolved(ExtensionBindingResult)
  /// Invalidated after we evaluated another extension that
  /// introduced conflicting type members.
  case invalidated(
    invalidatedResult: ExtensionBindingResult,
    invalidatingExtension: ExtensionDeclSyntax,
    invalidatingType: QualifiedTypeName,
    firstConflictingDependency: ExtensionBindingResult.Dependency,
    firstConflictingTypeDecls: [TypeDeclSyntax]
  )
  // TODO: Add example (from bug report)
  case cannotDependOnIntroducedMembers(typeMembers: [TypeDeclSyntax])
}

// @_spi(_QualifiedLookup) public enum TypeSyntaxResolutionState {
//   /// Indicates we started resolving this type syntax; helps us catch cycles.
//   case startedResolving
//   /// A cycle was detected.
//   ///
//   /// Two examples:
//   /// 1.Type aliases:
//   ///   typealias A = B
//   ///   typealias B = A
//   ///
//   /// 2.Nested type aliases:
//   ///   struct One { typealias A = Two.B }
//   ///   struct Two { typealias B = One.A }
//   case detectedCycle(cyclingSyntax: [TypeSyntax])
//
//   /// We resolved the given type syntax.
//   ///
//   /// If successful, we have a function type, tuple type,
//   /// a composition of nominal types, or a single nominal type.
//   ///
//   /// There are multiple causes of failure.
//   case resolved(
//     Result<MemberLookupResult<QualifiedTypeName>, TypeQualifier.Failure>
//   )
// }
// @_spi(_QualifiedLookup) public enum TypeResolutionState {
//   /// Contains the
//   case resolved(NominalType)
//
//   /// If we resolved to a single nominal type, we can bind extensions and update
//   /// the resolved type.
//   ///
//   /// Note that extensions cannot be resolved independently, so we need to
//   /// keep track of extensions whose extended-syntax resolution depends on
//   /// this type. Here's an example:
//   ///   struct A {}
//   ///   extension A.Inner {}
//   ///   extension A { typealias Inner = A }
//   /// In this example, we can't resolve `A.Inner` directly since it requires
//   /// looking up the type `Inner` on `A`, which means `A` we have to bind
//   /// all available extensions first. Through this example, we see why even
//   /// seemingly unrelated extensions may be necessary to obtain an extended
//   /// nominal type.
//   ///
//   /// Further, note that dependent extensions can depend on other dependent
//   /// extensions (which eventually depend on a non-dependent extension). E.g.:
//   ///   struct A {}
//   ///   extension A.Inner {} // Depends on `A` having an `Inner` type member
//   ///   extension A.Outer { struct Inner {} } // Depends on `A` having an `Outer` type member
//   ///   extension A { typealias Outer = A } // Non-dependent extension
//   /// Say we want to get the extended nominal type of `A`; we have to bind these
//   /// three potential extensions. First, `A.Inner` expects a type member `Inner`;
//   /// the main declaration doesn't give us that yet. So we check the next extension,
//   /// but `A.Outer` depends on a type member `Outer`; we keep going. Finally, the
//   /// last extension has no dependencies so we get a type `Outer`. Hence, we can
//   /// make progress on `A.Outer` and resolve it, giving us `A.Inner`. Finally,
//   /// we resolve `A.Inner` and don't bind it since the type is unrelated.
//   ///
//   /// Important: As we bind dependent extensions, we assume the members we found
//   /// are unique. However,
//   ///
//   case bindingPotentialExtensions(
//     oldVersion: NominalType,
//     current: NominalType,
//     forSyntax: TypeSyntax,
//     potentialExtensions: [ExtensionDeclSyntax],
//   )
//   // /// The remaining extensions we need to bind
//   // var possibleExtensionQueue: [ExtensionDeclSyntax]
//   // /// Extensions we were able to successfully bind
//   // var currentlyBou§ndExtensions: [ExtensionDeclSyntax: QualifiedTypeName]
// }
@_spi(_QualifiedLookup) public final class SymbolTable3 {
  public typealias Module = Identifier
  let moduleToSources: [Module: [String: SourceFileSyntax]]

  // internal var typeSyntaxState: [TypeSyntax: TypeSyntaxResolutionState] = [:]
  // internal var typeState: [QualifiedTypeName: TypeResolutionState] = [:]
  internal private(set) var typeState: [QualifiedTypeName: NominalType] = [:]
  internal private(set) var extensionState: [ExtensionDeclSyntax: ExtensionBindingState] = [:]
  internal private(set) lazy var unresolvedExtensions: [SourceFileSyntax: Set<ExtensionDeclSyntax>] = {
    var result = [SourceFileSyntax: Set<ExtensionDeclSyntax>]()
    for (module, files) in moduleToSources {
      for (_, file) in files {
        // TODO: Implement configuredRegions
        result[file] = file.findExtensions(configuredRegions: nil)
      }
    }
    return result
  }()

  public init(moduleToSources: [Module: [String: SourceFileSyntax]]) {
    self.moduleToSources = moduleToSources
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

extension DeclGroupSyntax {
  fileprivate func _groupTypeMembers() -> [Identifier: [TypeDeclSyntax]] {
    var result = [Identifier: [TypeDeclSyntax]]()
    // TODO: Handle configuredRegions
    visitDirectMembers(
      configuredRegions: nil,
      visit: { valueDecl in
        guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
        guard let typeIdentifier = Identifier(validating: typeDecl.name) else { return }
        result[typeIdentifier, default: []].append(typeDecl)
      }
    )
    return result
  }
}

// MARK: Registering Nominal
extension SymbolTable3 {
  func registerNominal(
    mainDecl: NominalTypeDeclSyntax2,
    redeclarations: [NominalTypeDeclSyntax2],
    qualifiedName: QualifiedTypeName
  ) {
    typeState[qualifiedName] = NominalType(
      qualifiedName: qualifiedName,
      mainDecl: mainDecl,
      redeclarations: redeclarations,
      extensions: [:]
    )
  }
}

// MARK: Nominal + Extension Binding
extension SymbolTable3 {
  enum ExtensionBindingFailure: Error {
    case alreadyResolved
    case cannotBindInvalidated
    case cannotFixNonInvalidated
    /// Either root isn't a source file, or said source file isn't registered
    case nonRegisteredSyntaxRoot
    case boundToUnresolvedName
    // See todo comment below
    case bindingBeforeFixingInvalidatedExtensions(invalidatedExtension: ExtensionDeclSyntax)
  }

  typealias InvalidatedExtensions = [ExtensionDeclSyntax]

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
  func bindExtension(
    _ extensionDecl: ExtensionDeclSyntax,
    to result: Result<QualifiedTypeName, TypeQualifier.Failure>,
    dependencies: [ExtensionBindingResult.Dependency]
  ) -> Result<InvalidatedExtensions, ExtensionBindingFailure> {
    _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: false,
      to: result,
      dependencies: dependencies
    )
  }

  /// Similar to `bindExtension` but for the extensions that were invalidated.
  /// All invalidated extensions should be fixed before calling `bindExtension`
  /// again.
  func fixInvalidatedExtension(
    _ extensionDecl: ExtensionDeclSyntax,
    to result: Result<QualifiedTypeName, TypeQualifier.Failure>,
    dependencies: [ExtensionBindingResult.Dependency]
  ) -> Result<InvalidatedExtensions, ExtensionBindingFailure> {
    _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: true,
      to: result,
      dependencies: dependencies
    )
  }

  /// Helper for `bindExtension` and `fixInvalidatedExtension`.
  fileprivate func _admitExtension(
    _ extensionDecl: ExtensionDeclSyntax,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<QualifiedTypeName, TypeQualifier.Failure>,
    dependencies: [ExtensionBindingResult.Dependency]
  ) -> Result<InvalidatedExtensions, ExtensionBindingFailure> {
    // Get file and module
    guard
      let sourceFile = extensionDecl.root.as(SourceFileSyntax.self),
      let module = moduleMap[sourceFile]
    else {
      return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    }

    // Ensure we haven't already bound
    guard
      var unresolvedFileExtensions = unresolvedExtensions[sourceFile],
      unresolvedFileExtensions.contains(extensionDecl)
    else {
      return .failure(ExtensionBindingFailure.alreadyResolved)
    }
    switch (isFixingInvalidating, extensionState[extensionDecl]) {
    case (false, nil), (true, .invalidated):
      break
    case (true, nil):
      return .failure(ExtensionBindingFailure.cannotFixNonInvalidated)
    case (false, .invalidated):
      return .failure(ExtensionBindingFailure.cannotFixNonInvalidated)
    case (_, let resolvedExtension?) /* .cannotDependOnIntroducedMembers, .resolved */:
      assertionFailure(
        "[SwiftLexicalLookup] Internal error: Unexpectedly found extension state despite `unresolvedExtensions` indicating the extension hasn't been bound: \(resolvedExtension)."
      )
    }

    // TODO: This might not be necessary if we change the model,
    // but we should check that all invalidated extehsions
    // have been handled.

    // Compute the new extension state and what old extensions we've broken
    let newExtensionState: ExtensionBindingState
    let invalidatedExtensions: [ExtensionDeclSyntax]
    switch result {
    case .success(let resolvedName):
      // Get nominal type
      guard let currentNominal = typeState[resolvedName] else {
        return .failure(ExtensionBindingFailure.boundToUnresolvedName)
      }
      // Find introduced type members
      // TODO: configuredRegions
      let typeMembers: [Identifier: [TypeDeclSyntax]] = extensionDecl._groupTypeMembers()
      // Ensure type member validity:
      // TODO: Factor these checks out
      // 1. Can't introduce members we depend on (without a cycle)
      if let (_, recursiveTypeMembers) = dependencies._firstMatchingTypeMembers(
        resolvedType: resolvedName,
        typeMembers: typeMembers
      ) {
        newExtensionState = ExtensionBindingState.cannotDependOnIntroducedMembers(
          typeMembers: recursiveTypeMembers
        )
        // This extension is invalid (its definition depends on at least one
        // of its type members), so we act like it doesn't introduce any
        // members.
        invalidatedExtensions = []
        break
      }
      // 2. Can't introduce members our dependencies' declaration contexts
      //    depend on (without a cycle)
      // TODO: Either prove this is sufficient or recursively search for dependencies (see
      // relevant documentation in NominalType.swift)
      var allRecursiveTypeMembers = [TypeDeclSyntax]()
      for dependency in dependencies {
        // We can't invalidate any of the extensions that introduced our the types
        // we depend on; otherwise, we risk a cycle.
        for (introducingExtension, _) in dependency.resolvedDecls {
          // Main declaration has no dependencies
          guard let introducingExtension = introducingExtension else { continue }

          // Ensure we don't invalidate the extension introducing the type
          // members we depend on
          guard case .resolved(let introducingExtensionResult) = extensionState[introducingExtension] else {
            // TODO: Make the required checks to justify this being a fatalError
            fatalError(
              "[SwiftLexicalLookup] Internal error: While trying to bind extension to '\(resolvedName)', found dependency to type member `\(dependency.typeMember.name)` originating from a non-resolved/invalidated extension: \(String(reflecting: extensionState[introducingExtension]))."
            )
          }

          // Continue if there are no conflicts
          guard
            let (_, recursiveTypeMembers) = introducingExtensionResult.dependencies._firstMatchingTypeMembers(
              resolvedType: resolvedName,
              typeMembers: typeMembers
            )
          else {
            continue
          }

          // Record recursive members
          allRecursiveTypeMembers.append(contentsOf: recursiveTypeMembers)
        }
      }
      guard allRecursiveTypeMembers.isEmpty else {
        // This extension is invalid (its definition depends on at least one
        // of its type members), so we act like it doesn't introduce any
        // members.
        newExtensionState = ExtensionBindingState.cannotDependOnIntroducedMembers(typeMembers: allRecursiveTypeMembers)
        invalidatedExtensions = []
        break
      }

      // 3. Invalidate extension-binding results depending on the type members
      //    we're adding
      // TODO: Find more efficient way to do this
      var brokenExtensionDecls = [ExtensionDeclSyntax]()
      for (extensionDecl, extensionState) in extensionState {
        // We can only break resolved extensions
        let extensionBindingResult: ExtensionBindingResult
        switch extensionState {
        case ExtensionBindingState.resolved(let result):
          extensionBindingResult = result
        case ExtensionBindingState.invalidated(_, let invalidatedExtension, _, _, _):
          // TODO: DECIDE: We've introduced an extension that invalidated another
          // extension, and now we're trying to bind a new extension entirely.
          // Is this allowed? I.e., do we want to allow binding new extension before we finished
          // fixing invalidated ones? For now, we throw an error
          return .failure(
            ExtensionBindingFailure.bindingBeforeFixingInvalidatedExtensions(
              invalidatedExtension: invalidatedExtension
            )
          )
        case ExtensionBindingState.cannotDependOnIntroducedMembers:
          // Skip invalid, self-referential extensions
          continue
        }

        // Get the conflict (otherwise, skip)
        guard
          let (firstConflictingDependency, firstConflictingTypeDecls) = extensionBindingResult.dependencies
            ._firstMatchingTypeMembers(
              resolvedType: resolvedName,
              typeMembers: typeMembers
            )
        else { continue }

        // Invalidate extension and add to results
        self.extensionState[extensionDecl] = ExtensionBindingState.invalidated(
          invalidatedResult: extensionBindingResult,
          // We're the ones doing the invalidating
          invalidatingExtension: extensionDecl,
          invalidatingType: resolvedName,
          // Record conflict
          firstConflictingDependency: firstConflictingDependency,
          firstConflictingTypeDecls: firstConflictingTypeDecls
        )
        brokenExtensionDecls.append(extensionDecl)
      }
      newExtensionState = ExtensionBindingState.resolved(
        ExtensionBindingResult(dependencies: [], resolution: .success(resolvedName))
      )
      invalidatedExtensions = brokenExtensionDecls

      // Update ``NominalType``
      var newNominal: NominalType = currentNominal
      // Add extension
      let insertResult = newNominal.extensions[module, default: []].insert(extensionDecl)
      assert(
        insertResult.inserted,
        "[SwiftLexicalLookup] Internal error: Extension was already in `extensions` despite appearing in `unresolvedExtensions"
      )
      // Update lookup table
      typeState[resolvedName] = newNominal
    case .failure(let failure):
      // Otherwise just save the failure
      newExtensionState = ExtensionBindingState.resolved(
        ExtensionBindingResult(dependencies: [], resolution: .failure(failure))
      )
      // Can't break a type's extensions since we didn't bind to one
      invalidatedExtensions = []
    }

    // Invalidate the extensions depending on the type members that this
    // extension introduces.
    //
    // Each extension `x`'s type-resolution results depend on one or more
    // type-member results. E.g.,
    //   struct A { typealias B = C  }
    //   typealias B = A.B
    //   struct C {}
    //
    //   extension B.C {}
    // Here, `extension B.C` depends on `(File.swift)::A>B == [typealias B = C]` (because of `typealias B = A.B`)
    // and `(File.swift)::A>C == []` so that `typealias B = C` resolves to `(File.swift)::C`.
    // We denote these dependencies of an extension `x` as the list `dependencies(x)`
    // where the dependencies appear in the order in which they appear during type resolution.
    // Each element of the list is a tuple of the qualified type, the type identifier, and the set
    // of type declarations to which they refer.
    // So in the above example, `dependencies(x)={
    //   [`(File.swift)::A`, `B`, (`typealias B = C`)],
    //   [`(File.swift)::A`, `C`, ()]
    // }
    //
    // So we define the `invalidates(x,y)` function which, given an extension `x` that
    // successfully evaluated to qualified name `τ_χ`, it checks if it
    // invalidates an extension `y`'s type resolution. Namely, it returns true iff
    // `x` introduces a type member μ such that `dependencies(y)` contains
    // `(τ_x, identifier(μ), (μ_1, ..., μ_n))` so that `μ_i!=μ` for all `i=1,...,n`.
    //
    // Based on `invalidates(x,y)`, we define `recursivelyInvalidates(x,y)` to handle
    // something like
    //
    // ```swift
    // struct A {}
    // struct B {}
    //
    // extension A { typealias C = B }
    // //        |- Depends on : `()`
    // //        |- Resolves to: `(File.swift)::A`
    // //        `- Introduces : `(File.swift)::A>C`
    //
    // extension A.C { typealias D = A }
    // //        |- Depends on : `(File.swift)::A>C`, `(File.swift)::A>B`
    // //        |- Resolves to: `(File.swift)::B`
    // //        `- Introduces : `(File.swift)::B>D`
    //
    // extension B { typealias E = D }
    // //        |- Depends on : ()
    // //        |- Resolves to: `(File.swift)::B`
    // //        `- Introduces : `(File.swift)::B>E`
    //
    // extension B.E { struct B {} }
    // //       |- Depends on : `(File.swift)::B>E`, `(File.swift)::B>D`, `(File.swift)::B>A`
    // //       |- Resolves to: `(File.swift)::A`
    // //       `- Introduces : `(File.swift)::A>B
    // ```
    // TODO: This example doesn't provide an example where we need recursive invalidation.
    //
    // To avoid cycles, we stipulate that to bind an extension `x` (that resolved
    // successfully), each currently bound extension `y` (also successfully evaluated)
    // must satisfy that `invalidates(y, x) = false`.
    // This is an example of why transitive dependencies matter:
    // TODO: Do we need recursive invalidation?
    //
    // Note that this doesn't form a cycle. Extension `x` with type members τ_{x, 1}, ..., τ_{x,n}
    // (with repetition allowed) invalidates extensions `y_j` from `j=1,..., m` when
    // `dependencies(y_j)\cap \set{τ_{x, 1}, ..., τ_{x,n}}\ne \varnothing`. So for some `y_j`
    // to invalidate `x`, it or one of the extensions it invalidates must contain a type member
    // `τ_{y_j, k}=τ_{x, i}` for some k and i.
    //
    // That's because for a cycle to form,
    // the extensions we invalidate must then invalidate us (this extension).
    // For the invalidated extensions to invalidate us, we must be relying on
    // type members
    // Note that invalidating extensions that depend on this extension's type
    // members doesn't form a cycle because we checked that this extension doesn't
    // transitively depend on said members. TODO: Refine wording

    // Save extension
    extensionState[extensionDecl] = newExtensionState
    // Remove from unresovled
    unresolvedFileExtensions.remove(extensionDecl)
    unresolvedExtensions[sourceFile] = unresolvedFileExtensions

    // Return which extensions broke
    return .success(invalidatedExtensions)
  }
}
