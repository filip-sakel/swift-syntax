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
  let declGroup: SourceFileRoot<DeclGroup>
  let typeMap: TypeDependencyGraph.TypeTable

  var node: DeclGroup { declGroup.node }
  var fileRoot: SourceFileSyntax { declGroup.fileRoot }
}

extension MappedDeclGroup: Hashable {
  static func == (a: Self, b: Self) -> Bool { a.declGroup == b.declGroup }
  func hash(into hasher: inout Hasher) {
    hasher.combine(declGroup)
  }
}

// MARK: Construction

extension MappedDeclGroup {
  static func from(declGroup: SourceFileRoot<DeclGroup>, configuredRegions: ConfiguredRegions?) -> MappedDeclGroup {
    MappedDeclGroup(
      declGroup: declGroup,
      typeMap: TypeDependencyGraph.TypeTable(
        from: declGroup.node._groupTypeMembers(configuredRegions: configuredRegions),
        introducedIn: declGroup.as(ExtensionDeclSyntax.self)
      )
    )
  }
}

extension DeclGroupSyntax {
  internal func _groupTypeMembers(configuredRegions: ConfiguredRegions?) -> [Identifier: [TypeDeclSyntax]] {
    var result = [Identifier: [TypeDeclSyntax]]()
    visitDirectMembers(
      configuredRegions: configuredRegions,
      visit: { valueDecl in
        guard let typeDecl = valueDecl.as(TypeDeclSyntax.self) else { return }
        guard let typeIdentifier = Identifier(validating: typeDecl.name) else { return }
        result[typeIdentifier, default: []].append(typeDecl)
      }
    )
    return result
  }
}

// MARK: Erasure

extension MappedDeclGroup {
  func erased() -> MappedDeclGroup<DeclGroupSyntaxType> {
    // We're erasing so the source-file root will be retained
    MappedDeclGroup<_>(declGroup: SourceFileRoot(DeclGroupSyntaxType(declGroup))!, typeMap: typeMap)
  }
}
