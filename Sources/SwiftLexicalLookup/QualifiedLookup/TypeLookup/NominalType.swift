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

  var declGroups: [DeclGroupSyntaxType] {
    [DeclGroupSyntaxType(exactly: mainDecl)] + extensions.map(DeclGroupSyntaxType.init(exactly:))
  }
}
