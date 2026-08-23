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

// MARK: Extension Finder

extension SymbolTable {
  internal func _findUnresolvedExtensions() -> [SourceFileSyntax: OrderedSet<Attached<ExtensionDeclSyntax>>] {
    var result = [SourceFileSyntax: OrderedSet<Attached<ExtensionDeclSyntax>>]()
    for (_, files) in moduleToSources {
      for (_, file) in files {
        guard case .success(let fileConfiguredRegions) = getConfiguredRegions(forFile: file) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly cannot get configured regions for registered file."
          )
        }
        result[file] = file.findExtensions(configuredRegions: fileConfiguredRegions)
      }
    }
    return result
  }
}

// MARK: Registering Nominal

extension SymbolTable {
  /// Registers nominal type by forwarding to `TypeGraph/registerNominalType`
  func registerNominalType(
    topScopeMainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileConfiguredRegions: ConfiguredRegions?,
    declModule: ModuleName,
    isGlobal: Bool,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> Result<ResolvedNominalTypeReference, TypeGraph.NominalRegistrationFailure> {
    return typeGraph.registerNominalType(
      topScopeMainDecl: topScopeMainDecl,
      declName: declName,
      declFileConfiguredRegions: declFileConfiguredRegions,
      declModule: declModule,
      isGlobal: isGlobal,
      symbolTable: self
    ).map({ nominalRef in
      ResolvedNominalTypeReference(
        nominalTypeRef: nominalRef,
        originatingSyntax: originatingSyntax
      )
    })
  }
  /// Registers nominal type by forwarding to `TypeGraph/registerNominalType`
  func registerNominalType(
    nestedMainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileConfiguredRegions: ConfiguredRegions?,
    declModule: ModuleName,
    baseDeclGroup: Attached<DeclGroupSyntaxType>,
    baseType: ResolvedNominalTypeReference,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> Result<ResolvedNominalTypeReference, TypeGraph.NestedNominalRegistrationFailure> {
    return typeGraph.registerNominalType(
      nestedMainDecl: nestedMainDecl,
      declName: declName,
      declFileConfiguredRegions: declFileConfiguredRegions,
      declModule: declModule,
      baseDeclGroup: baseDeclGroup,
      baseType: baseType.nominalTypeRef,
      symbolTable: self
    ).map({ nominalRef in
      ResolvedNominalTypeReference(
        nominalTypeRef: nominalRef,
        originatingSyntax: originatingSyntax
      )
    })
  }
}

@_spi(_QualifiedLookupTests) public enum ExtensionBindingFailure: Error {
  /// Either root isn't a source file, or said source file isn't registered
  case nonRegisteredSyntaxRoot

  case admissionFailure(TypeGraph.ExtensionAdmissionFailure)
}

// MARK: Extension Binding

extension SymbolTable {
  typealias InvalidatedExtensions = OrderedSet<ExtensionDeclSyntax>
  typealias ExtensionBindingFailure = SwiftLexicalLookup.ExtensionBindingFailure

  func getExtensionResolvedType(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<
    GenericResolvedNominalTypeReference<GlobalNominalTypeRef>,
    BindingFailure
  >? {
    typeGraph.getExtensionResolvedType(extensionDecl)?.map({ (globalReference, mainDecl) in
      GenericResolvedNominalTypeReference<GlobalNominalTypeRef>(
        nominalTypeRef: globalReference,
        originatingSyntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }

  /// Add extension to the type graph and, if possible, bind it
  /// to the resolved nominal type.
  ///
  /// Notes
  /// 1. Helper for  that forwards to `TypeGraph/admitExtension`
  /// 2. Handles failed resolutions and resolutions that cause cycles.
  ///
  /// Returns: Evicted extensions or binding failure.
  /// TODO: Consider inlining into `_bindRequestedExtension`
  fileprivate func _admitExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    to result: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencies: DependencyTracker,
    verbose: Bool
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // Get extension module and its file's configured regions
    guard
      let module = moduleMap[extensionDecl.fileRoot],
      case .success(let fileConfiguredRegions) = getConfiguredRegions(forFile: extensionDecl.fileRoot)
    else {
      return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    }
    let admissionResult = typeGraph.admitExtension(
      extensionDecl,
      extensionDeclModule: module,
      extensionFileConfiguredRegions: fileConfiguredRegions,
      to: result,
      dependencyTracker: dependencies,
      symbolTable: self
    )

    // Log results
    //
    // TODO: Add behind verbose flag
    //
    // Describe dependencies
    let dependencyDescription = "[\(dependencies.dependencies.map(\.debugDescription).joined(separator: ", "))]"
    // Describe result
    let admissionResultDescriptions = admissionResult.map({ results in
      results.invalidatedExtensions.map({ result in
        "\(result.extensionDecl._memberlessDescription) -> \(result.resolvedType)"
      }).joined(separator: ", ")
    })
    // New graph description
    // TODO: Remove once done debugging
    if false || verbose {
      let (typeGraphDescription, hasErrors) = typeGraph._describe(symbolTable: self)
      print(String(repeating: "-", count: 80))
      print(
        "After admitting extension `\(extensionDecl._memberlessDescription)` to \(result.map(\.qualifiedName.debugDescription)) with dependencies: \(dependencyDescription); admission result (i.e. invalidated exts): \(admissionResultDescriptions), new dependency graph is:"
      )
      print(typeGraphDescription)
      print(String(repeating: "-", count: 80) + "\n")
      precondition(!hasErrors, "[SwiftLexicalLookup] Internal error: Detected dependency-graph corruption.")
    }

    switch admissionResult {
    case .success(let success):
      // If successfully bound, remove from `unresolvedExtensions`
      unresolvedExtensions[extensionDecl.fileRoot]?.remove(extensionDecl)

      return .success(success)
    case .failure(let admissionFailure):
      return .failure(ExtensionBindingFailure.admissionFailure(admissionFailure))
    }
  }
}

// MARK: Extension Binding 2

extension SymbolTable {
  /// Tries to bind the given extension; returns `nil` or failure.
  ///
  /// If no binding request is already underway, the given extensions
  /// should be admitted to the graph after this call. Otherwise, the provided
  /// extensions are queued up for the existing request to handle.
  @_spi(_QualifiedLookupTests) public func admitExtensions(
    _ extensionDecls: [Attached<ExtensionDeclSyntax>]
  ) {
    withLogging(
      request: "Admitting extensions: \(extensionDecls.map(\._memberlessDescription))",
      describe: { _ in "" },
      perform: {
        $0._admitExtensions(extensionDecls)
      }
    )
  }

  /// Implements `admitExtensions`
  // TODO: At least find a way to cache available extensions. (E.g. don't
  // recalculate accessible extensions if ongoing request targetted the same file)
  fileprivate func _admitExtensions(
    _ extensionDecls: [Attached<ExtensionDeclSyntax>]
  ) {
    // Whether we will bind the requested extensions or we'll delegate to an
    // ongoing request
    let willBindRequests = self.requestedExtensions.isEmpty

    // Register the extensions to be processed.
    //
    // Note: `requestedExtensions` is an `OrderedSet` so we don't introduce
    // duplicates.
    self.requestedExtensions.append(contentsOf: extensionDecls)

    // Ensure there's no binding request underway
    guard willBindRequests else {
      // This request will be handled after the current binding (see
      // `admitExtensions` docstring).
      // TODO: Is this the right failure type?
      return
    }

    // Handle all binding requests
    //
    // We use a while loop since a single binding request may generate more
    // binding requests. E.g., Say we want to resolve:
    // ```swift
    // struct A {}
    // extension A.B {
    //   func f(_: Self) {} // <- Look up here
    // }
    // extension A { struct B {} }
    // ```
    // Then, `Self` will only try to bind `extension A.B` but to resolve `A.B`, we
    // need to fully resolve `A` so we also have to bind `extension A`.
    while let extensionDecl = self.requestedExtensions.first {
      // We remove at the end of the iteration because we want nested syntax-resolution
      // requests to see that we're actively trying to bind this extension.
      defer {
        // TODO: Ensure .last and .removeLast are ok (or if we should do a queue-like approach.
        let poppedExtension = self.requestedExtensions.removeFirst()
        assert(
          poppedExtension == extensionDecl,
          "[SwiftLexicalLookup] Internal error: Unexpectedly found different requested extension when popping."
        )
      }

      // The result can change after binding more extensions; ignore for now.
      _ = _bindRequestedExtension(extensionDecl)
    }

    assert(
      self.requestedExtensions.isEmpty,
      "[SwiftLexicalLookup] Internal error: Requested extensions still not admitted after `bindExtensions`."
    )
  }

  /// Admits the given extension added to `self.requestedExtensions`. Only
  /// `bindExtensions` should call this method.
  ///
  /// Handles extensions already admitted to the graph, and fixes
  /// invalidated extensions.
  ///
  /// - Precondition: `extensionDecl` must be in `self.requestedExtensions`
  private func bindRequestedExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, TypeResolver.Failure> {
    withLogging(
      request: "Binding `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription
    ) {
      $0._bindRequestedExtension(extensionDecl)
    }
  }

  /// Prepends given elements. New elements get added as expected and existing elements
  /// get moved to the front of the list. Despite the current elements of the ordered set,
  /// the new set will always start out with a deduplicated set of `elements`.
  /// TODO: Remove if we have no references to this
  func prepend<E: Hashable>(to orderedSet: inout OrderedSet<E>, contentsOf elements: [E]) {
    let oldElements = orderedSet
    orderedSet.removeAll(keepingCapacity: true)
    orderedSet.append(contentsOf: elements)
    orderedSet.append(contentsOf: oldElements)
  }

  /// Implements `bindRequestedExtension`
  ///
  /// - Precondition: `extensionDecl` must be in `self.requestedExtensions`
  /// FIXME: Make _bindExtension handle other generated requests;
  /// e.g. if we're resolving `extension A.B {}`, we will prob have to fully resolve `A`.
  private func _bindRequestedExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, TypeResolver.Failure> {
    // Uphold invariant
    assert(
      self.requestedExtensions.contains(extensionDecl),
      "[SwiftLexicalLookup] Internal error: Called `bindRequestedExtension` without first adding to `self.requestedExtensions`."
    )

    // TODO: Remove
    func mapToNominalTypeReference(
      _ typeInfo: (globalReference: GlobalNominalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>)
    ) -> GenericResolvedNominalTypeReference<GlobalNominalTypeRef> {
      GenericResolvedNominalTypeReference<GlobalNominalTypeRef>(
        nominalTypeRef: typeInfo.globalReference,
        originatingSyntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    }

    // Return saved result if the extension was already admitted to the graph
    // TODO: Should this ever happen?
    if let existingResolution = typeGraph.getExtensionResolvedType(extensionDecl) {
      return existingResolution.map(mapToNominalTypeReference(_:))
    }

    // TODO: Extension binding uses its own visitedTypeSyntax; also pass `visitedTypeSyntax` to every function.

    // === Resolve Extension ===

    // Resolve the extended type, tracking dependencies
    //
    // Note: We don't add these dependencies to our dependencies since
    // this is considered a completely separate type resolution. We
    // track these dependencies in the symbol table's corresponding
    // extension state.
    var resolver = TypeResolver(symbolTable: self, _verbose: _verbose)
    let extendedTypeResult = resolver._resolveExtendedTypeSyntax(extensionDecl: extensionDecl)

    // Register in the symbol table to get invalidated extensions
    let bindingResult: Result<BindingResult, SymbolTable.ExtensionBindingFailure>
    bindingResult = _admitExtension(
      extensionDecl,
      // Only get the name and main decl
      to: extendedTypeResult.map({ extendedTypeReference in
        return (extendedTypeReference.nominalTypeRef.name, extendedTypeReference.nominalTypeRef.mainDecl)
      }),
      dependencies: resolver.dependencyTracker,
      verbose: _verbose
    )

    // Extract the invalidated extensions or handle failures
    let (resolvedType, invalidatedExtensions): BindingResult
    switch bindingResult {
    case .success(let success):
      (resolvedType, invalidatedExtensions) = success
    case .failure(let failure):
      // Ensure we handle future failure types
      switch failure {
      case .nonRegisteredSyntaxRoot:
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly not in symbol table"
        )
      case .admissionFailure(.cannotReadmit(let existingState)):
        // We check there's no state at the start of the function

        // TODO: Remove
        // print(
        //   "[SwiftLexicalLookup] Internal error: Tried to readmit `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
        // )
        // return symbolTable.typeGraph.getExtensionResolvedType(extensionDecl)!.map(mapToNominalTypeReference(_:))
        fatalError(
          "[SwiftLexicalLookup] Internal error: Tried to readmit `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
        )
      case .admissionFailure(.invalidDependencyExtension(let extensionState)):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly has wrong dependency; state \(extensionState.debugDescription)."
        )
      }
    }
    log(
      "Resolved to \(extendedTypeResult); Dependencies: \(resolver.dependencyTracker.dependencies.map(\.debugDescription)); Invalidated: \(invalidatedExtensions.map(\ExtensionState.extensionDecl._memberlessDescription))"
    )

    // TODO: Does this even work?
    // prepend(to: &self.requestedExtensions, contentsOf: invalidatedExtensions.map(\.extensionDecl))
    self.requestedExtensions.append(contentsOf: invalidatedExtensions.map(\.extensionDecl))
    return resolvedType.map(mapToNominalTypeReference(_:))

    // FIXME: Get rid of below code or sm.
    //
    // // === Fix Invalidated Extensions ===
    // //
    // // We use a for loop because fixing one invalidated extension may invalidate
    // // other extensions.
    // var invalidatedExtensionsStack = invalidatedExtensions
    // // TODO: Pull out invalidateExtension into its own function
    // while let invalidatedExtension = invalidatedExtensionsStack.first {
    //   //  TODO: Could we straight-up pop during the while let loop-condition.
    //   defer {
    //     let poppedExtension = invalidatedExtensionsStack.removeFirst()
    //     assert(
    //       poppedExtension.extensionDecl == invalidatedExtension.extensionDecl,
    //       "[SwiftLexicalLookup] Internal error: Unexpectedly found different invalidated extension when popping."
    //     )
    //   }
    //
    //   self.requestedExtensions.append(invalidatedExtension.extensionDecl)
    //   _ = _bindExtension(invalidatedExtension.extensionDecl)
    //   let removed = self.requestedExtensions.removeLast()
    //   assert(
    //     removed == invalidatedExtension.extensionDecl,
    //     "[SwiftLexicalLookup] Internal error: Unexpectedly found different invalidated extension when popping."
    //   )
    //   continue
    //
    //   // TODO: Remove following
    //
    //   // Re-resolve with dependency tracking
    //   log("Recomputing invalidated `\(invalidatedExtension.extensionDecl._memberlessDescription)`")
    //   let (_, _, nestedInvalidatedExtensions) = withLogging(
    //     request: "Fixing invalidated `\(invalidatedExtension.extensionDecl._memberlessDescription)`",
    //     describe: {
    //       (
    //         extendedTypeResult: Result<ResolvedNominalTypeReference, Failure>,
    //         extensionDependencies: DependencyTracker,
    //         invalidatedExtensions: InvalidatedExtensions
    //       ) in
    //       "\(extendedTypeResult._debugDescription); Dependencies: \(extensionDependencies.dependencies.map(\.debugDescription))"
    //     },
    //     perform: {
    //       var extensionDependencies = DependencyTracker()
    //       let extendedTypeResult: Result<ResolvedNominalTypeReference, Failure> = $0._resolveExtendedTypeSyntax(
    //         extensionDecl: invalidatedExtension.extensionDecl,
    //         memberDependencies: &extensionDependencies
    //       )
    //
    //       // Register in the symbol table
    //       let nestedBindingResult =
    //         $0.symbolTable.fixInvalidatedExtension(
    //           invalidatedExtension.extensionDecl,
    //           // Only get the name
    //           to: extendedTypeResult.map({ (typeReference: ResolvedNominalTypeReference) in
    //             // FIXME: This assert shouldn't exist; extension decl should just give us a global type.
    //             guard case .topLevel(let extendedGlobalName) = typeReference.qualifiedName else {
    //               fatalError(
    //                 "[SwiftLexicalLookup] Internal error: Unexpectedly resolved extension to local type \(typeReference.qualifiedName)"
    //               )
    //             }
    //             return (extendedGlobalName, typeReference.mainDecl)
    //           }),
    //           dependencies: extensionDependencies
    //         ) as Result<BindingResult, SymbolTable3.ExtensionBindingFailure>
    //
    //       // Return results or handle failures
    //       switch nestedBindingResult {
    //       case .success(let success):
    //         return (extendedTypeResult, extensionDependencies, success.invalidatedExtensions)
    //       case .failure(let failure):
    //         // Ensure we handle future failure types
    //         switch failure {
    //         case .nonRegisteredSyntaxRoot:
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly not in symbol table"
    //           )
    //         case .admissionFailure(.cannotReadmit(let existingState)):
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Tried to fix admitted extension `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
    //           )
    //         case .admissionFailure(.invalidDependencyExtension(let extensionState)):
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly has wrong dependency; state \(extensionState.debugDescription)."
    //           )
    //         }
    //       }
    //     }
    //   )
    //
    //   // Enqueue invalidated extensions
    //   invalidatedExtensionsStack.append(contentsOf: nestedInvalidatedExtensions)
    // }
    //
    // return resolvedType.map(mapToNominalTypeReference(_:))
  }
}

// MARK: Qualified Type Lookup

extension SymbolTable {
  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    introducingTypeSyntax: Attached<TypeLikeSyntax>,
    introducingModule: ModuleName,
    dependencyTracker: inout DependencyTracker,
  ) -> Result<
    [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)],
    TypeGraph.QualifiedTypeLookupFailure
  > {
    assert(
      moduleMap[introducingTypeSyntax.fileRoot] == introducingModule,
      "[SwiftLexicalLookup] Internal error: Caller passed wrong module for `\(introducingTypeSyntax.trimmedDescription)`: got '\(introducingModule.name)' but expected \(moduleMap[introducingTypeSyntax.fileRoot].debugDescription)"
    )

    // TODO: Remove
    if _verbose {
      print("Finding member \(baseType) > \(memberTypeName.name)")
    }
    defer {
      if _verbose {
        print("New deps for member-type lookup: \(dependencyTracker.dependencies)")
      }
    }

    return typeGraph.findMemberType(
      baseType: baseType,
      memberTypeName: memberTypeName,
      origin: (typeSyntax: introducingTypeSyntax, module: introducingModule),
      moduleMap: moduleMap,
      dependencyTracker: &dependencyTracker,
      symbolTable: self
    )
  }
}
