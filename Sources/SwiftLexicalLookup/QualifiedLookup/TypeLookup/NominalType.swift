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

import SwiftSyntax
import SwiftIfConfig

// TODO: Assert each decl has a source-file parent
@_spi(_QualifiedName) public struct NominalType {
  // Globally unique name
  let qualifiedName: QualifiedTypeName
  // The main declaration of this type
  let mainDecl: NominalTypeDeclSyntax2
  // Invalid redeclarations that use the same name
  let redeclarations: [NominalTypeDeclSyntax2]
  // All extensions organized by the module in which they were declared.
  // Only the modules included in this query are included
  // let moduleToExtensions: [Identifier: [ExtensionDeclSyntax]]
  let extensions: [ExtensionDeclSyntax]
}

extension NominalType {
  fileprivate var _declGroups: [DeclGroupSyntaxType] {
    [DeclGroupSyntaxType(exactly: mainDecl)] + extensions.map(DeclGroupSyntaxType.init(exactly:))
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

    for declGroup in _declGroups {
      guard let declFile = declGroup.root.as(SourceFileSyntax.self) else {
        return .failure(.declNotAttachedToSourceFile(declGroup))
      }
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
    else /* selectedModule == nil */ {
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

  func findMemberType(
    selectedModule: Identifier? = nil,
    lookupPosition: (file: SourceFileSyntax, position: AbsolutePosition)
    importedModules: [Identifier],
    moduleMap: [SourceFileSyntax: Identifier],
    configuredRegions: ConfiguredRegions?
  ) -> Result<[TypeDeclSyntax], MemberLookupFailure> {
    var typeDecls = [TypeDeclSyntax]()

    let result = _visitMembers(
      lookupPosition: lookupPosition,
      importedModules: importedModules,
      moduleMap: moduleMap,
      configuredRegions: configuredRegions,
      visit: { decl in
        guard let typeDecl = decl.as(TypeDeclSyntax.self) else { return }
        typeDecls.append(typeDecl)
      }
    )

    if case .failure(let failure) = result {
      return .failure(failure)
    }

    return .success(typeDecls)
  }
}
