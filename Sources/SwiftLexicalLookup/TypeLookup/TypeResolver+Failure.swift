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

extension TypeResolver {
  @_spi(_QualifiedLookupTests)
  public typealias Failure = GenericFailure<ResolvedTypeSyntax>

  @_spi(_QualifiedLookupTests)
  public indirect enum GenericFailure<NominalType: NominalTypeResultProtocol>:
    Error
  {
    /// A type declaration in an outer scope has an invalid identifier.
    ///
    /// E.g.
    /// ```swift
    /// struct { // ❌ Invalid identifier
    ///   let _: Self // <- Lookup here
    /// }
    /// ```
    case invalidNameToken(TokenSyntax)

    /// Cannot find the given type identifier in scope (using unqualified lookup).
    ///
    /// E.g.,
    /// ```
    /// func f(_: A) {} // ❌ error: cannot find type 'A' in scope
    /// ```
    case noTypeInScope

    /// Only protocol, class and composition types can form compositions.
    ///
    /// I.e. We don't allow structs/enums/actors, functions, tuples.
    case cannotComposeNonClassOrProtocol(resolved: GenericTypeResult<NominalType>)
    case noTypeMember(member: TypeReference, in: GenericTypeResult<NominalType>)

    /// We can only extend structs/enums/classes/actors/protocols
    ///
    /// I.e. We can't extend tuples, functions, protocol compositions, metatypes, etc.
    case cannotExtendNonNominal(nonnominal: GenericTypeResult<NominalType>)
    /// Extensions may only appear at file scope (top-level).
    /// ```swift
    /// func f() {
    ///   struct A {}
    ///   extension A {} // ❌
    /// }
    /// ```
    case extensionNotAtFileScope(extensionDecl: ExtensionDeclSyntax)
    /// Child has error, so we can't qualify this type but we can't offer a useful diagnostic either.
    ///
    /// E.g.
    ///   typealias A = Encodable & Int.Type // ❌ error: non-protocol, non-class type 'Int.Type' cannot be used within a protocol-constrained type
    ///   func f(_: A) {} // No diagnostic here
    case invalidAliasedType(Self)
    case invalidComposition([(TypeSyntax, Self)])
    /// An error in partial-type resolution where further type-resolution
    /// steps don't make sense. For instance, we can't parse a wildcard type
    /// or an identifier type syntax with an invalid identifier.
    case partialTypeResolutionFailure(PartialTypeResolutionFailure)

    /// We defer generic parameters/associated types to the type checker.
    case genericParameterOrAssociatedType

    /// Type members (obtained through qualified lookup) had errors
    ///
    /// E.g.
    /// ```swift
    /// protocol A { typealias T = Undefined }
    /// class B<Generic> { typealias T = Generic }
    ///
    /// func f(_: (A & B).T)
    /// ```
    case invalidMembers([(TypeLikeSyntax, Self)])

    /// The base type which we need to derive a qualified name is invalid.
    ///
    /// Causes:
    /// 1. Nested in invalid nominal type declaration, e.g.:
    ///    ```swift
    ///    struct { // ❌ error: expected identifier in struct declaration
    ///      typealias A = Int
    ///      func f(a: A) {
    ///        let n: Int = a + "" // ✅ Compiler doesn't diagnose
    ///      }
    ///    }
    ///    ```
    ///    Note that if we use an invalid name like `struct 555`, the compiler
    ///    will interpret the name as the backtick-escaped '`555`' to offer
    ///    better diagnostics.
    /// 2. Nested in extension whose type doesn't resolve to a nominal type
    ///
    ///    This failure happens when unqualified lookup wants to return the
    ///    extended type or a member/generic parameter of the extended type.
    ///    E.g.:
    ///
    ///    ```swift
    ///    extension UndefinedType { // ❌ error: cannot find 'UndefinedType' in scope
    ///      func f(a: AlsoUndefined) {} // ✅ Compiler doesn't diagnose
    ///    }
    ///    extension UndefinedType {
    ///      typealias T = Int
    ///      func f(a: T) -> Int {} // ❌ error: cannot find type 'T' in scope
    ///    }
    ///    ```
    case invalidBaseType(Self)

    /// Name lookup found multiple type redeclarations so references to that
    /// type name are ambiguous; not necessarily an error, we just defer to
    /// the type checker for disambiguation.
    ///
    /// For example:
    ///   typealias A = Bool
    ///   typealias A = Int
    ///   typealias A = String
    ///
    ///   let a: A // ❌ error: 'A' is ambiguous for type lookup
    case ambiguousTypeDecl([TypeDeclSyntax])

    /// All evaluated syntax must have a ``SourceFileSyntax`` root that's
    /// registered in the provided symbol table.
    case syntaxNotInSymbolTable(SourceFileSyntax)

    /// Cannot resolve type syntax nested inside a disabled `#if`
    /// (given the symbol table's configured regions).
    case syntaxInDisabledRegion

    /// A type syntax that resolves to its own definition.
    ///
    /// E.g.
    /// ```swift
    /// typealias A = B
    /// typealias B = A
    /// ```
    ///
    /// The cycle consists of all the type syntax reference we resolved
    /// to get to the cycle (minus the starting syntax).
    case cyclicalTypeReference(cycle: [TypeSyntax])

    // The type resolution depends on a cyclical extension: an extension that
    // introduces type members on which its own resolution depends.
    //
    // E.g.
    // ```swift
    // struct A {}
    // extension A { typealias B = A }
    // extension A.B {
    //   struct A {}
    //
    //   func f(_: Self) {} // <- Look up `Self` here
    // }
    // ```
    case cyclicalExtensionDependency(GenericExtensionBindingCycle<TypeGraph.GlobalTypeName>)

    /// We bind extensions to types incrementally, so a type-resolution request
    /// might be nested within an extension binding request, but it may itself
    /// make an extension-binding request. In that case, the nested type resolution
    /// fails and we mark the dependency. *Users should not see this error.*
    ///
    /// TODO: Find use case where this actually happens; currently, only `bindExtension`
    /// emits this error.
    case extensionNotBoundYet
  }
}

extension TypeResolver.GenericFailure {
  @_spi(_QualifiedLookupTests)
  public func _map<NewNominalType>(
    mapNominal: (NominalType) -> NewNominalType
  ) -> TypeResolver.GenericFailure<NewNominalType> {
    func mapNested(_ nestedFailure: Self) -> TypeResolver.GenericFailure<NewNominalType> {
      nestedFailure._map(mapNominal: mapNominal)
    }

    switch self {
    // Passthrough
    case .invalidNameToken(let nameToken):
      return .invalidNameToken(nameToken)
    case .noTypeInScope:
      return .noTypeInScope
    case .extensionNotAtFileScope(let extensionDecl):
      return .extensionNotAtFileScope(extensionDecl: extensionDecl)
    case .partialTypeResolutionFailure(let partialResolutionFailure):
      return .partialTypeResolutionFailure(partialResolutionFailure)
    case .genericParameterOrAssociatedType:
      return .genericParameterOrAssociatedType
    case .ambiguousTypeDecl(let ambiguousDecls):
      return .ambiguousTypeDecl(ambiguousDecls)
    case .syntaxNotInSymbolTable(let fileRoot):
      return .syntaxNotInSymbolTable(fileRoot)
    case .syntaxInDisabledRegion:
      return .syntaxInDisabledRegion
    case .cyclicalTypeReference(let cycle):
      return .cyclicalTypeReference(cycle: cycle)
    case .extensionNotBoundYet:
      return .extensionNotBoundYet
    // Actual maps
    case .cyclicalExtensionDependency(let cycle):
      return .cyclicalExtensionDependency(cycle)
    case .cannotComposeNonClassOrProtocol(let type):
      return .cannotComposeNonClassOrProtocol(resolved: type.mapNominals(mapNominal))
    case .noTypeMember(let member, let type):
      return .noTypeMember(member: member, in: type.mapNominals(mapNominal))
    case .cannotExtendNonNominal(let nonnominal):
      return .cannotExtendNonNominal(nonnominal: nonnominal.mapNominals(mapNominal))
    case .invalidAliasedType(let nestedFailure):
      return .invalidAliasedType(mapNested(nestedFailure))
    case .invalidComposition(let invalidChildren):
      return .invalidComposition(
        invalidChildren.map({ syntax, nestedFailure in
          (syntax, mapNested(nestedFailure))
        })
      )
    case .invalidMembers(let invalidMembers):
      return .invalidMembers(
        invalidMembers.map({ syntax, nestedFailure in
          (syntax, mapNested(nestedFailure))
        })
      )
    case .invalidBaseType(let baseFailure):
      return .invalidBaseType(mapNested(baseFailure))
    }
  }
}

// MARK: Dependency Cycle

@_spi(_QualifiedLookupTests)
public struct GenericDependencyCycleElement<TypeName: Sendable>: Sendable {
  public let introducingTypeDecl: TypeDeclSyntax?
  public let extensionDecl: ExtensionDeclSyntax
  public let boundType: TypeName

  public init(
    introducingTypeDecl: TypeDeclSyntax?,
    extensionDecl: ExtensionDeclSyntax,
    boundType: TypeName
  ) {
    self.introducingTypeDecl = introducingTypeDecl
    self.extensionDecl = extensionDecl
    self.boundType = boundType
  }

  fileprivate func _map<NewTypeName>(mapName: (TypeName) -> NewTypeName) -> GenericDependencyCycleElement<NewTypeName> {
    GenericDependencyCycleElement<NewTypeName>(
      introducingTypeDecl: introducingTypeDecl,
      extensionDecl: extensionDecl,
      boundType: mapName(boundType)
    )
  }
}
@_spi(_QualifiedLookupTests)
public typealias DependencyCycleElement = GenericDependencyCycleElement<
  TypeGraph.GlobalTypeName
>

@_spi(_QualifiedLookupTests)
public struct GenericExtensionBindingCycle<TypeName: Sendable>: Sendable {
  public let dependencyPath: [GenericDependencyCycleElement<TypeName>]
  public let dependencyMember: Identifier

  public init(
    dependencyPath: [GenericDependencyCycleElement<TypeName>],
    dependencyMember: Identifier
  ) {
    self.dependencyPath = dependencyPath
    self.dependencyMember = dependencyMember
  }
}
@_spi(_QualifiedLookupTests)
public typealias ExtensionBindingCycle = GenericExtensionBindingCycle<
  TypeGraph.GlobalTypeName
>

// MARK: Debug

@_spi(_QualifiedLookupTests)
extension GenericDependencyCycleElement: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    "DependencyCycleElement(introducingTypeDecl: `\(introducingTypeDecl?._memberlessDescription ?? "nil")`, extensionDecl: `\(extensionDecl._memberlessDescription)`, boundType: '\(boundType.debugDescription)'"
  }
}

@_spi(_QualifiedLookupTests)
extension GenericExtensionBindingCycle: CustomDebugStringConvertible where TypeName: CustomDebugStringConvertible {
  public var debugDescription: String {
    let pathDescriptions = dependencyPath.map(\.debugDescription).joined(separator: ",\n    ")
    return """
      ExtensionBindingCycle(
        dependencyPath: [
          \(pathDescriptions)
        ],
        dependencyMember: '\(dependencyMember.name)'
      )"
      """
  }
}

extension TypeResolver.GenericFailure: CustomDebugStringConvertible {
  /// Debug description
  ///
  /// Namely, for syntax nodes we use `.trimmedDescription` and for `ResolvedNominalTypeReference`
  /// we simply compare the qualified type name description.
  public var debugDescription: String {
    func describeNested(_ nestedFailure: Self) -> String {
      nestedFailure.debugDescription.replacing("\n", with: "\n  ")
    }

    switch self {
    case .invalidNameToken(let nameToken):
      return ".invalidNameToken(\(nameToken.trimmedDescription))"
    case .noTypeInScope:
      return ".noTypeInScope"
    case .cannotComposeNonClassOrProtocol(let type):
      return ".cannotComposeNonClassOrProtocol(\(type.debugDescription))"
    case .noTypeMember(let member, let type):
      return
        ".noTypeMember(member: \(member.debugDescription), in: \(type.debugDescription))"
    case .cannotExtendNonNominal(let nonnominal):
      return ".cannotExtendNonNominal(nonnominal: \(nonnominal.debugDescription))"
    case .extensionNotAtFileScope(let extensionDecl):
      return ".extensionNotAtFileScope(extensionDecl: `\(extensionDecl._memberlessDescription)`)"
    case .invalidAliasedType(let nestedFailure):
      return """
        .invalidAliasedType(
          \(describeNested(nestedFailure))
        )
        """
    case .invalidComposition(let invalidChildren):
      let invalidChildrenDescription = invalidChildren.map({ (childSyntax, childFailure) in
        return "  \(childSyntax.trimmedDescription): \(describeNested(childFailure))"
      }).joined(separator: ",\n")
      return ".invalidComposition([\(invalidChildrenDescription)])"
    case .partialTypeResolutionFailure(let partialResolutionFailure):
      return ".partialTypeResolutionFailure(\(partialResolutionFailure.debugDescription))"
    case .genericParameterOrAssociatedType:
      return ".genericParameterOrAssociatedType"
    case .invalidMembers(let invalidMembers):
      let invalidMembersDescription = invalidMembers.map({ (childSyntax, memberFailure) in
        return "  \(childSyntax.trimmedDescription): \(describeNested(memberFailure))"
      }).joined(separator: ",\n")
      return ".invalidMembers([\(invalidMembersDescription)])"
    case .invalidBaseType(let baseFailure):
      return """
        .invalidBaseType(
          \(describeNested(baseFailure))
        )
        """
    case .ambiguousTypeDecl(let ambiguousDecls):
      let ambiguousDeclsDescription = ambiguousDecls.map(\.trimmedDescription).joined(separator: ", ")
      return ".ambiguousTypeDecl([\(ambiguousDeclsDescription)])"
    case .syntaxNotInSymbolTable(let fileRoot):
      return ".syntaxNotInSymbolTable(rootKind: \(fileRoot))"
    case .syntaxInDisabledRegion:
      return ".syntaxInDisabledRegion"
    case .cyclicalTypeReference(let cycle):
      return ".cyclicalTypeReference(\(cycle.map(\.trimmedDescription)))"
    case .cyclicalExtensionDependency(let cycle):
      return ".cyclicalExtensionDependencies(\(cycle.debugDescription))"
    case .extensionNotBoundYet:
      return ".extensionNotBoundYet"
    }
  }
}

// MARK: Nested-Cycle Detection

extension TypeResolver.Failure {
  /// Tries to pull out a ``.cyclicalTypeReference`` from this failure at depth
  /// zero or one (non-recursive).
  var nestedCycle: [TypeSyntax]? {
    switch self {
    case .cyclicalTypeReference(let cycle):
      return cycle

    // Simple nesting
    case .invalidAliasedType(.cyclicalTypeReference(let nestedCycle)),
      .invalidBaseType(.cyclicalTypeReference(let nestedCycle)):
      return nestedCycle

    // No nested ``TypeQualifierFailure`` => nil
    case .invalidNameToken(_), .noTypeInScope, .cannotComposeNonClassOrProtocol(_),
      .noTypeMember(member: _, in: _), .cannotExtendNonNominal(nonnominal: _),
      .extensionNotAtFileScope(extensionDecl: _), .partialTypeResolutionFailure(_),
      .genericParameterOrAssociatedType, .ambiguousTypeDecl(_),
      .syntaxNotInSymbolTable, .syntaxInDisabledRegion, .extensionNotBoundYet,
      // Extension cycles are distinct
      .cyclicalExtensionDependency(_),
      // If the above case don't directly contain a cycle
      .invalidAliasedType(_), .invalidBaseType(_):
      return nil

    // Only return a nested cycle if we have exactly one result.
    case .invalidMembers(let nestedFailures):
      guard
        case (_, TypeResolver.GenericFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    case .invalidComposition(let nestedFailures):
      guard
        case (_, TypeResolver.GenericFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    }
  }
}
