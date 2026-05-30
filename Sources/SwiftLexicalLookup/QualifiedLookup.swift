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

import SwiftIfConfig
import SwiftSyntax

public struct QualifiedLookupConfig {
  public var configuredRegions: ConfiguredRegions? = nil

  public init(configuredRegions: ConfiguredRegions? = nil) {
    self.configuredRegions = configuredRegions
  }
}
public struct QualifiedTableLookupConfig {
  public var lookupSuperprotocols: Bool
  public var lookupSuperclasses: Bool
  public var configuredRegions: ConfiguredRegions?

  /// Parameters:
  /// - lookupSuperprotocols: Whether to recursively look up
  ///       inherited or conformed-to protocols.
  /// - lookupSuperclasses: Whether to recursively look up
  ///       superclasses, and the protocols they conform to (if
  ///       `lookupSuperprotocols` is true).
  public init(
    lookupSuperprotocols: Bool = false,
    lookupSuperclasses: Bool = false,
    configuredRegions: ConfiguredRegions? = nil
  ) {
    self.lookupSuperprotocols = lookupSuperprotocols
    self.lookupSuperclasses = lookupSuperclasses
    self.configuredRegions = configuredRegions
  }
}

public struct DeclGroupSyntaxType: DeclGroupSyntax {
  // TODO: Consider using an enum representing a union of NominalTypeDeclSyntax
  // ProtocolDeclSyntax and ExtensionDeclSyntax.
  //
  //  private enum _Storage {
  //   case typeDecl(any NominalTypeDeclSyntax)
  //   case protocolDecl(ProtocolDeclSyntax)
  //   case extensionDecl(ExtensionDeclSyntax)
  // }
  //
  // private let box: _Storage
  //
  // public init?(_ node: borrowing some SyntaxProtocol) {
  //   if let castNode = node.asProtocol((any NominalTypeDeclSyntax).self) {
  //     box = .typeDecl(castNode)
  //   } else if let castNode = node.as(ProtocolDeclSyntax.self) {
  //     box = .protocolDecl(castNode)
  //   } else if let castNode = node.as(ExtensionDeclSyntax.self) {
  //     box = .extensionDecl(castNode)
  //   } else {
  //     return nil
  //   }
  // }
  private var box: any DeclGroupSyntax

  public init?(_ node: borrowing some SyntaxProtocol) {
    if let castNode = node.asProtocol((any NominalTypeDeclSyntax).self) {
      box = castNode
    } else if let castNode = node.as(ProtocolDeclSyntax.self) {
      box = castNode
    } else if let castNode = node.as(ExtensionDeclSyntax.self) {
      box = castNode
    } else {
      return nil
    }
  }

  fileprivate init(exactly node: some DeclGroupSyntax) {
    box = node
  }
  // public var identifier: Identifier? {
  //   if let castNode = box.as(StructDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(EnumDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ClassDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ActorDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else if let castNode = box.as(ProtocolDeclSyntax.self) {
  //     castNode.name.identifier
  //   } else { /* extensions have types not identifiers */
  //     nil
  //   }
  // }

  // TODO: Implement canonical type
  public var type: TypeSyntax? {
    if let castNode = box.as(StructDeclSyntax.self) {
      TypeSyntax(castNode.name)
    } else if let castNode = box.as(EnumDeclSyntax.self) {
      TypeSyntax(castNode.name)
    } else if let castNode = box.as(ClassDeclSyntax.self) {
      TypeSyntax(castNode.name)
    } else if let castNode = box.as(ActorDeclSyntax.self) {
      TypeSyntax(castNode.name)
    } else if let castNode = box.as(ProtocolDeclSyntax.self) {
      TypeSyntax(castNode.name)
    } else if let castNode = box.as(ExtensionDeclSyntax.self) {
      castNode.extendedType
    } else {
      nil
    }
  }

  public var attributes: SwiftSyntax.AttributeListSyntax {
    get { box.attributes }
    set { box.attributes = newValue }
  }

  public var modifiers: SwiftSyntax.DeclModifierListSyntax {
    get { box.modifiers }
    set { box.modifiers = newValue }
  }

  public var introducer: SwiftSyntax.TokenSyntax {
    get { box.introducer }
    set { box.introducer = newValue }
  }

  public var inheritanceClause: SwiftSyntax.InheritanceClauseSyntax? {
    get { box.inheritanceClause }
    set { box.inheritanceClause = newValue }
  }

  public var genericWhereClause: SwiftSyntax.GenericWhereClauseSyntax? {
    get { box.genericWhereClause }
    set { box.genericWhereClause = newValue }
  }

  public var memberBlock: SwiftSyntax.MemberBlockSyntax {
    get { box.memberBlock }
    set { box.memberBlock = newValue }
  }

  public var _syntaxNode: SwiftSyntax.Syntax {
    box._syntaxNode
  }

  public static let structure: SwiftSyntax.SyntaxNodeStructure = .choices([
    .node(StructDeclSyntax.self), .node(EnumDeclSyntax.self), .node(ClassDeclSyntax.self),
    .node(ActorDeclSyntax.self), .node(ProtocolDeclSyntax.self), .node(ExtensionDeclSyntax.self),
  ])
}

/// Contains the results of a qualified lookup request
public enum QualifiedLookupResult {
  /// Explicitly declared members.
  ///
  /// Includes static/class/instance stored and computed properties,
  /// functions, subscripts and initializers, dynamic-member-lookup
  /// results, along with nested types, type aliases and associated
  /// types. E.g.
  /// ```
  /// struct MyStruct<T> {
  ///   func callAsFunction() {}
  /// }
  /// ```
  /// Qualified lookup within the `MyStruct` scope would
  /// return the `callAsFunction()` function declaration.
  /// Note that qualified lookup won't surface
  /// operator functions, objc functions using dynamic lookup, and
  /// generic parameters like `MyStruct.T` (semantically wrong).
  case members([DeclSyntax], introducedIn: DeclSyntax)
  /// Members declared in conditional extensions, e.g.
  /// ```
  /// extension Array where Element == Int {
  ///   func sum() -> Int { reduce(0, +) }
  /// }
  /// ```
  /// Qualified lookup will return the `sum()` declaration in
  /// the extension above together with the `where Element == Int`
  /// clause.
  case conditionalMembers(
    [DeclSyntax],
    introducedIn: DeclSyntax,
    inheritanceClause: InheritanceClauseSyntax?,
    genericClause: GenericWhereClauseSyntax?
  )
  /// Implicit members in the given group declaration like `self`,
  /// `Type` and synthesized initializers.
  case implicitMembers([DeclSyntax], introducedIn: DeclGroupSyntaxType)
  /// Types and protocols annotated with `@dynamicMemberLookup` have
  /// one or more subscripts with a `dynamicMember` string or keypath
  /// argument. We defer to the type-checker to determine what members
  /// these subscripts can produce.
  case lookForDynamicMembers(
    dynamicMemberSubscripts: [SubscriptDeclSyntax],
    introducedIn: DeclGroupSyntaxType
  )
  /// Any unknown attributes that could be attached macros or property
  /// wrappers that expand to more declarations, e.g.
  /// ```swift
  /// struct MyView {
  ///   @State var myState = 0
  /// }
  /// ```
  /// In this case, we instruct the tooling to look up what the
  /// `@State` attribute expands to in the variable declaration above
  /// (if anything).
  case lookForMacros(
    potentialMacroDecl: [DeclSyntax],
    introducedIn: DeclGroupSyntaxType
  )
  /// Look for any "supertypes" we encountered in the lookup and which
  /// we didn't retrieve from the symbol table (if we performed `SymbolTable`
  /// lookup with the `lookupSuperprotocols` or `lookupSuperclasses`
  /// options).
  case lookForSupertypes(
    inheritedFrom: InheritanceClauseSyntax,
    genericClause: GenericWhereClauseSyntax?
  )
}

public class SymbolTable {
  let fileSyntax: SourceFileSyntax
  lazy var globalTypes:
    (
      types: [Identifier: [DeclGroupSyntaxType]],
      extensions: [TypeSyntax: [ExtensionDeclSyntax]],
      aliases: [Identifier: [TypeAliasDeclSyntax]]
    ) = SymbolTable._getTypes(of: fileSyntax)
  /// Construct a table for caching symbol lookup
  /// for the given file syntax.
  public init(fileSyntax: SourceFileSyntax) {
    self.fileSyntax = fileSyntax
  }

  static func _addCodeBlock(
    decl: DeclSyntax,
    types: inout [Identifier: [DeclGroupSyntaxType]],
    extensions: inout [TypeSyntax: [ExtensionDeclSyntax]],
    aliases: inout [Identifier: [TypeAliasDeclSyntax]]
  ) {
    // Look for declaration groups:
    //   1. nominal types (structs, enums, classes, actors)
    if let nominalType = decl.asProtocol((any NominalTypeDeclSyntax).self),
      let typeName = nominalType.name.identifier
    {
      types[typeName, default: []].append(DeclGroupSyntaxType(exactly: nominalType))
      //   2. protocols (same as nominal types)
    } else if let protocolDecl = decl.as(ProtocolDeclSyntax.self),
      let typeName = protocolDecl.name.identifier
    {
      types[typeName, default: []].append(DeclGroupSyntaxType(exactly: protocolDecl))
      //   3. extensions (different because extensions can have a member type, e.g. `extension A.B {}`)
    } else if let extensionDecl = decl.as(ExtensionDeclSyntax.self) {
      // Check the extended type isn't `Any` or `Self`; these are caught in Semantic Analysis
      // but we don't want name lookup to get confused
      // TODO: Check if this actually happens
      // Make sure
      guard extensionDecl.extendedType.description != "Any",
        extensionDecl.extendedType.description != "Self"
      else {
        return
      }

      extensions[extensionDecl.extendedType, default: []].append(extensionDecl)
      // Look for type aliases
    } else if let typeAlias = decl.as(TypeAliasDeclSyntax.self),
      let typeName = typeAlias.name.identifier
    {
      aliases[typeName, default: []].append(typeAlias)
    }
  }

  // TODO: Technically, we know this can never be a protocol/extension (we can't nest
  //       these under types)
  //
  /// Retrieve all types nested in the given declaration group (no recursion).
  static func _getNestedTypes(
    of group: DeclGroupSyntaxType
  ) -> (
    nestedTypes: [Identifier: [DeclGroupSyntaxType]],
    aliases: [Identifier: [TypeAliasDeclSyntax]]
  ) {
    var nestedTypes = [Identifier: [DeclGroupSyntaxType]]()
    var aliases = [Identifier: [TypeAliasDeclSyntax]]()
    for member in group.memberBlock.members {
      var nestedExtensions = [TypeSyntax: [ExtensionDeclSyntax]]()
      _addCodeBlock(decl: member.decl, types: &nestedTypes, extensions: &nestedExtensions, aliases: &aliases)
      // TODO Handle extensions (tho they can't actually be nested, we could do it for diagnostic purposes)
      _ = nestedExtensions
    }

    return (nestedTypes, aliases)
  }

  /// Retrieve all declaration groups in the top level of the given file syntax
  /// (no recursion).
  static func _getTypes(
    of fileSyntax: SourceFileSyntax
  ) -> (
    types: [Identifier: [DeclGroupSyntaxType]],
    extensions: [TypeSyntax: [ExtensionDeclSyntax]],
    aliases: [Identifier: [TypeAliasDeclSyntax]]
  ) {
    var types = [Identifier: [DeclGroupSyntaxType]]()
    var extensions = [TypeSyntax: [ExtensionDeclSyntax]]()
    var aliases = [Identifier: [TypeAliasDeclSyntax]]()

    for stmt in fileSyntax.statements {
      // Only declarations can introduce types
      guard case .decl(let decl) = stmt.item else { continue }
      // Process
      _addCodeBlock(decl: decl, types: &types, extensions: &extensions, aliases: &aliases)
    }
    return (types, extensions, aliases)
  }
}

extension DeclGroupSyntax {
  /// Search for members matching given identifier.
  /// Parameters:
  /// - lookUpPosition: Indicates position where we should
  ///     start lookup. Will enable future expansion that filters
  ///     by access control.
  public func lookupMember(
    _ identifier: Identifier?,
    // TODO: Consider changing this and unqualified lookup to "lookupPosition"
    // since "lookup" functions as a noun here.
    from lookUpPosition: AbsolutePosition?,
    with config: QualifiedLookupConfig = QualifiedLookupConfig()
  ) -> [QualifiedLookupResult] {
    // FIXME: Implement
    []
  }

  /// Search for members matching given identifier in the given symbol table.
  /// Parameters:
  /// - lookUpPosition: Indicates position where we should
  ///     start lookup. Will enable future expansion that filters
  ///     by access control.
  public func lookupMember(
    _ identifier: Identifier?,
    from lookUpPosition: AbsolutePosition?,
    using symbolTable: SymbolTable,
    with config: QualifiedTableLookupConfig = QualifiedTableLookupConfig()
  ) -> [QualifiedLookupResult] {
    // FIXME: Implement
    []
  }
}

extension SymbolTable {
  // FIXME: Should support all Types
  // where identifier -> base global lookup
  //       member -> recursive on first, then it's our bread&butter
  //       compositions -> look into composing protocols&/types
  //       some T -> look into T (protocol or composition thereof, or class)
  //       any T -> look into (protocol or composition thereof, or class)
  //                (don't care if it's final; will be diagnosed later)
  //       T.self -> look into static members of T (look for static members)
  //       tuple -> if arity is known, return `.0, .1, ...` (no other members because
  //                that's not allowed for non-nominal types)
  //       [unwrapped]optional, array, dictionary, inline array,
  //       class restriction -> look into said class?
  //       function -> definitionally no results
  //       pack element -> look into inheritance/where clauses of pack decl?
  //       suppressed type -> can't do anything yet (return dedicated result type)
  // TODO: Handle cycles
  public func _lookupType(type: TypeSyntax, config: QualifiedTableLookupConfig, into results: inout [LookupResult]) {
    guard let identifier
  }

  /// Look up (named) members declared inside the given group declaration.
  /// If an identifier is given, only return declaration matching that name.
  /// If a given config-region is given, filter by that.
  /// Handles if-configs
  private func _lookupDirect(
    on groupDecl: DeclGroupSyntax,
    identifier: Identifier?,
    configuredRegions: ConfiguredRegions?
  ) -> [any NamedDeclSyntax] {
    /// Process a member or a member nested inside an if-config declaration.
    func processMemberInRegion(member: MemberBlockItemSyntax, configuredRegions: ConfiguredRegions) -> [any NamedDeclSyntax] {
      // Add named-declaration members
      if let namedDecl = member.decl.asProtocol((any NamedDeclSyntax).self) {
        [namedDecl]
      // For if-configs with an active clause constisting of declarations,
      // process each declaration.
      //
      // We do this recursively to handle nested if-config declarations
      } else if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self),
                      case .decls(let decls) = configuredRegions.activeClause(for: ifConfigDecl)?.elements {
        decls.flatMap({ processMemberInRegion(member: $0, configuredRegions: configuredRegions) })
      // No name, no gain
      } else {
        []
      }
    }

    /// Process a member or a member nested inside an if-config declaration.
    func processMember(member: MemberBlockItemSyntax) -> [any NamedDeclSyntax] {
      if let namedDecl = member.decl.asProtocol((any NamedDeclSyntax).self) {
        [namedDecl]
      // Like above, but process all if-config clauses
      } else if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self) {
        ifConfigDecl.clauses.flatMap({ clause -> [NamedDeclSyntax] in
          guard case .decls(let members) = clause.elements else { return [] }
          return members.flatMap({ processMember(member: $0) })
        })
      } else {
        []
      }
    }

    // Look up each member in the group declaration
    return if let configuredRegions {
      groupDecl.memberBlock.members.flatMap({ processMemberInRegion(member: $0, configuredRegions: configuredRegions) })
    } else {
      groupDecl.memberBlock.members.flatMap(processMember(member:))
    }
  }

  private func _visitSupertypes(
    of groupDecl: DeclGroupSyntax,
    lookingFor identifier: Identifier?,
    from lookupLocation: AbsolutePosition?,
  )

  // Finds decl groups nested in identifier types
  // TODO: Attach inheritance&where clauses from extensions/typealiases
  private func _lookupGlobalType(
    type: IdentifierTypeSyntax,
    identifier: Identifier?,
    config: QualifiedTableLookupConfig,
    into results: [QualifiedLookupResult]
  ) {
    // FIXME: Handle modules and module selectors
    precondition(type.moduleSelector == nil, "[SwiftLexicalLookup] Internal error: Module selector not implemented yet.")
    // Ensure identifier is valid (can't do lookup with invalid identifier)
    guard let typeIdentifier = type.name.identifier else { return }

    // Look inside main declaration (duplicate declarations should be diagnosed in
    // later stages)
    // If there are many declarations, assume last one is valid
    // TODO: Check if compiler also gets the last decl
    if let matchingTypeDecl = globalTypes.types[typeIdentifier]?.last {
      results.append(.members(matchingTypeDecl.lookupMember(identifier, configuredRegions: config.configuredRegions), introducedIn: matchingTypeDecl))
      matchingTypeDecl.lookupSuper
      // TODO: Handle implicit-conformances/type-constraints from where clauses,
      // along with inheritance clause + config.lookUpSuper[classes/protocols]
      // E.g.
      // let supertypeQuery = matchingTypeDecl.supertypes(config: config)
      // if supertypeQuery.lookIntoWhere { results.append(.lookIntoWhereClause(matchingTypeDecl.genericWhereClause)) }
      // if supertypeQuery.lookIntoInheritance { results.append(.lookIntoInheritanceClause(matchingTypeDecl.inheritanceClause)) }
      // for supertype in supertypeQuery.supertypes {
      //   _lookupType(type: supertype, config: config, into: &results)
      // }
    }
    // Check out all extensions matching the name
    // TODO: Ensure hashing works as expected for TypeSyntax (i.e. we use canonical type)
    for extensionDecl in globalTypes.extensions[TypeSyntax(type)] ?? [] {
      results.append(.exte)
      extensionDecl.lookupMember(identifier, configuredRegions: config.configuredRegions)
    }
    // TODO: What if we have `struct A {}; typealias A = Int`? do we look up `Int` too?
    if let typealiasDecls =
    return result
  }

  func lookupNestedType(
    type: MemberTypeSyntax,
    identifier: Identifier?,
    config: QualifiedTableLookupConfig,
    into results: [QualifiedLookupResult]
  ) {

  }
}

// Helper to aid with getting the main nominal-type declaration
// on which we can actually perform qualified lookup.
extension SymbolTable {
  func lookupDeclGroups(_ type: IdentifierTypeSyntax?, config: LookupConfig) -> [DeclGroupSyntaxType] {
    // TODO: Look into using unqualified lookup for this (look at reproducer example)
    // TODO: Decide how to handle generic arguments, etc.
    // FIXME: Support modules & module selectors
    // FIXME: Use canonical types (perhaps when adding to symboltable hash using canonical names?)
    // FIXME: Handle type aliases (handle no generics first; then with generics)
    //        [how does the compiler handle type aliases?]
    //        [typealiases only matter for extensions (nominal types can't use a type alias as a name),
    //        so we could just internally know why we emitted an extension with a type alias but
    //        not modify the extension decl (let the type checker deal with that) [but maybe include some more context]]
    // let typeAlias = (1 as any Any) as! TypeAliasDeclSyntax

    precondition(
      type.moduleSelector == nil,
      "[SwiftLexicalLookup] Internal eror: Name lookup doesn't support module selectors yet."
    )
    // Get the identifier from the name.
    //
    // According to the `IdentifierTypeSyntax.name` documentation, the name will be
    // a valid identifier, `Any`, `Self` or `_`. The last three are invalid and hence
    // not useful for top-level lookup.
    // guard let typeName = type.name.identifier else { return [] }
    // // Look up the type in the given file syntax.
    // let types = fileSyntax.sequentialLookup(
    //   in: fileSyntax.statements,
    //   type.name,
    //   at: type.position,
    //   with: config
    // )

    // According to the `IdentifierTypeSyntax.name` documentation, the name will be
    // a valid identifier, `Any`, `Self` or `_`. The last three are invalid and hence
    // not useful for top-level lookup.
    guard let typeName = type.map({ $0.name.identifier }) else { return [] }

    return fileSyntax.statements.lazy

      .compactMap({ stmt in DeclGroupSyntaxType(stmt.item) })
      // Return declarations with matching types
      .filter({ declGroup in declGroup.type == TypeSyntax(type) })
  }
}
