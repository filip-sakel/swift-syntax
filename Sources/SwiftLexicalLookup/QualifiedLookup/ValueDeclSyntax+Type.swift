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

// MARK: Type in SymbolTable
//
// E.g.
// func f() {
//   struct A {
//     struct B {
//       struct A {
//         func f(a: A) -> Self {} // <- Looking up `A` and `Self` here resolves to `A.B.A`
//      }
//     }
//   }
// }

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
  // func asTypeIdentifier() -> [ValueDeclSyntax] {
  //   // Find first nominal-type parent. Note that we can cross declaration-scope boundaries, e.g.
  //   //   struct A {
  //   //     func f() { // <- declaration-scope boundary
  //   //       var a: Self = A() // `Self` -> `A`
  //   //     }
  //   //   }
  //   // if typeID.tokenKind == .keyword(.Self) {
  //   //
  //   // }
  //
  //   // Convert to identifier
  //   guard let typeID = Identifier(validating: self) else { return [] }
  //
  //   let results = lookup(typeID, with: LookupConfig(_lookupTopScope: true))
  //   results.flatMap({ result -> [TypeSyntax] in
  //     switch result {
  //     case .fromScope(let scope, let names):
  //       // Note that we skip non-type declarations, even if they have the same name.
  //       // For instance:
  //       //   struct A {
  //       //     func f() {
  //       //       let A = 1
  //       //       func A() {}
  //       //       var hey: A  = self
  //       //     }
  //       //   }
  //       names.compactMap({ name -> TypeSyntax? in
  //         switch name {
  //         case .implicit(.`Self`(let decl)):
  //           // TODO: Should probably be DeclGroupSyntax to begin with
  //           guard let groupDecl = decl.as(DeclGroupSyntaxType.self) else { return nil }
  //           return groupDecl.type
  //         case .declaration(let decl):
  //           // Skip non-type declarations
  //           guard
  //             let valueDecl = decl.as(ValueDeclSyntax.self),
  //             let typeName = valueDecl.typeName
  //           else { return nil }
  //
  //           return TypeSyntax(IdentifierTypeSyntax(name: typeName))
  //         // Identifiers, `self`, `newValue`, `error`, and `oldValue` can't be type decls.
  //         case .identifier, .implicit(.`self`), .implicit(.newValue), .implicit(.oldValue), .implicit(.error):
  //           return nil
  //         }
  //       })
  //     case .lookForMembers(let declGroup):
  //       let typeDecls = declGroup.findDirectMembers(
  //         name: DeclNameRef(baseName: .identifier(identifier: typeID, args: nil)),
  //         kind: .includeTypes
  //       )
  //       return typeDecls.compactMap({ typeDecl in
  //         guard let typeName = typeDecl.typeName else {
  //           assertionFailure("[SwiftLexicalLookup] Internal Error: Expected type-only lookup to yield only types.")
  //         }
  //         return TypeSyntax(IdentifierTypeSyntax(name: typeName))
  //       })
  //     case .lookForGenericParameters(let genericParams):
  //       return TypeSyntax(
  //         IdentifierTypeSyntax(
  //           name: TokenSyntax.init(.identifier(typeID), presence: .present).with(\.position, genericParams.position)
  //         )
  //       )
  //     // Closure parameters can't be type declarations
  //     case .lookForImplicitClosureParameters(_):
  //       return []
  //     }
  //   })
  // }
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
    // TODO: Ensure we reject `Self` and `Any` (along with metatypes, some/any, tuples, and other non nominal)
    // TODO: We should probably reject force-unwrapped optional, e.g.,
    //         `typealias A = Int!` and `extension Int! {}`

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

/// The symbol table facilitates lookup. The central API consists of looking up
/// a declaration name reference in some type syntax. For instance, in type
/// `Int` >lookup> `bitWidth`.
///
/// Taking a step back, these are two operations: (1) find all declaration groups (nominal types
/// and extensions) that `Int` refers to, and (2) look up the declaration name reference `bitWidth`
/// in each.
///
/// 1. Resolving `TypeSyntax`
///    In valid programs, any type syntax resolves will resolve to one or more extended nominal
///    types (we'll define these soon). Examples:
///    a. `Int` resolves to `Swift::Int`
///    b. `Codable` (an alias for `Encodable & Decodable`) resolves to `Swift::Encodable`
///    `Swift::Decodable`.
///
///    TODO: Does it make sense to extend these qualified identifiers to `DeclName`?
///
///    To facilitate this lookup, we give declaration names scope identifiers. There are
///    three types of identifiers:
///    1. Top-level names
///       These are accessible from the top-level (without filtering for access control).
///       They consist of one or more dot-separated components, each fully qualified.
///       A fully qualified means we specify the module name. Additionally, for internal
///       declarations (declared in our own module), we specify the file where the main
///       declaration lives.
///
///       Specifying the file name for internal names disambiguates fileprivate
///       declarations. For instance:
///         // FileA.swift
///         fileprivate struct A {}
///         // FileB.swift
///         fileprivate struct A {}
///       Notes:
///       a. File IDs aren't necessary in external modules because
///          we can assume everything comes in one module interface file
///          where everything is public, or internal (e.g. for `@usableFromInline`).
///       b. File IDs are granular enough for internal declarations. Ultimately,
///          most times we use `private`, it's interpreted as `fileprivate`:
///            // MyFile.swift
///            extension Int {
///              private struct A {}
///            }
///            extension Int {
///              private struct A {} // ❌ Invalid redeclaration of `A`
///            }
///
///        Examples include:
///        a. `Swift::Int` (external module)
///        b. `Swift::String.Foundation::Encoding` (different external modules)
///        c. `Swift::Int.MyModule(FileA.swift)::A` and `Swift::Int.MyModule(FileB.swift)::A` in:
///              // MyModule>FileA.swift
///              extension Int {
///                fileprivate struct A {}
///              }
///              // MyModule>FileB.swift
///              extension Int {
///                fileprivate struct A {}
///              }
///     2. Internal, nested-scope names
///        These are nested scopes, i.e., `CodeBlockItemListSyntax` that's not just
///        the top-level file scope.
///
///        Notes:
///        a. Types declared in nested scopes aren't accessible from the top-level.
///
///           For instance, we can't access `A` in:
///             func f() {
///               struct A { // (f scope)->A
///                 struct B {} // (f scope)->A.B
///               }
///             }
///             extension A {} // ❌ Cannot find `A`
///
///           Hence, we only need to specify the scope for the base type of a
///           member type syntax. That is, we don't write `(f scope)->A.(f scope)->B`.
///
///        b. Nested-scope types are only relevant for internal declarations.
///
///           Since we can't access types declared in nested scopes from the top-level,
///           they're only useful for type-checking and code generation. However,
///           all external function/storage declarations have already been type checked.
///
///           Hence, we don't need to specify the module; it's implicitly our module.
///
///    Type syntax broadly falls into 3 types:
///    1. Type sugar:
///
///    Extended nominal types consist of the the main type declaration
///    (`[Struct/Enum/Class/Actor/Protocol]DeclSyntax`) and all the extensions
///    referencing them. Hence, to find the extended nominal type, we follow
///    the steps below:
///    1. Get the referenced type declaration.
///       We get the main declaration by performing unqualified lookup from the
///       position of the type syntax looking for the base type name. For instance:
///         struct A {
///           func f() {
///             struct A {
///               func g(a: A) {}
///                         `- Lookup `A` from here
///             }
///           }
///         }
/// │     If unqualified lookup decides not to lie to us, we should get the nested
/// │     `struct A` declaration. This lookup is similar to the compiler's
/// │     `directReferencesForUnqualifiedTypeLookup`.
/// │
/// │  2. Resolve to a main nominal-type declaration.
/// │      Unqualified lookup simply returns a type declaration, which could be a:
/// │      a. Nominal type: great! we can move onto the next step
/// ├───── b. Type alias: we need to recursively resolve the aliased type syntax
/// │      c. Associated type or generic parameter: we can't do much here (TODO:: Check the compiler also gives up)
/// │
/// │  3. Fully qualify the main type declaration.
/// │     We go up the syntax tree to find the first `CodeBlockItemListSyntax`
/// │     ancestor; this is our scope. There are two cases:
/// │     a. Our main declaration is a direct child of the scope node, so
/// │        we can qualify it:
/// │         i. If the scope's parent is a `SourceFileSyntax`, this is a
/// │            top-level name whose fully qualified name is:
/// │              MyModule(MyFile.swift)::MyType`.
/// │            E.g. In FileA.swift `struct A {}` becomes `MyModue(FileA.swift)::A`.
/// │        ii. Otherwise, we have a nested scope. The qualified name is:
/// │              (nested scope)->MyType
/// │            E.g. `func f() { struct A{} }` becomes `(f scope)->A`
/// │     b. Our main declaration has a declaration-group (nominal type declaration
/// │        or extension) parent, which we need to qualify first.
/// │         i. If the declaration-group parent is a nominal-type declaration,
/// │            we go to step (1).
/// ╰─────── ii. If the declaration-group parent is an extension, recursively
///              resolve the extended type syntax. Since we can only extend
///              nominal types, the resolved type syntax should give us one
///              extended nominal-type declaration. Based on the parent's type
///              id, we construct this type's id:
///              1. if the parent is a top-level id, we have:
///                   <parent id>.MyModule(MyFile.swift)::MyType
///              2. if the parent is a nested scope, we have:
///                   <parent id>.MyType
///
///    After identifying the main declaration, we need to find its extensions.
///    For the lack of an easier way, we actually resolve all extended type
///    syntax (the compiler does this in `bindExtensions`).
///      Note: This approach differs from our lazy computations up to this point: we've
///            only been resolving type syntax that we know is relevant to our query.
///            The reason is that to lazily find all extensions of a type, we need
///            to know all of its aliases. Unfortunately, there's no easy way to find
///            just one type's aliases without resolving *all* type aliases. Hence, it's
///            easier to directly bind all extensions to a main nominal-type declaration.
///    Thus, the main declaration and every extension with the same type identifier forms
///    an _extended_ nominal type.
///
///    Finally, in this extended nominal type, we can perform qualified lookup
///    to find types (`directReferencesForQualifiedTypeLookup` in the compiler).
///    Namely, we call `_visitDirectMembers` on each `DeclGroupSyntax`
///    of the extended nominal type, and filter down to type declarations.
///    type declarations. We can then follow repeat the same process starting
///    from step (2). Thus, we've resolved a type identifier.
///
/// 2. Looking up names in `DeclGroupSyntax`
///    This is handled in `DeclGroupLookup` by calling `_visitDirectMembers`
struct SymbolTable2 {
  enum MainTypeDecl {
    case nominal(any NominalTypeDeclSyntax)
    case alias(TypeAliasDeclSyntax)
    case associatedType(AssociatedTypeDeclSyntax)

    var decl: ValueDeclSyntax {
      return switch self {
      case .nominal(let decl):
        ValueDeclSyntax(fromProtocol: decl)
      case .alias(let decl):
        ValueDeclSyntax(decl)
      case .associatedType(let decl):
        ValueDeclSyntax(decl)
      }
    }
  }

  // TODO: Assert we have at least one `mainDecl` and provide `.mainDecl` property
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
  /// Maps from type refs to types, and type declarations (nominal, aliases and associated types)
  /// to type refs.
  // TODO: Use CanonicalType for type decls, and type refs for extensions
  typealias ScopeTypeMap = (typeToRef: [TypeNameRef: SourceType], refToType: [ValueDeclSyntax: TypeNameRef])

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
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl,
      .extensionDecl:
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
  // TODO: Do we need to get into the child scopes?
  func mapScopeTypes(
    scope: CodeBlockItemListSyntax,
    moduleName: Identifier?
  ) -> ScopeTypeMap {
    var refToType = [TypeNameRef: SourceType]()
    var typeToRef = [ValueDeclSyntax: TypeNameRef]()
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
    // TODO: Include protocols as nominal types
    func processDecl(_ decl: DeclSyntax, parentTypeRef: TypeNameRef?) {
      // Handle extensions
      if let extensionDecl = decl.as(ExtensionDeclSyntax.self) {
        // We can only extend nominal types
        guard let typeRef = try? TypeNameRef.validatingNominal(extensionDecl.extendedType).get() else {
          return
        }
        // Add extended type
        refToType[typeRef, default: SourceType()].extensions.append(extensionDecl)
        // Note we don't reference extensions back (it's trivial to get .extendedType from
        // an extension decl)
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
      refToType[typeRef, default: SourceType()].mainDecls.append(mainDecl)
      typeToRef[mainDecl.decl] = typeRef
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

    return (refToType, typeToRef)
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

// MARK: Resolving TypeRefs
enum ResolvedScope {
  // We can't access non-file scopes from other modules, and
  // everything in file-scope declared public/internal must be unique
  // for lookup purposes.
  //
  // Note that `internal` is accessible under `@usableFromInline`-like attributes.
  case externalModule(Identifier)
  // We might have multiple declarations at module scope so we need a fileID
  // to discriminate.
  //
  // For instnace, the following is common:
  //   // FileA.swift
  //   fileprivate struct A {}
  //   // FileB.swift
  //   fileprivate struct A {}
  //
  // Note that `private` is often interpreted as fileprivate:
  //   extension Int {
  //     private struct A {}
  //   }
  //   extension Int {
  //     private struct A {} // <- Invalid redeclaration of `A`
  //   }
  // So lookup is unambiguous after specifying the fileID.
  case internalModule(fileID: SyntaxIdentifier)
  // Each nested scope allows for one valid declaration.
  //
  // E.g. A function body, variable accessor, `do` body.
  // Because nested scopes can't be extended, we don't have to worry
  // about multiple types of the same name (see `internalModule` above)
  case internalNested(CodeBlockItemListSyntax)
}

indirect enum ResolvedTypeName {
  case member(base: ResolvedTypeName?, scope: ResolvedScope, typeName: Identifier)
}

struct Module {
  let name: Identifier
  let interfaceSyntax: SourceFileSyntax
}

extension SymbolTable2 {
  enum ResolutionFailure: Error {
    case typeNotFound(TypeNameRef)
    case invalidScope
  }

  func moduleLookup(module: Identifier, name: DeclNameRef) {}
  func moduleLookup(module: Identifier, typeName: Identifier) {}

  func internalLookup(decl)

  // Resolves a type reference to a source type (with at least one) main declaration.
  // Returns appropriate error if not possible.
  //
  // Handles:
  // 1. Same top-level names in a module, e.g.:
  //
  // E.g.
  //
  // // FileA.swift
  // extension Int {
  //   fileprivate struct A {}
  // }
  // // FileB.swift
  // extension Int.A {} // <- What does Int.A refer to?
  //
  // We resolve to `Swift::Int.OurModule::FileA.swift:A`
  // In this case, `Int.A` does to FileA's scope Int.A
  //
  // 2. Same names across modules, e.g.:
  //   // FileA.swift
  //   fileprivate struct Int {}
  //   // FileB.swift
  //   fileprivate struct Int {}
  //   extension Int {} // <- Refers to OurModule::FileB:Int
  func resolveTypeRef(_ typeRef: TypeNameRef, in scope: CodeBlockItemListSyntax, moduleName: Identifier?) -> Result<ResolvedTypeName, ResolutionFailure> {
    // Get base type
    func getBaseTypeRef(typeRef: TypeNameRef) -> TypeNameRef {
      switch typeRef {
      case .member(let base?, _, _):
        base
      default:
        typeRef
      }
    }
    // let baseType: (moduleName: Identifier?, typeName: Identifier) = switch getBaseTypeRef(typeRef: typeRef) {
    //   case .member(_, let moduleName, let typeName): (moduleName, typeName)
    // }
    let baseType = getBaseTypeRef(typeRef: typeRef)

    func isInternal(moduleName queryName: Identifier?) -> Bool {
      moduleName == queryName
    }

    switch typeRef {
    case .member(base: nil, let moduleName, let typeName):
      guard isInternal(moduleName: moduleName) else {
        fatalError("[SwiftLexicalLookup] Module lookup not yet implemented")
      }

      guard let scope = scopeMap[scope] else {
        return .failure(.invalidScope)
      }
      guard let
    case .member(let base?, let moduleName, let typeName):
    }


    // Find base type in scope
    // FIXME: Here we assume this is a top-level type ref
    guard let baseTypeSource = scopeMap[scope]?.typeToRef[baseType] else {
      return .failure(.typeNotFound(baseType))
    }
    guard let mainDecl = baseTypeSource.mainDecls.first else {
      fatalError("[SwiftLexicalLookup] Internal Error: Type map should have at least one main declaration.")
    }

  }
}

// MARK: IdType -> SourceType

extension SymbolTable {
  enum TypeIDResult {
    // Look inside members of the given DeclGroupSyntax
    // E.g.
    //   struct A {
    //     struct B {
    //       func f() -> A {} // Look up `A`
    //     }
    //   }
    //   extension A.B {
    //     struct A {}
    //   }
    // In this case, `A` resolves to `A.B.A`. If we removed the extension, it would
    // instead refer to `A`. Hence, we need to look inside `A.B` first, and then
    // consider `A` if we get no results.
    case lookInside(DeclGroupSyntaxType)

    // E.g. the return type `A` in `struct A { struct B { func f() -> A { ... } } }` refers
    // to the decl `struct A`.
    case mainTypeDecl(ValueDeclSyntax)
    // A top-level reference to a type generated by an extension.
    //
    // E.g. `Self` in `extension Int { func f() -> Self { ... } }`
    // references `Int`.
    //
    // Top-level reference means the type is `Int` relative to the file scope.
    case fileScopeReference(TypeNameRef)
    case genericParameter
    // Always emitted at the end
    // case lookInModule
    // case lookInImportedModule

    func resolve() {
      // For main decl, get typeref
      // For lookInside with nominal, get nominal's typeref
      // For lookInside with extension, resolve extended-type ref, look up name in typeref
      // For fileScopeReference, resolve typeref
      // For generic param, give up
    }
  }

  func findTypeID(
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
        declGroup.
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
