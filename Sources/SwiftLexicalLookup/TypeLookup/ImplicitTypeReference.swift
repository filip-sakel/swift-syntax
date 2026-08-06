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

/// A type reference component consists of an optional module selector, the
/// identifier of the type, and the type-like syntax generating the reference.
@_spi(_QualifiedLookupTests) public struct ImplicitTypeReferenceComponent: Sendable, CustomDebugStringConvertible {
  let module: Identifier?
  let name: Identifier
  let introducingSyntax: Attached<TypeLikeSyntax>

  internal init(module: Identifier? = nil, name: Identifier, introducingSyntax: Attached<TypeLikeSyntax>) {
    self.module = module
    self.name = name
    self.introducingSyntax = introducingSyntax
  }

  @_spi(_QualifiedLookupTests) public init(from sourceComponent: TypeReference) {
    self.module = sourceComponent.module
    self.name = sourceComponent.name
    self.introducingSyntax = Attached<TypeLikeSyntax>(sourceComponent.introducingSyntax)
  }

  public var debugDescription: String {
    let modulePrefix: String
    if let module {
      modulePrefix = "\(module)::"
    } else {
      modulePrefix = ""
    }

    return "\(modulePrefix)\(name.name)"
  }
}
