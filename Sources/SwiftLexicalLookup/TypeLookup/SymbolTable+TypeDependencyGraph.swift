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
        // TODO: Implement configuredRegions
        result[file] = file.findExtensions(configuredRegions: nil)
      }
    }
    return result
  }
}

// MARK: Registering Nominal

extension SymbolTable {
  enum NominalRegistrationFailure: Error {
    case invalidReregistration(existingMainDecl: NominalTypeDeclSyntax)
  }

  /// Register the given qualified name with the given main declaration.
  // func registerNominalTypeReference(
  //   qualifiedName: TypeName,
  //   mainDecl: Attached<NominalTypeDeclSyntax>
  // ) -> Result<NominalTypeRef, TypeDependencyGraph.NominalRegistrationFailure> {
  //   return dependencyGraph.registerNominalTypeReference(
  //     rawQualifiedName: qualifiedName,
  //     mainDecl: mainDecl,
  //     configuredRegions: configuredRegions
  //   )
  // }

  /// Like above but returns `ResolvedNominalTypeReference`
  func registerNominalTypeReference(
    qualifiedName: TypeName,
    mainDecl: Attached<NominalTypeDeclSyntax>,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> Result<ResolvedNominalTypeReference, TypeDependencyGraph.NominalRegistrationFailure> {
    return dependencyGraph.registerNominalTypeReference(
      rawQualifiedName: qualifiedName,
      mainDecl: mainDecl,
      configuredRegions: configuredRegions
    ).map({ nominalRef in
      ResolvedNominalTypeReference(
        nominalTypeRef: nominalRef,
        // We'll get a failure if `mainDecl` is a redeclaration.
        mainDecl: mainDecl,
        originatingSyntax: originatingSyntax
      )
    })
  }
}

@_spi(_QualifiedLookupTests) public enum ExtensionBindingFailure<TypeName: Sendable>: Error {
  /// Either root isn't a source file, or said source file isn't registered
  case nonRegisteredSyntaxRoot

  case admissionFailure(TypeDependencyGraph.ExtensionAdmissionFailure)
}

// MARK: Extension Binding

extension SymbolTable {
  typealias InvalidatedExtensions = OrderedSet<ExtensionDeclSyntax>
  typealias ExtensionBindingFailure = SwiftLexicalLookup.ExtensionBindingFailure<TypeName>

  /// Add extension to the symbol table and, if possible, bind it
  /// to the resolved nominal type. Cannot run on invalidated extensions.
  /// All invalidated extensions must be fixed before calling `bindExtension`
  /// again.
  ///
  /// Handles failed resolutions and resolutions that cause cycles.
  ///
  /// Returns: Broken extensions or binding failure.
  func bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    to result: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencies: DependencyTracker,
    verbose: Bool
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // TODO: Remove
    // // TODO: Refactor; super ugly (perhaps the caller should have this responsibility;
    // // also we get back a NominalTypeRef only to discard it)
    // if case .success(let (qualifiedName, mainDecl)) = result {
    //   let nominalRegistrationResult = dependencyGraph.registerNominalTypeReference(
    //     rawQualifiedName: TypeName.global(qualifiedName),
    //     mainDecl: mainDecl,
    //     configuredRegions: configuredRegions
    //   )
    //
    //   // TODO: Rewrite so we don't even have a failure
    //   // Ensure we succeed (guards against future cases)
    //   switch nominalRegistrationResult {
    //   case .success(_): break
    //   case .failure(TypeDependencyGraph.NominalRegistrationFailure.parentNotRegistered)
    //   }
    // }
    return _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: false,
      to: result,
      dependencies: dependencies,
      verbose: verbose
    )
  }

  func getExtensionResolvedType(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<
    GenericResolvedNominalTypeReference<GlobalNominalTypeRef>,
    BindingFailure
  >? {
    dependencyGraph.getExtensionResolvedType(extensionDecl)?.map({ (globalReference, mainDecl) in
      GenericResolvedNominalTypeReference<GlobalNominalTypeRef>(
        nominalTypeRef: globalReference,
        mainDecl: mainDecl,
        originatingSyntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }

  /// Similar to `bindExtension` but for the extensions that were invalidated.
  /// All invalidated extensions should be fixed before calling `bindExtension`
  /// again.
  func fixInvalidatedExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    to result: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencies: DependencyTracker,
    verbose: Bool
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    _admitExtension(
      extensionDecl,
      isUpdatingInvalidating: true,
      to: result,
      dependencies: dependencies,
      verbose: verbose
    )
  }

  /// Helper for `bindExtension` and `fixInvalidatedExtension`.
  fileprivate func _admitExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>,
    isUpdatingInvalidating isFixingInvalidating: Bool,
    to result: Result<
      (qualifiedName: GlobalTypeName, mainDecl: Attached<NominalTypeDeclSyntax>),
      TypeResolver.Failure
    >,
    dependencies: DependencyTracker,
    verbose: Bool
  ) -> Result<BindingResult, ExtensionBindingFailure> {
    // Get extension and module
    guard let module = moduleMap[extensionDecl.fileRoot] else {
      return .failure(ExtensionBindingFailure.nonRegisteredSyntaxRoot)
    }
    let admissionResult = dependencyGraph.admitExtension(
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
    // TODO: Remove once done debugging
    if false || verbose {
      let (dependencyGraphDescription, hasErrors) = dependencyGraph._describe(symbolTable: self)
      print(String(repeating: "-", count: 80))
      print(
        "After \(actionVerb) extension `\(extensionDecl._memberlessDescription)` to \(result.map(\.qualifiedName.debugDescription)) with dependencies: \(dependencyDescription); admission result (i.e. invalidated exts): \(admissionResultDescriptions), new dependency graph is:"
      )
      print(dependencyGraphDescription)
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

// MARK: Qualified Type Lookup

extension SymbolTable {
  @_spi(_QualifiedLookupTests) public enum QualifiedTypeLookupFailure: Error {
    /// Type syntax doesn't have source-file root or source-file root isn't in
    /// module map.
    case unregisteredSourceRoot

    case lookupFailure(TypeDependencyGraph.QualifiedTypeLookupFailure)
  }

  func findMemberType(
    baseType: NominalTypeRef,
    memberTypeName: Identifier,
    introducingTypeSyntax: Attached<TypeLikeSyntax>,
    introducingModule: ModuleName,
    dependencyTracker: inout DependencyTracker,
  ) -> Result<[Attached<TypeDeclSyntax>], QualifiedTypeLookupFailure> {
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
