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

// TODO: Remove Glibc import
@preconcurrency import Glibc
import SwiftIfConfig
import SwiftSyntax

extension Result {
  var _success: Success? {
    switch self {
    case .success(let success): return success
    case .failure: return nil
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

/// The minimal defining components of a nominal type: the main declaration and the qualified name.
/// Unlike ``NominalType``, doesn't include extensions.
///
/// TODO: Make into `NominalTypeRef` + `TypeLikeSyntax`
@_spi(_QualifiedLookup)
public struct GenericResolvedNominalTypeReference<TypeRef: Sendable & Hashable & CustomDebugStringConvertible>:
  Sendable, CustomDebugStringConvertible
{
  // public let mainDecl: Attached<NominalTypeDeclSyntax>
  // public let qualifiedName: TypeName
  public let nominalTypeRef: TypeRef
  // The main declaration helps in two ways:
  // 1. To detect if we have a class/protocol for compositions
  // 2. To find generic parameters
  public let mainDecl: Attached<NominalTypeDeclSyntax>
  public let originatingSyntax: Attached<TypeLikeSyntax>

  @_spi(_QualifiedLookupTests) public init(
    // _mainDecl mainDecl: Attached<NominalTypeDeclSyntax>,
    // name: TypeName,
    nominalTypeRef: TypeRef,
    mainDecl: Attached<NominalTypeDeclSyntax>,
    originatingSyntax: Attached<TypeLikeSyntax>,
  ) {
    // self.mainDecl = mainDecl
    // self.qualifiedName = name
    self.nominalTypeRef = nominalTypeRef
    self.mainDecl = mainDecl
    self.originatingSyntax = originatingSyntax
  }

  public var debugDescription: String {
    "\(nominalTypeRef.debugDescription) [\(mainDecl.kind)]"
  }
}

@_spi(_QualifiedLookup) public typealias ResolvedNominalTypeReference = GenericResolvedNominalTypeReference<
  NominalTypeRef
>

extension GenericResolvedNominalTypeReference where TypeRef == NominalTypeRef {
  var _succinctDescription: String {
    switch nominalTypeRef.storage {
    case .global(let global):
      return global.name.debugDescription
    case .local(let nominalDecl):
      return nominalDecl._memberlessDescription
    }
  }
}

extension ResolvedNominalTypeReference {
  init(globalTypeReference: GenericResolvedNominalTypeReference<GlobalNominalTypeRef>) {
    // self.init(
    //   _mainDecl: globalTypeReference.mainDecl,
    //   name: TypeName.global(globalTypeReference.qualifiedName),
    //   originatingSyntax: globalTypeReference.originatingSyntax
    // )
    self.init(
      nominalTypeRef: NominalTypeRef(globalReference: globalTypeReference.nominalTypeRef),
      mainDecl: globalTypeReference.mainDecl,
      originatingSyntax: globalTypeReference.originatingSyntax
    )
  }
}

@_spi(_QualifiedLookup)
public indirect enum TypeResolutionFailure<TypeName: Sendable, MinimalNominal: Sendable, ExtendedNominal: Sendable>:
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

  /// We can only extend structs/enums/classes/actors/protocols
  ///
  /// I.e. We can't extend tuples, functions, protocol compositions, metatypes, etc.
  case cannotExtendNonNominal(nonnominal: MemberLookupResult<MinimalNominal>)
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

extension TypeResolutionFailure where TypeName: CustomDebugStringConvertible {
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
    case .extensionNotAtFileScope(let extensionDecl):
      return ".extensionNotAtFileScope(extensionDecl: `\(extensionDecl._memberlessDescription)`)"
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

extension TypeResolutionFailure:
  CustomDebugStringConvertible
where
  TypeName: CustomDebugStringConvertible,
  MinimalNominal: CustomDebugStringConvertible,
  ExtendedNominal: CustomDebugStringConvertible
{
  func _describe(describeTypeName: (TypeName) -> String) -> String {
    _describeDebug(
      resolveMininalNominal: \.debugDescription,
      resolveExtendedNominal: \.debugDescription
    )
  }

  public var debugDescription: String {
    _describe(describeTypeName: \.debugDescription)
  }
}

extension TypeResolutionFailure {
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
      .cannotExtendNonNominal(nonnominal: _), .extensionNotAtFileScope(extensionDecl: _),
      .other(_), .genericParameterOrAssociatedType, .ambiguousTypeDecl(_), .syntaxNotInSymbolTable,
      .syntaxInDisabledRegion, .extensionNotBoundYet,
      // Extension cycles are distinct
      .cyclicalExtensionDependency(_),
      // If the above case don't directly contain a cycle
      .invalidAliasedType(_), .invalidBaseType(_):
      return nil

    // Only return a nested cycle if we have exactly one result.
    case .invalidMembers(let nestedFailures):
      guard
        case (_, TypeResolutionFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    case .invalidComposition(let nestedFailures):
      guard
        case (_, TypeResolutionFailure.cyclicalTypeReference(let nestedCycle))? = nestedFailures.first,
        nestedFailures.count == 1
      else { return nil }
      return nestedCycle
    }
  }
}

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeResolver {
  // var logText = ""
  var logPrefix = [String]()

  mutating func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // Keep log text separately
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    // logText += newLine + "\n"
    // Print new line
    print(newLine)
    // TODO: Remove
    fflush(stdout)
  }

  mutating func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: inout TypeResolver) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit, logPrefix.count >= nestingLimit {
      fflush(stdout)
      fatalError(
        "Exceeded log nesting limit of \(nestingLimit), suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in `TypeQualifier`."
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(&self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }

  public typealias Failure = TypeResolutionFailure<
    GlobalTypeName, ResolvedNominalTypeReference, NominalTypeRef
  >

  let symbolTable: SymbolTable
  // var visitedTypeSyntax: OrderedSet<SourceFileRoot<TypeSyntax>> = []

  let _verbose: Bool
  /// The number of `withLogging` calls we can nest. Useful for debugging infinite loops
  /// that otherwise fill up standard output and become illegible.
  let _logNestingLimit: Int?
  let _checkNominalInCompositionIsClassOrProtocol = true

  public init(symbolTable: SymbolTable, _verbose: Bool, _logNestingLimit: Int? = nil) {
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
    typeSyntax: Attached<TypeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
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
  func extractModule<S: SyntaxProtocol>(syntax: Attached<S>) -> ModuleName {
    guard let module = symbolTable.moduleMap[syntax.fileRoot] else {
      // Should be checked upon entrance in `resolveSyntax`
      fatalError("[SwiftLexicalLookup] Internal error: Unexpectedly found unregistered file: ```\(syntax.fileRoot)```")
    }
    return module
  }

  /// Sorts

  public mutating func _resolveSyntax(
    typeSyntax: Attached<TypeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
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
    let partialType: Result<PartiallyResolvedType, PartialTypeResolutionFailure> = typeSyntax.partiallyResolve()
    switch partialType {
    case .success(.anyType):
      return Result.success(MemberLookupResult.anyType)
    case .success(.tuple(let labels)):
      return Result.success(.tuple(labels: labels))
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
          childSyntax: Attached<TypeSyntax>,
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
      childSyntax: Attached<TypeSyntax>,
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
        // Append types we don't already have
        for nominal in nominals {
          // This search takes linear time but we don't expect compositions to
          // reference a large number of nominal types.
          guard !types.contains(where: { $0.mainDecl == nominal.mainDecl }) else { continue }
          types.append(nominal)
        }
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
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
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

  enum DeclContext {
    case declGroup(Attached<DeclGroupSyntaxType>)
    case codeBlock(Attached<CodeBlockItemListSyntax>)
  }
  func _describeDeclContext(_ declContext: DeclContext) -> String {
    switch declContext {
    case .declGroup(let declGroup):
      return declGroup._memberlessDescription
    case .codeBlock(let codeBlock):
      guard let sourceFileScope = codeBlock.parent?.as(SourceFileSyntax.self) else {
        // `codeBlock.parent` shouldn't be `nil` in a valid program because of `Attached<_>`
        return "<\(codeBlock.parent?.parent?.kind ?? .missing)>"
      }
      return symbolTable.debugFileMap.describeFileID(sourceFileScope.node.id)
    }
  }

  /// Implements `resolveTypeReference`
  fileprivate mutating func _resolveTypeReference(
    typeComponent: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
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

    log("Lookup results: \(lookupResults.map(\.debugDescription))")

    // Find first matching type declaration
    for lookupResult: UnqualifiedTypeLookupResult in lookupResults {
      // The enclosing type, and whether to look for the selected member.
      //
      // `lookForSelectedMember` is false if we can return the enclosing type
      // itself; true if we need to perform qualified lookup and return a type
      // member.
      let enclosingTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
      let lookForSelectedMember: Bool

      // TODO: Use withLogging
      logPrefix.append("Trying \(lookupResult._describeSuccinctly(lookedUpName: typeComponent.name))")
      defer { logPrefix.removeLast() }

      switch lookupResult {
      case .nonNestedTypeDecl(let typeDecl, redeclarations: _, let parentCodeBlock):
        enclosingTypeResult = resolveTypeDecl(
          typeDecl: typeDecl,
          declContext: DeclContext.codeBlock(parentCodeBlock),
          originatingSyntax: typeComponent.introducingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
        lookForSelectedMember = false
      case .lookForMember(let declGroupParent, let lookForSelf):
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
        enclosingTypeResult = resolveDeclGroup(
          declGroup: declGroupParent,
          originatingSyntax: typeComponent.introducingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        ).map({ MemberLookupResult.memberResults([$0]) })
        // To find the member
        lookForSelectedMember = !lookForSelf

      case .genericParameters(firstMatch: _, redeclarations: _, genericClause: _):
        // TODO: Should we throw if we get redeclarations?
        // (do the same in `.lookForGenericParameters`)
        return .failure(.genericParameterOrAssociatedType)

      case .lookForGenericParameters(let extensionDecl):
        // TODO: Implement logging for all unqualified lookup results
        let matchingGenericParameterResult: Result<GenericParameterSyntax?, Failure> = withLogging(
          request: "Generic parameters",
          describe: { result in
            result.map({ $0?.trimmedDescription })._debugDescription
          },
          perform: {
            // Resolve extended type
            let baseType: GenericResolvedNominalTypeReference<GlobalNominalTypeRef>
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

  /// Helper for `resolveDeclGroup`
  fileprivate func _findDeclContext(ofDeclGroup node: Attached<DeclGroupSyntaxType>) -> DeclContext {
    var currentAncestor: Attached<Syntax>? = node.parent
    while let ancestor = currentAncestor {
      if let codeBlockScope = ancestor.as(CodeBlockItemListSyntax.self) {
        return DeclContext.codeBlock(codeBlockScope)
      } else if let declGroupScope = ancestor.as(DeclGroupSyntaxType.self) {
        return DeclContext.declGroup(declGroupScope)
      } else {
        currentAncestor = ancestor.parent
      }
    }
    // Shouldn't happen because `Attached<DeclGroupSyntaxType>` has
    // a `SourceFileSyntax` root that we should have run into.
    fatalError(
      "[SwiftLexicalLookup] Internal error: Unexpectedly didn't find declaration context of attached decl group `\(node._memberlessDescription)`."
    )
  }

  fileprivate mutating func resolveDeclGroup(
    declGroup: Attached<DeclGroupSyntaxType>,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    withLogging(
      request: "Decl group `\(declGroup._memberlessDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveDeclGroup(
          declGroup: declGroup,
          originatingSyntax: originatingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  fileprivate mutating func _resolveDeclGroup(
    declGroup: Attached<DeclGroupSyntaxType>,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    let declContext: DeclContext = _findDeclContext(ofDeclGroup: declGroup)

    log("Found decl context `\(_describeDeclContext(declContext))` containing `\(declGroup._memberlessDescription)`")

    if let nominalTypeDecl = declGroup.as(NominalTypeDeclSyntax.self) {
      return resolveNominalTypeDecl(
        nominalDecl: nominalTypeDecl,
        declContext: declContext,
        originatingSyntax: originatingSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )

    } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
      // TODO: Produce accurate error; move check to `bindExtension`
      guard
        case .codeBlock(let fileStatements) = declContext,
        fileStatements.node == extensionDecl.fileRoot.statements
      else {
        return .failure(Failure.extensionNotBoundYet)
      }
      // Wrap the global reference
      return bindExtension(extensionDecl).map(ResolvedNominalTypeReference.init(globalTypeReference:))
    } else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Expected decl group to be either a nominal type or extension decl; instead found \(declGroup.kind)."
      )
    }
  }

  /// Resolve the given type declaration produced by the given `baseTypeDecl`.
  /// This subrequest was initiated by a request to resolve a ``originatingSyntax``.
  ///
  /// This requests explicitly doesn't resolve associated types and generic-parameter
  /// declarations.
  fileprivate mutating func resolveTypeDecl(
    typeDecl: Attached<TypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Decl \(typeDecl.kind) `\(typeDecl.node.name.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveTypeDecl(
          typeDecl: typeDecl,
          declContext: declContext,
          originatingSyntax: originatingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  /// Implements `resolveTypeDecl`
  fileprivate mutating func _resolveTypeDecl(
    typeDecl: Attached<TypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // We mainly handle nominal types; type aliases are trivially recursive, and we skip
    // associated types and generic parameters
    if let nominalTypeDecl = typeDecl.as(NominalTypeDeclSyntax.self) {
      // Resolve the main nominal-type decl and wrap it in `MemberLookupResult.memberResults`
      return resolveNominalTypeDecl(
        nominalDecl: nominalTypeDecl,
        declContext: declContext,
        originatingSyntax: originatingSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      ).map({ MemberLookupResult.memberResults([$0]) })
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
  }

  fileprivate mutating func resolveNominalTypeDecl(
    nominalDecl: Attached<NominalTypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    withLogging(
      request: "Nominal `\(nominalDecl._memberlessDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveNominalTypeDecl(
          nominalDecl: nominalDecl,
          declContext: declContext,
          originatingSyntax: originatingSyntax,
          memberDependencies: &memberDependencies,
          visitedTypeSyntax: visitedTypeSyntax
        )
      }
    )
  }

  fileprivate mutating func _resolveNominalTypeDecl(
    nominalDecl: Attached<NominalTypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    // TODO: Reenable cache or remove
    // let registeredGlobalName = symbolTable.dependencyGraph.namesToTypes.first(where: { (name, type) in
    //   type.mainDecl.declGroup == nominalDecl
    // })?.key
    // if let registeredGlobalName = registeredGlobalName,
    //   let registeredGlobalReference = symbolTable.dependencyGraph.getNominalTypeReference(name: registeredGlobalName)
    // {
    //   return .success(
    //     ResolvedNominalTypeReference(
    //       nominalTypeRef: registeredGlobalReference,
    //       mainDecl: nominalDecl,
    //       originatingSyntax: originatingSyntax
    //     )
    //   )
    // }

    guard let name = Identifier(validating: nominalDecl.node.name) else {
      // TODO: Produce actual error
      struct InvalidIdentifier: Error {}
      return .failure(Failure.other(InvalidIdentifier()))
    }

    let file = nominalDecl.fileRoot
    let module = extractModule(syntax: nominalDecl)
    switch declContext {
    case .declGroup(let declGroupParent):
      // Find the base type
      let baseResult: Result<ResolvedNominalTypeReference, Failure> = resolveDeclGroup(
        declGroup: declGroupParent,
        originatingSyntax: originatingSyntax,
        memberDependencies: &memberDependencies,
        visitedTypeSyntax: visitedTypeSyntax
      )
      // Extract the type, or throw
      let baseType: ResolvedNominalTypeReference
      switch baseResult {
      case .success(let success):
        baseType = success
      case .failure(let failure):
        return .failure(Failure.invalidBaseType(failure))
      }

      // Find this nominal declaration through qualified lookup
      let resolvedBase: NominalTypeRef
      switch resolveType(typeReference: baseType) {
      case .success(let success):
        resolvedBase = success
      case .failure(let failure):
        return .failure(Failure.invalidBaseType(failure))
      }
      // Don't track dependencies (nominals don't currently have dependencies)
      var dependencies = DependencyTracker()
      let memberResult: Result<Attached<TypeDeclSyntax>?, Failure> = findNominalTypeMemberDecl(
        resolvedNominalBaseType: resolvedBase,
        memberName: name,
        memberIntroducingSyntax: Attached<TypeLikeSyntax>(nominalDecl),
        dependencyTracker: &dependencies
      )
      // Ensure we exist and there are no duplicates
      switch memberResult {
      case .success(Attached<TypeDeclSyntax>(nominalDecl)):
        break
      case .success(let unexpectedResult):
        // We should have diagnosed an ambiguity if there was a different
        // nominal decl or we couldn't find a member
        fatalError(
          "[SwiftLexicalLookup] Internal error: Qualified lookup of \(baseType._succinctDescription) > '\(name.name)' unexpectedly returned `\(unexpectedResult.debugDescription)`"
        )
      case .failure(let failure):
        return .failure(failure)
      }

      // FIXME: Register type here and return
      let globalTypeName: GlobalTypeName
      switch baseType.nominalTypeRef.storage {
      case .global(let globalReference):
        globalTypeName = globalReference.name.addingComponents([
          GlobalTypeName.Component(name: name, file: file, module: module, symbolTable: symbolTable)
        ])
      case .local(localReference: _):
        // TODO: Either call into `TypeDependencyGraph.registerNominalTypeReference`, or simplify
        // it so it doesn't handle the local case (accepts `GlobalTypeName` instead)
        return .success(
          ResolvedNominalTypeReference(
            nominalTypeRef: NominalTypeRef(localNominalType: nominalDecl),
            mainDecl: nominalDecl,
            originatingSyntax: originatingSyntax
          )
        )
      }

      let resolvedReferenceResult =
        symbolTable.registerNominalTypeReference(
          qualifiedName: TypeName.global(globalTypeName),
          mainDecl: nominalDecl,
          originatingSyntax: originatingSyntax
        ) as Result<ResolvedNominalTypeReference, TypeDependencyGraph.NominalRegistrationFailure>
      let resolvedReference: ResolvedNominalTypeReference
      switch resolvedReferenceResult {
      case .success(let success):
        resolvedReference = success
      case .failure(let registrationFailure):
        switch registrationFailure {
        // TODO: Explain why these invariants hold
        case .cannotRegisterUnderRedeclaration, .noDeclGroupParent, .parentNotRegistered, .parentExtensionUnbound,
          .differentRedeclarationFile:
          fatalError(
            "[ewiftLexicalLookup] Internal error: Unexpected nominal-registration error: \(registrationFailure)"
          )
        }
      }

      // TODO: Do we need to register in `SymbolTable`?
      return .success(resolvedReference)

    case .codeBlock(let codeBlockScope):
      let isTopLevel: Bool = codeBlockScope.node == file.statements

      // Gather type decls with the same name
      var scopeTypeDecls = [TypeDeclSyntax]()
      codeBlockScope.node._visitDirectMembers(
        configuredRegions: symbolTable.configuredRegions,
        visit: { valueDecl in
          guard
            let typeDecl = valueDecl.as(TypeDeclSyntax.self),
            typeDecl.name.identifier == name
          else {
            return
          }
          scopeTypeDecls.append(typeDecl)
        }
      )
      // If we're at top-level, consider other internal declarations
      if isTopLevel {
        // TODO: Look in the module, and add those decls
        // IMPORTANT: Make sure results are correctly sorted
      }

      // Diagnose redeclarations
      guard scopeTypeDecls == [TypeDeclSyntax(nominalDecl.node)] else {
        // Results are already sorted from lookup
        return .failure(Failure.ambiguousTypeDecl(scopeTypeDecls))
      }

      // Get the type name
      let typeName: TypeName
      if isTopLevel {
        typeName = .global(
          GlobalTypeName(
            component: GlobalTypeName.Component(name: name, file: file, module: module, symbolTable: symbolTable)
          )
        )
      } else {
        typeName = .local(LocalTypeName(scope: codeBlockScope, base: name))
      }

      let resolvedReferenceResult = symbolTable.registerNominalTypeReference(
        qualifiedName: typeName,
        mainDecl: nominalDecl,
        originatingSyntax: originatingSyntax
      )

      // Extract reference, or throw
      let resolvedReference: ResolvedNominalTypeReference
      switch resolvedReferenceResult {
      case .success(let success):
        resolvedReference = success
      case .failure(let registrationFailure):
        switch registrationFailure {
        // TODO: Explain why these invariants hold
        case .cannotRegisterUnderRedeclaration, .noDeclGroupParent, .parentNotRegistered, .parentExtensionUnbound,
          .differentRedeclarationFile:
          fatalError(
            "[ewiftLexicalLookup] Internal error: Unexpected nominal-registration error: \(registrationFailure)"
          )
        }
      }

      return .success(resolvedReference)
    }
  }

  /// Resolves the given member reference of the provided, resolved base type,
  /// recording our dependencies on qualified-lookup queries.
  ///
  /// Note: The base type might have redeclarations, in which case we return
  /// the appropriate error.
  fileprivate mutating func resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    typeMember: ImplicitTypeReferenceComponent,
    memberDependencies: inout DependencyTracker,
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Describe the base type(s)
    let baseDescription: String
    switch baseType {
    case .success(MemberLookupResult.memberResults(let baseTypes)):
      baseDescription = baseTypes.map(\.nominalTypeRef._succinctDescription).joined(separator: " & ")
    case .success(_):
      baseDescription = "<non-nominal>"
    case .failure:
      baseDescription = "<failure>"
    }

    return withLogging(
      request:
        "Member `\(baseDescription)` > `\(typeMember.debugDescription)`",
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
    visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>>
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
    // Accept nominals (count == 1) or compositions (count > 1).
    //
    // 'Compositions' of count == 0 (e.g. `Int.Type`) have no nominal types
    // and are automatically diagnosed at the end of the function.
    case .memberResults(let types):
      baseTypes = types
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
    var visitedDecls = Set<Attached<TypeDeclSyntax>>()
    var declsAndResults = [(decl: Attached<TypeDeclSyntax>, result: MemberLookupResult<ResolvedNominalTypeReference>)]()
    var failures = [(Attached<TypeLikeSyntax>, Failure)]()
    var nominalBaseTypes = [NominalTypeRef]()

    for baseType in baseTypes {
      // We'll collect the result, and type syntax
      //
      // We rely on definite initialization to ensure `memberResult` is
      // initialized exactly once, ensuring each member produces exactly one
      // result.
      let memberResult:
        Result<
          (typeDecl: Attached<TypeDeclSyntax>, result: MemberLookupResult<ResolvedNominalTypeReference>)?,
          Failure
        >
      logPrefix.append("Base `\(baseType._succinctDescription)`")
      defer {
        logPrefix.removeLast()
        switch memberResult {
        case Result.success((let memberTypeDecl, let memberResult)?):
          // Add if not already added
          guard visitedDecls.insert(memberTypeDecl).inserted else { break }
          declsAndResults.append((memberTypeDecl, memberResult))
        case Result.success(nil):
          // No results; continue in case next one has a result.
          break
        case Result.failure(let failure):
          failures.append((typeMember.introducingSyntax, failure))
        }
      }

      // Bind extensions and construct a nominal type.
      // We ignore failures since they're from non-matching extensions and diagnosed separately
      let nominalBaseType: NominalTypeRef
      switch resolveType(typeReference: baseType) {
      case .success(let success):
        nominalBaseType = success
      case .failure(let failure):
        memberResult = Result.failure(failure)
        continue
      }
      nominalBaseTypes.append(nominalBaseType)

      // Get the member decl
      let memberTypeDeclResult = findNominalTypeMemberDecl(
        resolvedNominalBaseType: nominalBaseType,
        memberName: typeMember.name,
        memberIntroducingSyntax: typeMember.introducingSyntax,
        dependencyTracker: &memberDependencies
      )
      log("Type members matching '\(typeMember.name.name)': \(memberTypeDeclResult._debugDescription)")
      // Collect; skip if it doesn't exist; throw on failure
      let memberTypeDecl: Attached<TypeDeclSyntax>
      switch memberTypeDeclResult {
      case .success(let success?):
        memberTypeDecl = success
      case .success(nil):
        // Skip if no such member exists, e.g.: in `(Encodable & Collection<Int>).Element`,
        // `Encodable` may not have an `Element` type member.
        memberResult = Result.success(nil)
        continue
      case .failure(let failure):
        memberResult = Result.failure(failure)
        continue
      }

      // Resolve this type declaration and add it to the results
      memberResult = resolveTypeDecl(
        typeDecl: memberTypeDecl,
        declContext: DeclContext.declGroup(Attached<DeclGroupSyntaxType>(baseType.mainDecl)),
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
    guard let (_, firstResult) = declsAndResults.first else {
      return Result.failure(
        Failure.noTypeMember(
          member: typeMember,
          in: MemberLookupResult.memberResults(nominalBaseTypes)
        )
      )
    }
    // TODO: Ensure we're properly shadowing and not giving false-positive errors
    guard declsAndResults.count == 1 else {
      return Result.failure(
        Failure.ambiguousTypeDecl(declsAndResults.map(\.decl.node))
      )
    }

    return Result.success(firstResult)
  }

  /// Finds the member type-decl of a nominal base type.
  ///
  /// A helper for `resolveMember` and `resolveNominalTypeDecl`.
  fileprivate mutating func findNominalTypeMemberDecl(
    resolvedNominalBaseType: NominalTypeRef,
    memberName: Identifier,
    memberIntroducingSyntax: Attached<TypeLikeSyntax>,
    dependencyTracker memberDependencies: inout DependencyTracker
  ) -> Result<Attached<TypeDeclSyntax>?, Failure> {
    return withLogging(
      request:
        "Nominal type member `\(resolvedNominalBaseType._succinctDescription)` > `\(memberName.name)`",
      describe: \._debugDescription
    ) {
      $0._findNominalTypeMemberDecl(
        resolvedNominalBaseType: resolvedNominalBaseType,
        memberName: memberName,
        memberIntroducingSyntax: memberIntroducingSyntax,
        dependencyTracker: &memberDependencies
      )
    }
  }

  fileprivate func _findNominalTypeMemberDecl(
    resolvedNominalBaseType: NominalTypeRef,
    memberName: Identifier,
    memberIntroducingSyntax: Attached<TypeLikeSyntax>,
    dependencyTracker memberDependencies: inout DependencyTracker
  ) -> Result<Attached<TypeDeclSyntax>?, Failure> {
    // Perform direct type lookup and mark dependency
    //
    // First, get the module
    let introducingModule = extractModule(syntax: memberIntroducingSyntax)
    // Look up
    let memberTypeDeclsResult: Result<[Attached<TypeDeclSyntax>], SymbolTable.QualifiedTypeLookupFailure> =
      symbolTable.findMemberType(
        baseType: resolvedNominalBaseType,
        memberTypeName: memberName,
        introducingTypeSyntax: memberIntroducingSyntax,
        introducingModule: introducingModule,
        dependencyTracker: &memberDependencies
      )

    // Handle failures
    let memberTypeDecls: [Attached<TypeDeclSyntax>]
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
        "[SwiftLexicalLookup] Internal error: Base type \(resolvedNominalBaseType) was unexpectedly invalid."
      )
    }

    // Process the results
    //
    // 1. Return `nil` if no such declaration exists.
    guard let firstTypeDecl = memberTypeDecls.first else {
      return Result.success(nil)
    }
    // 2. Cannot have multiple type declarations named the same.
    //    E.g.
    //    struct A {
    //      typealias B = Int
    //      typealias B = Bool
    //      let b: B // ❌ ambiguous
    //    }
    // TODO: Add ability to disambiguite shadowing/fileprivate
    guard memberTypeDecls.count == 1 else {
      // TODO: Find more efficient solution (perhaps force `symbolTable.findMembers` to sort for us).
      return Result.failure(Failure.ambiguousTypeDecl(symbolTable.sortDeclarations(memberTypeDecls).map(\.node)))
    }
    // There's just one member; return that
    return Result.success(firstTypeDecl)
  }
}

// MARK: Extended-Type Syntax

extension TypeResolver {
  /// Resolve the given type syntax from an extension declaration
  /// to a single nominal type.
  ///
  /// Note that we only diagnose extending tuples/functions and compositions
  /// (e.g. `Codable = Encodable & Decodable`). However, we don't diagnose
  /// things like extending an existential (e.g. `extension any Collection`).
  mutating func resolveExtendedTypeSyntax(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    memberDependencies: inout DependencyTracker
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, Failure> {
    withLogging(
      request: "Extended type syntax `\(extensionDecl.extendedType.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveExtendedTypeSyntax(extensionDecl: extensionDecl, memberDependencies: &memberDependencies)
      }
    )
  }

  /// Implements `resolveExtendedTypeSyntax`
  mutating func _resolveExtendedTypeSyntax(
    extensionDecl: Attached<ExtensionDeclSyntax>,
    memberDependencies: inout DependencyTracker
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, Failure> {
    // Ensure extension is at file scope
    let declContext = _findDeclContext(ofDeclGroup: Attached<DeclGroupSyntaxType>(extensionDecl))
    guard
      case DeclContext.codeBlock(let scope) = declContext,
      scope.node == extensionDecl.fileRoot.statements
    else {
      return .failure(Failure.extensionNotAtFileScope(extensionDecl: extensionDecl.node))
    }

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
      guard let nominalType = results.first, results.count == 1 else {
        return .failure(Failure.cannotExtendNonNominal(nonnominal: resolvedType))
      }
      // That types needs to be global (can't extended local types)
      let nominalRef = nominalType.nominalTypeRef
      guard case .global(let globalNominalRef) = nominalRef.storage else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type of top-level extension `\(extensionDecl._memberlessDescription)` unexpectedly evaluated to local type `\(nominalRef._succinctDescription)`."
        )
      }
      // Return global reference
      return .success(
        GenericResolvedNominalTypeReference(
          nominalTypeRef: globalNominalRef,
          mainDecl: nominalType.mainDecl,
          originatingSyntax: nominalType.originatingSyntax
        )
      )
    // Functions/tuples/`Any` aren't nominal
    case .function, .tuple, .anyType:
      return .failure(.cannotExtendNonNominal(nonnominal: resolvedType))
    }
  }
}

// MARK: Resolve Extension / Nominal

extension TypeResolver {
  /// Resolve a qualified-type name to a nominal type with all accessible
  /// extensions bound.
  @_spi(_QualifiedLookupTests) public mutating func resolveType(
    typeReference: ResolvedNominalTypeReference
  ) -> Result<NominalTypeRef, Failure> {
    withLogging(
      request: "Extended nominal`\(typeReference._succinctDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveType(typeReference: typeReference)
      }
    )
  }

  /// Implements `resolveNominalType`
  fileprivate mutating func _resolveType(
    typeReference: ResolvedNominalTypeReference
  ) -> Result<NominalTypeRef, Failure> {
    // Skip extension binding for local declarations.
    //
    // For instance, there's no way to extend `A` in `func f() { struct A {} }`
    // since extensions may only be declared at the top level.
    guard case .global(let qualifiedGlobalRef) = typeReference.nominalTypeRef.storage else {
      return .success(typeReference.nominalTypeRef)
    }

    // Get the nominal type from the symbol table (or register accordingly)
    let currentNominalResult: Result<NominalTypeRef, TypeDependencyGraph.NominalTypeRefUpdateFailure> =
      symbolTable.dependencyGraph.updateNominalTypeReference(oldReference: typeReference.nominalTypeRef)

    // Handle reregistration (we should diagnose reregistrations and not save them in the table)
    let currentNominal: NominalTypeRef
    switch currentNominalResult {
    case .success(let success):
      currentNominal = success
    // If the reference changed, report those failures
    case .failure(.redeclared(let declarations)):
      return .failure(Failure.ambiguousTypeDecl(declarations.map({ TypeDeclSyntax($0.node) })))
    case .failure(.removed):
      return .failure(Failure.noTypeInScope)
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

    // Find all the extensions we need to bind
    let accessibleExtensions = symbolTable.findAllExtensions(
      accessibleFrom: typeReference.originatingSyntax.fileRoot,
      configuredRegions: symbolTable.configuredRegions
    )
    log("Accessible extensions: \(accessibleExtensions.map(\._memberlessDescription))")

    // Queue up the extensions that need binding
    let unadmittedExtensions: [Attached<ExtensionDeclSyntax>] = accessibleExtensions.filter({
      accessibleExtension in
      symbolTable.unresolvedExtensions[accessibleExtension.fileRoot, default: []].contains(accessibleExtension)
    })

    // Return if no extensions are available
    guard !unadmittedExtensions.isEmpty else {
      log("No extensions to bind.")
      return .success(currentNominal)
    }

    symbolTable.admitExtensions(unadmittedExtensions)

    // After binding all extensions, get the new nominal type
    guard
      case .success(let finalizedNominalRef) = symbolTable.dependencyGraph.updateNominalTypeReference(
        oldReference: NominalTypeRef(globalReference: qualifiedGlobalRef)
      )
    else {
      // We checked the nominal type is registered at the start.
      // TODO: Make sure this assumption holds true
      fatalError(
        "[SwiftLexicalLookup] Internal error: Nominal type unexpectedly removed from symbol table after binding extensions."
      )
    }

    return .success(finalizedNominalRef)
  }

  /// Returns the nominal-type reference with the extension's extended-type
  /// syntax as the originating syntax.
  @_spi(_QualifiedLookupTests) public mutating func bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, Failure> {
    withLogging(
      request: "Binding extension `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._bindExtension(extensionDecl)
      }
    )
  }

  fileprivate mutating func _bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> Result<GenericResolvedNominalTypeReference<GlobalNominalTypeRef>, Failure> {
    if let alreadyBoundResult = symbolTable.getExtensionResolvedType(extensionDecl) {
      return alreadyBoundResult
    }

    symbolTable.admitExtensions([extensionDecl])

    // If there's not an existing extension-binding request, the extension
    // should be admitted. Otherwise, return a failure for now.
    guard let boundTypeResult = symbolTable.dependencyGraph.getExtensionResolvedType(extensionDecl) else {
      // The extension graph tracks dependencies so this result should be
      // invalidated and fixed after the primary extension-binding request
      // completes.
      return .failure(Failure.extensionNotBoundYet)
    }

    return boundTypeResult.map({ (globalReference, mainDecl) in
      GenericResolvedNominalTypeReference<GlobalNominalTypeRef>(
        nominalTypeRef: globalReference,
        mainDecl: mainDecl,
        originatingSyntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }
}
