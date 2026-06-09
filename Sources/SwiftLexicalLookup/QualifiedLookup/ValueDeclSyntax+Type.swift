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

// MARK: Type Queries

@_spi(_QualifiedLookup) public indirect enum UnresolvedTypeRef: Equatable {
  // E.g. Int, Swift::Int, String::Swift::UTF8View
  // TODO: Implement generics
  case member(base: UnresolvedTypeRef?, moduleName: Identifier?, typeName: Identifier)
  // `any <ProtocolOrObject>`. Note that we don't check if `base` is actually a protocol or object.
  // E.g. `any CustomStringConvertible`
  case existential(base: UnresolvedTypeRef)
  // <Type>.Type. Note that `<MyProto>.Protocol` is translated as `(any <MyProto>).Type`
  // E.g. `Int.Type`
  case metatype(base: UnresolvedTypeRef)
  // case `function`(args: [UnresolvedTypeRef], returnType: [UnresolvedTypeRef])

  // init(syntax: TypeSyntax) {
  //   // FIXME: TODO
  // }

  public enum Failure: Error {
    case invalidKind(SyntaxKind)
    case invalidIdentifier(TokenSyntax)
    case genericsNotYetSupported
    /// The ``MetatypeTypeSyntax/metatypeSpecifier`` field
    /// was neither `Type` nor `Protocol`
    /// Shouldn't occur with a valid syntax tree.
    case invalidMetatypeSpecifier(TokenSyntax)
  }

  static let _stdlibModuleIdentifier = Identifier(canonicalName: "Swift")

  // TODO: Implement the rest
  public static func fromTypeSyntax(_ typeSyntax: TypeSyntax) -> Result<UnresolvedTypeRef, Failure> {
    func parseIdentifier(token: TokenSyntax) throws(Failure) -> Identifier {
      guard let identifier = Identifier(validating: token) else {
        throw Failure.invalidIdentifier(token)
      }
      return identifier
    }
    func parseGenerics(_ genericArgumentClause: GenericArgumentClauseSyntax?) throws(Failure) {
      if genericArgumentClause != nil { throw Failure.genericsNotYetSupported }
    }

    return Result(catching: { () throws(Failure) -> UnresolvedTypeRef in
      switch typeSyntax.as(TypeSyntaxEnum.self) {
      case .identifierType(let identifierType):
        try parseGenerics(identifierType.genericArgumentClause)
        return UnresolvedTypeRef.member(
          base: nil,
          moduleName: try (identifierType.moduleSelector?.moduleName).map(parseIdentifier(token:)),
          typeName: try parseIdentifier(token: identifierType.name),
        )
      case .memberType(let memberType):
        try parseGenerics(memberType.genericArgumentClause)
        return UnresolvedTypeRef.member(
          base: try fromTypeSyntax(typeSyntax).get(),
          moduleName: try (memberType.moduleSelector?.moduleName).map(parseIdentifier(token:)),
          typeName: try parseIdentifier(token: memberType.name)
        )
      case .metatypeType(let metatypeType):
        // According to the docs, metatypeSpecifier := `Type` | `Protocol`
        switch metatypeType.metatypeSpecifier.tokenKind {
        case .keyword(.Type):
          return UnresolvedTypeRef.metatype(base: try fromTypeSyntax(metatypeType.baseType).get())
        case .keyword(.Protocol):
          return UnresolvedTypeRef.metatype(
            base: UnresolvedTypeRef.existential(base: try fromTypeSyntax(metatypeType.baseType).get())
          )
        default:
          throw Failure.invalidMetatypeSpecifier(metatypeType.metatypeSpecifier)
        }
      // Example of handling built-in types
      // case .optionalType(let optionalType):
      //   return UnresolvedTypeRef.member(
      //     base: nil,
      //     moduleName: Self._stdlibModuleIdentifier,
      //     typeName: Identifier(canonicalName: "Optional")
      //   )
      default:
        throw .invalidKind(typeSyntax.kind)
      }
    })
  }
}

//
// extension ValueDeclSyntax {
//
//   // TODO: Figure out how to handle nominal types inside function-likes
//   // (funcs, inits, deinits, var accessors, subscripts), i.e., 'anonymous' contexts
//   private func _getTypeDeclType(_ typeDecl: some NominalTypeDeclSyntax) -> UnresolvedTypeRef? {
//     // Approach 1: If the type of the parent named decl is a metatype, then attach ourselves instead of .Type
//     //
//     // Approach 2: Go up the tree and check for 3 things:
//     //   (1) found decl context => return as global type
//     //   (2) found nominal type || prptocol => return membertype of <decl group type>.name
//     //   (3) found extension => return <extension type>.name
//     //   (4) anything else => keep going up
//
//     // No type with invalid identifier
//     guard let name: String = Identifier(validating: typeDecl.name) else { return nil }
//     func process(node: Syntax) -> UnresolvedTypeRef? {
//       if self._asDeclContext != nil {
//         return TypeRef.member(nil, moduleName: nil, typeMember: name)
//       } else if let nominalParent = node.asProtocol((any NominalTypeDeclSyntax).self) {
//         return TypeRef.member(ValueDeclSyntax(nominalParent).contextualType, moduleName: nil, typeMember: name)
//       } else if let extensionParent = node.as(ExtensionDeclSyntax.self) {
//         return TypeRef.member(TypeRef(syntax: extensionParent.extendedType), moduleName: nil, typeMember: name)
//       } else if let grandparent = node.parent {
//         return process(node: grandparent)
//       } else {
//         return nil
//       }
//     }
//
//     return parent.flatMap(process(node:))
//   }
//
//   /// A type that's valid in ``ValueDeclSyntax/declContext``.
//   var contextualType: UnresolvedTypeRef? {
//     // fatalError("[SwiftLexicalLookup] Internal Error: `type` query is not yet implemented for ValueDeclSyntax")
//     switch _syntaxNode.kind {
//     // Types
//     case .structDecl:
//       return _getDeclGroupType(_syntaxNode.cast(StructDeclSyntax.self))
//     case .enumDecl:
//       return _getDeclGroupType(_syntaxNode.cast(EnumDeclSyntax.self))
//     case .classDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ClassDeclSyntax.self))
//     case .actorDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ActorDeclSyntax.self))
//     case .protocolDecl:
//       return _getDeclGroupType(_syntaxNode.cast(ProtocolDeclSyntax.self))
//     case .typeAliasDecl:
//       return TypeRef(syntax: _syntaxNode.cast(TypeAliasDeclSyntax.self).initializer.value)
//     case .associatedTypeDecl:
//       return _syntaxNode.cast(AssociatedTypeDeclSyntax.self).name
//
//     case .initializerDecl:
//       // (Args...) -> Self
//     case .deinitializerDecl:
//       // (Self) -> () -> Void
//       // Function-like, user provided
//     case .identifierPattern:
//       // Either ScopeLookupError, or RetType not provided error for computer, or .inferFromLet, or VarDecl RetType
//     case .functionDecl:
//       // Either (Self) -> (Args...) -> RetType or (Args...) -> RetType
//       return _syntaxNode.cast(FunctionDeclSyntax.self).name
//     case .subscriptDecl:
//       // Either (Self) -> (Args...) -> RetType or (Args...) -> RetType
//
//       // Macro
//     case .macroDecl:
//       return _syntaxNode.cast(MacroDeclSyntax.self).name
//     // Enum element
//     case .enumCaseElement:
//       return _syntaxNode.cast(EnumCaseElementSyntax.self).name
//     default:
//       fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.kind)")
//     }
//
//   }
// }
