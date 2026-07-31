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

extension Result where Success: CustomDebugStringConvertible, Failure: CustomDebugStringConvertible {
  var _debugDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.debugDescription))"
    case .failure(let error):
      return ".error(\(error.debugDescription))"
    }
  }
}
extension Result where Success: SyntaxProtocol, Failure: CustomDebugStringConvertible {
  fileprivate var _debugSyntaxDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.trimmedDescription))"
    case .failure(let error):
      return ".error(\(error.debugDescription))"
    }
  }
}
extension Result where Success == [TypeDeclSyntax], Failure: CustomDebugStringConvertible {
  fileprivate var _debugSyntaxDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.map(\.trimmedDescription)))"
    case .failure(let error):
      return ".error(\(error.debugDescription))"
    }
  }
}
// extension Result where Success == ResolvedNominalTypeReference, Failure: CustomDebugStringConvertible {
//   fileprivate func _describe(describeTypeName: (QualifiedTypeName) -> String) -> String {
//     switch self {
//     case .success(let success):
//       return ".success(\(success._describe(describeTypeName: describeTypeName))"
//     case .failure(let error):
//       return ".error(\(error.debugDescription))"
//     }
//   }
// }
// extension Result
// where Success == MemberLookupResult<ResolvedNominalTypeReference>, Failure: CustomDebugStringConvertible {
//   fileprivate func _describe(describeTypeName: (QualifiedTypeName) -> String) -> String {
//     switch self {
//     case .success(let success):
//       return
//         ".success(\(success._describe(describeMembers: { $0.map({ $0._describe(describeTypeName: describeTypeName) }).joined(separator: ", ") }))"
//     case .failure(let error):
//       return ".error(\(error.debugDescription))"
//     }
//   }
// }

/// The minimal defining components of a nominal type: the main declaration and the qualified name.
/// Unlike ``NominalType``, doesn't include extensions.
///
/// TODO: Make into `NominalTypeRef` + `TypeLikeSyntax`
@_spi(_QualifiedLookup)
public struct GenericResolvedNominalTypeReference<TypeName: Sendable & Hashable & CustomDebugStringConvertible>:
  Sendable, Hashable, CustomDebugStringConvertible
{
  public let mainDecl: SourceFileRoot<NominalTypeDeclSyntax>
  public let qualifiedName: TypeName
  // public let nominalTypeRef: NominalTypeRef
  public let originatingSyntax: SourceFileRoot<TypeLikeSyntax>

  @_spi(_QualifiedLookup) public init(
    mainDecl: SourceFileRoot<NominalTypeDeclSyntax>,
    name: TypeName,
    // nominalTypeRef: NominalTypeRef,
    originatingSyntax: SourceFileRoot<TypeLikeSyntax>,
  ) {
    self.mainDecl = mainDecl
    self.qualifiedName = name
    // self.nominalTypeRef = nominalTypeRef
    self.originatingSyntax = originatingSyntax
  }

  public var debugDescription: String {
    "\(qualifiedName.debugDescription) (\(mainDecl.kind))"
  }
}

@_spi(_QualifiedLookup) public typealias ResolvedNominalTypeReference = GenericResolvedNominalTypeReference<
  QualifiedTypeName
>

extension ResolvedNominalTypeReference {
  init(_ globalTypeReference: GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>) {
    self.init(
      mainDecl: globalTypeReference.mainDecl,
      name: QualifiedTypeName.topLevel(globalTypeReference.qualifiedName),
      originatingSyntax: globalTypeReference.originatingSyntax
    )
  }
}

// TODO: Remove
// extension ResolvedNominalTypeReference {
//   @_spi(_QualifiedLookupTests) public static func _mockMarkerType(
//     mainDecl: SourceFileRoot<NominalTypeDeclSyntax>,
//     originatingSyntax: TypeSyntax
//   ) -> ResolvedNominalTypeReference {
//     ResolvedNominalTypeReference(
//       mainDecl: mainDecl,
//       name: QualifiedTypeName.topLevel(
//         QualifiedTypeNameGlobalType(
//           components: [
//             QualifiedTypeNameGlobalType.Component(
//               name: Identifier(canonicalName: "_")
//               qualifier: .external(moduleName: Identifier(canonicalName: "_")),
//             )
//           ]
//         )!
//       ),
//       originatingSyntax: TypeLikeSyntax(originatingSyntax)
//     )
//   }
// }

@_spi(_QualifiedLookup)
public indirect enum TypeQualifierFailure<TypeName: Sendable, MinimalNominal: Sendable, ExtendedNominal: Sendable>:
  Error
{
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
  case cannotComposeNonClassOrProtocol(resolved: MemberLookupResult<MinimalNominal>)
  case noTypeMember(member: ImplicitTypeReferenceComponent, in: MemberLookupResult<ExtendedNominal>)

  // // TODO: Can we simplify to a single failure?
  // case invalidChildren([TypeSyntax: [Failure]])

  /// We can only extend structs/enums/classes/actors/protocols
  ///
  /// I.e. We can't extend tuples, functions, protocol compositions, metatypes, etc.
  case cannotExtendNonNominal(nonnominal: MemberLookupResult<MinimalNominal>)
  /// Child has error, so we can't qualify this type but we can't offer a useful diagnostic either.
  ///
  /// E.g.
  ///   typealias A = Encodable & Int.Type // ❌ error: non-protocol, non-class type 'Int.Type' cannot be used within a protocol-constrained type
  ///   func f(_: A) {} // No diagnostic here
  case invalidAliasedType(Self)
  case invalidComposition([(TypeSyntax, Self)])
  // TODO: Get rid of this
  case other(any Error)

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
  case cyclicalExtensionDependency(GenericExtensionBindingCycle<TypeName>)

  /// We bind extensions to types incrementally, so a type-resolution request
  /// might be nested within an extension binding request, but it may itself
  /// make an extension-binding request. In that case, the nested type resolution
  /// fails and we mark the dependency. *Users should not see this error.*
  ///
  /// TODO: Find use case where this actually happens; currently, only `bindExtension`
  /// emits this error.
  case extensionNotBoundYet
}

extension TypeQualifierFailure where TypeName: CustomDebugStringConvertible {
  /// Produce a simplified description for debugging.
  ///
  /// Namely, for syntax nodes we use `.trimmedDescription` and for `ResolvedNominalTypeReference`
  /// we simply compare the qualified type name description.
  @_spi(_QualifiedLookup) public func _describeDebug(
    resolveMininalNominal: (MinimalNominal) -> String,
    resolveExtendedNominal: (ExtendedNominal) -> String,
    newlinePrefix: String = ""
  ) -> String {
    let prefixStep = "  "
    func describeType<T>(_ memberResults: MemberLookupResult<T>, describe: (T) -> String) -> String {
      return memberResults._describe(describeMembers: { results in
        results.map(describe).joined(separator: ", ")
      })
    }

    switch self {
    case .noTypeInScope:
      return ".noTypeInScope"
    case .cannotComposeNonClassOrProtocol(let type):
      return ".cannotComposeNonClassOrProtocol(\(describeType(type, describe: resolveMininalNominal)))"
    case .noTypeMember(let member, let type):
      return
        ".noTypeMember(member: \(member.debugDescription), in: \(describeType(type, describe: resolveExtendedNominal)))"
    case .cannotExtendNonNominal(let nonnominal):
      return ".cannotExtendNonNominal(nonnominal: \(describeType(nonnominal, describe: resolveMininalNominal)))"
    case .invalidAliasedType(let nestedFailure):
      return """
        .invalidAliasedType(
        \(nestedFailure._describeDebug(
          resolveMininalNominal: resolveMininalNominal,
          resolveExtendedNominal: resolveExtendedNominal,
          newlinePrefix: newlinePrefix + prefixStep
          )
        )
        \(newlinePrefix))
        """
    case .invalidComposition(let invalidChildren):
      let invalidChildrenDescription = invalidChildren.map({ (childSyntax, childFailure) in
        let childDescription = childFailure._describeDebug(
          resolveMininalNominal: resolveMininalNominal,
          resolveExtendedNominal: resolveExtendedNominal,
          newlinePrefix: newlinePrefix + prefixStep + prefixStep
        )
        return "\(newlinePrefix)\(prefixStep)\(childSyntax.trimmedDescription): \(childDescription)"
      }).joined(separator: ",\n")
      return ".invalidComposition([\(invalidChildrenDescription)])"
    case .other(let otherFailure):
      return ".other(\(String(reflecting: otherFailure)))"
    case .genericParameterOrAssociatedType:
      return ".genericParameterOrAssociatedType"
    case .invalidMembers(let invalidMembers):
      let invalidMembersDescription = invalidMembers.map({ (childSyntax, memberFailure) in
        let memberDescription = memberFailure._describeDebug(
          resolveMininalNominal: resolveMininalNominal,
          resolveExtendedNominal: resolveExtendedNominal,
          newlinePrefix: newlinePrefix + prefixStep + prefixStep
        )
        return "\(newlinePrefix)\(prefixStep)\(childSyntax.trimmedDescription): \(memberDescription)"
      }).joined(separator: ", ")

      return """
        \(newlinePrefix).invalidMembers(
        \(invalidMembersDescription)
        \(newlinePrefix))
        """
    case .invalidBaseType(let baseFailure):
      let baseDescription = baseFailure._describeDebug(
        resolveMininalNominal: resolveMininalNominal,
        resolveExtendedNominal: resolveExtendedNominal,
        newlinePrefix: newlinePrefix + prefixStep + prefixStep
      )

      return """
        \(newlinePrefix).invalidBaseType(
        \(baseDescription)
        \(newlinePrefix))
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

extension TypeQualifierFailure:
  CustomDebugStringConvertible
where
  TypeName: CustomDebugStringConvertible,
  MinimalNominal: CustomDebugStringConvertible,
  ExtendedNominal: CustomDebugStringConvertible
{
  func _describe(describeTypeName: (QualifiedTypeName) -> String) -> String {
    _describeDebug(
      resolveMininalNominal: \.debugDescription,
      resolveExtendedNominal: \.debugDescription
    )
  }

  public var debugDescription: String {
    _describe(describeTypeName: \.debugDescription)
  }
}

extension TypeQualifierFailure {
  /// Tries to pull out a ``.cyclicalTypeReference`` from this failure at depth
  /// zero or one (non-recursive).
  fileprivate var _nestedCycle: [TypeSyntax]? {
    switch self {
    case .cyclicalTypeReference(let cycle):
      return cycle

    // Simple nesting
    case .invalidAliasedType(.cyclicalTypeReference(let nestedCycle)),
      .invalidBaseType(.cyclicalTypeReference(let nestedCycle)):
      return nestedCycle

    // No nested ``TypeQualifierFailure`` => nil
    case .noTypeInScope, .cannotComposeNonClassOrProtocol(_), .noTypeMember(member: _, in: _),
      .cannotExtendNonNominal(nonnominal: _), .other(_), .genericParameterOrAssociatedType,
      .ambiguousTypeDecl(_), .syntaxNotInSymbolTable, .syntaxInDisabledRegion, .extensionNotBoundYet,
      // Extension cycles are distinct
      .cyclicalExtensionDependency(_),
      // If the above case don't directly contain a cycle
      .invalidAliasedType(_), .invalidBaseType(_):
      return nil

    // Only return a nested cycle if we have exactly one result.
    case .invalidMembers(let nestedFailures):
      guard
        case (_, TypeQualifierFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    case .invalidComposition(let nestedFailures):
      guard
        case (_, TypeQualifierFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    }
  }
}

// TODO: Remove
//
// @_spi(_QualifiedLookupTests) public enum ExtensionBindingState {
//   case singleRequest(
//     currentRequest: SourceFileRoot<ExtensionDeclSyntax>,
//     nestedRequests: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>>
//   )
//   case batchRequest(requests: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>>)
//
//   // private(set) var singleRequest: SourceFileRoot<ExtensionDeclSyntax>?
//   // private(set) var batchBinding: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>>
// }
//
// extension Optional where Wrapped == ExtensionBindingState {
//   /// Marks that we'll start binding the given extension and returns `true` if
//   /// possible. Returns `false` if we already have binding requests underway.
//   fileprivate mutating func attemptToStartBindingSingle(extensionDecl: SourceFileRoot<ExtensionDeclSyntax>) -> Bool {
//     switch self {
//     case nil:
//       // No request underway; just add us
//       self = ExtensionBindingState.singleRequest(currentRequest: extensionDecl, nestedRequests: [])
//       return true
//     case
//       // We're processing a single different request with no
//       ExtensionBindingState.singleRequest(currentRequest: _, nestedRequests: [])?,
//       //
//       ExtensionBindingState.singleRequest(currentRequest: extensionDecl, nestedRequests: _)?:
//       return false
//     case :
//       // A single request underway without a batch; don't add
//       return false
//     case ExtensionBindingState.singleRequest(let currentRequest, var nestedRequests)?
//     where currentRequest != extensionDecl /* && nestedRequests != [] */:
//       // A single request underway with a nested request; we add to said request if not already added
//       let shouldBind = nestedRequests.append(extensionDecl).inserted
//       self = ExtensionBindingState.singleRequest(currentRequest: currentRequest, nestedRequests: nestedRequests)
//       return shouldBind
//     case ExtensionBindingState.batchRequest(var requests)?:
//       // If there's a batch request, just add there
//       let shouldBind = requests.append(extensionDecl).inserted
//       self = ExtensionBindingState.batchRequest(requests: requests)
//       return shouldBind
//     }
//   }
// }

// TODO: Add .lookForSupertype, .lookForDynamicMember & implemenet internal/external module lookup

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeQualifier {
  var logText = ""
  var logPrefix = [String]()

  mutating func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // Keep log text separately
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    logText += newLine + "\n"
    // Print new line
    print(newLine)
  }

  mutating func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: inout TypeQualifier) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit {
      precondition(
        logPrefix.count < nestingLimit,
        "Exceeded log nesting limit, suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in ``TypeQualifier``"
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(&self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }

  public typealias Failure = TypeQualifierFailure<
    QualifiedTypeNameGlobalType, ResolvedNominalTypeReference, NominalTypeRef
  >

  let symbolTable: SymbolTable3
  var requestedExtensions: OrderedSet<SourceFileRoot<ExtensionDeclSyntax>> = []
  // var visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>> = []

  let _verbose: Bool
  /// The number of `withLogging` calls we can nest. Useful for debugging infinite loops
  /// that otherwise fill up standard output and become illegible.
  let _logNestingLimit: Int?
  let _checkNominalInCompositionIsClassOrProtocol = true

  public init(symbolTable: SymbolTable3, _verbose: Bool, _logNestingLimit: Int? = nil) {
    self.symbolTable = symbolTable
    self._verbose = _verbose
    self._logNestingLimit = _logNestingLimit
  }

  // TODO: Add per-scope canonicalized cache so that:
  //   func f() {
  //     // === `f`'s scope ===
  //     let a: ProtoA // -> canonical syntax `_::ProtoA`
  //     let aAgain: (ProtoA) // -> same canonical syntax
  //     let aOnceMore: (ProtoA & Any) & ~Escapable // -> same canonical syntax
  //     let aOnceAgain: (~Copyable & Any) & ProtoA // -> same canonical syntax
  //   }
  //   // === top-level scope ===
  //   let maybeDifferentA: ProtoA // -> same canonical syntax, but different scope
  //   NOTE: This is just the syntax; if we want to treat this as a nominal type (e.g.
  //    to store in a property), then we need to consider that `ProtoA` != ``
  public mutating func resolveSyntax(
    typeSyntax: SourceFileRoot<TypeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Resolve syntax `\(typeSyntax.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveSyntax(
          typeSyntax: typeSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  /// Assumes the file is registered; traps otherwise.
  func extractModule<S: SyntaxProtocol>(syntax: SourceFileRoot<S>) -> SymbolTable3.Module {
    guard let module = symbolTable.moduleMap[syntax.fileRoot] else {
      // Should be checked upon entrance in `resolveSyntax`
      fatalError("[SwiftLexicalLookup] Internal error: Unexpectedly found unregistered file: ```\(syntax.fileRoot)```")
    }
    return module
  }

  public mutating func _resolveSyntax(
    typeSyntax: SourceFileRoot<TypeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Ensure we're not forming a cycle
    if let existingSyntaxIndex = visitedTypeSyntax.firstIndex(of: typeSyntax) {
      // We might have valid references before the actual cycle; chop those off
      // to isolate the cycle.
      //
      // E.g.:
      //   typealias A = B
      //   typealias B = A
      //   func f(_: A) // <- Lookup here
      // Starting from `A`, `visitedTypeSyntax` would be:
      //   [
      //     A // from f(_: A),
      //     B // from typealias A = B
      //     A // from typealias B = A
      //   ]
      // And we isolate to the cycle [B, A]
      let isolatedCycle = Array(visitedTypeSyntax[existingSyntaxIndex...])
      return .failure(Failure.cyclicalTypeReference(cycle: isolatedCycle.map(\.node)))
    }
    // // Record this type syntax for cycle detection
    // visitedTypeSyntax.append(typeSyntax)
    // defer { visitedTypeSyntax.remove(typeSyntax) }
    // Append this type syntax
    var visitedTypeSyntax = visitedTypeSyntax
    visitedTypeSyntax.append(typeSyntax)

    // We assert the file root is registered in the symbol table.
    guard symbolTable.moduleMap[typeSyntax.fileRoot] != nil else {
      return .failure(Failure.syntaxNotInSymbolTable(typeSyntax.fileRoot))
    }
    // Further, if given `configuredRegions`, ensure the given syntax is active.
    if let configuredRegions = symbolTable.configuredRegions,
      configuredRegions.isActive(typeSyntax.node) != .active
    {
      return .failure(Failure.syntaxInDisabledRegion)
    }

    // Partially resolve the type and handle each case accordingly
    let partialType: Result<PartiallyResolvedType, TypeResolutionFailure> = typeSyntax.partiallyResolve()
    switch partialType {
    case .success(.anyType):
      return Result.success(MemberLookupResult.anyType)
    case .success(.function(let argumentCount)):
      return Result.success(.function(argumentCount: argumentCount))
    case .success(.tuple(let labels)):
      return Result.success(.tuple(labels: labels))
    // case .metatype(of: _):
    //   // // Empty type case
    //   // guard let firstTypeReferenceResult = typeReferenceResults.first else {
    //   //   log("Resolved \(typeSyntax.trimmedDescription) to empty type")
    //   //   return Result.success(.memberResults([]))
    //   // }
    //   return Result.success(MemberLookupResult.memberResults([]))
    case .success(.typeIdentifier(.success(let component))):
      return resolveTypeReference(
        typeComponent: ImplicitTypeReferenceComponent(from: component),
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
    case .success(.member(let baseTypeSyntax, .success(let memberComponent))):
      let baseTypeResult = resolveSyntax(
        typeSyntax: baseTypeSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
      return resolveMember(
        baseType: baseTypeResult,
        typeMember: ImplicitTypeReferenceComponent(from: memberComponent),
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
    case .success(.composition(let childTypes)):
      // TODO: Record assumption that `childTypes` is unique.
      var syntaxToTypes = [
        (
          childSyntax: SourceFileRoot<TypeSyntax>,
          childResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
        )
      ]()
      for childTypeSyntax in childTypes {
        let childResult = resolveSyntax(
          typeSyntax: childTypeSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
        syntaxToTypes.append((childTypeSyntax, childResult))
      }
      return reduceComposition(syntaxToTypes)
    case .failure(let failure):
      return Result.failure(Failure.other(failure))
    case .success(.member(base: _, .failure(let nameFailure))),
      .success(.typeIdentifier(.failure(let nameFailure))):
      return Result.failure(Failure.other(nameFailure))
    }
  }

  func reduceComposition(
    _ syntaxToTypes: [(
      childSyntax: SourceFileRoot<TypeSyntax>,
      childResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
    )]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Collect valid types and failures
    var anyTypeCounter = 0
    var types = [ResolvedNominalTypeReference]()
    var failures = [(TypeSyntax, Failure)]()
    for (childTypeSyntax, childTypeResult) in syntaxToTypes {
      switch childTypeResult {
      // Only nominals are valid in compositions
      // TODO: Diagnose composing metatype but distinguish from `& Any`
      case .success(.memberResults(let nominals)):
        if _checkNominalInCompositionIsClassOrProtocol {
          switch (nominals.count, nominals.first?.mainDecl.kind) {
          // If we have one nominal, check it's a protocol or class.
          // If we have multiple, i.e., a composition, we've already  checked it recursively.
          case (1, .protocolDecl), (1, .classDecl), (2..., _):
            break
          // If we have no nominals, e.g., `Int.Type`, or a single nominal that's not
          // a struct/enum/actor, we throw an error
          default:
            failures.append(
              (
                childSyntax: childTypeSyntax.node,
                childFailure: Failure.cannotComposeNonClassOrProtocol(
                  resolved: .memberResults(nominals)
                )
              )
            )
          }
        }
        types.append(contentsOf: nominals)
      // Tuples/function
      case .success(.function(let argumentCount)):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: Failure.cannotComposeNonClassOrProtocol(
              resolved: .function(argumentCount: argumentCount)
            )
          )
        )
      case .success(.tuple(let labels)):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: Failure.cannotComposeNonClassOrProtocol(
              resolved: .tuple(labels: labels)
            )
          )
        )
      // `Any` doesn't contribute any types but IS valid
      // E.g. `Codable & Any` ✅
      // But: `Codable & Int.Type` ❌
      case .success(.anyType):
        anyTypeCounter += 1
      // Ignore if this particular type didn't contain the type member.
      // E.g.
      //   protocol A { typealias T = Int }
      //   protocol B {}
      //   let ab: (A & B).T // ✅
      case .failure(Failure.noTypeMember):
        continue
      case .failure(let resolutionFailure):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: resolutionFailure
          )
        )
      }
    }

    // Stop even if we only have one failure
    guard failures.isEmpty else {
      return Result.failure(Failure.invalidComposition(failures))
    }

    // We get `anyType` only when all the child types are `any`,
    // and have at least one children.
    //
    // We need to check we have more than one children because,
    // for instance, `Int.Type` returns an empty array which
    // doesn't equal the `Any` type.
    if anyTypeCounter > 0, anyTypeCounter == syntaxToTypes.count {
      return Result.success(MemberLookupResult.anyType)
    }

    return Result.success(MemberLookupResult.memberResults(types))
  }

  /// Resolves the given type reference (an optional module selector +
  /// the type-name identifier) by performing unqualified lookup.
  ///
  /// E.g. The syntax `A & MyModule::B` will issue two `resolveTypeReference`
  /// calls: one for `A` and one for `MyModule::B`. Type members are handled
  /// in other functions.
  ///
  /// Note: We don't resolve generic parameters.
  fileprivate mutating func resolveTypeReference(
    typeComponent: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    return withLogging(
      request: "Type reference `\(typeComponent.debugDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveTypeReference(
          typeComponent: typeComponent,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  /// Implements `resolveTypeReference`
  fileprivate mutating func _resolveTypeReference(
    typeComponent: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Perfom unqualified lookup up to find the base type's declaration
    //
    // e.g.
    //   extension String.UTF8View { <- Resolve
    //     struct A { // <- Resolve
    //       struct B {} // <- Look up here
    //     }
    //   }
    let lookupResults: [UnqualifiedTypeLookupResult]
    if let module = typeComponent.module {
      // Top-level unqualified lookup in external module
      //
      // Top-level means that we look for declarations at the file scope of the
      // external module. For instance:
      //   // MyModule>MyFile.swift
      //   extension Int {
      //     func f() { MyModule::f() } // ❌ Member `f` not imported through `MyModule`
      //   }
      fatalError("Top-level external-module not lookup (while looking up \(module.name))")
      // baseLookupResults = findExternalTopLevelUnqualifiedType(
      //   module: module,
      //   topLevelName: typeName,
      //   fromSyntax: originatingSyntax
      // )
    } else {
      // Scoped unqualified lookup in this module
      lookupResults = typeComponent.introducingSyntax.findUnqualifiedType(
        typeComponent.name,
        configuredRegions: symbolTable.configuredRegions
      )
    }

    log("Lookup results: \(lookupResults)")

    // Find first matching type declaration
    for lookupResult in lookupResults {
      // The enclosing type, and whether to look for the selected member.
      //
      // `lookForSelectedMember` is false if we can return the enclosing type
      // itself; true if we need to perform qualified lookup and return a type
      // member.
      let enclosingTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
      let lookForSelectedMember: Bool

      // TODO: Use withLogging
      logPrefix.append("Trying \(lookupResult._compactDescription(lookedUpName: typeComponent.name))")
      defer { logPrefix.removeLast() }

      switch lookupResult {
      case .lookForType(let typeDecl, let findSelectedMember):
        enclosingTypeResult = resolveTypeDecl(
          typeDecl: typeDecl,
          originatingSyntax: typeComponent.introducingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
        lookForSelectedMember = findSelectedMember
      case .lookForExtension(let extensionDecl, let findSelectedMember):
        // We might have to look inside an extension
        // For instance:
        //   extension Int {
        //     struct A {
        //       typealias B = String
        //     }
        //   }
        //   extension Int {
        //     func f(_: A.B) {} // Look up `A.B` here
        //   }
        // To find `A.B`, we first need to perform unqualified type lookup to find the base `A`
        // and then look for the member chain `.B`.
        // One of the lookup results will be to look for `A` in `extension Int`.
        // The enclosing type is `Swift::Int.(MyFile.swift)::A`. Then, to find `A.B` we'll
        // just append `.A` to the member chain. Hence, we look for `.A.B` in `Swift::Int`
        let extendedNominal = bindExtension(extensionDecl)
        enclosingTypeResult = extendedNominal.map({
          MemberLookupResult.memberResults([ResolvedNominalTypeReference($0)])
        })
        lookForSelectedMember = findSelectedMember
      case .lookForGenericParameters(let extensionDecl):
        // TODO: Implement logging for all unqualified lookup results
        let matchingGenericParameterResult: Result<GenericParameterSyntax?, Failure> = withLogging(
          request: "Generic parameters",
          describe: { result in
            result.map({ $0?.trimmedDescription })._debugDescription
          },
          perform: {
            // Resolve extended type
            let baseType: GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>
            switch $0.bindExtension(extensionDecl) {
            case .success(let type):
              baseType = type
            case .failure(let failure):
              return Result.failure(Failure.invalidBaseType(failure))
            }

            // Get first matching generic parameter
            let matchingGenericParameter = baseType.mainDecl.node.findGenericParameters(
              withName: typeComponent.name
            ).first
            return .success(matchingGenericParameter)
          }
        )

        // Get the generic parameter (continue if we got no generic parameters;
        // forward failures)
        switch matchingGenericParameterResult {
        case .success(_?):
          break
        case .success(nil):
          continue
        case .failure(let failure):
          return .failure(failure)
        }

        // We don't resolve generic parameters (same as ``resolveTypeDecl``).
        enclosingTypeResult = Result.failure(.genericParameterOrAssociatedType)
        lookForSelectedMember = false
      case .lookInModule:
        // TODO: Handle
        continue
      case .lookInImports:
        // TODO: Handle
        continue
      }

      // Whether we have to look for a member or not, we can't succeed without
      // knowing the enclosing type
      let enclosingType: MemberLookupResult<ResolvedNominalTypeReference>
      switch (enclosingTypeResult, lookForSelectedMember) {
      case (.success(let result), _):
        enclosingType = result
      // Continue to next scope if unqualified lookup didn't find the type in this scope
      case (.failure(.noTypeInScope), _):
        continue
      // Return failure directly if we're not looking for the selected member
      case (.failure(let failure), false):
        return Result.failure(failure)
      // Otherwise, wrap in a '.invalidBaseType'
      case (.failure(let failure), true):
        return Result.failure(Failure.invalidBaseType(failure))
      }

      // If we don't have to look for a member, return
      if !lookForSelectedMember { return Result.success(enclosingType) }

      // Look for the member
      let memberTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> = resolveMember(
        baseType: Result.success(enclosingType),
        typeMember: typeComponent,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )

      // Get the type member
      let memberType: MemberLookupResult<ResolvedNominalTypeReference>
      switch memberTypeResult {
      case .success(let result):
        memberType = result
      // Continue like above
      case .failure(.noTypeMember):
        continue
      // Note: `resolveMember` wraps the underlying error in ``Failure.invalidMembers``
      case .failure(let failure):
        return Result.failure(failure)
      }

      return Result.success(memberType)
    }

    // No type matched
    return Result.failure(Failure.noTypeInScope)
  }

  /// Resolve the given type declaration produced by the given `baseTypeDecl`.
  /// This subrequest was initiated by a request to resolve a ``originatingSyntax``.
  ///
  /// This requests explicitly doesn't resolve associated types and generic-parameter
  /// declarations.
  fileprivate mutating func resolveTypeDecl(
    typeDecl: SourceFileRoot<TypeDeclSyntax>,
    originatingSyntax: SourceFileRoot<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Decl \(typeDecl.kind) `\(typeDecl.node.name.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveTypeDecl(
          typeDecl: typeDecl,
          originatingSyntax: originatingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  /// Implements `resolveTypeDecl`
  fileprivate mutating func _resolveTypeDecl(
    typeDecl: SourceFileRoot<TypeDeclSyntax>,
    originatingSyntax: SourceFileRoot<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // We mainly handle nominal types; type aliases are trivially recursive, and we skip
    // associated types and generic parameters
    let nominalDecl: SourceFileRoot<NominalTypeDeclSyntax>
    if let nominalTypeDecl = typeDecl.as(NominalTypeDeclSyntax.self) {
      nominalDecl = nominalTypeDecl
    } else if let typeAlias = typeDecl.as(TypeAliasDeclSyntax.self) {
      let aliasedTypeSyntax = typeAlias.node.initializer.value
      log(
        "Found aliased type `\(aliasedTypeSyntax)`"
      )

      let aliasedResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> = resolveSyntax(
        typeSyntax: typeAlias.initializerValue,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
      // Wrap in a failure unless we're part of a cycle
      switch aliasedResult {
      case .success(let success):
        return Result.success(success)
      case .failure(let failure):
        // If we're part of the cycle, return the cycle
        if let nestedCycle = failure._nestedCycle, nestedCycle.contains(aliasedTypeSyntax) {
          return Result.failure(Failure.cyclicalTypeReference(cycle: nestedCycle))
        }
        // Wrapping the failure indicates the type alias itself isn't the
        // problem; the referenced type is the problem (diagnosed separately).
        return Result.failure(Failure.invalidAliasedType(failure))
      }
    } else { /* else if it's an associated type or generic parameter */
      // No members for generic parameters and associated types
      return Result.failure(Failure.genericParameterOrAssociatedType)
    }

    // Get the type chain
    let typeChainResult: Result<ChainResolution, ChainResolutionFailure> =
      nominalDecl.findTypeChain(symbolTable: symbolTable)
    let typeChain: ChainResolution
    switch typeChainResult {
    case .success(let result):
      typeChain = result
    case .failure(.unregisteredFile):
      // We check that the root is a source file (& registered in the symbol table)
      // at the top of ``resolveSyntax``.
      //
      // TODO: Maybe merge with general-case `extractModule` failure
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly asked to resolve a type declaration whose file isn't registered in the symbol table: ```\(nominalDecl.fileRoot.trimmedDescription)```"
      )
    case .failure(.invalidIdentifier(let invalidIdentifier)):
      // TODO: Decide if this is too granular and we shud have a more general `.invalidContext` instead.
      return .failure(.other(ChainResolutionFailure.invalidIdentifier(invalidIdentifier)))
    }

    switch typeChain {
    case .resolved(let qualifiedTypeName):
      return Result.success(
        MemberLookupResult.memberResults([
          ResolvedNominalTypeReference(
            mainDecl: nominalDecl,
            name: qualifiedTypeName,
            originatingSyntax: originatingSyntax
          )
        ])
      )
    case .partiallyResolved(let partiallyResolvedName):
      // Resolve the base extension and resolve the type chain
      let qualifiedBaseResult = bindExtension(partiallyResolvedName.base)
      // Get the module
      let originatingModule = extractModule(syntax: originatingSyntax)

      // Handle result
      switch qualifiedBaseResult {
      case .success(let resolvedExtendedBaseNominal):
        let resolvedBaseNominal = partiallyResolvedName.resolve(
          resolvedBase: resolvedExtendedBaseNominal,
          originatingSyntax: originatingSyntax,
          originatingModule: originatingModule,
          symbolTable: symbolTable
        )
        return Result.success(
          MemberLookupResult.memberResults([resolvedBaseNominal])
        )
      case .failure(let failure):
        return Result.failure(Failure.invalidBaseType(failure))
      }
    }
  }

  /// Resolves the given member reference of the provided, resolved base type,
  /// recording our dependencies on qualified-lookup queries.
  fileprivate mutating func resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    typeMember: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Member `\(typeMember.debugDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveMember(
        baseType: baseType,
        typeMember: typeMember,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
    }
  }

  /// Implements `resolveMember`
  fileprivate mutating func _resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    typeMember: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Get base type(s), or throw (can't resolve anything without the base)
    let rawBaseType: MemberLookupResult<ResolvedNominalTypeReference>
    switch baseType {
    case .success(let success): rawBaseType = success
    case .failure(let failure): return Result.failure(failure)
    }

    // Extract nominal type or composition thereof
    let baseTypes: [ResolvedNominalTypeReference]
    switch rawBaseType {
    // Accept nominals (count 1) or compositions (> 1)
    case .memberResults(let types) /* where types.count >= 1 */:
      baseTypes = types
    // Nonnominals don't have type members
    //
    // For instance, the following are invalid:
    //   let x: (a: Int, b: Int).a // ❌ 'a' is not a member type of '(a: Swift.Int, b: Swift.Int)'
    //   let y: Int.Type.MyType    // ❌ 'MyType' is not a member type of 'Swift.Int.Type'
    // TODO: Think about a helper for mapping non-member types
    case MemberLookupResult.memberResults([]):
      return Result.failure(Failure.noTypeMember(member: typeMember, in: MemberLookupResult.memberResults([])))
    case MemberLookupResult.anyType:
      return Result.failure(Failure.noTypeMember(member: typeMember, in: MemberLookupResult.anyType))
    case MemberLookupResult.function(let argumentCount):
      return Result.failure(
        Failure.noTypeMember(member: typeMember, in: MemberLookupResult.function(argumentCount: argumentCount))
      )
    case MemberLookupResult.tuple(let labels):
      return Result.failure(Failure.noTypeMember(member: typeMember, in: MemberLookupResult.tuple(labels: labels)))
    }

    // Perform qualified type lookup and mark the dependencies
    //
    // Note: We collect all types and failures.
    //
    // This approach allows the type checker can check if members of
    // compositions actually resolve to the same type. For instance:
    //   protocol A { typealias T = Int }
    //   final class B { typealias T = [String].Index /* i.e. Int */ }
    //   protocol C { typealias T = Int }
    //   typealias ABC = A & B & C
    //   let a: ABC.T // ✅ T resolves to `Int` in both cases
    // Of course, if we change the class' alias to `typealias T = String`,
    // the compiler will complain that `ABC.T` is ambiguous.
    //
    // Also, collecting all failures surfaces all errors at once for better
    // diagnostics.
    var results = [SourceFileRoot<TypeDeclSyntax>: MemberLookupResult<ResolvedNominalTypeReference>]()
    var failures = [(SourceFileRoot<TypeLikeSyntax>, Failure)]()
    var nominalBaseTypes = [NominalTypeRef]()

    for baseType in baseTypes {
      // We'll collect the result, and type syntax
      //
      // We rely on definite initialization to ensure `memberResult` is
      // initialized exactly one, ensuring each member produces exactly one
      // result.
      let memberResult:
        Result<
          (typeDecl: SourceFileRoot<TypeDeclSyntax>, result: MemberLookupResult<ResolvedNominalTypeReference>)?,
          Failure
        >
      defer {
        switch memberResult {
        case Result.success((let memberTypeDecl, let memberResult)?):
          results[memberTypeDecl] = memberResult
        case Result.success(nil):
          // No results; continue in case next one has a result.
          break
        case Result.failure(let failure):
          failures.append((typeMember.introducingSyntax, failure))
        }
      }

      // Bind extensions and construct a nominal type.
      // We ignore failures since they're from non-matching extensions and diagnosed separately
      let nominalBaseType = resolveNominalType(typeReference: baseType)
      nominalBaseTypes.append(nominalBaseType)

      // Perform direct type lookup and mark dependency
      //
      // First, get the module
      let introducingModule = extractModule(syntax: typeMember.introducingSyntax)
      // Look up
      let memberTypeDeclsResult: Result<[SourceFileRoot<TypeDeclSyntax>], SymbolTable3.QualifiedTypeLookupFailure> =
        symbolTable.findMemberType(
          baseType: nominalBaseType,
          memberTypeName: typeMember.name,
          introducingTypeSyntax: typeMember.introducingSyntax,
          introducingModule: introducingModule,
          dependencyTracker: &memberDependencies
        )

      // Handle failures
      let memberTypeDecls: [SourceFileRoot<TypeDeclSyntax>]
      switch memberTypeDeclsResult {
      case .success(let success):
        memberTypeDecls = success
      case .failure(.unregisteredSourceRoot):
        // We check that the root is a source file in the symbol table
        // at the top of ``resolveSyntax``.
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly asked to resolve a type declaration whose root isn't a file or a file not registered in the symbol table."
        )
      case .failure(.lookupFailure(.invalidBase)):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Base type \(nominalBaseType) was unexpectedly invalid."
        )
      }

      // TODO: Remove
      // // Save the dependency
      // //
      // // First, group the decls by extension
      // let dependency = ExtensionBindingResult.Dependency(
      //   baseTypeName: baseType.qualifiedName,
      //   typeMemberName: typeMember.name,
      //   resolvedDecls: memberTypeDecls
      // )
      // log("Recording dependency: \(dependency.debugDescription)")
      // memberDependencies.append(dependency)

      // Process the results
      // 1. Skip this nominal type if it didn't contain said type member.
      //
      //    E.g. In `(Encodable & Collection<Int>).Element`, `Encodable` may not have an `Element`
      // type member.
      guard let firstTypeDecl = memberTypeDecls.first else {
        memberResult = Result.success(nil)
        continue
      }
      // 2. Cannot have multiple type declarations named the same.
      //    E.g.
      //      typealias A = Int
      //      typealias A = Bool
      //      let a: A // ❌ ambiguous
      // TODO: Ensure we're not shadowing; I think
      // we can only shadow type decls from external modules
      guard memberTypeDecls.count == 1 else {
        memberResult = Result.failure(Failure.ambiguousTypeDecl(memberTypeDecls.map(\.node)))
        continue
      }
      // There's just one; use that
      let memberTypeDecl = firstTypeDecl

      // Resolve this type declaration and add it to the results
      memberResult = resolveTypeDecl(
        typeDecl: memberTypeDecl,
        originatingSyntax: typeMember.introducingSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      ).map({ result in Optional((typeDecl: memberTypeDecl, result: result)) })
    }

    // If there are failures, give up.
    //
    // The compiler also gives up. For instance, if we write the following, we
    // only get an error for the alias:
    //   protocol ValidProto { typealias IntAlias = Int }
    //
    //   typealias InvalidAlias = Int.Type.InvalidMember // ❌ No member 'InvalidMember'
    //   typealias Composition = ValidProto & InvalidAlias
    //   let a: Composition.IntAlias = "" // ✅ No errors yet
    // It's only when we use a valid composition that we get an error, e.g.:
    //   typealias Composition = ValidProto & Any
    //   let a: Composition.IntAlias = "" // ❌ Cannot value of type 'String' to specified type 'Int'
    guard failures.isEmpty else {
      return Result.failure(
        Failure.invalidMembers(failures.map({ (typeSyntax, failure) in (typeSyntax.node, failure) }))
      )
    }

    // Diagnose if we get no results
    // E.g. `(Any & Sendable).MyType` yields no results for either `Any.MyType` or
    //   `Sendable.MyType`; hence, `MyType` isn't a member of `Any & Sendable`.
    guard let (_, firstResult) = results.first else {
      return Result.failure(
        Failure.noTypeMember(
          member: typeMember,
          in: MemberLookupResult.memberResults(nominalBaseTypes)
        )
      )
    }
    // TODO: Ensure we're properly shadowing and not giving false-positive errors
    guard results.count == 1 else {
      return Result.failure(
        Failure.ambiguousTypeDecl(results.keys.map(\.node))
      )
    }

    return Result.success(firstResult)
  }
}

// MARK: Extension Binding

extension TypeQualifier {
  /// Resolve the given type syntax from an extension declaration
  /// to a single nominal type.
  ///
  /// Note that we only diagnose extending tuples/functions and compositions
  /// (e.g. `Codable = Encodable & Decodable`). However, we don't diagnose
  /// things like extending an existential (e.g. `extension any Collection`).
  fileprivate mutating func _resolveExtendedTypeSyntax(
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    memberDependencies: inout DependencyTracker
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    withLogging(
      request: "Extended type syntax `\(extensionDecl.extendedType.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveExtendedTypeSyntax(extensionDecl: extensionDecl, memberDependencies: &memberDependencies)
      }
    )
  }

  /// Implements `resolveExtendedTypeSyntax`
  fileprivate mutating func __resolveExtendedTypeSyntax(
    extensionDecl: SourceFileRoot<ExtensionDeclSyntax>,
    memberDependencies: inout DependencyTracker
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    // TODO: Make comment more concise
    //
    // Note: We pass `visitedTypeSyntax==[]` because extended type syntax can't
    // form cycles. That's because, we can't reference extension declarations
    // since they're implicitly part of the type. By contrast, type aliases
    // can indirectly refer to themselves, e.g.:
    //   typealias A = B // Defines itself as `B`, which defines itself as `A`
    //   typealias B = A
    // This self-reference isn't possible with extensions since we can't
    // reference the extended type syntax. The only way we can (almost) refer
    // to the extended type syntax is with `Self`; however, `Self` actually
    // just binds the extension and then looks at the resolved type.
    let resolvedTypeResult = resolveSyntax(
      typeSyntax: extensionDecl.extendedType,
      memberDependencies: &memberDependencies,
      visitedTypeSyntax: []
    )
    // Throw if syntax resolution fails
    let resolvedType: MemberLookupResult<ResolvedNominalTypeReference>
    switch resolvedTypeResult {
    case .success(let result):
      resolvedType = result
    case .failure(let failure):
      return .failure(failure)
    }

    // Extract a nominal type
    switch resolvedType {
    case .memberResults(let results):
      // We're expecting exactly one nominal type.
      // No types means non-nominal, e.g., `Int.Type` and compositions are
      // also not extensible, e.g., `Encodable & Decodable`.
      guard let firstNominalType = results.first, results.count == 1 else {
        return .failure(.cannotExtendNonNominal(nonnominal: resolvedType))
      }
      return .success(firstNominalType)
    // Functions/tuples/`Any` aren't nominal
    case .function, .tuple, .anyType:
      return .failure(.cannotExtendNonNominal(nonnominal: resolvedType))
    }
  }

  /// Tries to bind the given extension; returns `nil` or failure.
  ///
  /// If no binding request is already underway, the given extensions
  /// should be admitted to the graph after this call. Otherwise, the provided
  /// extensions are queued up for the existing request to handle.
  @_spi(_QualifiedLookupTests) public mutating func admitExtensions(
    _ extensionDecls: [SourceFileRoot<ExtensionDeclSyntax>]
  ) {
    withLogging(
      request: "Admitting extensions: \(extensionDecls.map(\._memberlessDescription))",
      describe: { _ in "" },
      perform: {
        $0._admitExtensions(extensionDecls)
      }
    )
  }

  /// Implements `admitExtensions`
  fileprivate mutating func _admitExtensions(
    _ extensionDecls: [SourceFileRoot<ExtensionDeclSyntax>]
  ) {
    // Whether we will bind the requested extensions or we'll delegate to an
    // ongoing request
    let willBindRequests = self.requestedExtensions.isEmpty

    // Register the extensions to be processed.
    //
    // Note: `requestedExtensions` is an `OrderedSet` so we don't introduce
    // duplicates.
    self.requestedExtensions.append(contentsOf: extensionDecls)

    // Ensure there's no binding request underway
    guard willBindRequests else {
      // This request will be handled after the current binding (see
      // `admitExtensions` docstring).
      // TODO: Is this the right failure type?
      return
    }

    // Handle all binding requests
    //
    // We use a while loop since a single binding request may generate more
    // binding requests. E.g., Say we want to resolve:
    // ```swift
    // struct A {}
    // extension A.B {
    //   func f(_: Self) {} // <- Look up here
    // }
    // extension A { struct B {} }
    // ```
    // Then, `Self` will only try to bind `extension A.B` but to resolve `A.B`, we
    // need to fully resolve `A` so we also have to bind `extension A`.
    while let extensionDecl = self.requestedExtensions.last {
      // We remove at the end of the iteration because we want nested syntax-resolution
      // requests to see that we're actively trying to bind this extension.
      defer {
        // TODO: Ensure .last and .removeLast are ok (or if we should do a queue-like approach.
        let poppedExtension = self.requestedExtensions.removeLast()
        assert(
          poppedExtension == extensionDecl,
          "[SwiftLexicalLookup] Internal error: Unexpectedly found different invalidated extension when popping."
        )
      }

      // The result can change after binding more extensions; ignore for now.
      _ = _bindRequestedExtension(extensionDecl)
    }

    assert(
      self.requestedExtensions.isEmpty,
      "[SwiftLexicalLookup] Internal error: Requested extensions still not admitted after `bindExtensions`."
    )
  }

  /// Admits the given extension added to `self.requestedExtensions`. Only
  /// `bindExtensions` should call this method.
  ///
  /// Handles extensions already admitted to the graph, and fixes
  /// invalidated extensions.
  ///
  /// - Precondition: `extensionDecl` must be in `self.requestedExtensions`
  private mutating func _bindRequestedExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>, Failure> {
    withLogging(
      request: "Binding `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription
    ) {
      $0.__bindRequestedExtension(extensionDecl)
    }
  }

  /// Implements `bindRequestedExtension`
  ///
  /// - Precondition: `extensionDecl` must be in `self.requestedExtensions`
  /// FIXME: Make _bindExtension handle other generated requests;
  /// e.g. if we're resolving `extension A.B {}`, we will prob have to fully resolve `A`.
  private mutating func __bindRequestedExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>, Failure> {
    // Uphold invariant
    assert(
      self.requestedExtensions.contains(extensionDecl),
      "[SwiftLexicalLookup] Internal error: Called `bindRequestedExtension` without first adding to `self.requestedExtensions`."
    )

    func mapToNominalTypeReference(
      _ typeInfo: (qualifiedName: QualifiedTypeNameGlobalType, mainDecl: SourceFileRoot<NominalTypeDeclSyntax>)
    ) -> GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType> {
      GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>(
        mainDecl: typeInfo.mainDecl,
        name: typeInfo.qualifiedName,
        originatingSyntax: SourceFileRoot<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    }

    // Return saved result if the extension was already admitted to the graph
    // TODO: Should this ever happen?
    if let existingResolution = symbolTable.dependencyGraph.getExtensionResolvedType(extensionDecl) {
      return existingResolution.map(mapToNominalTypeReference(_:))
    }

    // TODO: Extension binding uses its own visitedTypeSyntax; also pass `visitedTypeSyntax` to every function.

    // === Resolve Extension ===

    // Resolve the extended type, tracking dependencies
    //
    // Note: We don't add these dependencies to our dependencies since
    // this is considered a completely separate type resolution. We
    // track these dependencies in the symbol table's corresponding
    // extension state.
    var extensionDependencies = DependencyTracker()
    let extendedTypeResult = _resolveExtendedTypeSyntax(
      extensionDecl: extensionDecl,
      memberDependencies: &extensionDependencies
    )

    // Register in the symbol table to get invalidated extensions
    let bindingResult: Result<BindingResult, SymbolTable3.ExtensionBindingFailure>
    bindingResult = symbolTable.bindExtensionAndRegisterExtended(
      extensionDecl,
      // Only get the name
      to: extendedTypeResult.map({ extendedTypeReference in
        // FIXME: We should actually make this into a TypeQualifier error, i.e., at `resolveExtendedTypeSyntax`
        // check the extension's scope is SourceFileSyntax or throw `nonGlobalExtension`
        // e.g. func f() {
        //        extension A {
        //          func f(_: Self) {} // <- Lookup up here
        //        }
        //      }
        guard case .topLevel(let extendedGlobalName) = extendedTypeReference.qualifiedName else {
          fatalError(
            "[SwiftLexicalLookup] Internal error: Unexpectedly resolved extension to local type \(extendedTypeReference.qualifiedName)"
          )
        }
        return (extendedGlobalName, extendedTypeReference.mainDecl)
      }),
      dependencies: extensionDependencies
    )

    // Extract the invalidated extensions or handle failures
    let (resolvedType, invalidatedExtensions): BindingResult
    switch bindingResult {
    case .success(let success):
      (resolvedType, invalidatedExtensions) = success
    case .failure(let failure):
      // Ensure we handle future failure types
      switch failure {
      case .nonRegisteredSyntaxRoot:
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly not in symbol table"
        )
      case .admissionFailure(.cannotReadmit(let existingState)):
        // We check there's no state at the start of the function

        // TODO: Remove
        // print(
        //   "[SwiftLexicalLookup] Internal error: Tried to readmit `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
        // )
        // return symbolTable.dependencyGraph.getExtensionResolvedType(extensionDecl)!.map(mapToNominalTypeReference(_:))
        fatalError(
          "[SwiftLexicalLookup] Internal error: Tried to readmit `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
        )
      case .admissionFailure(.invalidDependencyExtension(let extensionState)):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly has wrong dependency; state \(extensionState.debugDescription)."
        )
      }
    }
    log(
      "Resolved to \(extendedTypeResult); Dependencies: \(extensionDependencies.dependencies.map(\.debugDescription)); Invalidated: \(invalidatedExtensions.map(\ExtensionState.extensionDecl._memberlessDescription))"
    )

    // TODO: Does this even work?
    self.requestedExtensions.append(contentsOf: invalidatedExtensions.map(\.extensionDecl))
    return resolvedType.map(mapToNominalTypeReference(_:))

    // FIXME: Get rid of below code or sm.
    //
    // // === Fix Invalidated Extensions ===
    // //
    // // We use a for loop because fixing one invalidated extension may invalidate
    // // other extensions.
    // var invalidatedExtensionsStack = invalidatedExtensions
    // // TODO: Pull out invalidateExtension into its own function
    // while let invalidatedExtension = invalidatedExtensionsStack.first {
    //   //  TODO: Could we straight-up pop during the while let loop-condition.
    //   defer {
    //     let poppedExtension = invalidatedExtensionsStack.removeFirst()
    //     assert(
    //       poppedExtension.extensionDecl == invalidatedExtension.extensionDecl,
    //       "[SwiftLexicalLookup] Internal error: Unexpectedly found different invalidated extension when popping."
    //     )
    //   }
    //
    //   self.requestedExtensions.append(invalidatedExtension.extensionDecl)
    //   _ = _bindExtension(invalidatedExtension.extensionDecl)
    //   let removed = self.requestedExtensions.removeLast()
    //   assert(
    //     removed == invalidatedExtension.extensionDecl,
    //     "[SwiftLexicalLookup] Internal error: Unexpectedly found different invalidated extension when popping."
    //   )
    //   continue
    //
    //   // TODO: Remove following
    //
    //   // Re-resolve with dependency tracking
    //   log("Recomputing invalidated `\(invalidatedExtension.extensionDecl._memberlessDescription)`")
    //   let (_, _, nestedInvalidatedExtensions) = withLogging(
    //     request: "Fixing invalidated `\(invalidatedExtension.extensionDecl._memberlessDescription)`",
    //     describe: {
    //       (
    //         extendedTypeResult: Result<ResolvedNominalTypeReference, Failure>,
    //         extensionDependencies: DependencyTracker,
    //         invalidatedExtensions: InvalidatedExtensions
    //       ) in
    //       "\(extendedTypeResult._debugDescription); Dependencies: \(extensionDependencies.dependencies.map(\.debugDescription))"
    //     },
    //     perform: {
    //       var extensionDependencies = DependencyTracker()
    //       let extendedTypeResult: Result<ResolvedNominalTypeReference, Failure> = $0._resolveExtendedTypeSyntax(
    //         extensionDecl: invalidatedExtension.extensionDecl,
    //         memberDependencies: &extensionDependencies
    //       )
    //
    //       // Register in the symbol table
    //       let nestedBindingResult =
    //         $0.symbolTable.fixInvalidatedExtension(
    //           invalidatedExtension.extensionDecl,
    //           // Only get the name
    //           to: extendedTypeResult.map({ (typeReference: ResolvedNominalTypeReference) in
    //             // FIXME: This assert shouldn't exist; extension decl should just give us a global type.
    //             guard case .topLevel(let extendedGlobalName) = typeReference.qualifiedName else {
    //               fatalError(
    //                 "[SwiftLexicalLookup] Internal error: Unexpectedly resolved extension to local type \(typeReference.qualifiedName)"
    //               )
    //             }
    //             return (extendedGlobalName, typeReference.mainDecl)
    //           }),
    //           dependencies: extensionDependencies
    //         ) as Result<BindingResult, SymbolTable3.ExtensionBindingFailure>
    //
    //       // Return results or handle failures
    //       switch nestedBindingResult {
    //       case .success(let success):
    //         return (extendedTypeResult, extensionDependencies, success.invalidatedExtensions)
    //       case .failure(let failure):
    //         // Ensure we handle future failure types
    //         switch failure {
    //         case .nonRegisteredSyntaxRoot:
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly not in symbol table"
    //           )
    //         case .admissionFailure(.cannotReadmit(let existingState)):
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Tried to fix admitted extension `\(extensionDecl._memberlessDescription)`; old state \(existingState)."
    //           )
    //         case .admissionFailure(.invalidDependencyExtension(let extensionState)):
    //           fatalError(
    //             "[SwiftLexicalLookup] Internal error: Extension \(extensionDecl._memberlessDescription) unexpectedly has wrong dependency; state \(extensionState.debugDescription)."
    //           )
    //         }
    //       }
    //     }
    //   )
    //
    //   // Enqueue invalidated extensions
    //   invalidatedExtensionsStack.append(contentsOf: nestedInvalidatedExtensions)
    // }
    //
    // return resolvedType.map(mapToNominalTypeReference(_:))
  }
}

// MARK: Resolve Extension / Nominal

extension TypeQualifier {
  /// Resolve a qualified-type name to a nominal type with all accessible
  /// extensions bound.
  @_spi(_QualifiedLookupTests) public mutating func resolveNominalType(
    typeReference: ResolvedNominalTypeReference
  ) -> NominalTypeRef {
    withLogging(
      request: "Extended nominal`\(typeReference.qualifiedName)`",
      describe: \.debugDescription,
      perform: {
        $0._resolveNominalType(typeReference: typeReference)
      }
    )
  }

  /// Implements `resolveNominalType`
  fileprivate mutating func _resolveNominalType(
    typeReference: ResolvedNominalTypeReference
  ) -> NominalTypeRef {
    // TODO: See if we actually need to check for accessible extensions even if
    // there's an ongoing request.
    // TODO: At least find a way to cache available extensions. (E.g. don't
    // recalculate accessible extensions if ongoing request targetted the same file)

    // There are three paths:
    // 1. The symbol table hasn't resolved the extensions accessibles from this source file
    //    We need to bind all said extensions
    // 2. We're already binding extensions by servicing another request
    // 3. The symbol table has a cached/resolved version

    // Get the nominal type from the symbol table (or register accordingly)
    let currentNominalResult: Result<NominalTypeRef, TypeDependencyGraph.NominalRegistrationFailure> =
      symbolTable.registerNominalTypeReference(
        qualifiedName: typeReference.qualifiedName,
        mainDecl: typeReference.mainDecl
      )
    // Handle reregistration (we should diagnose reregistrations and not save them in the table)
    let currentNominal: NominalTypeRef
    switch currentNominalResult {
    case .success(let success):
      currentNominal = success
    // TODO: Remove if we don't handle this failure
    //
    // case .failure(.parentNotRegistered(let parentName)):
    //   fatalError(
    //     "[SwiftLexicalLookup] Internal error: Tried to register \(typeReference.qualifiedName.debugDescription) but the parent \(parentName.debugDescription) is unexpectedly unregistered."
    //   )
    // TODO: Remove old failure
    //
    // case .failure(.unexpectedReregistration(existingMainDecl: _)):
    //   fatalError(
    //     "[SwiftLexicalLookup] Internal error: Unexpectedly found nominal type `\(typeReference.qualifiedName)` registered under a different main declaration."
    //   )
    }

    // Skip extension binding for local declarations.
    //
    // For instance, there's no way to extend `A` in `func f() { struct A {} }`
    // since extensions may only be declared at the top level.
    guard case .topLevel(let qualifiedGlobalName) = typeReference.qualifiedName else { return currentNominal }

    // TODO: Remove
    //
    // // If there's an existing request, it will take care of the rest
    // guard self.requestedExtensions.isEmpty else {
    //   log("Binding request already underway; returning")
    //
    //   // Even if not all extensions are loaded, we queued up all extensions that
    //   // need to be processed, so we'll get invalidated appropriately.
    //   return currentNominal
    // }

    // Find all the extensions we need to bind
    let accessibleExtensions = symbolTable.findAllExtensions(
      accessibleFrom: typeReference.originatingSyntax.fileRoot,
      configuredRegions: symbolTable.configuredRegions
    )
    log("Accessible extensions: \(accessibleExtensions.map(\._memberlessDescription))")

    // Queue up the extensions that need binding
    let unadmittedExtensions: [SourceFileRoot<ExtensionDeclSyntax>] = accessibleExtensions.filter({
      accessibleExtension in
      !symbolTable.unresolvedExtensions[accessibleExtension.fileRoot, default: []].contains(accessibleExtension)
    })

    // Return if no extensions are available
    guard !unadmittedExtensions.isEmpty else {
      log("No extensions to bind.")
      return currentNominal
    }

    admitExtensions(unadmittedExtensions)

    // After binding all extensions, get the new nominal type
    guard let finalizedNominalRef = symbolTable.getNominalTypeReference(name: qualifiedGlobalName) else {
      // We checked the nominal type is registered at the start.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Nominal type unexpectedly removed from symbol table after binding extensions."
      )
    }

    return finalizedNominalRef
  }

  @_spi(_QualifiedLookupTests) public mutating func bindExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>, Failure> {
    withLogging(
      request: "Binding extension `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._bindExtension(extensionDecl)
      }
    )
  }

  fileprivate mutating func _bindExtension(
    _ extensionDecl: SourceFileRoot<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>, Failure> {
    admitExtensions([extensionDecl])

    // If there's not an existing extension-binding request, the extension
    // should be admitted. Otherwise, return a failure for now.
    guard let boundTypeResult = symbolTable.dependencyGraph.getExtensionResolvedType(extensionDecl) else {
      // TODO: Remove
      // fatalError(
      //   "[SwiftLexicalLookup] Internal error: Nominal type unexpectedly removed from symbol table after binding extensions."
      // )

      // The extension graph tracks dependencies so this result should be
      // invalidated and fixed after the primary extension-binding request
      // completes.
      return .failure(Failure.extensionNotBoundYet)
    }

    return boundTypeResult.map({ typeInfo in
      GenericResolvedNominalTypeReference<QualifiedTypeNameGlobalType>(
        mainDecl: typeInfo.mainDecl,
        name: typeInfo.qualifiedName,
        originatingSyntax: SourceFileRoot<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }
}
