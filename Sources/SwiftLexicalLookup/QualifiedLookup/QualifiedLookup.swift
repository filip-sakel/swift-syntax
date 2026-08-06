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

// public enum QualifiedLookupResult2 {
//   case members([DeclSyntax], constraints: [GenericWhereClauseSyntax])
// }

/// Contains the results of a qualified lookup request
@_spi(_QualifiedLookup) public enum QualifiedLookupResult {
  public enum ImplicitDeclaration {
    case `Type`
    case `Protocol`
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
  case members([ValueDeclSyntax], introducedIn: DeclGroupSyntaxType)
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
    [ValueDeclSyntax],
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
    potentialMacroDecl: [ValueDeclSyntax],
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

// MARK: - Compiler Validation

extension SymbolTable {
  // enum NLOptions : unsigned {
  //   /// Consider declarations within protocols to which the context type conforms.
  //   NL_ProtocolMembers = 1 << 0,
  //
  //   /// Remove non-visible declarations from the set of results.
  //   NL_RemoveNonVisible = 1 << 1,
  //
  //   /// Remove overridden declarations from the set of results.
  //   NL_RemoveOverridden = 1 << 2,
  //
  //   /// Remove associated type declarations from the set of results. This is used
  //   /// by conformance checking for resolving type witnesses.
  //   NL_RemoveAssociatedTypes = 1 << 3,
  //
  //   /// Don't check access when doing lookup into a type.
  //   ///
  //   /// When performing lookup into a module, this option only applies to
  //   /// declarations in the same module the lookup is coming from.
  //   NL_IgnoreAccessControl = 1 << 4,
  //
  //   /// This lookup should only return type declarations.
  //   NL_OnlyTypes = 1 << 5,
  //
  //   /// Include synonyms declared with @_implements()
  //   NL_IncludeAttributeImplements = 1 << 6,
  //
  //   // Include @usableFromInline and @inlinable
  //   NL_IncludeUsableFromInline = 1 << 7,
  //
  //   /// Exclude names introduced by macro expansions in the top-level module.
  //   NL_ExcludeMacroExpansions = 1 << 8,
  //
  //   /// This lookup should only return macro declarations.
  //   NL_OnlyMacros = 1 << 9,
  //
  //   /// Include members that would otherwise be filtered out because they come
  //   /// from a module that has not been imported.
  //   NL_IgnoreMissingImports = 1 << 10,
  //
  //   /// If @abi attributes are present, return the decls representing the ABI,
  //   /// not the API.
  //   NL_ABIProviding = 1 << 11,
  //
  //   /// The default set of options used for qualified name lookup.
  //   ///
  //   /// FIXME: Eventually, add NL_ProtocolMembers to this, once all of the
  //   /// callers can handle it.
  //   NL_QualifiedDefault = NL_RemoveNonVisible | NL_RemoveOverridden,
  //
  //   /// The default set of options used for unqualified name lookup.
  //   NL_UnqualifiedDefault = NL_RemoveNonVisible | NL_RemoveOverridden
  // };
  public struct LookupOptions: OptionSet, Sendable {
    // TODO: Convert to option sets

    // enum Source: UInt8 { case superProtocols, superClasses, macroExpansions, abi, implements }
    // let sources: Set<Source>
    // let includeMissingImports: Bool
    //
    // enum TargetDecl: UInt8 { case macros, static(onlyTypes: Bool = false), protocolMembers(withAssociatedTypes: Bool = true),   }
    // let targetDecls: Set<TargetDecl>
    // let nonVisible

    public let rawValue: UInt32
    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    /// Consider declarations within protocols to which the context type conforms.
    public static let protocolMembers =
      LookupOptions(rawValue: 1 << 0)

    /// Remove non-visible declarations from the set of results.
    public static let removeNonVisible =
      LookupOptions(rawValue: 1 << 1)

    /// Remove overridden declarations from the set of results.
    public static let removeOverridden =
      LookupOptions(rawValue: 1 << 2)

    /// Remove associated type declarations from the set of results.
    /// This is used by conformance checking for resolving type witnesses.
    public static let removeAssociatedTypes =
      LookupOptions(rawValue: 1 << 3)

    /// Don't check access when doing lookup into a type.
    ///
    /// When performing lookup into a module, this option only applies to
    /// declarations in the same module the lookup is coming from.
    public static let ignoreAccessControl =
      LookupOptions(rawValue: 1 << 4)

    /// This lookup should only return type declarations.
    public static let onlyTypes =
      LookupOptions(rawValue: 1 << 5)

    /// Include synonyms declared with @_implements()
    public static let includeAttributeImplements =
      LookupOptions(rawValue: 1 << 6)

    /// Include @usableFromInline and @inlinable
    public static let includeUsableFromInline =
      LookupOptions(rawValue: 1 << 7)

    /// Exclude names introduced by macro expansions in the top-level module.
    public static let excludeMacroExpansions =
      LookupOptions(rawValue: 1 << 8)

    /// This lookup should only return macro declarations.
    public static let onlyMacros =
      LookupOptions(rawValue: 1 << 9)

    /// Include members that would otherwise be filtered out because they come
    /// from a module that has not been imported.
    public static let ignoreMissingImports =
      LookupOptions(rawValue: 1 << 10)

    /// If @abi attributes are present, return the decls representing the ABI,
    /// not the API.
    public static let abiProviding =
      LookupOptions(rawValue: 1 << 11)

    /// The default set of options used for qualified name lookup.
    ///
    /// FIXME: Eventually, add `protocolMembers` to this, once all callers can handle it.
    public static let qualifiedDefault: LookupOptions = [.removeNonVisible, .removeOverridden]

    /// The default set of options used for unqualified name lookup.
    public static let unqualifiedDefault: LookupOptions = [.removeNonVisible, .removeOverridden]
  }

  /// Look for the set of declarations with the given name within a type,
  /// its extensions and, optionally, its supertypes.
  ///
  /// This routine performs name lookup within a given type, its extensions
  /// and, optionally, its supertypes and their extensions, from the perspective
  /// of the current DeclContext. It can eliminate non-visible, hidden, and
  /// overridden declarations from the result set. It does not, however, perform
  /// any filtering based on the semantic usefulness of the results.
  ///
  /// \param type The type to look into.
  ///
  /// \param member The member to search for.
  ///
  /// \param options Options that control name lookup, based on the
  /// \c NL_* constants in \c NameLookupOptions.
  ///
  /// \param[out] decls Will be populated with the declarations found by name
  /// lookup.
  ///
  /// \returns true if anything was found.
  // bool lookupQualified(Type type, DeclNameReference member,
  //                      SourceLoc loc, NLOptions options,
  //                      SmallVectorImpl<ValueDecl *> &decls) const;
  func lookupMember(
    withName name: DeclNameReference,
    inType type: TypeSyntax,
    fromLocation location: AbsolutePosition,
    options: LookupOptions
  ) -> [ValueDeclSyntax] {
    []
  }

  /// Look for the set of declarations with the given name within the
  /// given set of nominal type declarations.
  ///
  /// \param types The type declarations to look into.
  ///
  /// \param member The member to search for.
  ///
  /// \param options Options that control name lookup, based on the
  /// \c NL_* constants in \c NameLookupOptions.
  ///
  /// \param[out] decls Will be populated with the declarations found by name
  /// lookup.
  ///
  /// \returns true if anything was found.
  // bool lookupQualified(ArrayRef<NominalTypeDecl *> types, DeclNameReference member,
  //                      SourceLoc loc, NLOptions options,
  //                      SmallVectorImpl<ValueDecl *> &decls) const;
  func lookupMember(
    withName name: DeclNameReference?,
    inDeclGroup declGroup: DeclGroupSyntaxType,
    fromLocation location: AbsolutePosition,
    memberKind: MemberKind = .default,
    lookupSupertypes: Bool = false
  ) -> [ValueDeclSyntax] {
    []
  }
}
