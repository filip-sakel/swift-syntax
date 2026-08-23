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

// /// A local type is a type declared within a `CodeBlockItemListSyntax`, e.g.,
// /// in a while loop or function body.
// ///
// /// Array of identifiers, e.g., `A.B.C` for
// /// ```swift
// /// func f() {
// ///   struct A { struct B { struct C {} } }
// /// }
// /// ```
// @_spi(_QualifiedLookupTests)
// public struct LocalTypeName: Sendable, Hashable, CustomDebugStringConvertible {
//   /// The local scope at which this type is declared.
//   let scope: Attached<CodeBlockItemListSyntax>
//   /// The type's components
//   /// Invariant: `components.count >= 1`
//   private(set) var components: [Identifier]
//
//   /// Creates a local-type name from the given components; returns `nil`
//   /// if no components are provided.
//   init?(scope: Attached<CodeBlockItemListSyntax>, components: [Identifier]) {
//     // Upholds invariant
//     guard !components.isEmpty else { return nil }
//
//     self.scope = scope
//     self.components = components
//   }
//
//   init(scope: Attached<CodeBlockItemListSyntax>, base: Identifier) {
//     // We force unwrap because we provide a component
//     self.init(scope: scope, components: [base])!
//   }
//
//   consuming func addingComponents(_ tailComponents: [Identifier]) -> LocalTypeName {
//     var copy = self
//     copy.components.append(contentsOf: tailComponents)
//     return copy
//   }
//
//   /// The debug description is NOT deterministic (depends on the scope id's hash value)
//   public var debugDescription: String {
//     let componentsDescription = components.map(\.name).joined(separator: ".")
//     return "\(scope.node.id.hashValue)>\(componentsDescription)"
//   }
// }
//
// /// A globally unique type name. Either a global type (top-level type or nested
// /// under another global type), or a local type (nested in a `CodeBlockItemListSyntax`
// /// like a `while` loop or function body.)
// @_spi(_QualifiedLookupTests)
// public enum TypeName: Sendable, Hashable, CustomDebugStringConvertible {
//   /// Specifies top-level type: a collection of internal and external components
//   case global(GlobalTypeName)
//   // Specifies an (internal) local scope and a dot-separated sequence of identifiers.
//   case local(LocalTypeName)
//
//   public var debugDescription: String {
//     switch self {
//     case .global(let globalType):
//       return globalType.debugDescription
//     case .local(let localType):
//       return localType.debugDescription
//     }
//   }
// }
