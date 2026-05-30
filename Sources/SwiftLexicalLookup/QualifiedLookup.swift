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

public enum QualifiedLookupResult2 {
  case members([DeclSyntax], constraints: [GenericWhereClauseSyntax])
}

/// Contains the results of a qualified lookup request
public enum QualifiedLookupResult {
  public enum ImplicitDeclaration {
    case `Type`
    case `self`
  }

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
  case members([DeclSyntax], introducedIn: DeclGroupSyntaxType)
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
    introducedIn: DeclGroupSyntaxType,
    inheritanceClause: InheritanceClauseSyntax?,
    genericClause: GenericWhereClauseSyntax?
  )
  /// Implicit members in the given group declaration like `self`,
  /// `Type` and synthesized initializers.
  case implicitMembers([ImplicitDeclaration], introducedIn: DeclGroupSyntaxType)
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
  lazy var globalGroups:
    (
      types: [Identifier: [DeclGroupSyntaxType]],
      extensions: [CanonicalType: [ExtensionDeclSyntax]],
      aliases: [Identifier: [TypeAliasDeclSyntax]]
    ) = SymbolTable._getTypes(of: fileSyntax)
  /// Construct a table for caching symbol lookup
  /// for the given file syntax.
  public init(fileSyntax: SourceFileSyntax) {
    self.fileSyntax = fileSyntax
  }

  // indirect enum ResolvedType: Hashable {
  //   case id(IdentifierTypeSyntax)
  //   case member(MemberTypeSyntax, baseTypeMap: ResolvedType)
  //   // TODO: Other types
  //
  //   case idMap(IdentifierTypeSyntax, canonicalType: ResolvedType, using: TypeAliasDeclSyntax)
  //   case memberMap(MemberTypeSyntax, canonicalType: ResolvedType, using: TypeAliasDeclSyntax)
  //
  //   static func from(type: TypeSyntax, nestedAliases: borrowing [ResolvedType?: [Identifier: [TypeAliasDeclSyntax]]) -> [ResolvedType] {
  //     // TODO: Other types
  //     if let idType = type.as(IdentifierTypeSyntax.self) {
  //       // Can't do anything with non-identifier name
  //       guard let identifier = idType.name.identifier else { return [] }
  //       // nil because it's not nested
  //       let relevantMappings = nestedAliases[ResolvedType?.none, default: [:]][identifier, default: []]
  //       let possibleResolutions = relevantMappings.map {
  //         ResolvedType.idMap(idType, canonicalIdentifier: )
  //       }
  //     } else if let memberType = type.as(MemberTypeSyntax)
  //   }
  //
  //   func hash(into hasher: inout Hasher) {
  //     hasher.combine(canonicalType)
  //   }
  //   static func == (a: ResolvedType, b: ResolvedType) -> Bool {
  //     a.canonicalType == b.canonicalType
  //   }
  //
  //   var canonicalType: TypeSyntax {
  //     // switch self {
  //     // case let .id(idType):
  //     //   TypeSyntax(idType)
  //     // case let .member(memberType, baseTypeMap):
  //     //   TypeSyntax(memberType.with(\.baseType, baseTypeMap.canonicalType))
  //     // case let .idMap(idType, resolvedType, _):
  //     //   resolvedType.canonicalType
  //     // case let .memberMap(memberType, resolvedMemberType, _):
  //     //   let canonicalMemberType = resolvedMemberType.canonicalType
  //     //   switch resolvedMemberType {
  //     //     case let .id(idType):
  //     //       memberType.with(\.name, idType.name)
  //     //     case let .
  //     //   }
  //     //   TypeSyntax(memberType.with(\.name, TokenSyntax.identifier(canonicalIdentifier.name)))
  //     // }
  //   }
  // }
  // TODO: Implement kinda like above
  // FIXME: Add type-alias resolving
  // E.g.
  // struct LongStructNameElement {}
  // struct LongStructName {
  //   struct LongNestedName {}
  //   typealias Element = LongStructNameElement
  // }
  // extension LongStructName.Element {} // This should match LongStructNameElement

  // A unique way to refer to types.
  //
  // Note that at this stage, there may be multiple main
  // declarations for each resolved type (invalid but diagnosed later),
  // or none (e.g. extension references unknown type without type-aliases).
  // `CanonicalType`s just provide unique identifier for looking up types.
  struct CanonicalType: Hashable {
    private let _type: TypeSyntax
    private init(_type: TypeSyntax) {
      self._type = _type
    }

    static func from(type: TypeSyntax) -> [CanonicalType] {
      [CanonicalType(_type: type)]
    }

    /// Note that the resulting type may not refer to any valid main declaration
    init(topLevelName: Identifier) {
      _type = TypeSyntax(IdentifierTypeSyntax(name: .identifier(topLevelName.name)))
    }

    /// Returns nil if id token can't be converted to an identifier
    private init?(_topLevelNominalType name: TokenSyntax) {
      guard name.identifier != nil else { return nil }
      _type = TypeSyntax(IdentifierTypeSyntax(name: name))
    }
    /// Nil if type's name can't be converted to an identifier.
    init?(topLevelDecl: some NominalTypeDeclSyntax) {
      self.init(_topLevelNominalType: topLevelDecl.name)
    }
    /// Nil if type's name can't be converted to an identifier.
    init?(topLevelDecl: ProtocolDeclSyntax) {
      self.init(_topLevelNominalType: topLevelDecl.name)
    }
  }

  static func _addCodeBlock(
    decl: DeclSyntax,
    types: inout [Identifier: [DeclGroupSyntaxType]],
    // TODO: Consider making this lazy
    // Useful for quick member(nested)-type lookup. E.g.
    // `UnicodeScalarIndex {}` is canonicalized to `String.UnicodeScalarView.Index`
    // Also consider the following test case (should we do lookup on Int or not)?
    //   struct A {}
    //   typealias A = Int
    // here, do we look up `Int` too?
    extensions: inout [CanonicalType: [ExtensionDeclSyntax]],
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

      let possibleResolutions = CanonicalType.from(type: extensionDecl.extendedType)
      for resolvedType in possibleResolutions {
        extensions[resolvedType, default: []].append(extensionDecl)
      }
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
      var nestedExtensions = [CanonicalType: [ExtensionDeclSyntax]]()
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
    extensions: [CanonicalType: [ExtensionDeclSyntax]],
    aliases: [Identifier: [TypeAliasDeclSyntax]]
  ) {
    var types = [Identifier: [DeclGroupSyntaxType]]()
    var extensions = [CanonicalType: [ExtensionDeclSyntax]]()
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
  enum MemberKind {
    case all
    case `static`(onlyTypes: Bool = false)

    func addingStatic() -> MemberKind {
      switch self {
        case .all: .static()
        case .static(let onlyTypes): .static(onlyTypes: onlyTypes)
      }
    }
  }

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
  private func _lookUpTypeMember(
    type: TypeSyntax,
    identifier: Identifier?,
    kind memberKind: MemberKind,
    config: QualifiedTableLookupConfig,
    into results: inout [QualifiedLookupResult]
  ) {
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
      _lookUpGlobalTypeMember(type: identifierType, identifier: identifier, kind: memberKind, config: config, into: &results)
    } else if let memberType = type.as(MemberTypeSyntax.self) {
      _lookUpNestedTypeMember(type: memberType, identifier: identifier, kind: memberKind, config: config, into: &results)
    } else {
      fatalError("[SwiftLexicalLookup] Internal error: This type lookup \(type.kind) isn't implemented")
    }
  }

  /// Find named member declarations in the given group declaration.
  /// If an identifier is given, only return declaration matching that name.
  /// If a configuredRegion is provided, consider only the active clause's
  /// members.
  private func _addDirectMembers(
    of groupDecl: DeclGroupSyntax,
    identifier: Identifier?,
    kind memberKind: MemberKind,
    configuredRegions: ConfiguredRegions?,
    to result: inout [any NamedDeclSyntax]
  ) {
    // FIXME: Filter by memberKind

    /// Process a member or a member nested inside an if-config declaration.
    func processMember(member: MemberBlockItemSyntax) -> [any NamedDeclSyntax] {
      // Add named-declaration members
      if let namedDecl = member.decl.asProtocol((any NamedDeclSyntax).self) {
        [namedDecl]

      // If configuredRegions is set, visit the members of the active clause (if it exists)
      //
      // We do this recursively to handle nested if-config declarations
      } else if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self),
                let configuredRegions,
                case .decls(let members) = configuredRegions.activeClause(for: ifConfigDecl)?.elements {
        members.flatMap(processMember(member:))
      // If configuredRegions is nil, visit all if-config clauses
      } else if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self) {
        ifConfigDecl.clauses.flatMap({ clause -> [NamedDeclSyntax] in
          guard case .decls(let members) = clause.elements else { return [] }
          return members.flatMap(processMember(member:))
        })
      // No name, no gain
      } else {
        []
      }
    }

    // Add each member in the group declaration
    result.append(contentsOf: groupDecl.memberBlock.members.lazy.flatMap(processMember(member:)))
  }

  private func _visitSupertypes(
    of groupDecl: DeclGroupSyntax,
    lookingFor identifier: Identifier?,
    kind memberKind: MemberKind,
    results: inout [QualifiedLookupResult]
  ) {
    fatalError("[SwiftLexicalLookup] Internal error: Supertypes not implemented yet.")
    // Supertypes show up in:
    // 1. inheritance clauses
    //    (for nominal types+protocols+extensions)
    // 2. where clauses of the form `Self : Supertype`
    //    (also for nominal types+protocols+extensions)
    //    Note that it will always be `Self` because:
    //    1. A supertype constraint in that position is a generic parameter or `Self`
    //       1. It can't be a reference of `Self` like a typealias because the following fails:
    //          typealias A<T> = B<T>
    //          struct B<T> where A<T>: CustomStringConvertible {}
    //    2. Contraints on generic parameter's don't impose supertype constraints on `Self`
  }

  private func _lookUpGroupMembers(
    group: DeclGroupSyntaxType,
    identifier: Identifier?,
    kind memberKind: MemberKind,
    config: QualifiedTableLookupConfig,
    into results: inout [QualifiedLookupResult]
  ) {
    // Add direct members
    var directMembers = [any NamedDeclSyntax]()
    _addDirectMembers(
      of: group, identifier: identifier, kind: memberKind, configuredRegions: config.configuredRegions,
      to: &directMembers)
    // We assume NamedDeclSyntax is a DeclSyntax
    // TODO: Look for more elegant solution
    results.append(.members(directMembers.map({ DeclSyntax($0)! }), introducedIn: group))

    // Visit supertypes
    _visitSupertypes(of: group, lookingFor: identifier, kind: memberKind, results: &results)
  }

  // Finds decl groups nested in identifier types
  // TODO: Attach inheritance&where clauses from extensions/typealiases
  private func _lookUpGlobalTypeMember(
    type: IdentifierTypeSyntax,
    identifier: Identifier?,
    kind memberKind: MemberKind,
    config: QualifiedTableLookupConfig,
    into results: inout [QualifiedLookupResult]
  ) {
    // FIXME: Handle modules and module selectors
    precondition(type.moduleSelector == nil, "[SwiftLexicalLookup] Internal error: Module selector not implemented yet.")
    // Ensure type identifier is valid (can't do lookup with invalid identifier)
    guard let typeIdentifier = type.name.identifier else { return }

    // Look inside main declaration
    // If there are many declarations, assume last one is valid (duplicate
    // declarations should be diagnosed in later stages)
    // TODO: Check if compiler also gets the last decl
    if let matchingTypeDecl = globalGroups.types[typeIdentifier]?.last {
      _lookUpGroupMembers(group: matchingTypeDecl, identifier: identifier, kind: memberKind, config: config, into: &results)
    }
  }

  func _findMainDeclsOfNestedType(
    type: MemberTypeSyntax,
    identifier: Identifier?,
    config: QualifiedTableLookupConfig,
    into results: inout [QualifiedLookupResult]
  ) {
    // TODO: Move _lookUpNestedTypeMember part into here
  }
  func _findExtensionsOfNestedType(

  )

  func _lookUpNestedTypeMember(
    type: MemberTypeSyntax,
    identifier: Identifier?,
    kind memberKind: MemberKind,
    config: QualifiedTableLookupConfig,
    into results: inout [QualifiedLookupResult]
  ) {
    // FIXME: Handle modules and module selectors
    precondition(type.moduleSelector == nil, "[SwiftLexicalLookup] Internal error: Module selector not implemented yet.")
    // Ensure identifier is valid (can't do lookup with invalid identifier)
    guard let typeIdentifier = type.name.identifier else { return }

    // Process "implicit" types that aren't really types
    guard typeIdentifier.name != "self" else {
      // Forward lookup to the base type
      _lookUpTypeMember(type: type.baseType, identifier: identifier, kind: memberKind, config: config, into: &results)
      return
    }
    // TODO: Figure out how to handle this (currently we include nothing)
    guard typeIdentifier.name != "Type" else {
      return
    }

    // Two scopes can introduce members in nested types. The main declaration
    // and any top-level extensions (nested extensions are currently illegal).
    // Each of these scopes can either have member declarations or introduce
    // supertypes.

    // For one, get the main declaration.
    // Get possible declarations by looking up through the base type
    var nestedTypeDecls = [QualifiedLookupResult]()
    _lookUpTypeMember(type: type.baseType, identifier: typeIdentifier, kind: .static(onlyTypes: true), config: config, into: &nestedTypeDecls)
    // Filter down to nominal-type declarations.
    //
    // At this point, we may have many such declarations. Here's a
    // well-formed example:
    //    // FileA.swift
    //    struct A { fileprivate struct B {} }
    //    // FileB.swift
    //    extension A { fileprivate struct B {} }
    // But putting these in the same file makes the above an illegal program.
    // Either way, for now we keep both.
    // TODO: Look at how compiler handles many
    // TODO: Look at how potential access control influences lookup
    // TODO: Look at how to handle `lookFor[..]` queries
    var extendedLookup = [QualifiedLookupResult]()
    var mainDecls = [CanonicalType: DeclGroupSyntaxType]()
    for result in nestedTypeDecls {
      switch result {
      case .members(let decls, _):
        // Ensure look up gave us nominal declarations
        mainDecls.append(contentsOf: decls.lazy.map({
          guard let nominalType = $0.asProtocol((any NominalTypeDeclSyntax).self) else {
            assertionFailure("[SwiftLexicalLookup] Internal assertion failure: Expected only nominal types after performing type-only lookup.")
          }
          return DeclGroupSyntaxType(exactly: nominalType)
        })
      case .implicitMembers(_, _):
        // Handled above so lookup shouldn't surface implicit members when the requested
        // identifier isn't one.
        assertionFailure("[SwiftLexicalLookup] Internal assertion failure: Expected no implicit members aftering filtering out `Type` and `self`.")
      case .conditionalMembers(let conditionalDecls, _, _, _):
        // Ignore inheritance/where clauses for now
        mainDecls.append(contentsOf: conditionalDecls.lazy.compactMap(DeclGroupSyntaxType.init(_:)))
      case .lookForDynamicMembers, .lookForSupertypes, .lookForMacros:
        extendedLookup.append(result)
      }
    }
    let mainDecls =

    // Find extensions for each main decl
    for mainDeclType in mainDecls.keys {
      let possibleExtensions = globalGroups.extensions[mainDeclType, default: []]
      possibleExtensions
    }
    // Look up on main
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
