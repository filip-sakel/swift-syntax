//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

// extension QualifiedTypeNameGlobalType {
//   /// Parameters:
//   /// - sourceModule: Where the given type identifiers were added
//   func addingTypeIdentifiers(
//     _ identifiers: [PartiallyResolvedTypeIdentifier.Component],
//     in file: SourceFileSyntax, of sourceModule: (name: Identifier, isInternal: Bool)
//   ) -> QualifiedTypeNameGlobalType {
//     QualifiedTypeNameGlobalType(
//       components: self.components + identifiers.map({ (moduleName, identifier) in
//         // External if the
//         let qualifier: Qualifier = if let moduleName, moduleName != sourceModule.name {
//           Qualifier.external(moduleName: moduleName)
//         } else if sourceModule.isInternal {
//           Qualifier.internal(fileID: SyntaxIdentifier)
//         } else {
//           nil
//         }
//         return (qualifier: Qualifier.)
//       })
//     )
//   }
// }
