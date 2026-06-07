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

@_spi(RawSyntax) import SwiftSyntax

/// A value declaration is a declaration that evaluates to a value and
/// which typically has a type and a name.
///
/// Value declarations are:
/// 1. Type declarations, meaning: nominal types (structs, enums, classes, actors),
///                                protocols, type aliases, associated types,
/// TODO: What about generic parameter types? `https://download.swift.org/docs/assets/generics.pdf`
///                                generic parameter declarations
/// 2. Abstract function declarations (functions, initializers, deinitializers)
/// 3. Abstract storage declarations (variable identifier patterns and subscripts)
/// 4. Macro declarations
/// 5. Enum element declarations
///
/// Most value declarations are actual declarations. However,
/// there are two exceptions: enum case elements (``EnumCaseElementSyntax``)
/// and identifier patterns (``IdentifierPatternSyntax``). These are value
/// declarations because they have names and can evaluate to values, however
/// they're not actual declarations conforming to `DeclSyntaxProtocol` and
/// they lack things like modifiers and attributes.
/// While simple variable declarations like `let a: Int` contain a single
/// identifier pattern `a`, it's possible to write `let a, b: Int`. Similarly,
/// enum cases look like `case myCaseA, myCaseB`. As a result, ``ValueDeclSyntax``
/// doesn't conform to ``DeclSyntaxProtocol``.
///
/// Hence, for queries to work correctly, the scope ``SyntaxProtocol/scope``
/// for ``IdentifierPatternSyntax`` must be ``VariableDeclSyntax`` and the
/// scope for ``EnumCaseElementSyntax`` must be ``EnumCaseDeclSyntax``.
/// Otherwise, queries like ``ValueDeclSyntax/isStatic`` return nil.
///
/// Basically, anything that named lookup can return.
public struct ValueDeclSyntax: SyntaxProtocol, SyntaxHashable {
  public let _syntaxNode: Syntax

  /// Try to cast a specific ``SyntaxProtocol``-conforming type to
  /// a ``ValueDeclSyntax``.
  public init?(_ node: __shared some SyntaxProtocol) {
    switch node.raw.kind {
    // Types (nominal, protocols, aliases, associated types, generic types)
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl,
      .typeAliasDecl, .associatedTypeDecl,
      // Functions (funcs, inits, deinits)
      .functionDecl, .initializerDecl, .deinitializerDecl,
      // Storage (vars, subscripts)
      .identifierPattern, .subscriptDecl,
      // Macro & Enum element
      .macroDecl, .enumCaseElement:
      _syntaxNode = node._syntaxNode
    default:
      return nil
    }
  }

  public static var structure: SyntaxNodeStructure {
    return .choices([
      // Types
      .node(StructDeclSyntax.self),
      .node(EnumDeclSyntax.self),
      .node(ClassDeclSyntax.self),
      .node(ActorDeclSyntax.self),
      .node(ProtocolDeclSyntax.self),
      .node(TypeAliasDeclSyntax.self),
      .node(AssociatedTypeDeclSyntax.self),
      // Functions
      .node(FunctionDeclSyntax.self),
      .node(InitializerDeclSyntax.self),
      .node(DeinitializerDeclSyntax.self),
      // Storage
      .node(IdentifierPatternSyntax.self),
      .node(SubscriptDeclSyntax.self),
      // Macro
      .node(MacroDeclSyntax.self),
      // Enum element
      .node(EnumCaseElementSyntax.self),
    ])
  }
}

// MARK: Declalaration Name

extension Identifier {
  init?(validating token: TokenSyntax) {
    guard let identifier = token.identifier, !token.hasError else {
      return nil
    }
    self = identifier
  }
}

extension ValueDeclSyntax {
  /// Helper that converts a function parameter clause to declaration-name arguments
  func _paramsToArgs(_ parameterClause: FunctionParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``FunctionParameterSyntax/firstName`` is either an identifier
    // or "_". If it's "_", then `firstName.identifier` is `nil`.
    parameterClause.parameters.map({ Identifier(validating: $0.firstName) })
  }
  /// Helper that converts a subscript parameter clause to declaration-name arguments
  ///
  /// This is because subscripts don't have argument labels by default.
  func _subscriptParamsToArgs(_ parameterClause: FunctionParameterClauseSyntax) -> DeclNameArgs {
    // According to the docs, ``FunctionParameterSyntax/firstName`` is either an identifier
    // or "_". If it's "_", then `firstName.identifier` is `nil`.
    parameterClause.parameters.map({
      // Subscripts need both names to get an argument label.
      guard $0.secondName != nil else { return nil }
      return Identifier(validating: $0.firstName)
    })
  }
  /// Helper that converts an enum case element's parameter clause to declaration-name arguments
  ///
  /// Note that since enum elements with parentheses but no associated values aren't allowed,
  /// e.g., `myCase()`, we treat them identifiers without arguments, i.e., `myCase`.
  func _enumParamsToArgs(_ parameterClause: EnumCaseParameterClauseSyntax) -> DeclNameArgs? {
    // According to the docs, ``EnumCaseParameterClauseSyntax/firstName`` is either an identifier,
    // "_" or nil. So if it's not convertible to an identifier, it must be `nil`.
    let args = parameterClause.parameters.map({ $0.firstName.flatMap(Identifier.init(validating:)) })
    // No associated values => no arguments (because `myCase()` is illegal)
    return args.isEmpty ? nil : args
  }

  /// Returns true if the given macro is freestanding; false if attached.
  func _macroType(_ macroDecl: MacroDeclSyntax) -> DeclName.MacroType {
    // TODO: Implement in a way that handles if configs

    // return macroDecl.attributes.reduce(
    //   DeclName.MacroType(isFreestanding: false, isAttached: false),
    //   { (macroType: DeclName.MacroType, attribute: AttributeListSyntax.Element) -> DeclName.MacroType in
    //     return DeclName.MacroType(
    //       isFreestanding: macroType.isFreestanding
    //         || attribute.attributeName.as(IdentifierTypeSyntax.self)?.name == .identifier("freestanding"),
    //       isAttached: macroType.isAttached
    //         || attribute.attributeName.as(IdentifierTypeSyntax.self)?.name == .identifier("attached")
    //     )
    //   }
    // )
    print("[SwiftLexicalLookup] Warning: Macro type determination hasn't been implemented yet.")
    return DeclName.MacroType(isFreestanding: false, isAttached: false)
  }

  /// The canonical name of the declaration, including argument names where applicable.
  ///
  /// For instance, `func f(x: Int, y: Int)` has a canonical name of ''f(x:y:)''.
  var declName: DeclName {
    switch _syntaxNode.as(SyntaxEnum.self) {
    // Types and pattern identifiers have no args
    case .structDecl(let structDecl):
      return DeclName.fromToken(structDecl.name, args: nil)
    case .enumDecl(let enumDecl):
      return DeclName.fromToken(enumDecl.name, args: nil)
    case .classDecl(let classDecl):
      return DeclName.fromToken(classDecl.name, args: nil)
    case .actorDecl(let actorDecl):
      return DeclName.fromToken(actorDecl.name, args: nil)
    case .protocolDecl(let protocolDecl):
      return DeclName.fromToken(protocolDecl.name, args: nil)
    case .typeAliasDecl(let typeAliasDecl):
      return DeclName.fromToken(typeAliasDecl.name, args: nil)
    case .associatedTypeDecl(let associatedTypeDecl):
      return DeclName.fromToken(associatedTypeDecl.name, args: nil)
    case .identifierPattern(let identifierPattern):
      return DeclName.fromToken(identifierPattern.identifier, args: nil)
    // Functions
    case .functionDecl(let funcDecl):
      guard let identifier = Identifier(validating: funcDecl.name) else {
        return DeclName.invalid(
          nonIdentifier: funcDecl.name.tokenKind,
          args: _paramsToArgs(funcDecl.signature.parameterClause)
        )
      }
      // Check for callAsFunction (instance method named `callAsFunction`).
      if identifier.name == "callAsFunction", self.isStatic == .success(false) {
        return DeclName.callAsFunction(args: _paramsToArgs(funcDecl.signature.parameterClause))
      }
      return DeclName.identifier(identifier: identifier, args: _paramsToArgs(funcDecl.signature.parameterClause))
    case .initializerDecl(let initDecl):
      return DeclName.`init`(args: _paramsToArgs(initDecl.signature.parameterClause))
    case .deinitializerDecl:
      // deinits don't have a name
      return DeclName.deinit

    // Subscripts
    case .subscriptDecl(let subscriptDecl):
      return DeclName.subscript(args: _subscriptParamsToArgs(subscriptDecl.parameterClause))
    // Macro
    case .macroDecl(let macroDecl):
      return DeclName.fromToken(
        macroDecl.name,
        macro: _macroType(macroDecl),
        args: _paramsToArgs(macroDecl.signature.parameterClause)
      )
    // Enum element
    case .enumCaseElement(let enumElement):
      return DeclName.fromToken(
        enumElement.name,
        args: enumElement.parameterClause.flatMap(_enumParamsToArgs(_:))
      )
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }
}

// MARK: Basic Queries

extension ValueDeclSyntax {
  /// Get the variable declaration parent of this identifier pattern
  /// value-declaration. Returns `nil` if the scope is invalid.
  private func _findVariableDeclSyntax(
    _ identifierPattern: IdentifierPatternSyntax
  ) -> VariableDeclSyntax? {
    // The hierarchy goes as follows
    //   VariableDecl -> PatternBindingList -> PatternBinding -> Pattern
    guard
      let binding = identifierPattern.parent?.as(PatternBindingSyntax.self),
      let bindingList = binding.parent?.as(PatternBindingListSyntax.self),
      let varDecl = bindingList.parent?.as(VariableDeclSyntax.self)
    else {
      return nil
    }
    return varDecl
  }
  /// Get the enum case declaration parent of this enum element
  /// value-declaration. Returns `nil` if the scope is invalid.
  private func _findEnumCaseDeclSyntax(
    _ enumElement: EnumCaseElementSyntax
  ) -> EnumCaseDeclSyntax? {
    // The hierarchy goes as follows
    //   EnumCaseDecl -> EnumCaseElementList -> EnumCaseElement
    guard
      let elementList = enumElement.parent?.as(EnumCaseElementListSyntax.self),
      let caseDecl = elementList.parent?.as(EnumCaseDeclSyntax.self)
    else {
      return nil
    }
    return caseDecl
  }

  /// The modifiers attached to this value declaration (or the respective parent).
  ///
  /// Since identifier patterns and enum elements aren't themselves declarations
  /// and don't have modifiers, we return `nil` if we can't find their parents.
  var modifiers: DeclModifierListSyntax? {
    switch _syntaxNode.as(SyntaxEnum.self) {
    // Types
    case .structDecl(let structDecl):
      return structDecl.modifiers
    case .enumDecl(let enumDecl):
      return enumDecl.modifiers
    case .classDecl(let classDecl):
      return classDecl.modifiers
    case .actorDecl(let actorDecl):
      return actorDecl.modifiers
    case .protocolDecl(let protocolDecl):
      return protocolDecl.modifiers
    case .typeAliasDecl(let typeAliasDecl):
      return typeAliasDecl.modifiers
    case .associatedTypeDecl(let associatedTypeDecl):
      return associatedTypeDecl.modifiers
    // Functions
    case .functionDecl(let funcDecl):
      return funcDecl.modifiers
    case .initializerDecl(let initDecl):
      return initDecl.modifiers
    case .deinitializerDecl(let deinitDecl):
      return deinitDecl.modifiers
    // Storage
    case .identifierPattern(let identifierPattern):
      return _findVariableDeclSyntax(identifierPattern)?.modifiers
    case .subscriptDecl(let subscriptDecl):
      return subscriptDecl.modifiers
    // Macro
    case .macroDecl(let macroDecl):
      return macroDecl.modifiers
    // Enum element
    case .enumCaseElement(let enumElement):
      return _findEnumCaseDeclSyntax(enumElement)?.modifiers
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  var attributes: AttributeListSyntax? {
    switch _syntaxNode.as(SyntaxEnum.self) {
    // Types
    case .structDecl(let structDecl):
      return structDecl.attributes
    case .enumDecl(let enumDecl):
      return enumDecl.attributes
    case .classDecl(let classDecl):
      return classDecl.attributes
    case .actorDecl(let actorDecl):
      return actorDecl.attributes
    case .protocolDecl(let protocolDecl):
      return protocolDecl.attributes
    case .typeAliasDecl(let typeAliasDecl):
      return typeAliasDecl.attributes
    case .associatedTypeDecl(let associatedTypeDecl):
      return associatedTypeDecl.attributes
    // Functions
    case .functionDecl(let funcDecl):
      return funcDecl.attributes
    case .initializerDecl(let initDecl):
      return initDecl.attributes
    case .deinitializerDecl(let deinitDecl):
      return deinitDecl.attributes
    // Storage
    case .identifierPattern(let identifierPattern):
      return _findVariableDeclSyntax(identifierPattern)?.attributes
    case .subscriptDecl(let subscriptDecl):
      return subscriptDecl.attributes
    // Macro
    case .macroDecl(let macroDecl):
      return macroDecl.attributes
    // Enum element
    case .enumCaseElement(let enumElement):
      return _findEnumCaseDeclSyntax(enumElement)?.attributes
    default:
      fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
    }
  }

  enum StaticLookupFailure: Equatable, Error {
    /// Static only makes sense in a nominal type.
    ///
    /// That is, we check that the value declaration appears inside a decl
    /// group (nominal type including protocols, or extension thereof).
    case unsupportedAtTopLevel
    /// Macros may only appear at file scope; it's not clear what "static" means
    case macrosOnlyAtFileScope
    /// The value declaration has an invalid scope: this is either
    /// an enum element without an enum case parent, or an identifier
    /// pattern without a variable declaration parent.
    case scopeFailure
  }

  /// Whether the given list of modifiers include the `static` and/or `class` keywords.
  func _modifiersIncludeStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains(where: { modifier in
      modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
    })
  }

  /// Whether the given declaration is available from a static/type context.
  ///
  /// Notes:
  /// 1. This query considers parent context, e.g., querying ``isStatic`` on a
  ///    top-level declaration fails with ``StaticLookupFailure.unsupportedAtTopLevel``.
  ///    However, it's flexible and will accept `class func` as static even in
  ///    a struct (assuming the user meant `static`).
  /// 2. Macro declarations will return a `macrosOnlyAtFileScope` failure.
  /// 3. Pattern identifiers that aren't inside a ``VariableDeclSyntax``
  ///    scope, or enum elements that aren't in ``EnumCaseDeclSyntax``
  ///    return a ``.scopeFailure``.
  var isStatic: Result<Bool, StaticLookupFailure> {
    /// Check that this value declaration is in a declaration group.
    func checkParentIsDeclGroup(_ parent: Syntax?) throws(StaticLookupFailure) {
      // The hierarchy is as follows:
      //    DeclGroup->MemberBlock->MemberBlockItemList->MemberBlockItem-><value decl>
      // So traverse bottom-up
      guard
        let item = parent?.as(MemberBlockItemSyntax.self),
        let list = item.parent?.as(MemberBlockItemListSyntax.self),
        let block = list.parent?.as(MemberBlockSyntax.self),
        // Check we get a decl group
        block.parent?.is(DeclGroupSyntaxType.self) == true
      else {
        throw StaticLookupFailure.unsupportedAtTopLevel
      }
    }

    return Result(catching: { () throws(StaticLookupFailure) -> Bool in
      switch _syntaxNode.as(SyntaxEnum.self) {
      // Types are always static
      case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl,
        // Inits are static, e.g., MyStruct.init(...)
        .initializerDecl:
        try checkParentIsDeclGroup(self.parent)
        return true
      // Enum cases elements are static, e.g., MyEnum.myCase
      case .enumCaseElement(let enumElement):
        // Find the enum case declaration parent.
        guard let enumCaseDecl = _findEnumCaseDeclSyntax(enumElement) else {
          throw StaticLookupFailure.scopeFailure
        }
        // Check the var declaration's parent is a group declaration
        //
        // We don't care if the parent is specifically an enum to tolerate user
        // error. For instance, the user might have converted an enum to a
        // struct and have a leftover case declaration; we just interpret that
        // as a static method and diagnose elsewhere.
        try checkParentIsDeclGroup(enumCaseDecl.parent)
        return true

      // Deinits operate on instances, so not static.
      case .deinitializerDecl:
        try checkParentIsDeclGroup(self.parent)
        return false

      // Functions, variables and subscripts can be static or non-static
      //
      // This depends on whether they have the 'static'/'class' modifiers
      case .functionDecl(let funcDecl):
        try checkParentIsDeclGroup(self.parent)
        return _modifiersIncludeStatic(funcDecl.modifiers)
      case .subscriptDecl(let subscriptDecl):
        try checkParentIsDeclGroup(self.parent)
        return _modifiersIncludeStatic(subscriptDecl.modifiers)
      case .identifierPattern(let identifierPattern):
        // We need to find the parent variable declaration
        guard let varDecl = _findVariableDeclSyntax(identifierPattern) else {
          throw StaticLookupFailure.scopeFailure
        }
        // Check the var declaration's parent is a group declaration
        try checkParentIsDeclGroup(varDecl.parent)
        return _modifiersIncludeStatic(varDecl.modifiers)
      // Macro
      case .macroDecl:
        throw StaticLookupFailure.macrosOnlyAtFileScope
      default:
        fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
      }
    })
  }

  /// Whether the declaration is a type declaration, meaning it introduces a
  /// new type (or alias thereof).
  var isTypeDecl: Bool {
    switch _syntaxNode.kind {
    case .structDecl, .enumDecl, .classDecl, .actorDecl, .protocolDecl, .typeAliasDecl, .associatedTypeDecl:
      return true
    default:
      return false
    }
  }

  /// Whether this value declaration must always appear at file scope; useful
  /// for filtering declarations during lookup.
  ///
  /// Currently, this includes just macro declarations. Other declarations
  /// of note:
  /// 1. Protocols: Can be nested under nominal type declarations (but not
  ///    other protocols) following SE 404.
  ///
  ///    Note that although a protocol nested under another protocol is still
  ///    illegal, tooling may want to still surface a nested protocol to
  ///    improve developer experience. Consider:
  ///      protocol MyProto { protocol Element {} }
  ///    We can trivially rewrite this illegal program to:
  ///      protocol MyProtoElement {}
  ///      protocol MyProto { typealias Element = MyProtoElement }
  ///
  /// 2. Enum case elements: Only legal inside cases living in enums.
  ///
  ///    Similar to case 1, the user might have accidentally typed `struct { case caseA }`
  ///    instead of using an `enum`, so lookup should be nice to the user.
  ///
  /// 3. Associated types: Only legal inside protocols.
  ///
  ///    Following a similar argument, a user using an associated type inside
  ///    a nominal type might have wanted to use a generic argument. We'll
  ///    still make a best-effort attempt to look it up.
  var isAlwaysGlobal: Bool {
    return switch _syntaxNode.kind {
    case .macroDecl: true
    default: false
    }
  }
}

// MARK: Type Queries

/// A declaration scope is basically any ``CodeBlockItemListSyntax``, whose
/// child declarations can only be referenced within said scope's block
/// items (with the exception of ``SourceFileSyntax``). Usually accessed
/// through ``ValueDeclSyntax/declScope``.
///
/// The most common declaration scope is the code block of the source file
/// itself:
///   // File.swift
///   struct MyStruct {}
/// Here, `MyStruct` is accessible within the entire file and --because
/// source files are special-- within the rest of the module.
///
/// Here's a more elaborate example:
///   // File.swift
///   struct A {
///     struct B {}
///     func myFunc() { struct C {} }
///   }
/// In this example there are two declarations scope: (1) the source file
/// itself (like in any valid syntax tree) and (2) the body of `myFunc`.
/// Because structs `A` and `B` are in the same scope, which happens to be
/// a file scope, they're accessible in the entire module as `A` and `A.B`.
/// However, they're no way to refer to `C` outside of the body of `myFunc`.
@_spi(_QualifiedLookup) public struct DeclScope {
  /// The code items, some of which are (scoped) declarations.
  public let codeItems: CodeBlockItemListSyntax
  /// Whether this declaration scope is file scope. `nil` if unknown.
  public let isFileScope: Bool?
}

extension SyntaxProtocol {
  /// Try to convert this syntax to a declaration scope consisting of the
  /// underlying codeblock list item list and a flag for whether this is file scope.
  ///
  /// If this declaration isn't a declaration scope, we return `nil`. If it
  /// is a declaration scope (code block item list syntax) without a parent,
  /// we set `isFileScope` to `nil`. We only get `isFileScope == true`
  /// when the scope is the direct child of ``SourceFileSyntax``.
  fileprivate var _asDeclScope: DeclScope? {
    // Check we a code block with a parent.
    guard let codeItems = self.as(CodeBlockItemListSyntax.self) else { return nil }

    // There's one ``SourceFileSyntax`` per syntax tree with exactly one
    // ``CodeBlockItemListSyntax`` child.
    //
    // If the code block doesn't have a parent, the syntax tree is likely
    // invalid so we set `isSourceFile` to nil.
    let isFileScope = codeItems.parent?.is(SourceFileSyntax.self)

    return DeclScope(codeItems: codeItems, isFileScope: isFileScope)
  }

  /// Finds the declaration scope of the current value declaration by looking
  /// through its recursive parents.
  @_spi(_QualifiedLookup) public var declScope: DeclScope? {
    // No parent means no scope.
    //
    // In this case, if `self` isn't a `SourceFileSyntax`, the syntax tree
    // is likely invalid
    guard let parent else { return nil }

    // See if parent is a declaration context; otherwise, get its context.
    return parent._asDeclScope ?? parent.declScope
  }
}

indirect enum UnresolvedTypeRef: Equatable {
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

  enum Failure: Error {
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
  static func fromTypeSyntax(_ typeSyntax: TypeSyntax) -> Result<UnresolvedTypeRef, Failure> {
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
//       fatalError("[Internal Error] Invalid syntax kind for ValueDeclSyntax: \(_syntaxNode.raw.kind)")
//     }
//
//   }
// }

// MARK: Upcasting

// Conrete types
extension ValueDeclSyntax {
  // Types
  public init(_ syntax: StructDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: EnumDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ClassDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ActorDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: ProtocolDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: TypeAliasDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: AssociatedTypeDeclSyntax) {
    self.init(syntax)!
  }

  // Function decls
  public init(_ syntax: FunctionDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: InitializerDeclSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: DeinitializerDeclSyntax) {
    self.init(syntax)!
  }

  // Storage decls
  public init(_ syntax: IdentifierPatternSyntax) {
    self.init(syntax)!
  }
  public init(_ syntax: SubscriptDeclSyntax) {
    self.init(syntax)!
  }

  // Macro decl
  public init(_ syntax: MacroDeclSyntax) {
    self.init(syntax)!
  }

  // Enum case elements
  public init(_ syntax: EnumCaseElementSyntax) {
    self.init(syntax)!
  }
}

// Protocols
extension ValueDeclSyntax {
  init(fromProtocol syntax: borrowing some NominalTypeDeclSyntax) {
    // We know this cast is going to succeed. Go through `init(_: SyntaxData)` just to double-check and
    // verify the kind matches in debug builds and get maximum performance in release builds.
    self = Syntax(syntax).cast(ValueDeclSyntax.self)
  }
}

// MARK: `as` Casts

extension ValueDeclSyntax {
  public func `as`(_ syntaxType: StructDeclSyntax.Type) -> StructDeclSyntax? {
    return StructDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: EnumDeclSyntax.Type) -> EnumDeclSyntax? {
    return EnumDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ClassDeclSyntax.Type) -> ClassDeclSyntax? {
    return ClassDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ActorDeclSyntax.Type) -> ActorDeclSyntax? {
    return ActorDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: ProtocolDeclSyntax.Type) -> ProtocolDeclSyntax? {
    return ProtocolDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: TypeAliasDeclSyntax.Type) -> TypeAliasDeclSyntax? {
    return TypeAliasDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: AssociatedTypeDeclSyntax.Type) -> AssociatedTypeDeclSyntax? {
    return AssociatedTypeDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: FunctionDeclSyntax.Type) -> FunctionDeclSyntax? {
    return FunctionDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: InitializerDeclSyntax.Type) -> InitializerDeclSyntax? {
    return InitializerDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: DeinitializerDeclSyntax.Type) -> DeinitializerDeclSyntax? {
    return DeinitializerDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: IdentifierPatternSyntax.Type) -> IdentifierPatternSyntax? {
    return IdentifierPatternSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: SubscriptDeclSyntax.Type) -> SubscriptDeclSyntax? {
    return SubscriptDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: MacroDeclSyntax.Type) -> MacroDeclSyntax? {
    return MacroDeclSyntax(_syntaxNode)
  }
  public func `as`(_ syntaxType: EnumCaseElementSyntax.Type) -> EnumCaseElementSyntax? {
    return EnumCaseElementSyntax(_syntaxNode)
  }

  @available(*, deprecated, message: "This cast will always fail")
  public func `as`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> S? {
    return nil
  }
}

// MARK: DeclSyntaxProtocol Conversions

extension DeclSyntaxProtocol {
  public func `as`(_ syntaxType: ValueDeclSyntax.Type) -> ValueDeclSyntax? {
    Syntax(self).as(ValueDeclSyntax.self)
  }

  public func `is`(_ syntaxType: ValueDeclSyntax.Type) -> Bool {
    self.as(syntaxType) != nil
  }
}

// MARK: `is` Checks

extension ValueDeclSyntax {
  public func `is`(_ syntaxType: StructDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: EnumDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ClassDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ActorDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: ProtocolDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: TypeAliasDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: AssociatedTypeDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: FunctionDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: InitializerDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: DeinitializerDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: IdentifierPatternSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: SubscriptDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: MacroDeclSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }
  public func `is`(_ syntaxType: EnumCaseElementSyntax.Type) -> Bool {
    return self.as(syntaxType) != nil
  }

  @available(*, deprecated, message: "This check will always fail")
  public func `is`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> Bool {
    return false
  }
}
