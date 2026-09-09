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
    /// The extensions that have not yet been admitted to the type graph.
    fileprivate private(set) var unresolvedExtensions: [SourceFileSyntax: [Attached<ExtensionDeclSyntax>]]
    private var requestedArray: [Attached<ExtensionDeclSyntax>]
    private var requestedSet: Set<Attached<ExtensionDeclSyntax>>

    /// Initialize `RequestedExtensions`, keeping track of unresolved extensions.
    ///
    /// Complexity: O(n) where `n` is the number of extensions across all files.
    init(fileToInfo: [SourceFileSyntax: FileInfo]) {
      // Find all the unresolved extensions
      var unresolvedExtensions = [SourceFileSyntax: [Attached<ExtensionDeclSyntax>]]()
      for (file, fileInfo) in fileToInfo {
        // Note: findExtensions gurantees in-order and no duplicates
        unresolvedExtensions[file] = file.findExtensions(configuredRegions: fileInfo.configuredRegions)
      }

      self.current = nil
      (self.requestedArray, self.requestedSet) = ([], [])
      self.unresolvedExtensions = unresolvedExtensions
    }

    /// Appends the requested extensions
    ///
    /// Complexity: O(n) where `n` is the number of `elements`.
    private mutating func append(contentsOf elements: [Attached<ExtensionDeclSyntax>]) {
      for element in elements {
        // Don't add the currently processing array
        guard current != element else { continue }
        // Add the extension if not already in the set.
        guard requestedSet.insert(element).inserted else { continue }
        requestedArray.append(element)
      }
    }

    /// Complexity: O(n) where `n` is the number of extensions in `sourceFile`.
    mutating func request(sourceFile: SourceFileSyntax) {
      guard let sourceFileExtensions = unresolvedExtensions.removeValue(forKey: sourceFile) else {
        // Return if already removed
        return
      }
      append(contentsOf: sourceFileExtensions)
    }

    /// Complexity: O(n) where `n` is the number of extensions in `extensionDecl`
    /// file root.
    mutating func request(extensionDecl: Attached<ExtensionDeclSyntax>) {
      // Return if the file is resolved
      guard var sourceFileExtensions = unresolvedExtensions[extensionDecl.fileRoot] else { return }
      // Return if the extension is resolved (in an unresolved file)
      guard let unresolvedExtensionIndex = sourceFileExtensions.firstIndex(of: extensionDecl) else { return }
      // Mark as resolved
      sourceFileExtensions.remove(at: unresolvedExtensionIndex)
      unresolvedExtensions[extensionDecl.fileRoot] = sourceFileExtensions

      // Add the request
      append(contentsOf: [extensionDecl])
    }

    /// Complexity: O(n) where `n` is the number of extensions.
    fileprivate mutating func request(evictedExtensions: [Attached<ExtensionDeclSyntax>]) {
      append(contentsOf: evictedExtensions)
    }

    fileprivate var alreadyProcessing: Bool {
      current != nil
    }

    /// Returns the last index and element of the requestedExtensions without
    /// popping; `nil` if empty.
    ///
    /// Precondition: No extensions are currently bound, i.e., the previous
    /// `current == nil`.
    ///
    /// Complexity: O(1) with respect to the number of requested extensions.
    fileprivate mutating func beginPop() -> Attached<ExtensionDeclSyntax>? {
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
    fileprivate mutating func finalizePop(_ extensionDecl: Attached<ExtensionDeclSyntax>) {
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

// MARK: Extension Requests

extension SymbolTable {
  @_spi(_QualifiedLookupTests)
  public func admitExtensions(accessibleFrom sourceFile: SourceFileSyntax) {
    // Whether we will bind the requested extensions or we'll delegate to an
    // ongoing request
    let alreadyProcessing = self.requestedExtensions.alreadyProcessing

    // Request all accessible files (for now, this is just internal files)
    // TODO: Include external/imported modules
    for (_, sourceFile) in moduleToSources[moduleName, default: [:]] {
      self.requestedExtensions.request(sourceFile: sourceFile)
    }

    // Admit requests (if no request is already underway)
    if !alreadyProcessing { _admitRequestedExtensions() }
  }

  /// Returns the nominal-type reference with the extension's extended-type
  /// syntax as the originating syntax.
  @_spi(_QualifiedLookupTests)
  public func bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<TypeResolver.GloballyResolvedTypeSyntax, TypeResolver.Failure> {
    // We check here because `request(extensionDecl:)` takes `O(n)` time to update
    // the unresolvedFiles dictionary.
    if let alreadyBoundResult = getExtensionResolvedType(extensionDecl) {
      return alreadyBoundResult
    }

    // Whether we will bind the requested extensions or we'll delegate to an
    // ongoing request
    let alreadyProcessing = self.requestedExtensions.alreadyProcessing

    // Request extension
    self.requestedExtensions.request(extensionDecl: extensionDecl)

    // Admit requests (if no request is already underway)
    if !alreadyProcessing { _admitRequestedExtensions() }

    // If there's not an existing extension-binding request, the extension
    // should be admitted. Otherwise, return a failure for now.
    guard let boundTypeResult = typeGraph.getExtensionResolvedType(extensionDecl) else {
      // The extension graph tracks dependencies so this result should be
      // invalidated and fixed after the primary extension-binding request
      // completes.
      return .failure(.extensionNotBoundYet)
    }

    return boundTypeResult.map({ (globalReference, mainDecl) in
      TypeResolver.GloballyResolvedTypeSyntax(
        type: globalReference,
        syntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }
}

// MARK: Extension Binding

extension SymbolTable {
  /// Tries to admit all requested extensions, handling new requests in the
  /// process.
  fileprivate func _admitRequestedExtensions() {
    log("Admitting all requested extensions")

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
    while self._admitCurrentExtension() {}

    assert(
      self.requestedExtensions.current == nil,
      "[SwiftLexicalLookup] Internal error: Requested extensions still not admitted after `bindExtensions`."
    )
  }

  /// Admits the given extension added to `self.requestedExtensions`. Only
  /// `_admitCurrentExtension` should call this method.
  ///
  /// Handles extensions already admitted to the graph, and requests
  /// that evicted extensions be re-admitted.
  ///
  /// - Precondition: No extensions are currently bound, i.e., the
  /// `requestedExtensions.current == nil`
  private func _admitCurrentExtension() -> Bool {
    // Begin popping the current extension
    guard let extensionDecl = self.requestedExtensions.beginPop() else { return false }
    // We remove at the end because we want nested syntax-resolution
    // requests to see that we're actively trying to bind this extension.
    defer { self.requestedExtensions.finalizePop(extensionDecl) }

    log("Binding `\(extensionDecl._memberlessDescription)`")

    // === Resolve Extension ===

    // Get extension file info
    guard let fileInfo = getFileInfo(extensionDecl.fileRoot) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly not in symbol table"
      )
    }

    // Resolve the extended type, tracking dependencies
    //
    // Note: We don't add these dependencies to our dependencies since
    // this is considered a completely separate type resolution. We
    // track these dependencies in the symbol table's corresponding
    // extension state.
    var resolver = TypeResolver(symbolTable: self)
    let extendedTypeResult = resolver._resolveExtendedTypeSyntax(extensionDecl: extensionDecl)

    // Admit to the type graph and get evicted extensions
    let bindingResult: Result<BindingResult, TypeGraph.ExtensionAdmissionFailure>
    bindingResult = typeGraph.admitExtension(
      extensionDecl,
      extensionDeclModule: fileInfo.module,
      extensionFileConfiguredRegions: fileInfo.configuredRegions,
      // Extract the name and main decl
      to: extendedTypeResult.map({ extendedTypeReference in
        return (extendedTypeReference.type.name, extendedTypeReference.type.mainDecl)
      }),
      dependencyTracker: resolver.dependencyTracker,
      symbolTable: self
    )

    // Extract the invalidated extensions or handle failures
    let (resolvedType, evictedExtensions): BindingResult
    switch bindingResult {
    case .success(let success):
      (resolvedType, evictedExtensions) = success
    case .failure(let failure):
      // Ensure we handle future failure types
      switch failure {
      case .cannotReadmit(let existingState):
        // We require this as a precondition
        fatalError(
          "[SwiftLexicalLookup] Internal error: Tried to readmit `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
        )
      case .invalidDependencyExtension(let extensionState):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly has wrong dependency; state \(extensionState.debugDescription)."
        )
      }
    }
    log(
      "Resolved to \(resolvedType); Dependencies: \(resolver.dependencyTracker.dependencies.map(\.debugDescription)); Invalidated: \(evictedExtensions.map(\ExtensionState.extensionDecl._memberlessDescription))"
    )

    self.requestedExtensions.request(evictedExtensions: evictedExtensions.map(\.extensionDecl))

    return true
  }
}

// MARK: Qualified-Lookup Requests

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

// MARK: Registration Requests

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
}
