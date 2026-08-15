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

enum TypeNameResolution {
  /// The scope can be global (`SourceFileSyntax/statements`) or local (e.g. a function body)
  case base(name: TypeName, mainDecl: Attached<NominalTypeDeclSyntax>, scope: Attached<CodeBlockItemListSyntax>)
  case nested(PartialTypeName)
}
struct PartialTypeName: CustomDebugStringConvertible {
  // The enclosing declaration group or `nil` for top-level declarations
  // or non-nested declarations at local scope.
  //
  // Invariant: Base and members are in the same file
  let base: Attached<DeclGroupSyntaxType>
  /// The name and main decl of the type
  let nameAndMainDecl: (name: Identifier, mainDecl: Attached<NominalTypeDeclSyntax>)

  // IMPORTANT: Base and members must share the same fileSyntax root.
  init(
    base: Attached<DeclGroupSyntaxType>,
    nameAndMainDecl: (name: Identifier, mainDecl: Attached<NominalTypeDeclSyntax>)
  ) {
    // Check source file
    assert(
      base.fileRoot == nameAndMainDecl.mainDecl.fileRoot,
      "[SwiftLexicalLookup] Internal error: Declaration's source file doesn't match base declaration's source file."
    )

    self.base = base
    self.nameAndMainDecl = nameAndMainDecl
  }

  var debugDescription: String {
    "`\(base._memberlessDescription)` > `\(nameAndMainDecl.mainDecl._memberlessDescription)`"
  }
}

enum TypeNameResolutionFailure: Error {
  /// We need the fileRoot to be registered in the symbol table.
  case unregisteredFile
  /// We need all type names in the chain to be valid identifiers
  case invalidIdentifier(TokenSyntax)
  /// Extensions are only valid at top level. We can't declare
  /// extensions in local contexts (e.g. in a `while` loop) or
  /// other declaration groups (e.g. in a `struct`'s members).
  case nonTopLevelExtension(extensionDecl: Attached<ExtensionDeclSyntax>)
}

extension Attached where Node == NominalTypeDeclSyntax {
  /// Walks to outer scopes to determine the type name that uniquely identifies this type.
  func resolveTypeName(symbolTable: SymbolTable) -> Result<TypeNameResolution, TypeNameResolutionFailure> {
    /// Parse the token into a valid identifier or throw
    func parseName(_ token: TokenSyntax) -> Result<Identifier, TypeNameResolutionFailure> {
      guard let identifier = Identifier(validating: token) else {
        return .failure(TypeNameResolutionFailure.invalidIdentifier(token))
      }
      return .success(identifier)
    }

    // Parse the first name
    guard let firstParsedName = Identifier(validating: node.name) else {
      return .failure(TypeNameResolutionFailure.invalidIdentifier(node.name))
    }
    let nameAndMainDecl = (name: firstParsedName, mainDecl: self)
    // Get the module
    guard let moduleName = symbolTable.moduleMap[fileRoot] else {
      return .failure(TypeNameResolutionFailure.unregisteredFile)
    }

    var ancestor: Attached<Syntax>? = parent
    // Set if we get an extension decl. We save the extension in a variable instead of
    // directly returning it to diagnose non-top-level extensions.
    var foundExtensionDecl: Attached<ExtensionDeclSyntax>? = nil

    while let currentAncestor = ancestor {
      // Nominal types go to the front of the "chain"
      if let nominalTypeDecl: Attached<NominalTypeDeclSyntax> = currentAncestor.as(NominalTypeDeclSyntax.self) {
        // Check for nested extensions
        if let existingExtension = foundExtensionDecl {
          return .failure(TypeNameResolutionFailure.nonTopLevelExtension(extensionDecl: existingExtension))
        }

        return .success(
          TypeNameResolution.nested(
            PartialTypeName(
              base: Attached<DeclGroupSyntaxType>(nominalTypeDecl),
              nameAndMainDecl: nameAndMainDecl
            )
          )
        )
      }
      // Extensions can't be resolved right now.
      else if let extensionDecl = currentAncestor.as(ExtensionDeclSyntax.self) {
        // Check for nested extensions
        if let existingExtension = foundExtensionDecl {
          return .failure(TypeNameResolutionFailure.nonTopLevelExtension(extensionDecl: existingExtension))
        }

        // We don't return yet; we still have to check this is a top-level extension
        foundExtensionDecl = extensionDecl
      }
      // Top-level scope
      else if let fileScope = currentAncestor.as(CodeBlockItemListSyntax.self),
        fileScope.parent?.node == Syntax(self.fileRoot)
      {
        // The extension is top-level so it's valid
        if let parentExtension = foundExtensionDecl {
          return .success(
            TypeNameResolution.nested(
              PartialTypeName(base: Attached<DeclGroupSyntaxType>(parentExtension), nameAndMainDecl: nameAndMainDecl)
            )
          )
        }
        // Otherwise, the declaration is top-level
        return .success(
          TypeNameResolution.base(
            name: TypeName.global(
              GlobalTypeName(
                component: GlobalTypeName.Component(
                  name: firstParsedName,
                  file: fileRoot,
                  module: moduleName,
                  symbolTable: symbolTable
                )
              )
            ),
            mainDecl: self,
            scope: fileScope
          )
        )
      }
      // Nested scope (if CodeBlockItemListSyntax isn't nested directly under `SourceFileSyntax`)
      else if let scope = currentAncestor.as(CodeBlockItemListSyntax.self) {
        // Can't declare extension at local scope
        if let parentExtension = foundExtensionDecl {
          return .failure(TypeNameResolutionFailure.nonTopLevelExtension(extensionDecl: parentExtension))
        }

        // Otherwise, the declaration is a non-nested local declaration.
        return .success(
          TypeNameResolution.base(
            name: TypeName.local(LocalTypeName(scope: scope, base: firstParsedName)),
            mainDecl: self,
            scope: scope
          )
        )
      }

      ancestor = currentAncestor.parent
    }

    // Shouldn't happen because we checked there's a source-file root above.
    fatalError(
      "[SwiftLexicalLookup] Internal error: Unexpectedly got no result despite having verified source-file root."
    )
  }
}

// extension GlobalTypeName {
//   func register(
//     members: [(Attached<NominalTypeDeclSyntax>, Identifier)],
//     symbolTable: SymbolTable
//   ) -> Result<ResolvedNominalTypeReference, TypeResolver.Failure>? {
//     // TODO: Think about the broader architecture. Do I really need to be registering
//     // types not declared in extensions?
//     guard let firstMember = members.first else { return nil }
//     let baseName =
//       symbolTable.registerNominalTypeReference(
//         qualifiedName: TypeName,
//         mainDecl: Attached<NominalTypeDeclSyntax>,
//         originatingSyntax: Attached<TypeLikeSyntax>
//       )
//   }
// }

// TODO: Remove
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
