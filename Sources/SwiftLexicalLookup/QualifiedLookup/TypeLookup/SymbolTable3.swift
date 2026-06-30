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

// TODO: Assert each decl has a source-file parent
@_spi(_QualifiedLookupTests) public struct NominalType: Sendable {
  // Globally unique name
  @_spi(_QualifiedLookupTests) public let qualifiedName: QualifiedTypeName
  // The main declaration of this type
  let mainDecl: NominalTypeDeclSyntax2
  // Invalid redeclarations that use the same name
  let redeclarations: [NominalTypeDeclSyntax2]
  // All extensions organized by the module in which they were declared.
  // Only the modules included in this query are included
  // let moduleToExtensions: [Identifier: [ExtensionDeclSyntax]]
  //
  // Note that a fully instantiated nominal type may lack extensions to
  // non-imported files or have have more extensions than are available
  // through a specific file's imports.
  let extensions: [SourceFileSyntax: [ExtensionDeclSyntax]]
}

extension NominalType {
  fileprivate var _declGroups: [SourceFileSyntax: [DeclGroupSyntaxType]] {
    // TODO: Throw actual error
    guard let mainDeclFile = mainDecl.root.as(SourceFileSyntax.self) else {
      fatalError("[SwiftLexicalLookup] Internal error: mainDecl is not attached to a SourceFileSyntax")
    }
    var results = [mainDeclFile: [DeclGroupSyntaxType(exactly: mainDecl)]]
    for (file, extensionDecls) in extensions {
      results[file, default: []].append(
        contentsOf: extensionDecls.map(DeclGroupSyntaxType.init(exactly:))
      )
    }
    return results
  }

  enum MemberLookupFailure: Error {
    case fileNotInModuleMap(SourceFileSyntax)
    case declNotAttachedToSourceFile(DeclGroupSyntaxType)
    case selectedNonImportedModule(selectedModule: Identifier)
  }

  /// Visit the members from the
  fileprivate func _visitMembers(
    selectedModule: Identifier? = nil,
    lookupPosition: (file: SourceFileSyntax, position: AbsolutePosition),
    importedModules: [Identifier],
    moduleMap: [SourceFileSyntax: Identifier],
    configuredRegions: ConfiguredRegions?,
    visit: (ValueDeclSyntax) -> Void
  ) -> Result<Void, MemberLookupFailure> {
    guard let lookupModule = moduleMap[lookupPosition.file] else {
      return .failure(.fileNotInModuleMap(lookupPosition.file))
    }

    // Organize declaration groups into ones declared in this file,
    // other files in this module or external modules.
    var thisFile = [DeclGroupSyntaxType]()
    var otherInternalFiles = [DeclGroupSyntaxType]()
    var externalModules = [Identifier: [DeclGroupSyntaxType]]()

    for (declFile, declGroups) in _declGroups {
      for declGroup in declGroups {
        // guard let declFile = declGroup.root.as(SourceFileSyntax.self) else {
        //   return .failure(.declNotAttachedToSourceFile(declGroup))
        // }
        guard let declModule = moduleMap[declFile] else {
          return .failure(.fileNotInModuleMap(declFile))
        }

        if declFile == lookupPosition.file {
          thisFile.append(declGroup)
        } else if declModule == lookupModule {
          otherInternalFiles.append(declGroup)
        } else {
          externalModules[declModule, default: []].append(declGroup)
        }
      }
    }

    // If this module is selected, look into that
    if let selectedModule, selectedModule == lookupModule {
      // Look in this file
      for declGroup in thisFile {
        declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
      }
      // Look in other files in the module
      for declGroup in otherInternalFiles {
        declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
      }
    }
    // If an external module is selected, look into that (if imported)
    else if let selectedModule, selectedModule != lookupModule {
      // Ensure selected module was imported
      guard importedModules.contains(selectedModule) else {
        return .failure(.selectedNonImportedModule(selectedModule: selectedModule))
      }

      // Look in selected module
      for declGroup in externalModules[selectedModule, default: []] {
        declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
      }
    }
    // If no module is selected, look into this file, this module, and modules in reverse
    // order of the import list
    else /* selectedModule == nil */
    {
      for declGroup in thisFile {
        declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
      }
      for declGroup in otherInternalFiles {
        declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
      }
      // Look at imports in reversed order (later ones shadow earlier ones)
      // and visit each declaration group in that order
      for module in importedModules.reversed() {
        for declGroup in externalModules[module, default: []] {
          declGroup.visitDirectMembers(configuredRegions: configuredRegions, visit: visit)
        }
      }
    }

    return .success(())
  }

  func findMemberTypes(
    component: ImplicitTypeReferenceComponent,
    lookupPosition: (file: SourceFileSyntax, position: AbsolutePosition),
    importedModules: [Identifier],
    moduleMap: [SourceFileSyntax: Identifier],
    configuredRegions: ConfiguredRegions?,
    _verbose: Bool = false
  ) -> Result<[TypeDeclSyntax], MemberLookupFailure> {
    var typeDecls = [TypeDeclSyntax]()

    let result = _visitMembers(
      selectedModule: component.module,
      lookupPosition: lookupPosition,
      importedModules: importedModules,
      moduleMap: moduleMap,
      configuredRegions: configuredRegions,
      visit: { decl in
        if _verbose {
          print("[Direct lookup on \(qualifiedName)] Visiting decl: \(decl.trimmedDescription)")
        }
        // Get only types with matching names
        guard
          let typeDecl = decl.as(TypeDeclSyntax.self),
          typeDecl.name.identifier == component.name
        else {
          return
        }

        typeDecls.append(typeDecl)
      }
    )

    if case .failure(let failure) = result {
      return .failure(failure)
    }

    return .success(typeDecls)
  }
}
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
/// TODO: (Future) Do we also need to handle top-level decls changing? E.g. We bring external module
///  decls in first, before internal module; or we import another module that shadows previous top-level decl.
/// TODO: (Future) Is there a situation where updating dependent extensions can cause cycles?
///       Or rather, is it possible that we add a dependent extension, that adds
///       members that require updating other dependent extensions, which in turn
///       updates the dependent extension we added? (without causing a cycle)
@_spi(_QualifiedLookup) public struct ExtensionBindingState {
  // public enum ResolutionState {
  //   /// We're in the process of resolving this extension. Helps catch cycles.
  //   case resolving
  //   case resolved(
  //     dependencies: [Identifier: Result<MemberLookupResult<QualifiedTypeName>, TypeQualifier.Failure>],
  //     // TODO: How do we handle redeclarations in the same decl group
  //     assumedResolution: Result<QualifiedTypeName, TypeQualifier.Failure>
  //   )
  // }
  struct Dependence {
    let resolvedType: QualifiedTypeName
    let typeMember: Identifier
    var resolvedDecls: [TypeDeclSyntax]
  }
  var dependence: Dependence?
  var resolution: Result<QualifiedTypeName, TypeQualifier.Failure>
  // var typeMemberAssumptions: [PartiallyResolvedTypeIdentifier.Component: ResolvedNominalTypeReference]
  // var dependentExtensionsStack: [PartiallyResolvedTypeIdentifier.Component: [ExtensionDeclSyntax]]
}

@_spi(_QualifiedLookup) public enum TypeSyntaxResolutionState {
  /// Indicates we started resolving this type syntax; helps us catch cycles.
  case startedResolving
  /// A cycle was detected.
  ///
  /// Two examples:
  /// 1.Type aliases:
  ///   typealias A = B
  ///   typealias B = A
  ///
  /// 2.Nested type aliases:
  ///   struct One { typealias A = Two.B }
  ///   struct Two { typealias B = One.A }
  case detectedCycle(cyclingSyntax: [TypeSyntax])

  /// We resolved the given type syntax.
  ///
  /// If successful, we have a function type, tuple type,
  /// a composition of nominal types, or a single nominal type.
  ///
  /// There are multiple causes of failure.
  case resolved(
    Result<MemberLookupResult<QualifiedTypeName>, TypeQualifier.Failure>
  )
}
@_spi(_QualifiedLookup) public enum TypeResolutionState {
  /// Contains the
  case resolved(NominalType)

  /// If we resolved to a single nominal type, we can bind extensions and update
  /// the resolved type.
  ///
  /// Note that extensions cannot be resolved independently, so we need to
  /// keep track of extensions whose extended-syntax resolution depends on
  /// this type. Here's an example:
  ///   struct A {}
  ///   extension A.Inner {}
  ///   extension A { typealias Inner = A }
  /// In this example, we can't resolve `A.Inner` directly since it requires
  /// looking up the type `Inner` on `A`, which means `A` we have to bind
  /// all available extensions first. Through this example, we see why even
  /// seemingly unrelated extensions may be necessary to obtain an extended
  /// nominal type.
  ///
  /// Further, note that dependent extensions can depend on other dependent
  /// extensions (which eventually depend on a non-dependent extension). E.g.:
  ///   struct A {}
  ///   extension A.Inner {} // Depends on `A` having an `Inner` type member
  ///   extension A.Outer { struct Inner {} } // Depends on `A` having an `Outer` type member
  ///   extension A { typealias Outer = A } // Non-dependent extension
  /// Say we want to get the extended nominal type of `A`; we have to bind these
  /// three potential extensions. First, `A.Inner` expects a type member `Inner`;
  /// the main declaration doesn't give us that yet. So we check the next extension,
  /// but `A.Outer` depends on a type member `Outer`; we keep going. Finally, the
  /// last extension has no dependencies so we get a type `Outer`. Hence, we can
  /// make progress on `A.Outer` and resolve it, giving us `A.Inner`. Finally,
  /// we resolve `A.Inner` and don't bind it since the type is unrelated.
  ///
  /// Important: As we bind dependent extensions, we assume the members we found
  /// are unique. However,
  ///
  case bindingPotentialExtension(
    resolved: NominalType,
    stochasticMembers: [Identifier: [TypeDeclSyntax]],

  )
  // /// The remaining extensions we need to bind
  // var possibleExtensionQueue: [ExtensionDeclSyntax]
  // /// Extensions we were able to successfully bind
  // var currentlyBoundExtensions: [ExtensionDeclSyntax: QualifiedTypeName]
}
@_spi(_QualifiedLookup) public final class SymbolTable3 {
  public typealias Module = Identifier
  let moduleToSources: [Module: [String: SourceFileSyntax]]

  internal var typeSyntaxState: [TypeSyntax: TypeSyntaxResolutionState] = [:]
  internal var typeState: [QualifiedTypeName: TypeResolutionState] = [:]
  internal var extensionState: [ExtensionDeclSyntax: ExtensionBindingState] = [:]

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
