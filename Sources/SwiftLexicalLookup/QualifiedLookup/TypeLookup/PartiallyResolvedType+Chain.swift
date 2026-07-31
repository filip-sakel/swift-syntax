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

enum ChainResolution: CustomDebugStringConvertible {
  case resolved(QualifiedTypeName)
  case partiallyResolved(PartiallyResolvedNominalTypeChain)

  var debugDescription: String {
    switch self {
    case .resolved(let qualifiedName):
      return ".resolved(\(qualifiedName.debugDescription))"
    case .partiallyResolved(let partiallyResolvedName):
      return ".partiallyResolved(\(partiallyResolvedName.debugDescription))"
    }
  }
}

struct PartiallyResolvedNominalTypeChain: CustomDebugStringConvertible {
  // Base and members should be in the same file
  let base: SourceFileRoot<ExtensionDeclSyntax>
  /// The names of the members.
  ///
  /// E.g., in `extension Int { struct A { struct B {} } }` the
  /// members are "A" and "B"
  let memberNames: [Identifier]
  /// The main declaration of the partially resolved type or `nil` if the
  /// type is not yet resolved (``memberNames`` is empty).
  let mainDecl: SourceFileRoot<NominalTypeDeclSyntax>?

  // IMPORTANT: Base and members must share the same fileSyntax root.
  init(
    base: SourceFileRoot<ExtensionDeclSyntax>,
    members: [(mainDecl: SourceFileRoot<NominalTypeDeclSyntax>, name: Identifier)]
  ) {
    // Map and check source file
    let memberNames = members.map({ (decl, name) in
      assert(decl.fileRoot == base.fileRoot, "Invalid decl root, not source file")
      return name
    })

    self.base = base
    self.memberNames = memberNames
    self.mainDecl = members.last?.mainDecl
  }

  var debugDescription: String {
    let memberChain = memberNames.map(\.name).joined(separator: ".")
    return "<\(base.trimmedDescription)>.\(memberChain) (mainDecl: \(String(reflecting: mainDecl?.kind)))"
  }

  /// Resolve using now-qualified base.
  ///
  /// Parameters:
  /// - originatingSyntax: The syntax which we're resolving with this request.
  ///
  /// Returns: The resolved type reference or `nil` if the `originatingSyntax`
  /// isn't registered in the symbol table.
  func resolve(
    resolvedBase: GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>,
    originatingSyntax: SourceFileRoot<TypeLikeSyntax>,
    originatingModule: SymbolTable3.Module,
    symbolTable: borrowing SymbolTable3
  ) -> ResolvedNominalTypeReference {
    // Get the type's main declaration.
    //
    // If ``memberNames`` is empty, we didn't have a resolved main declaration so
    // ``mainDecl`` is `nil`; if ``memberNames`` isn't an empty, ``mainDecl`` should
    // have been set.
    let resolvedMainDecl = mainDecl ?? resolvedBase.mainDecl

    // Resolve the name
    let memberComponents = memberNames.map({ name in
      QualifiedTypeNameGlobalType.Component(
        name: name,
        file: originatingSyntax.fileRoot,
        module: originatingModule,
        symbolTable: symbolTable
      )
    })

    return ResolvedNominalTypeReference(
      mainDecl: resolvedMainDecl,
      name: QualifiedTypeName.topLevel(
        resolvedBase.qualifiedName.addingComponents(memberComponents)
      ),
      originatingSyntax: originatingSyntax
    )
  }
}

// Resolve all types required to qualify this type
extension SyntaxProtocol {
  // enum DeclRoot {
  //   case fileScope(SourceFileSyntax)
  //   case nestedScope(CodeBlockItemListSyntax)
  //   case `extension`(ExtensionDeclSyntax)
  // }
  // // Either file scope, nested scope, or extension.
  // // TODO: Merge with PartiallyResolvedType+Qualified
  // var declRoot: DeclRoot {
  //   guard let sourceFile = root.as(SourceFileSyntax.self) else {
  //     // FIXME: Throw
  //   }
  //   var ancestor: Syntax? = parent
  //   while let currentAncestor = ancestor {
  //     switch currentAncestor.as(SyntaxEnum.self) {
  //     case .codeBlockItemList(let itemList):
  //       if sourceFile.statements == itemList {
  //         return .fileScope(sourceFile)
  //       } else {
  //         return .nestedScope(itemList)
  //       }
  //     case .
  //     }
  //
  //     ancestor = currentAncestor.parent
  //   }
  //   // FIXME: Precondition failure (internal)
  // }
  //
  // func resolveDeclContext() -> PartiallyResolvedType {
  //   var parent =
  // }
}

enum ChainResolutionFailure: Error {
  /// We need the fileRoot to be registered in the symbol table.
  case unregisteredFile
  /// We need all type names in the chain to be valid identifiers
  case invalidIdentifier(TokenSyntax)
}

extension SourceFileRoot where Node == NominalTypeDeclSyntax {
  /// Walks to outer scopes to determine the type chain that uniquely identifies this type.
  ///
  /// Local types (e.g. `func f() { struct A { struct B {} } }`) always resolve.
  /// Global types can also fully resolve, but they only partially resolve if
  /// they're nested within an extension (e.g. `extension A { struct B {} }`).
  func findTypeChain(symbolTable: SymbolTable3) -> Result<ChainResolution, ChainResolutionFailure> {
    /// Parse the token into a valid identifier or throw
    func parseName(_ token: TokenSyntax) -> Result<Identifier, ChainResolutionFailure> {
      guard let identifier = Identifier(validating: token) else {
        return .failure(ChainResolutionFailure.invalidIdentifier(token))
      }
      return .success(identifier)
    }

    // Parse the first name
    let firstParsedName: Identifier
    switch parseName(node.name) {
    case .success(let success): firstParsedName = success
    case .failure(let failure): return .failure(failure)
    }

    var ancestor: SourceFileRoot<Syntax>? = parent
    // All the members. Since we include `self`, `members.count>=1`
    var members = [(mainDecl: self, name: firstParsedName)]

    while let currentAncestor = ancestor {
      // Nominal types go to the front of the "chain"
      if let nominalTypeDecl: SourceFileRoot<NominalTypeDeclSyntax> = currentAncestor.as(NominalTypeDeclSyntax.self) {
        let parsedName: Identifier
        switch parseName(nominalTypeDecl.node.name) {
        case .success(let success): parsedName = success
        case .failure(let failure): return .failure(failure)
        }
        members.insert((mainDecl: nominalTypeDecl, name: parsedName), at: 0)
      }
      // Extensions can't be resolved right now.
      else if let extensionDecl = currentAncestor.as(ExtensionDeclSyntax.self) {
        return .success(
          ChainResolution.partiallyResolved(
            PartiallyResolvedNominalTypeChain(base: extensionDecl, members: members)
          )
        )
      }
      // Top-level scope
      else if currentAncestor.parent?.node == Syntax(self.fileRoot) {
        // Get the module from the symbol table
        guard let module = symbolTable.moduleMap[fileRoot] else {
          return .failure(ChainResolutionFailure.unregisteredFile)
        }
        // Create all the components
        let components = members.map({ (_, name) in
          QualifiedTypeNameGlobalType.Component(
            name: name,
            file: fileRoot,
            module: module,
            symbolTable: symbolTable
          )
        })
        // Assert we have ennough members (we include `self` above)
        guard let globalType = QualifiedTypeNameGlobalType(components: components) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly got `nil` globalType, implying that `components` is empty, which shouldn't happen since `members` are always nonempty."
          )
        }

        return .success(
          ChainResolution.resolved(
            QualifiedTypeName.topLevel(
              globalType
            )
          )
        )
      }
      // Nested scope (if CodeBlockItemListSyntax isn't nested directly under `SourceFileSyntax`)
      else if let scope = currentAncestor.as(CodeBlockItemListSyntax.self) {
        let components = members.map(\.name)

        // Assert we have enough members (we include `self` above)
        guard let nestedType = QualifiedTypeNameNestedType(components: components) else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly got `nil` globalType, implying that `components` is empty, which shouldn't happen since `members` are always nonempty."
          )
        }

        return .success(
          ChainResolution.resolved(
            QualifiedTypeName.nestedScope(
              scope: scope,
              type: nestedType
            )
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
