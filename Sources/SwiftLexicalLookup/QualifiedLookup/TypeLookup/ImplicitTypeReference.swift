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

/// A type reference component either derived from source or implicitly generated.
///
/// E.g. In `let a: Int.MyType`, `MyType` is a source-derived reference. However,
/// we can also have:
///   struct A {
///     struct B {
///       struct C {
///         func f(_: C) // <- Look up here
///       }
///     }
///   }
/// In this case, we look inside "A.B" to find `C`, so we implicitly generate the
/// components `A` and `B`.
@_spi(_QualifiedLookup) public struct ImplicitTypeReferenceComponent: Sendable {
  let module: Identifier?
  let name: Identifier
  let introducingSyntax: TypeLikeSyntax

  init(from sourceComponent: PartiallyResolvedTypeIdentifier.Component) {
    self.module = sourceComponent.module
    self.name = sourceComponent.name
    self.introducingSyntax = TypeLikeSyntax.typeSyntax(sourceComponent.introducingSyntax)
  }
}
