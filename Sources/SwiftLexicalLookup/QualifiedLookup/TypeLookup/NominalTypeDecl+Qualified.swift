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

enum QualifiedTypeResolutionFailure: Error {
  /// No scope exists or scope doesn't have a parent (not even `SourceFileSyntax`)
  case invalidScope
}

// For global, we still need to resolve extensions
extension SyntaxProtocol {
  enum ResolutionResult {
   case resolveTopLevelBase(extensionType: TypeSyntax)
   case scope(CodeBlockItemListSyntax, isTopLevel: Bool)
   case resolved(QualifiedTypeName)
   case failure(QualifiedTypeResolutionFailure)
  }

  var _enclosingQualifiedTypeName: Result<QualifiedTypeName, QualifiedTypeResolutionFailure> {
    guard let parent else { return .failure(.invalidScope) }

    if let nominal = NominalTypeDeclSyntax2(parent) {
      nominal._enclosingQualifiedTypeName
    } else if let extension = ExtensionDeclSyntax(parent) {

      } else if let scope = CodeBlockItemListSyntax(parent) {
      // Top level
      // TODO: Use `DeclScope` isFileScope and throw appropriate errors
      if scope.parent?.is(SourceFileSyntax.self) {
        // Global
        return QualifiedTypeName()
      } else {
        // Nested
      }
    }
  }
}

// extension NominalTypeDeclSyntax2 {
//   enum Failure: Error {
//     case noDeclScope(for: NominalTypeDeclSyntax2)
//     case invalidIdentifier(for: NominalTypeDeclSyntax2)
//     case noSourceFileRoot(root: Syntax)
//   }
//
//   indirect enum PartiallyQualifiedTypeName {
//     case resolved(QualifiedTypeName)
//     case unresolved(rootTypeSyntax: TypeSyntax, components: [QualifiedTypeNameGlobalType.Component])
//   }
//
//   /// Qualify this nominal type in the given module. `nil` for internal module.
//   func qualifyTypeName(in module: Identifier?) -> Result<PartiallyQualifiedTypeName, Failure> {
//     return Result(catching: { () throws(Failure) in
//       // Get the file id (we require a non-detached node with a source-file root)
//       guard let sourceFile = root.as(SourceFileSyntax.self) else {
//         throw Failure.noSourceFileRoot(root: root)
//       }
//       let fileID = sourceFile.id
//       // Get the qualifier
//       let qualifier: QualifiedTypeNameGlobalType.Qualifier = if let module {
//         .external(moduleName: module)
//       } else {
//         .internal(fileID: fileID)
//       }
//
//       // Validate the name
//       guard let name = Identifier(self.name) else {
//         throw Failure.invalidIdentifier(for: self)
//       }
//
//       // Find parent decl group
//       var currentAncestor = self.parent
//       while let ancestor = currentAncestor {
//         // For parent nominal types, recursively obtain *their* qualified name
//         if let nominalType = ancestor.as(NominalTypeDeclSyntax2.self) {
//           // Try to qualify parent
//           let parentType: PartiallyQualifiedTypeName = try nominalType.qualifyTypeName(in: module).get()
//           // Append to parent
//           switch parentType {
//           case .resolved(.topLevel(let globalQualified)):
//             return PartiallyQualifiedTypeName.resolved(QualifiedTypeName.topLevel(
//               QualifiedTypeNameGlobalType(
//                 components: globalQualified.components + [(qualifier: qualifier, name: name)]
//               )
//             ))
//           case .resolved(.nestedScope(let scope, let parentType)):
//             return PartiallyQualifiedTypeName.resolved(
//               QualifiedTypeName.nestedScope(scope: scope, type: QualifiedTypeNameNestedType.member(base: parentType, name: name))
//             )
//           case .unresolved(let rootTypeSyntax, let parentComponents):
//             return PartiallyQualifiedTypeName.unresolved(
//               rootTypeSyntax: rootTypeSyntax,
//               components: parentComponents + [(qualifier: qualifier, name: name)]
//             )
//           }
//         }
//         // We can't resolve extensions
//         else if let extensionDecl = ancestor.as(ExtensionDeclSyntax.self) {
//           return PartiallyQualifiedTypeName.unresolved(rootTypeSyntax: extensionDecl.extendedType, components: [])
//         }
//         // Handle file scope
//         else if let scopeSyntax = ancestor.as(CodeBlockItemListSyntax.self), sourceFile.statements == scopeSyntax {
//           return PartiallyQualifiedTypeName.resolved(
//             QualifiedTypeName.topLevel(
//               QualifiedTypeNameGlobalType(components: [(qualifier: qualifier, name: name)])
//             )
//           )
//         }
//         // Handle nested scope
//         else if let scopeSyntax = ancestor.as(CodeBlockItemListSyntax.self) {
//           return PartiallyQualifiedTypeName.resolved(
//             QualifiedTypeName.nestedScope(scope: scopeSyntax, type: .base(name))
//           )
//         }
//
//         // Keep going up the syntax tree until we find a useful node
//         currentAncestor = ancestor.parent
//       }
//     })
//
//     // This shouldn't happen given that the root is a source file (with a valid
//     // `statements` scope), as asserted at the top of the function
//     preconditionFailure("[SwiftLexicalLookup] Internal Error: Unexpectedly couldn't qualify name despite having a source-file as the `root` node.")
//   }
// }
