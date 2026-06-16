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

// TODO: Every parent type needs to be resolved because even if we look for `A`
// in `extension String.UTF8View { struct A { func f(_: A) } }` and find `struct A`,
// we still need to bind extensions so we need to resolve `String.UTF8View`.
// I.e. Even if we find a matching type decl (and we know we can exit early),
//      qualifying the type means qualifying all parent scopes, which necessitates
//      resolving parent scopes.
enum TypeResultLookup {
  case nominal(NominalTypeDeclSyntax2)
  case `extension`(ExtensionDeclSyntax)
  case lookInside(DeclGroupSyntaxType)
  case lookForGenericParameters(GenericParameterListSyntax)

  enum Resolution {

  }
  enum Failure: Error {
  }
  func resolve() -> Result<TypeNameRef, Failure> {
    switch self {
    case .declGroup(let declGroup):

    }
  }
}

@_spi(_QualifiedLookup) public enum UnqualifiedResult {
  case lookIn(PartiallyResolvedType, includeGenericParams: Bool)
}
extension SyntaxProtocol {
  func findUnqualifiedType1(identifier: Identifier?, name: Identifier?) -> TypeDeclSyntax? {
    // Get next parent
    var genericOrAssociated = [GenericParameterSyntax]()
    var parentNames = [TypeDeclSyntax]()

  }
  func findUnqualifiedType2(
    _ typeName: TokenSyntax
  ) -> [DeclSyntax] {
    // Find first nominal-type parent. Note that we can cross declaration-scope boundaries, e.g.
    //   struct A {
    //     func f() { // <- declaration-scope boundary
    //       var a: Self = A() // `Self` -> `A`
    //     }
    //   }
    // if typeID.tokenKind == .keyword(.Self) {
    //
    // }

    // Convert to identifier
    guard let typeID = Identifier(validating: typeName) else { return [] }

    // TODO: Handle generic type decls (show up as a .fromScope(GenericParameterSyntax))
    func handleDecl(_ decl: DeclSyntax) -> Bool {
      return switch decl.kind {
      case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl,
        .typeAliasDecl, .associatedTypeDecl:
        self[scope:]
      default:
        false
      }
    }

    let results = typeName.lookup(typeID, with: LookupConfig(_lookupTopScope: true))
    results.flatMap({ result -> [TypeSyntax] in
      switch result {
      case .fromScope(let scope, let names):
        // Note that we skip non-type declarations, even if they have the same name.
        // For instance:
        //   struct A {
        //     func f() {
        //       let A = 1
        //       func A() {}
        //       var hey: A  = self
        //     }
        //   }
        names.compactMap({ name -> TypeSyntax? in
          switch name {
          case .implicit(.`Self`(let decl)):
            // TODO: Should probably be DeclGroupSyntax to begin with
            guard let groupDecl = decl.as(DeclGroupSyntaxType.self) else { return nil }
            return groupDecl.type
          case .declaration(let decl):
            // Skip non-type declarations
            guard
              let valueDecl = decl.as(ValueDeclSyntax.self),
              let typeName = valueDecl.typeName
            else { return nil }

            return TypeSyntax(IdentifierTypeSyntax(name: typeName))
          // Identifiers, `self`, `newValue`, `error`, and `oldValue` can't be type decls.
          case .identifier, .implicit(.`self`), .implicit(.newValue), .implicit(.oldValue), .implicit(.error):
            return nil
          }
        })
      case .lookForMembers(let declGroup):
        // let typeDecls = declGroup.findDirectMembers(
        //   name: DeclNameRef(baseName: .identifier(identifier: typeID, args: nil)),
        //   kind: .includeTypes
        // )
        // return typeDecls.compactMap({ typeDecl in
        //   guard let typeName = typeDecl.typeName else {
        //     assertionFailure("[SwiftLexicalLookup] Internal Error: Expected type-only lookup to yield only types.")
        //   }
        //   return TypeSyntax(IdentifierTypeSyntax(name: typeName))
        // })
        declGroup
      case .lookForGenericParameters(let genericParams):
        return TypeSyntax(
          IdentifierTypeSyntax(
            name: TokenSyntax.init(.identifier(typeID), presence: .present).with(\.position, genericParams.position)
          )
        )
      // Closure parameters can't be type declarations
      case .lookForImplicitClosureParameters(_):
        return []
      }
    })
  }
}
