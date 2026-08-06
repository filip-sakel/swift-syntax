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

struct MappedDeclGroup<DeclGroup: DeclGroupSyntax & SyntaxHashable> {
  let declGroup: Attached<DeclGroup>
  let typeMap: TypeTable

  var node: DeclGroup { declGroup.node }
  var fileRoot: SourceFileSyntax { declGroup.fileRoot }
}

extension MappedDeclGroup: Hashable {
  static func == (a: Self, b: Self) -> Bool { a.node == b.node }
  func hash(into hasher: inout Hasher) {
    hasher.combine(node)
  }
}

// MARK: Construction

extension MappedDeclGroup {
  static func from(declGroup: Attached<DeclGroup>, configuredRegions: ConfiguredRegions?) -> MappedDeclGroup {
    MappedDeclGroup(
      declGroup: declGroup,
      typeMap: TypeTable(
        from: declGroup._groupTypeMembers(configuredRegions: configuredRegions),
        introducedIn: declGroup.as(ExtensionDeclSyntax.self)
      )
    )
  }
}

extension Attached where Node: DeclGroupSyntax {
  internal func _groupTypeMembers(
    configuredRegions: ConfiguredRegions?
  ) -> [Identifier: [Attached<TypeDeclSyntax>]] {
    var result = [Identifier: [Attached<TypeDeclSyntax>]]()
    node.visitDirectMembers(
      configuredRegions: configuredRegions,
      visit: { valueDecl in
        guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
        guard let typeIdentifier = Identifier(validating: typeDecl.name) else { return }
        // Since these are our children, they will also be scope in the file.
        let wrappedTypeDecl = Attached<TypeDeclSyntax>(typeDecl)!
        result[typeIdentifier, default: []].append(wrappedTypeDecl)
      }
    )
    return result
  }
}

// MARK: Erasure

extension MappedDeclGroup {
  func erased() -> MappedDeclGroup<DeclGroupSyntaxType> {
    // Force-unwrap because we're simply erasing declGroup to DeclGroupSyntaxType
    MappedDeclGroup<_>(declGroup: declGroup.as(DeclGroupSyntaxType.self)!, typeMap: typeMap)
  }
}
