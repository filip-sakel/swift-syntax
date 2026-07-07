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

enum ChainResult: CustomDebugStringConvertible {
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
  let base: ExtensionDeclSyntax
  /// The names of the members.
  ///
  /// E.g., in `extension Int { struct A { struct B {} } }` the
  /// members are "A" and "B"
  let memberNames: [Identifier]
  // let members: [(mainDecl: NominalTypeDeclSyntax2, name: Identifier)]
  /// The main declaration of the partially resolved type or `nil` if the
  /// type is not yet resolved (``memberNames`` is empty).
  let mainDecl: NominalTypeDeclSyntax2?
  let sourceFile: SourceFileSyntax

  // IMPORTANT: Base and members must share the same fileSyntax root.
  init(base: ExtensionDeclSyntax, members: [(mainDecl: NominalTypeDeclSyntax2, name: Identifier)]) {
    // precondition(base.root == members.root, "Invalid root")
    guard let sourceFile = base.root.as(SourceFileSyntax.self) else {
      preconditionFailure("Invalid root, not source file")
    }
    // Map and check source file
    // TODO: Wrap in some sort of SymbolTableSyntax<>§
    let memberNames = members.map({ (decl, name) in
      assert(decl.root == sourceFile.root, "Invalid decl root, not source file")
      return name
    })

    self.base = base
    // self.members = members
    self.memberNames = memberNames
    self.mainDecl = members.last?.mainDecl
    self.sourceFile = sourceFile
  }

  var debugDescription: String {
    let memberChain = memberNames.map(\.name).joined(separator: ".")
    // let memberChain = members.map(\.name.name).joined(separator: ".")
    return "<\(base.trimmedDescription)>.\(memberChain) (mainDecl: \(String(reflecting: mainDecl?.kind)))"
  }

  /// Resolve using now-qualified base.
  ///
  /// Parameters:
  /// - originatingSyntax: The syntax which we're resolving with this request.
  /// - module: Module name or `nil` for this module (internal).
  func resolve(
    resolvedBase: ResolvedNominalTypeReference,
    originatingSyntax: TypeLikeSyntax,
    module: Identifier?,
    savingToTable symbolTable: SymbolTable3
  ) -> ResolvedNominalTypeReference {
    // Get the type's main declaration.
    //
    // If ``memberNames`` is empty, we didn't have a resolved main declaration so
    // ``mainDecl`` is `nil`; if ``memberNames`` isn't an empty, ``mainDecl`` should
    // have been set.
    let resolvedMainDecl = mainDecl ?? resolvedBase.mainDecl

    // Resolve the name
    switch resolvedBase.name {
    case .topLevel(let globalType):
      let qualifier: QualifiedTypeNameGlobalType.Qualifier =
        if let module {
          .external(moduleName: module)
        } else {
          .internal(fileID: sourceFile.id)
        }
      let memberComponents: [QualifiedTypeNameGlobalType.Component] = memberNames.map({ name in
        QualifiedTypeNameGlobalType.Component(
          qualifier: qualifier,
          name: name
        )
      })
      return ResolvedNominalTypeReference(
        mainDecl: resolvedMainDecl,
        name: QualifiedTypeName.topLevel(
          globalType.addingComponents(memberComponents)
        ),
        originatingSyntax: originatingSyntax,
        savingToTable: symbolTable
      )
    case .nestedScope(let scope, let type):
      return ResolvedNominalTypeReference(
        mainDecl: resolvedMainDecl,
        name: QualifiedTypeName.nestedScope(
          scope: scope,
          type: type.addingComponents(memberNames)
        ),
        originatingSyntax: originatingSyntax,
        savingToTable: symbolTable
      )
    }
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

extension NominalTypeDeclSyntax2 {
  enum ChainResolutionFailure: Error {
    // We can only perform chain resolution in nodes nested within a file
    case noSourceFileRoot(root: Syntax)
    // We need all type names in the chain to be valid identifiers
    case invalidIdentifier(TokenSyntax)
  }

  /// referencing this type from the given lookup loationFind the type chain of this source location. External module or `nil` for this module (internal).
  func findTypeChain(module: Identifier?) -> Result<ChainResult, ChainResolutionFailure> {
    /// Parse the token into a valid identifier or throw
    func parseName(_ token: TokenSyntax) throws(ChainResolutionFailure) -> Identifier {
      guard let identifier = Identifier(validating: token) else {
        throw .invalidIdentifier(token)
      }
      return identifier
    }

    return Result(catching: { () throws(ChainResolutionFailure) in
      guard let sourceFile = root.as(SourceFileSyntax.self) else {
        throw .noSourceFileRoot(root: root)
      }

      var ancestor: Syntax? = parent
      // All the members. Since we include `self`, `members.count>=1`
      var members = [(mainDecl: self, name: try parseName(self.name))]

      while let currentAncestor = ancestor {
        // Nominal types go to the front of the "chain"
        if let nominalTypeDecl = currentAncestor.as(NominalTypeDeclSyntax2.self) {
          try members.insert((mainDecl: nominalTypeDecl, name: parseName(nominalTypeDecl.name)), at: 0)
        }
        // Extensions can't be resolved right now.
        else if let extensionDecl = currentAncestor.as(ExtensionDeclSyntax.self) {
          return ChainResult.partiallyResolved(
            PartiallyResolvedNominalTypeChain(base: extensionDecl, members: members)
          )
        }
        // Top-level scope
        else if currentAncestor.parent == Syntax(sourceFile) {
          let qualifier: QualifiedTypeNameGlobalType.Qualifier =
            if let module {
              .external(moduleName: module)
            } else {
              .internal(fileID: sourceFile.id)
            }
          let components = members.map({
            QualifiedTypeNameGlobalType.Component(qualifier: qualifier, name: $0.name)
          })
          // Assert we have ennough members (we include `self` above)
          guard let globalType = QualifiedTypeNameGlobalType(components: components) else {
            fatalError(
              "[SwiftLexicalLookup] Internal error: Unexpectedly got `nil` globalType, implying that `components` is empty, which shouldn't happen since `members` are always nonempty."
            )
          }

          return ChainResult.resolved(
            QualifiedTypeName.topLevel(
              globalType
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

          return ChainResult.resolved(
            QualifiedTypeName.nestedScope(
              scope: scope,
              type: nestedType
            )
          )
        }

        ancestor = currentAncestor.parent
      }

      // Shouldn't happen because we checked there's a source-file root above.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly got no result despite having verified source-file root."
      )
    })
  }
}
