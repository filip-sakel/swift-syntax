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

extension NominalTypeDeclSyntax2 {
  /// Find the given generic parameter in this nominal-type declaration.
  /// Empty for protocols (they only have associated types)
  func findGenericParameters(withName name: Identifier?) -> [GenericParameterSyntax] {
    // Extract the parameter clause, or `nil` for protocols.
    let parameterClause: GenericParameterClauseSyntax?
    switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let nonProtocolDecl):
      parameterClause = nonProtocolDecl.genericParameterClause
    case .enumDecl(let nonProtocolDecl):
      parameterClause = nonProtocolDecl.genericParameterClause
    case .classDecl(let nonProtocolDecl):
      parameterClause = nonProtocolDecl.genericParameterClause
    case .actorDecl(let nonProtocolDecl):
      parameterClause = nonProtocolDecl.genericParameterClause
    case .protocolDecl:
      parameterClause = nil
    default:
      assertionFailure(
        "[SwiftLexicalLookup] Internal error: Unexpectedly got nominal type declaration of unrecognized kind '\(kind)'."
      )
      return []
    }

    guard let parameterClause else { return [] }

    // Return all parameters if we don't filter by name
    guard let name else { return Array(parameterClause.parameters) }
    return parameterClause.parameters.filter({ parameter in
      parameter.name.identifier == name
    })
  }
}
