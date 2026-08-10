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

// extension PartialTypeName {
//   /// Resolve using now-qualified base.
//   ///
//   /// Parameters:
//   /// - originatingSyntax: The syntax which we're resolving with this request.
//   ///
//   /// Returns: The resolved type reference or `nil` if the `originatingSyntax`
//   /// isn't registered in the symbol table.
//   func resolve(
//     resolvedBase: GenericResolvedNominalTypeReference<GlobalTypeName>,
//     originatingSyntax: Attached<TypeLikeSyntax>,
//     originatingModule: ModuleName,
//     symbolTable: borrowing SymbolTable
//   ) -> ResolvedNominalTypeReference {
//     // Get the type's main declaration.
//     //
//     // If ``memberNames`` is empty, we didn't have a resolved main declaration so
//     // ``mainDecl`` is `nil`; if ``memberNames`` isn't an empty, ``mainDecl`` should
//     // have been set.
//     let resolvedMainDecl = mainDecl ?? resolvedBase.mainDecl
//
//     // Resolve the name
//     let memberComponents = memberNames.map({ name in
//       GlobalTypeName.Component(
//         name: name,
//         file: originatingSyntax.fileRoot,
//         module: originatingModule,
//         symbolTable: symbolTable
//       )
//     })
//
//     return ResolvedNominalTypeReference(
//       mainDecl: resolvedMainDecl,
//       name: TypeName.global(
//         resolvedBase.qualifiedName.addingComponents(memberComponents)
//       ),
//       originatingSyntax: originatingSyntax
//     )
//   }
// }
