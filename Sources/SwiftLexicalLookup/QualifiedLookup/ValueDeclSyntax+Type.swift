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

import SwiftIfConfig
import SwiftSyntax

// MARK: Type Queries

extension ValueDeclSyntax {
  /// The type syntax of this type declaration; `nil` if not a type declaration.
  var typeName: TokenSyntax? {
    // TODO: Helper is useless; remove
    // Helper that converts TokenSyntax -> Identifier?
    func typeNameFromToken(_ name: TokenSyntax) -> TokenSyntax {
      name
    }

    // Just get the name
    return switch _syntaxNode.as(SyntaxEnum.self) {
    case .structDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    case .enumDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    case .classDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    case .actorDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    case .protocolDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    case .typeAliasDecl(let typeDecl):
      typeNameFromToken(typeDecl.name)
    default:
      nil
    }
  }
}

extension TokenSyntax {
  // enum IdentifierTypeLookupFailure: Error {
  //   /// Can't use `Self` in a non-child of a nominal type declaration or extension.
  //   case globalUseOfSelf
  //   case noParent
  // }

  // var _nominalParent: Result<any NominalTypeDeclSyntax, IdentifierTypeLookupFailure> {
  //   guard let parent else { return . }
  //   guard let nominalParent = parent
  // }

  // The difficulty is that a type isn't just one declaration; it's a name that can be extended and aliased.
  // The good news is that any types in nested scopes can't be extended. However, type alias can exist
  // anywhere which add some redirection.
  //
  // Examples:
  // 1. `typealias A = Int`; what should `A` lookup return? is it the type alias decl or `Int`?
  // 2. `func f() { struct A {} }`; what should `A` lookup return? is it the declaration or a type syntax `A`
  //     that must be scoped to be within the function!!

  // TODO: This method is only useful for resolving `Self` (kind of)

  /// Returns the declarations the given identifier syntax might refer to.
  func asTypeIdentifier() -> [ValueDeclSyntax] {
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
    guard let typeID = self.identifier else { return [] }

    let results = lookup(typeID, with: LookupConfig(_lookupTopScope: true))
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
        let typeDecls = declGroup.findDirectMembers(
          name: DeclNameRef(baseName: .identifier(identifier: typeID, args: nil)),
          kind: .includeTypes
        )
        return typeDecls.compactMap({ typeDecl in
          guard let typeName = typeDecl.typeName else {
            assertionFailure("[SwiftLexicalLookup] Internal Error: Expected type-only lookup to yield only types.")
          }
          return TypeSyntax(IdentifierTypeSyntax(name: typeName))
        })
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

indirect enum TypeNameRef: Hashable {
  case member(base: TypeNameRef?, moduleName: Identifier?, name: Identifier)

  enum NominalValidationFailure: Error {
    case invalidModuleIdentifier
    case invalidNameIdentifier
    case nonNominalType(TypeSyntax)
  }
  static func validatingNominal(_ type: TypeSyntax) -> Result<TypeNameRef, NominalValidationFailure> {
    let baseTypeSyntax: TypeSyntax?
    let moduleToken: TokenSyntax?
    let nameToken: TokenSyntax
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
      (baseTypeSyntax, moduleToken, nameToken) = (nil, identifierType.moduleSelector?.moduleName, identifierType.name)
    } else if let memberType = type.as(MemberTypeSyntax.self) {
      (baseTypeSyntax, moduleToken, nameToken) = (
        memberType.baseType, memberType.moduleSelector?.moduleName, memberType.name
      )
    }
    // TODO: Add sugar types like Array, Dict, InlineArray, Optional

    return Result(catching: { () throws(NominalValidationFailure) -> TypeNameRef in
      // Validate base
      let baseType = try baseTypeSyntax.map({ baseTypeSyntax throws(NominalValidationFailure) in
        try validatingNominal(baseTypeSyntax).get()
      })
      // Validate module name, if provided
      let moduleName = try moduleToken.map({ moduleToken throws(NominalValidationFailure) in
        guard let unwrappedModuleName = Identifier(validating: moduleToken) else {
          throw NominalValidationFailure.invalidModuleIdentifier
        }
        return unwrappedModuleName
      })
      // Validate name
      guard let name = Identifier(validating: nameToken) else {
        throw NominalValidationFailure.invalidNameIdentifier
      }
      // Init self
      return TypeNameRef.member(base: baseType, moduleName: moduleName, name: name)
    })
  }
}

extension Int {
  private struct A {}
}

struct SymbolTable2 {
  enum MainTypeDecl {
    case nominal(NominalTypeDeclSyntax)
    case alias(TypeAliasDeclSyntax)
    case associatedType(AssociatedTypeDeclSyntax)
  }
  struct SourceType {
    /// We'll always show the first mainDecl, because other type decls
    /// of the same name *in the same scope* are redeclarations.
    ///
    /// For instance, if we have `extension Int { private struct A {} }`
    /// in FileA.swift and then again in FileB.swift, those two are different
    /// file scopes.
    var mainDecls: [MainTypeDecl] = []
    var extensions: [ExtensionDeclSyntax] = []
    var aliasedBy: [(UnresolvedTypeRef, TypeAliasDeclSyntax)] = []
  }
  typealias ScopeTypeMap = [TypeNameRef: SourceType]

  var scopeMap = [CodeBlockItemListSyntax: ScopeTypeMap]()
  let configuredRegions: ConfiguredRegions?
}

// MARK: Scope Map

// TODO: Handle if configs
/// Walks
// class ScopeVisitor: SyntaxVisitor {
//   override func visit(_ node: ) -> SyntaxVisitorContinueKind {
//   code
//   }
// }

/// Visits type declarations (nominal types, type aliases and associated types),
/// in addition to extensions.
func _visitDirectTypesOfDecl(
  decl: DeclSyntax,
  configuredRegions: ConfiguredRegions?,
  visit: (DeclSyntax) -> Void
) {
  /// Process a member or a member nested inside an if-config declaration.
  ///
  /// This pattern is similar to the SyntaxVisitor pattern, but a SyntaxVisitor
  /// doesn't work because we use protocols like `NamedDeclSyntax`
  func processMember(decl: DeclSyntax) {
    switch decl.as(DeclSyntaxEnum.self) {
    // Visit type and extension decls
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .typeAliasDecl, .associatedTypeDecl, .extensionDecl:
      visit(decl)
    // Recursively handle if-configs
    case .ifConfigDecl(let ifConfigDecl):
      // If `configuredRegions` is provided, only look at active clause
      if let configuredRegions,
        case .decls(let members) = configuredRegions.activeClause(for: ifConfigDecl)?.elements
      {
        for member in members {
          processMember(decl: member.decl)
        }
      }
      // Without a configuration, visit all clauses
      else {
        for clause in ifConfigDecl.clauses {
          guard case .decls(let members) = clause.elements else { return }
          for member in members {
            processMember(decl: member.decl)
          }
        }
      }
    // Otherwise, do nothing
    default: break
    }
  }

  // Find all ValueDeclSyntax members in this declaration
  processMember(decl: decl)
}

extension SymbolTable2 {
  func visitBlock(
    in parentType: some NominalTypeDeclSyntax,
    base: TypeNameRef?,
    module: Identifier?,
    addingTo results: inout [TypeNameRef: SourceType]
  ) {
    //   // Visit type decls and store names
    //   // TODO: Add configured regions
    //   parentType.visitDirectMembers(configuredRegions: nil, visit: { valueDecl in
    //     // Only process type declarations (only type decls have type names)
    //     guard let typeNameToken = valueDecl.typeName, let typeID = Identifier(validating: typeNameToken) else {
    //       return
    //     }
    //
    //     let typeRef = TypeNameRef.member(base: base, moduleName: module, name: typeID)
    //
    //     let sourceType: SourceType
    //     if let nominalDecl = valueDecl.asProtocol((any NominalTypeDeclSyntax).self) {
    //       sourceType = .nominal(mainDecl: nominalDecl, extensions: [])
    //     } else if let typeAliasDecl = valueDecl.as(TypeAliasDeclSyntax.self) {
    //       sourceType = .alias(typeAliasDecl)
    //     } else if let associatedTypeDecl = valueDecl.as(AssociatedTypeDeclSyntax.self) {
    //       sourceType = .associatedType(associatedTypeDecl)
    //     } else {
    //       assertionFailure("[SwiftLexicalLookup] Internal error: No other known type/value declarations")
    //       return
    //     }
    //
    //     results[typeRef, default: []].append(sourceType)
    //   })
  }

  // TODO: Do we need to get into the child scopes?
  func mapScopeTypes(
    scope: CodeBlockItemListSyntax,
    moduleName: Identifier?
  ) -> [TypeNameRef: SourceType] {
    var results = [TypeNameRef: SourceType]()
    // Other decls we need to handle.
    var unvisitedTypes = [(typeRef: TypeNameRef?, nominalType: any NominalTypeDeclSyntax)]()

    // Add the given value declaration with the given parent type reference.
    //
    // For example, consider:
    //   func f() {
    //     struct A {
    //       struct B {}
    //     }
    //   }
    // Here, `A` doesn't have a parent reference (something like `f.A`); we just
    // refer to it as `A` from the body of the function. However, `B`'s parent type
    // reference is `A`, since we can write `A.B` to access the nested struct from
    // the body of the function.
    func processDecl(_ decl: DeclSyntax, parentTypeRef: TypeNameRef?) {
      // Handle extensions
      if let extensionDecl = decl.as(ExtensionDeclSyntax.self) {
        // We can only extend nominal types
        guard let typeRef = try? TypeNameRef.validatingNominal(extensionDecl.extendedType).get() else {
          return
        }
        // Add extended type
        results[typeRef, default: SourceType()].extensions.append(extensionDecl)
        return
      }

      // Only look at type decls
      let typeNameToken: TokenSyntax
      let mainDecl: MainTypeDecl
      if let nominalDecl = decl.asProtocol((any NominalTypeDeclSyntax).self) {
        (typeNameToken, mainDecl) = (nominalDecl.name, .nominal(nominalDecl))
      } else if let typeAliasDecl = decl.as(TypeAliasDeclSyntax.self) {
        (typeNameToken, mainDecl) = (typeAliasDecl.name, .alias(typeAliasDecl))
      } else if let associatedTypeDecl = decl.as(AssociatedTypeDeclSyntax.self) {
        (typeNameToken, mainDecl) = (associatedTypeDecl.name, .associatedType(associatedTypeDecl))
      } else {
        return
      }

      // Add the main decl
      guard let typeName = Identifier(validating: typeNameToken) else { return }
      let typeRef = TypeNameRef.member(base: parentTypeRef, moduleName: moduleName, name: typeName)
      results[typeRef, default: SourceType()].mainDecls.append(mainDecl)
      // Add nominal types to queue
      if case .nominal(let nominalType) = mainDecl {
        unvisitedTypes.append((typeRef, nominalType))
      }
    }

    // Visit top-scope declarations (no parent type reference)
    // TODO: Should we discard associated types if nominal type isn't a protocol?
    for scopeItem in scope {
      // Skip non-decls
      guard case .decl(let decl) = scopeItem.item else { continue }
      // Visit decls (handles if configs)
      _visitDirectTypesOfDecl(
        decl: decl,
        configuredRegions: configuredRegions,
        visit: { decl in
          processDecl(decl, parentTypeRef: nil)
        }
      )
    }

    // Visit types nested in nominal types
    // TODO: Change to Dequeue and use `popFirst` to have more sensible order
    while let (typeRef, nominalType) = unvisitedTypes.popLast() {
      for member in nominalType.memberBlock.members {
        _visitDirectTypesOfDecl(
          decl: member.decl,
          configuredRegions: configuredRegions,
          visit: { decl in
            processDecl(decl, parentTypeRef: typeRef)
          }
        )
      }
    }

    return results
  }

  // // Extensions are only valid at file scope.
  // // TODO: Consider whether we could add extensions for all scopes
  // func getScopeExtensions(scope: CodeBlockItemListSyntax) -> [TypeNameRef: [DeclGroupSyntaxType]] {
  //
  // }

  // func mapScope(scope: CodeBlockItemListSyntax) -> ScopeTypeMap {
  //   var typeMap: ScopeTypeMap = [TypeNameRef: SourceType]()
  //
  //   var declQueue = [()]
  //   for listItem in scope {
  //     guard
  //       decl = listItem.item.as(ValueDeclSyntax.self),
  //       let typeName = decl
  //   }
  // }

  subscript(
    scope scope: CodeBlockItemListSyntax,
    moduleName moduleName: Identifier?,
  ) -> ScopeTypeMap {
    mutating _read {
      guard let map = scopeMap[scope] else {
        let map = mapScopeTypes(scope: scope, moduleName: moduleName)
        scopeMap[scope] = map
        yield map
        return
      }
      yield map
    }
  }
}
