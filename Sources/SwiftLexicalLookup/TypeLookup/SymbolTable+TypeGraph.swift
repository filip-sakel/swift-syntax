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

// MARK: Requested Extensions

extension SymbolTable {
  struct RequestedExtensions {
    fileprivate private(set) var current: Attached<ExtensionDeclSyntax>?
    private var requestedArray: [Attached<ExtensionDeclSyntax>]
    private var requestedSet: Set<Attached<ExtensionDeclSyntax>>

    init() {
      self.current = nil
      (self.requestedArray, self.requestedSet) = ([], [])
    }

    /// Appends the requested extensions
    ///
    /// Complexity: O(n) where `n` is the number of `elements`.
    mutating func append(contentsOf elements: [Attached<ExtensionDeclSyntax>]) {
      for element in elements {
        // Don't add the currently processing array
        guard current != element else { continue }
        // Add the extension if not already in the set.
        guard requestedSet.insert(element).inserted else { continue }
        requestedArray.append(element)
      }
    }

    /// Returns the last index and element of the requestedExtensions without
    /// popping; `nil` if empty.
    ///
    /// Precondition: No extensions are currently bound, i.e., the previous
    /// `current == nil`.
    ///
    /// Complexity: O(1) with respect to the number of requested extensions.
    mutating func beginPop() -> Attached<ExtensionDeclSyntax>? {
      // Both of the following calls are O(1)
      guard let extensionDecl = requestedArray.popLast() else { return nil }
      requestedSet.remove(extensionDecl)

      if let current {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly popped extension `\(extensionDecl._memberlessDescription)` while binding other extension `\(current._memberlessDescription)`"
        )
      }
      current = extensionDecl
      return extensionDecl
    }
    /// Removes the requested extension at the given index if it exists, or
    /// returns `nil`.
    ///
    /// Precondition: The given extension is `current`.
    ///
    /// Complexity: O(1) with respect to the number of requested extensions.
    mutating func finalizePop(_ extensionDecl: Attached<ExtensionDeclSyntax>) {
      // Ensure we're finalizing the right extension
      precondition(
        extensionDecl == current,
        "[SwiftLexicalLookup] Internal error: Unexpectedly found different requested extension:  popped `\(extensionDecl._memberlessDescription)`; finalized `\(current?._memberlessDescription ?? "nil")`)"
      )
      // Reset the current
      current = nil
    }
  }
}

// MARK: Extension Finder

extension SymbolTable {
  /// Returns a map of each file to the file's extensions (in-order and without duplicates).
  internal func _findUnresolvedExtensions() -> [SourceFileSyntax: [Attached<ExtensionDeclSyntax>]] {
    var result = [SourceFileSyntax: [Attached<ExtensionDeclSyntax>]]()
    for (_, files) in moduleToSources {
      for (_, file) in files {
        guard let fileInfo = getFileInfo(file) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly cannot get configured regions for registered file."
          )
        }
        // Note: findExtensions gurantees in-order and no duplicates
        result[file] = file.findExtensions(configuredRegions: fileInfo.configuredRegions)
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
    declFileInfo: FileInfo,
    isGlobal: Bool,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> Result<TypeResolver.ResolvedTypeSyntax, TypeGraph.NominalRegistrationFailure> {
    return typeGraph.registerNominalType(
      topScopeMainDecl: topScopeMainDecl,
      declName: declName,
      declFileInfo: declFileInfo,
      isGlobal: isGlobal,
      symbolTable: self
    ).map({ nominalRef in
      TypeResolver.ResolvedTypeSyntax(
        type: nominalRef,
        syntax: originatingSyntax
      )
    })
  }
  /// Registers nominal type by forwarding to `TypeGraph/registerNominalType`
  func registerNominalType(
    nestedMainDecl: Attached<NominalTypeDeclSyntax>,
    declName: Identifier,
    declFileInfo: FileInfo,
    baseDeclGroup: Attached<DeclGroupSyntaxType>,
    baseType: TypeResolver.ResolvedTypeSyntax,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> Result<TypeResolver.ResolvedTypeSyntax, TypeGraph.NestedNominalRegistrationFailure> {
    return typeGraph.registerNominalType(
      nestedMainDecl: nestedMainDecl,
      declName: declName,
      declFileInfo: declFileInfo,
      baseDeclGroup: baseDeclGroup,
      baseType: baseType.type,
      symbolTable: self
    ).map({ nominalRef in
      TypeResolver.ResolvedTypeSyntax(
        type: nominalRef,
        syntax: originatingSyntax
      )
    })
  }
}

// MARK: Extension Binding

extension SymbolTable {
  @_spi(_QualifiedLookupTests) public enum ExtensionBindingFailure: Error {
    /// Either root isn't a source file, or said source file isn't registered
    case nonRegisteredSyntaxRoot

    case admissionFailure(TypeGraph.ExtensionAdmissionFailure)
  }

  func getExtensionResolvedType(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<TypeResolver.GloballyResolvedTypeSyntax, TypeResolver.Failure>? {
    typeGraph.getExtensionResolvedType(extensionDecl)?.map({ (globalReference, mainDecl) in
      TypeResolver.GloballyResolvedTypeSyntax(
        type: globalReference,
        syntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
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
      (qualifiedName: TypeGraph.GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencies: DependencyTracker,
    verbose: Bool
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // Get extension module and its file's configured regions
    guard let fileInfo = getFileInfo(extensionDecl.fileRoot) else {
      return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    }
    let admissionResult = typeGraph.admitExtension(
      extensionDecl,
      extensionDeclModule: fileInfo.module,
      extensionFileConfiguredRegions: fileInfo.configuredRegions,
      to: result,
      dependencyTracker: dependencies,
      symbolTable: self
    )

    // Log results
    //
    // Describe dependencies
    // TODO: Clean this up
    let dependencyDescription = "[\(dependencies.dependencies.map(\.debugDescription).joined(separator: ", "))]"
    // Describe result
    let admissionResultDescriptions = admissionResult.map({ results in
      results.invalidatedExtensions.map({ result in
        "\(result.extensionDecl._memberlessDescription) -> \(result.resolvedType)"
      }).joined(separator: ", ")
    })
    // New graph description
    if verbose {
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
      //
      // Note: This removal takes linear time. If a file has a lot of extensions, this operation
      // could end up being slow.
      unresolvedExtensions[extensionDecl.fileRoot, default: []].removeAll(where: { $0 == extensionDecl })

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
    let willBindRequests = self.requestedExtensions.current == nil

    // Register the extensions to be processed.
    //
    // Note: `requestedExtensions.append` doesn't introduce
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
    while let extensionDecl = self.requestedExtensions.beginPop() {
      // The result can change after binding more extensions; ignore for now.
      let _ = bindRequestedExtension(extensionDecl)

      // We remove at the end of the iteration because we want nested syntax-resolution
      // requests to see that we're actively trying to bind this extension.
      self.requestedExtensions.finalizePop(extensionDecl)
    }

    assert(
      self.requestedExtensions.current == nil,
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
  ) -> Result<TypeResolver.GloballyResolvedTypeSyntax, TypeResolver.Failure> {
    withLogging(
      request: "Binding `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription
    ) {
      $0._bindRequestedExtension(extensionDecl)
    }
  }

  /// Implements `bindRequestedExtension`
  ///
  /// - Precondition: `extensionDecl` must be in `self.requestedExtensions`
  /// FIXME: Make _bindExtension handle other generated requests;
  /// e.g. if we're resolving `extension A.B {}`, we will prob have to fully resolve `A`.
  private func _bindRequestedExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<TypeResolver.GloballyResolvedTypeSyntax, TypeResolver.Failure> {
    // Uphold invariant
    assert(
      self.requestedExtensions.current == extensionDecl,
      "[SwiftLexicalLookup] Internal error: Called `bindRequestedExtension` without first calling to `self.requestedExtensions.beginPop()`."
    )

    // TODO: Remove
    func mapToNominalTypeReference(
      _ typeInfo: (globalReference: TypeGraph.GlobalTypeRef, mainDecl: Attached<NominalTypeDeclSyntax>)
    ) -> TypeResolver.GloballyResolvedTypeSyntax {
      TypeResolver.GloballyResolvedTypeSyntax(
        type: typeInfo.globalReference,
        syntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    }

    // Return saved result if the extension was already admitted to the graph
    // TODO: Should this ever happen?
    if let existingResolution = typeGraph.getExtensionResolvedType(extensionDecl) {
      return existingResolution.map(mapToNominalTypeReference(_:))
    }

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
        return (extendedTypeReference.type.name, extendedTypeReference.type.mainDecl)
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

    self.requestedExtensions.append(contentsOf: invalidatedExtensions.map(\.extensionDecl))
    return resolvedType.map(mapToNominalTypeReference(_:))
  }
}

// MARK: Qualified Type Lookup

extension SymbolTable {
  func findMemberType(
    baseType: TypeGraph.TypeRef,
    memberTypeName: Identifier,
    introducingTypeSyntax: Attached<TypeLikeSyntax>,
    introducingModule: ModuleName,
    dependencyTracker: inout DependencyTracker
  ) -> Result<
    [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)],
    TypeGraph.QualifiedTypeLookupFailure
  > {
    // Assert we have the right module
    let fileModule = getFileInfo(introducingTypeSyntax.fileRoot)?.module
    assert(
      fileModule == introducingModule,
      "[SwiftLexicalLookup] Internal error: Caller passed wrong module for `\(introducingTypeSyntax.trimmedDescription)`: got '\(introducingModule.name)' but expected \(fileModule?.name ?? "nil")"
    )

    // TODO: Remove?
    log("Finding member \(baseType) > \(memberTypeName.name)")
    defer { log("New deps for member-type lookup: \(dependencyTracker.dependencies)") }

    return typeGraph.findMemberType(
      baseType: baseType,
      memberTypeName: memberTypeName,
      origin: (typeSyntax: introducingTypeSyntax, module: introducingModule),
      dependencyTracker: &dependencyTracker,
      symbolTable: self
    )
  }
}
