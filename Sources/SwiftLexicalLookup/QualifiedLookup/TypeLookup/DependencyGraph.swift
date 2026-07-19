// //===----------------------------------------------------------------------===//
// //
// // This source file is part of the Swift.org open source project
// //
// // Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// // Licensed under Apache License v2.0 with Runtime Library Exception
// //
// // See https://swift.org/LICENSE.txt for license information
// // See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
// //
// //===----------------------------------------------------------------------===//
//
// import SwiftIfConfig
// import SwiftSyntax
//
// /// A directed acyclic graph where types are nodes and extensions are edges.
// @_spi(_QualifiedLookupTests)
// public struct DependencyGraph {
//   struct TypeMember {
//     /// Parent type or `nil` for top-level in file scope (top-level type)
//     /// or other sequential scope (e.g. non-nested local decl)
//     let parentType: QualifiedTypeName
//     let name: Identifier
//
//   }
//
//   /// Type decl to its decl context (the introducing extension or `nil` for the
//   /// main declaration; the parent type or `nil` for top level)
//   var types: [TypeDeclSyntax: (introducingExtension: ExtensionDeclSyntax?, parentType: QualifiedTypeName?)]
//   var extensions:
//     [(
//       dependencies: TypeDeclSyntax, extensionDecl: ExtensionDeclSyntax, resolvedType: QualifiedTypeName,
//       dependents: [QualifiedTypeName]
//     )]
//
//   init() {
//     self.types = [:]
//     self.extensions = []
//   }
// }
//
// extension DependencyGraph {
//   struct InvalidReadmissionFailure: Error {}
//   /// Invalid types are types whose chain resolution produces a
//   /// ``ChainResolution.resolved`` result. In other words, types
//   /// whose resolution doesn't depend on binding an extension.
//   mutating func admitIndependent(
//     decl: TypeDeclSyntax,
//     parentType: QualifiedTypeName?
//   ) -> Result<Void, InvalidReadmissionFailure> {
//     guard types[decl] == nil else { return .failure(InvalidReadmissionFailure()) }
//     types[decl] = (introducingExtension: nil, parentType: parentType)
//   }
// }
//
// extension DependencyGraph {
//   /// An extension may introduce dependent types.
//   mutating func admitDependents(
//     dependencies: [TypeDeclSyntax],
//   )
// }
