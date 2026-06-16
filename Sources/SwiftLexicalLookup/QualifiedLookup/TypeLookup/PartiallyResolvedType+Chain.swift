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

enum ChainResult {
  case resolved(QualifiedTypeName)
  case partiallyResolved(PartiallyResolvedNominalTypeChain)
}

struct PartiallyResolvedNominalTypeChain {
  // Base and members should be in the same file
  let base: TypeSyntax
  let memberNames: [Identifier]
  let sourceFile: SourceFileSyntax

  // IMPORTANT: Base and members must share the same fileSyntax root.
  init(base: TypeSyntax, members: [(name: Identifier, decl: NominalTypeDeclSyntax2)]) {
    // precondition(base.root == members.root, "Invalid root")
    guard let sourceFile = base.root.as(SourceFileSyntax.self) else {
      preconditionFailure("Invalid root, not source file")
    }
    // Map and check source file
    let memberNames = members.map({ (name, decl) in
      assert(decl.root == sourceFile.root, "Invalid decl root, not source file")
      return name
    })

    self.base = base
    self.memberNames = memberNames
    self.sourceFile = sourceFile
  }

  // Resolve using now-qualified base. Module name or `nil` for this module (internal).
  func resolve(resolvedBase: QualifiedTypeName, module: Identifier?) -> QualifiedTypeName {
    switch resolvedBase {
    case .topLevel(let globalType):
      let qualifier: QualifiedTypeNameGlobalType.Qualifier =
        if let module {
          .external(moduleName: module)
        } else {
          .internal(fileID: sourceFile.id)
        }
      let memberComponents: [QualifiedTypeNameGlobalType.Component] = memberNames.map({ name in
        (qualifier: qualifier, name: name)
      })
      return QualifiedTypeName.topLevel(
        QualifiedTypeNameGlobalType(
          components: globalType.components + memberComponents
        )
      )
    case .nestedScope(let scope, let type):
      return QualifiedTypeName.nestedScope(scope: scope, type: type.addingComponents(memberNames))
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
    case invalidIdentifier(TokenSyntax)
  }

  // Find the type chain of this source location. Module or `nil` for this module (internal).
  func findTypeChain(module: Identifier?) -> Result<ChainResult, ChainResolutionFailure> {
    guard let sourceFile = root.as(SourceFileSyntax.self) else {
      // FIXME: Throw
    }

    func parseName(_ token: TokenSyntax) throws(ChainResolutionFailure) -> Identifier {
      guard let identifier = Identifier(validating: token) else {
        throw .invalidIdentifier(token)
      }
      return identifier
    }

    Result(catching: { () throws(ChainResolutionFailure) in
      var ancestor: Syntax? = parent
      // All the members. Since we include `self`, `members.count>=1`
      var members = [self]

      while let currentAncestor = ancestor {
        if let nominalTypeDecl = currentAncestor.as(NominalTypeDeclSyntax2.self) {
          members.append(nominalTypeDecl)
        } else if let extensionDecl = currentAncestor.as(ExtensionDeclSyntax.self) {
          return ChainResult.partiallyResolved(
            PartiallyResolvedNominalTypeChain(base: extensionDecl.extendedType, members: members)
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
          let components = try members.map({ (qualifier: qualifier, name: try parseName($0.name)) })
          // Assert we have ennough members (we include `self` above)
          guard let globalType = QualifiedTypeNameGlobalType(components: components) else {
            fatalError("Members shouldn't be empty")
          }

          return ChainResult.resolved(
            QualifiedTypeName.topLevel(
              globalType
            )
          )
        }
        // Nested scope (if CodeBlockItemListSyntax isn't nested directly under `SourceFileSyntax`)
        else if let scope = currentAncestor.as(CodeBlockItemListSyntax.self) {
          let components = try members.map({ member throws(ChainResolutionFailure) in
            try parseName(member.name)
          })

          // Assert we have ennough members (we include `self` above)
          guard let nestedType = QualifiedTypeNameNestedType(components: components) else {
            fatalError("Members shouldn't be empty")
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
    })
  }
}
