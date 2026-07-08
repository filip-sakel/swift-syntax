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
  /// Globally unique name
  @_spi(_QualifiedLookupTests) public let qualifiedName: QualifiedTypeName
  /// The main declaration of this type
  let mainDecl: NominalTypeDeclSyntax
  /// Invalid redeclarations that use the same name
  let redeclarations: [NominalTypeDeclSyntax]
  /// All extensions organized by the module in which they were declared.
  /// Only the modules included in this query are included.
  ///
  /// Note that a fully instantiated nominal type may lack extensions to
  /// non-imported files or have have more extensions than are available
  /// through a specific file's imports.
  ///
  /// However, within a module, extensions are "globally" available.
  /// That's because access control modifiers in extensions are basically
  /// a shorthand for writing said modifier in front of every member of
  /// the extension.
  ///
  /// Note that some extensions get invalidated. There are three cases:
  /// 1. We had an error and we may potentially succeed
  ///    In the following, we only succeed if this extension doesn't
  ///    introduce more ambiguities:
  ///    a. noTypeInScope
  ///       E.g.
  ///       ```swift
  ///       struct A { typealias B = C }
  ///       extension A.B {} // <- Bind here
  ///       extension A { struct C {} }
  ///       ```
  ///       Trying to bind `extension A.B` initially returns `noTypeInScope`
  ///       because we can't find `C`. Then we process `extension A` which
  ///       introduces a type `C`, after which, the error resolves.
  ///    b. noTypeMember
  ///       E.g.
  ///       ```swift
  ///       struct A {}
  ///       extension A.B {} // <- Bind here
  ///       extension A { struct B {} }
  ///       ```
  ///       Trying to bind `extension A.B` we get `noTypeMember`, but then
  ///       after binding `extension A` we have a type member `B`, so
  ///       we can successfully bind `extension A.B`.
  ///    c. invalidAliasedType
  ///       Recursively calls others.
  /// 2. We had an error and may update the diagnostic
  ///    a. cannotExtendNonNominal
  ///       We can never update a non-nominal but we may need to update the diagnostic.
  ///       ```swift
  ///       struct A { typealias B = () -> Bool }
  ///       extension A.B {} // <- Bind here
  ///       extension A { struct B {} }
  ///       ```
  ///       Here, trying to bind `extension A.B` will initially complain
  ///       that we're trying to extend a non-nominal (function) type.
  ///       However, binding the second extension, we get an ambiguity error
  ///       since there are two `A.B` types.
  ///    b. invalidComposition
  ///       We can never extend a composition, but we could get a different diagnostic.
  ///       E.g.
  ///       ```swift
  ///       struct A { protocol B {} }
  ///       extension A.B & A {} // <- Bind here
  ///       extension A { struct B {} }
  ///       ```
  ///       When first binding `extension A.B & A`, we complain that
  ///       the composition is invalid since `A` is a struct. But after
  ///       binding `extension A`, we complain that `A.B` is ambiguous.
  ///    b. other (parser error)
  ///       We can't fix that here.
  ///
  /// TODO: Finish up examples for the rest of the errors.
  ///
  /// TODO: Think about `@_private` Naive question: ""Does this hold true for @_private() imports,i.e., are only the imported
  /// file's extensions gonna appear, or do we transitively get the entire
  /// imported module."" I think @_private is only valid for files within the current
  /// module so that doesn't apply.
  ///
  /// TODO: Should invalidated extensions be removed from the nominal while we're recomputing.
  /// 1. If the extension was previously an error, it wasn't in a nominal's extensions anyway
  /// 2. If the extension was valid and we invalidate, we either resolve to an error or rebind
  ///    to a type where at least one unqualified lookup yields an type from a more inner scope.
  ///    a. Key insight: This means that cycles don't form unless an extension introduces members
  ///       on which its extended type relies.
  ///       The argument is as follows:
  ///       Type resolution consists of unqualified lookup and qualified lookup, where
  ///       unqualified/qualified lookup may involve redirection through type aliases
  ///       and nested qualified lookup.
  ///       what if we change inner result, resolve extension that changes outer result
  ///       struct D {}
  ///       struct B2 {}
  ///       struct A { typealias B = B2 }
  ///       extension A.B { typealias C = D }
  ///       extension A.B.C { typealias E = A  } // initially (File.swift)::D
  ///       // extension A.B { struct D {} } // Changes `extension A.B.C` resolution
  ///       extension A.B.C.E { struct B2 {}  }
  ///    b. If we have a type member, and an extension introduces a redeclaration,
  ///       which then invalidates an extension relying on said type member, then
  ///       the invalidated extension carries both declaring extensions' dependencies
  ///       transitively.
  ///       TODO: How does this interact with valid/erroneous extensions? I.e., what
  ///       should invalidated extensions be removed from the LUT while invalidating?
  ///       I think so because nothing we've calculated this far should rely on these
  ///       extensions according to the dependency-conflict rule
  ///
  ///
  ///    c. Example of valid invalidation
  ///         ```swift
  ///         struct C {}
  ///         struct A { typealias B = C }
  ///         extension A.C {} // <- Bind here
  ///         extension A { struct C {} }
  ///         ```
  ///       Trying to bind `extension A.C` first, we resolve to `(MyFile.swift)::C`.
  ///       However, after binding `extension A`, then `extension A.C` now rebinds
  ///       to `(MyFile.swift)::A.(MyFile.swift)::C`.
  ///
  ///
  internal var extensions: [SymbolTable3.Module: Set<ExtensionDeclSyntax>]

  // var typeLookupTable: [Identifier: [TypeDeclSyntax]]

  // let extensions: [SourceFileSyntax: [ExtensionDeclSyntax]]
}

extension NominalType {
  fileprivate var _declGroups: [SourceFileSyntax: [DeclGroupSyntaxType]] {
    // TODO: Throw actual error
    guard let mainDeclFile = mainDecl.root.as(SourceFileSyntax.self) else {
      fatalError("[SwiftLexicalLookup] Internal error: mainDecl is not attached to a SourceFileSyntax")
    }
    var results = [mainDeclFile: [DeclGroupSyntaxType(exactly: mainDecl)]]
    for (_, extensionDecls) in extensions {
      for extensionDecl in extensionDecls {
        guard let file = extensionDecl.root.as(SourceFileSyntax.self) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Should have checked extension declaration has source-file root before being bound to a nominal type."
          )
        }
        results[file, default: []].append(DeclGroupSyntaxType(exactly: extensionDecl))
      }
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

// MARK: Debug Description

extension NominalType: CustomDebugStringConvertible {
  @_spi(_QualifiedLookupTests) public func _describe(
    describeFileID: (SyntaxIdentifier) -> String
  ) -> String {
    let extensionDescriptions =
      extensions
      .flatMap(\.value)  // Get the extensions
      .map(\._memberlessDescription)  // Describe without members
      .joined(separator: ", ")

    return
      "NominalType(name: \(qualifiedName._describe(describeFileID: describeFileID)), kind: '\(mainDecl.kind)', extensions: [\(extensionDescriptions)])"
  }

  public var debugDescription: String {
    _describe(describeFileID: \.hashValue.description)
  }
}
