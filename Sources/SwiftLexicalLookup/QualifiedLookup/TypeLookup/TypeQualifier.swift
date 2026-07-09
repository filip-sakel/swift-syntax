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

extension Result where Success: CustomDebugStringConvertible {
  fileprivate var _debugDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.debugDescription))"
    case .failure(let error):
      return ".error(\(String(reflecting: error)))"
    }
  }
}
extension Result where Success: SyntaxProtocol {
  fileprivate var _debugSyntaxDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.trimmedDescription))"
    case .failure(let error):
      return ".error(\(String(reflecting: error)))"
    }
  }
}
extension Result where Success == [TypeDeclSyntax] {
  fileprivate var _debugSyntaxDescription: String {
    switch self {
    case .success(let success):
      return ".success(\(success.map(\.trimmedDescription)))"
    case .failure(let error):
      return ".error(\(String(reflecting: error)))"
    }
  }
}

/// The minimal defining components of a nominal type: the main declaration and the qualified name.
/// Unlike ``NominalType``, doesn't include extensions.
@_spi(_QualifiedLookup) public struct ResolvedNominalTypeReference: Sendable, Hashable, CustomDebugStringConvertible {
  public let mainDecl: NominalTypeDeclSyntax
  public let name: QualifiedTypeName
  public let originatingSyntax: TypeLikeSyntax

  private init(
    mainDecl: NominalTypeDeclSyntax,
    name: QualifiedTypeName,
    originatingSyntax: TypeLikeSyntax
  ) {
    self.mainDecl = mainDecl
    self.name = name
    self.originatingSyntax = originatingSyntax
  }

  public var debugDescription: String {
    "\(name) (\(mainDecl.kind))"
  }
}
extension ResolvedNominalTypeReference {
  @_spi(_QualifiedLookup) public init(
    mainDecl: NominalTypeDeclSyntax,
    name: QualifiedTypeName,
    originatingSyntax: TypeLikeSyntax,
    savingToTable symbolTable: SymbolTable3
  ) {
    self.mainDecl = mainDecl
    self.name = name
    self.originatingSyntax = originatingSyntax

    // Save to the symbol table
    symbolTable.registerNominal(qualifiedName: name, mainDecl: mainDecl)
  }

  @_spi(_QualifiedLookupTests) public static func _mockMarkerType(
    mainDecl: NominalTypeDeclSyntax,
    originatingSyntax: TypeSyntax
  ) -> ResolvedNominalTypeReference {
    ResolvedNominalTypeReference(
      mainDecl: mainDecl,
      name: QualifiedTypeName.topLevel(
        QualifiedTypeNameGlobalType(
          components: [
            QualifiedTypeNameGlobalType.Component(
              qualifier: .external(moduleName: Identifier(canonicalName: "_")),
              name: Identifier(canonicalName: "_")
            )
          ]
        )!
      ),
      originatingSyntax: TypeLikeSyntax(originatingSyntax)
    )
  }
}

@_spi(_QualifiedLookup)
public indirect enum TypeQualifierFailure<MinimalNominal: Sendable, ExtendedNominal: Sendable>: Error {
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
  /// TODO: Convert to tuple array
  case invalidMembers([TypeLikeSyntax: Self])

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

  /// Name lookup found invalid type redeclarations so references to that
  /// type name are ambiguous.
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
  case syntaxNotInSymbolTable(rootKind: SyntaxKind)

  /// Cannot resolve type syntax nested inside a disabled `#if`
  /// (given the symbol table's configured regions).
  case syntaxInDisabledRegion

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
      return memberResults._description(describeMembers: { results in
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
    case .syntaxNotInSymbolTable(let rootKind):
      return ".syntaxNotInSymbolTable(rootKind: \(rootKind))"
    case .syntaxInDisabledRegion:
      return ".syntaxInDisabledRegion"
    }
  }
}

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

  public typealias Failure = TypeQualifierFailure<ResolvedNominalTypeReference, NominalType>

  let symbolTable: SymbolTable3
  var requestedExtensions: OrderedSet<ExtensionDeclSyntax> = []

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
    typeSyntax: TypeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(request: "Resolve syntax `\(typeSyntax.trimmedDescription)`", describe: \._debugDescription) {
      $0._resolveSyntax(typeSyntax: typeSyntax, memberDependencies: &memberDependencies)
    }
  }

  public mutating func _resolveSyntax(
    typeSyntax: TypeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // We assert the syntax *entered* into the API is in the symbol table.
    // TODO: Consider how this plays out with `#if`, e.g., what if we're in a disabled region
    guard
      let fileRoot = typeSyntax.root.as(SourceFileSyntax.self),
      symbolTable.moduleMap[fileRoot] != nil
    else {
      return .failure(.syntaxNotInSymbolTable(rootKind: typeSyntax.root.kind))
    }
    // Further, if given `configuredRegions`, ensure the given syntax is active.
    if let configuredRegions = symbolTable.configuredRegions,
      configuredRegions.isActive(typeSyntax) != .active
    {
      return .failure(Failure.syntaxInDisabledRegion)
    }

    // Partially resolve the type and handle each case accordingly
    let partialType: Result<PartiallyResolvedType, TypeResolutionFailure> = typeSyntax.partiallyResolve()
    switch partialType {
    case .success(.anyType):
      // TODO: Handle so we don't fail `Encodable & Any` like we do `Encodable & Int.Type`
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
        typeBaseComponent: ImplicitTypeReferenceComponent(from: component),
        originatingSyntax: typeSyntax,
        memberDependencies: &memberDependencies
      )
    case .success(.member(let baseTypeSyntax, .success(let memberComponent))):
      let baseTypeResult = resolveSyntax(typeSyntax: baseTypeSyntax, memberDependencies: &memberDependencies)
      return resolveMember(
        baseType: baseTypeResult,
        firstTypeMember: ImplicitTypeReferenceComponent(from: memberComponent),
        memberDependencies: &memberDependencies
      )
    case .success(.composition(let childTypes)):
      // TODO: Record assumption that `consituentTypes` is unique.
      var syntaxToTypes = [
        (childSyntax: TypeSyntax, childResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>)
      ]()
      for childTypeSyntax in childTypes {
        let childResult = resolveSyntax(
          typeSyntax: childTypeSyntax,
          memberDependencies: &memberDependencies
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
      childSyntax: TypeSyntax,
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
                childSyntax: childTypeSyntax,
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
            childSyntax: childTypeSyntax,
            childFailure: Failure.cannotComposeNonClassOrProtocol(
              resolved: .function(argumentCount: argumentCount)
            )
          )
        )
      case .success(.tuple(let labels)):
        failures.append(
          (
            childSyntax: childTypeSyntax,
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
            childSyntax: childTypeSyntax,
            childFailure: resolutionFailure
          )
        )
      }
    }

    // Stop even if we only have one failure
    guard failures.isEmpty else {
      // log("Resolved \(typeSyntax.trimmedDescription) to failures \(failures)")
      return Result.failure(Failure.invalidComposition(failures))
    }

    // We get `anyType` only when all the constituent types are `any`.
    guard anyTypeCounter != syntaxToTypes.count else {
      return Result.success(MemberLookupResult.anyType)
    }

    return Result.success(MemberLookupResult.memberResults(types))
  }

  /// Resolve the given type syntax from an extension declaration
  /// to a single nominal type.
  ///
  /// Note that we only diagnose extending tuples/functions and compositions
  /// (e.g. `Codable = Encodable & Decodable`). However, we don't diagnose
  /// things like extending an existential (e.g. `extension any Collection`).
  fileprivate mutating func resolveExtendedTypeSyntax(
    extensionDecl: ExtensionDeclSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    withLogging(
      request: "Extended type syntax `\(extensionDecl.extendedType.trimmedDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveExtendedTypeSyntax(extensionDecl: extensionDecl, memberDependencies: &memberDependencies)
    }
  }

  /// Implements `resolveExtendedTypeSyntax`
  fileprivate mutating func _resolveExtendedTypeSyntax(
    extensionDecl: ExtensionDeclSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    // Throw if syntax resolution fails
    let lookupResult: MemberLookupResult<ResolvedNominalTypeReference>
    switch resolveSyntax(typeSyntax: extensionDecl.extendedType, memberDependencies: &memberDependencies) {
    case .success(let result):
      lookupResult = result
    case .failure(let failure):
      return .failure(failure)
    }

    // Extract a nominal type
    switch lookupResult {
    case .memberResults(let results):
      // We're expecting exactly one nominal type.
      // No types means non-nominal, e.g., `Int.Type` and compositions are
      // also not extensible, e.g., `Encodable & Decodable`.
      guard let firstNominalType = results.first, results.count == 1 else {
        return .failure(.cannotExtendNonNominal(nonnominal: lookupResult))
      }
      return .success(firstNominalType)
    // Functions/tuples/`Any` aren't nominal
    case .function, .tuple, .anyType:
      return .failure(.cannotExtendNonNominal(nonnominal: lookupResult))
    }
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
    typeBaseComponent: ImplicitTypeReferenceComponent,
    originatingSyntax: TypeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Type reference `\(typeBaseComponent.debugDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveTypeReference(
        typeBaseComponent: typeBaseComponent,
        originatingSyntax: originatingSyntax,
        memberDependencies: &memberDependencies
      )
    }
  }

  /// Implements `resolveTypeReference`
  fileprivate mutating func _resolveTypeReference(
    typeBaseComponent: ImplicitTypeReferenceComponent,
    originatingSyntax: TypeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Perfom unqualified lookup up to find the base type's declaration
    //
    // e.g.
    //   extension String.UTF8View { <- Resolve
    //     struct A { // <- Resolve
    //       struct B {} // <- Look up here
    //     }
    //   }
    let baseLookupResults: [UnqualifiedTypeLookupResult]
    if let module = typeBaseComponent.module {
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
      //
      // Note: We use ``originatingSyntax`` because `typeReference.typeSyntax`
      // is mostly used for producing diagnostics. However, the latter should
      // be a child of ``originatingSyntax``.
      baseLookupResults = originatingSyntax.findUnqualifiedType(
        typeBaseComponent.name,
        configuredRegions: symbolTable.configuredRegions
      )
    }

    log("Base lookup results: \(baseLookupResults)")

    // Find first matching type declaration
    for lookupResult in baseLookupResults {
      // The enclosing type
      let enclosingTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
      // False if we can return the enclosing type itself; true if we need to
      // perform qualified lookup and return a type member.
      let lookForSelectedMember: Bool

      switch lookupResult {
      case .lookForType(let typeDecl, let findSelectedMember):
        enclosingTypeResult = resolveTypeDecl(
          baseTypeDecl: typeDecl,
          baseTypeLikeSyntax: typeBaseComponent.introducingSyntax,
          memberDependencies: &memberDependencies,
          // memberChain: memberChainPrefix + typeReference.memberChain.map(ImplicitTypeReferenceComponent.init(from:)),
          // originatingSyntax: originatingSyntax
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
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl, memberDependencies: &memberDependencies) {
        case .success(let type):
          enclosingTypeResult = Result.success(MemberLookupResult.memberResults([type]))
        case .failure(let failure):
          return .failure(failure)
        }
        lookForSelectedMember = findSelectedMember
      case .lookForGenericParameters(let extensionDecl):
        // Resolve extended type
        let baseType: ResolvedNominalTypeReference
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl, memberDependencies: &memberDependencies) {
        case .success(let type):
          baseType = type
        case .failure(let failure):
          return Result.failure(Failure.invalidBaseType(failure))
        }

        // Continue if we didn't find matching generic parameters.
        guard baseType.mainDecl.findGenericParameters(withName: typeBaseComponent.name).first != nil else {
          continue
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
      switch enclosingTypeResult {
      case .success(let result):
        enclosingType = result
      // Continue to next scope if unqualified lookup didn't find the type in this scope
      case .failure(.noTypeInScope):
        continue
      case .failure(let failure):
        return Result.failure(Failure.invalidBaseType(failure))
      }

      // If we don't have to look for a member, return
      if !lookForSelectedMember { return Result.success(enclosingType) }

      // Look for the member
      let memberTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> = resolveMember(
        baseType: Result.success(enclosingType),
        firstTypeMember: typeBaseComponent,
        memberDependencies: &memberDependencies
      )

      // Get the type member
      let memberType: MemberLookupResult<ResolvedNominalTypeReference>
      switch memberTypeResult {
      case .success(let result):
        memberType = result
      // Continue like above
      case .failure(.noTypeMember):
        continue
      case .failure(let failure):
        return Result.failure(Failure.invalidMembers([typeBaseComponent.introducingSyntax: failure]))
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
    baseTypeDecl: TypeDeclSyntax,
    baseTypeLikeSyntax: TypeLikeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Decl \(baseTypeDecl.kind) `\(baseTypeDecl.name.trimmedDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveTypeDecl(
        baseTypeDecl: baseTypeDecl,
        baseTypeLikeSyntax: baseTypeLikeSyntax,
        memberDependencies: &memberDependencies
      )
    }
  }

  /// Implements `resolveTypeDecl`
  fileprivate mutating func _resolveTypeDecl(
    baseTypeDecl: TypeDeclSyntax,
    baseTypeLikeSyntax: TypeLikeSyntax,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // We mainly handle nominal types; type aliases are trivially recursive, and we skip
    // associated types and generic parameters
    let nominalDecl: NominalTypeDeclSyntax
    if let nominalTypeDecl = baseTypeDecl.as(NominalTypeDeclSyntax.self) {
      nominalDecl = nominalTypeDecl
    } else if let typeAlias = baseTypeDecl.as(TypeAliasDeclSyntax.self) {
      log(
        "Found aliased type `\(typeAlias.initializer.value)`"
      )

      let aliasedResult = resolveSyntax(
        typeSyntax: typeAlias.initializer.value,
        memberDependencies: &memberDependencies
      )
      // Map error so that callers don't think this type decl has an issue (the type alias is diagnosed separately)
      return aliasedResult.mapError(Failure.invalidAliasedType(_:))
    } else { /* else if it's an associated type or generic parameter */
      // No members for generic parameters and associated types
      return Result.failure(Failure.genericParameterOrAssociatedType)
    }

    // Get the type chain
    let typeChain: ChainResult
    switch nominalDecl.findTypeChain(module: nil) {
    case .success(let result):
      typeChain = result
    case .failure(.noSourceFileRoot(let nonFileRoot)):
      // We check that the root is a source file (& registered in the symbol table)
      // at the top of ``resolveSyntax``.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly asked to resolve a type declaration whose root (\(nonFileRoot.kind) isn't a file root."
      )
    case .failure(.invalidIdentifier(let invalidIdentifier)):
      // TODO: Decide if this is too granular and we shud have a more general `.invalidContext` instead.
      return .failure(.other(NominalTypeDeclSyntax.ChainResolutionFailure.invalidIdentifier(invalidIdentifier)))
    }

    switch typeChain {
    case .resolved(let qualifiedTypeName):
      return Result.success(
        MemberLookupResult.memberResults([
          ResolvedNominalTypeReference(
            mainDecl: nominalDecl,
            name: qualifiedTypeName,
            originatingSyntax: baseTypeLikeSyntax,
            savingToTable: symbolTable
          )
        ])
      )
    case .partiallyResolved(let partiallyResolvedName):
      // Resolve the base extension and resolve the type chain
      let qualifiedBaseResult = resolveExtendedTypeSyntax(
        extensionDecl: partiallyResolvedName.base,
        memberDependencies: &memberDependencies
      )
      let module: Identifier? = nil  // TODO: Find the actual module
      switch qualifiedBaseResult {
      case .success(let resolvedExtendedBaseNominal):
        let resolvedBaseNominal = partiallyResolvedName.resolve(
          resolvedBase: resolvedExtendedBaseNominal,
          originatingSyntax: baseTypeLikeSyntax,
          module: module,
          savingToTable: symbolTable
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
    firstTypeMember: ImplicitTypeReferenceComponent,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Member `\(firstTypeMember.debugDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveMember(baseType: baseType, firstTypeMember: firstTypeMember, memberDependencies: &memberDependencies)
    }
  }

  /// Implements `resolveMember`
  fileprivate mutating func _resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    firstTypeMember: ImplicitTypeReferenceComponent,
    memberDependencies: inout [ExtensionBindingResult.Dependency]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Get member type(s), or throw
    //
    // We throw because we can't resolve anything without the
    // member type reference.
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
      return Result.failure(Failure.noTypeMember(member: firstTypeMember, in: MemberLookupResult.memberResults([])))
    case MemberLookupResult.anyType:
      return Result.failure(Failure.noTypeMember(member: firstTypeMember, in: MemberLookupResult.anyType))
    case MemberLookupResult.function(let argumentCount):
      return Result.failure(
        Failure.noTypeMember(member: firstTypeMember, in: MemberLookupResult.function(argumentCount: argumentCount))
      )
    case MemberLookupResult.tuple(let labels):
      return Result.failure(Failure.noTypeMember(member: firstTypeMember, in: MemberLookupResult.tuple(labels: labels)))
    }

    // Perform qualified type lookup and mark the dependencies
    //
    // Note: We collect all types and failures. This approach allows the
    // type checker can check if members of compositions actually resolve
    // to the same type. For instance:
    //   protocol A { typealias T = Int }
    //   final class B { typealias T = [String].Index /* i.e. Int */ }
    //   protocol C { typealias T = Int }
    //   typealias ABC = A & B & C
    //   let a: ABC.T // ✅ T resolves to `Int` in both cases
    // Of course, if we change the class' alias to `typealias T = String`,
    // the compiler will complain that `ABC.T` is ambiguous. Also, collecting
    // all failures surfaces all errors at once for better diagnostics.
    var results = [TypeDeclSyntax: MemberLookupResult<ResolvedNominalTypeReference>]()
    var failures = [TypeLikeSyntax: Failure]()
    var nominalBaseTypes = [NominalType]()

    for baseType in baseTypes {
      // We'll collect the result, and type syntax
      //
      // We rely on definite initialization to ensure `memberResult` is
      // initialized exactly one, ensuring each member produces exactly one
      // result.
      let memberResult:
        Result<
          (typeDecl: TypeDeclSyntax, result: MemberLookupResult<ResolvedNominalTypeReference>)?,
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
          failures[firstTypeMember.introducingSyntax] = failure
        }
      }

      // Bind extensions and construct a nominal type.
      // We ignore failures since they're from non-matching extensions and diagnosed separately
      let nominalBaseType = resolveNominalType(
        name: baseType.name,
        originatingSyntax: firstTypeMember.introducingSyntax
      )
      nominalBaseTypes.append(nominalBaseType)

      // Perform direct type lookup and mark dependency
      // TODO: Figure out imported modules
      let originatingSyntax = Syntax(firstTypeMember.introducingSyntax)
      guard let file = originatingSyntax.root.as(SourceFileSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly had to resolve type syntax whose root isn't a source file."
        )
      }
      let lookupPosition = (file: file, position: originatingSyntax.position)
      let typeDeclsResult = nominalBaseType.findMemberTypes(
        component: firstTypeMember,
        lookupPosition: lookupPosition,
        importedModules: [],
        moduleMap: symbolTable.moduleMap,
        configuredRegions: symbolTable.configuredRegions,
        _verbose: _verbose
      )

      // Handle failures
      let memberTypeDecls: [ExtensionDeclSyntax?: [TypeDeclSyntax]]
      switch typeDeclsResult {
      case .success(let typeDecls):
        memberTypeDecls = Dictionary(
          typeDecls,
          uniquingKeysWith: { _, secondExtension in
            // A postcondition in the function docs promises this.
            fatalError(
              "[SwiftLexicalLookup] Internal error: `findMemberTypes` should have only generated one extension."
            )
          }
        )
      case .failure(.declNotAttachedToSourceFile), .failure(.fileNotInModuleMap):
        // We check that the root is a source file in the symbol table
        // at the top of ``resolveSyntax``.
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly asked to resolve a type declaration whose root isn't a file or a file not registered in the symbol table."
        )
      case .failure(.selectedNonImportedModule):
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly requested direct lookup for a module that wasn't imported."
        )
      }

      // Save the dependency
      //
      // First, group the decls by extension
      memberDependencies.append(
        ExtensionBindingResult.Dependency(
          baseTypeName: baseType.name,
          typeMember: firstTypeMember.name,
          resolvedDecls: memberTypeDecls
        )
      )

      // Process the results
      let flatMemberTypes = memberTypeDecls.flatMap(\.value)
      // 1. Skip this nominal type if it didn't contain said type member.
      //
      //    E.g. In `(Encodable & Collection<Int>).Element`, `Encodable` may not have an `Element`
      // type member.
      guard let firstTypeDecl = flatMemberTypes.first else {
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
      guard flatMemberTypes.count == 1 else {
        memberResult = Result.failure(Failure.ambiguousTypeDecl(flatMemberTypes))
        continue
      }
      // There's just one; use that
      let memberTypeDecl = firstTypeDecl

      // Resolve this type declaration and add it to the results
      memberResult = resolveTypeDecl(
        baseTypeDecl: memberTypeDecl,
        baseTypeLikeSyntax: firstTypeMember.introducingSyntax,
        memberDependencies: &memberDependencies
          // memberChain: remainingMemberChain,
          // originatingSyntax: originatingSyntax
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
      return Result.failure(Failure.invalidMembers(failures))
    }

    // Diagnose if we get no results
    // E.g. `(Any & Sendable).MyType` yields no results for either `Any.MyType` or
    //   `Sendable.MyType`; hence, `MyType` isn't a member of `Any & Sendable`.
    guard let (_, firstResult) = results.first else {
      return Result.failure(
        Failure.noTypeMember(
          member: firstTypeMember,
          in: MemberLookupResult.memberResults(nominalBaseTypes)
        )
      )
    }
    // TODO: Ensure we're properly shadowing and not giving false-positive errors
    guard results.count == 1 else {
      return Result.failure(
        Failure.ambiguousTypeDecl(Array(results.keys))
      )
    }

    return Result.success(firstResult)
  }

  /// Resolve a qualified-type name to a nominal type with all accessible
  /// extensions bound.
  fileprivate mutating func resolveNominalType(
    name: QualifiedTypeName,
    originatingSyntax: TypeLikeSyntax
  ) -> NominalType {
    withLogging(
      request: "Extended nominal`\(name)`",
      describe: \.debugDescription
    ) {
      $0._resolveNominalType(name: name, originatingSyntax: originatingSyntax)
    }
  }

  fileprivate mutating func _resolveNominalType(
    // TODO: What if we just take a `ResolvedNominalTypeReference` instead
    // and register types like that?
    name: QualifiedTypeName,
    originatingSyntax: TypeLikeSyntax
  ) -> NominalType {
    // There are three paths:
    // 1. The symbol table hasn't resolved the extensions accessibles from this source file
    //    We need to bind all said extensions
    // 2. We're already binding extensions by servicing another request
    // 3. The symbol table has a cached/resolved version

    // The type must already be in the symbol table (even with no extensions bound)
    // Should be guaranteed by `symbolTable` parameter in `ResolvedNominalTypeReference` initializer.
    guard let currentNominal = symbolTable.typeState[name] else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Tried resolving type whose name isn't in the symbol table to a nominal type."
      )
    }

    // Find all the extensions we need to bind
    //
    // First, get the file of the originatingSyntax
    guard let sourceFile = originatingSyntax.root.as(SourceFileSyntax.self) else {
      fatalError("[SwiftLexicalLookup] Internal error: Unexpectedly couldn't file source file of originating syntax")
    }
    let accessibleExtensions = symbolTable.findAllExtensions(
      accessibleFrom: sourceFile,
      configuredRegions: symbolTable.configuredRegions
    )
    log("Accessible extensions: \(accessibleExtensions.flatMap(\.value).map(\._memberlessDescription))")

    // Detect if there's an existing binding request (before requesting more extensions)
    let startsExtensionBinding = self.requestedExtensions.isEmpty

    // Queue up the extensions that need binding
    for (file, extensionDecls) in accessibleExtensions {
      // Skip if the file has already been resolved
      guard let unresolvedFileExtensions = symbolTable.unresolvedExtensions[file] else { continue }
      // Log the extension to be added (also subtract existing requestedExtensions since we're calling `formUnion` below)
      log(
        "Adding extensions: \(extensionDecls.intersection(unresolvedFileExtensions).subtracting(self.requestedExtensions).map(\._memberlessDescription))"
      )
      // Add the unresolved extensions in the file
      self.requestedExtensions.formUnion(extensionDecls.intersection(unresolvedFileExtensions))
    }

    // If there's an existing request, it will take care of the rest
    guard startsExtensionBinding else {
      log("Binding request already underway; returning")

      // Even if not all extensions are loaded, we queued up all extensions that
      // need to be processed, so we'll get invalidated appropriately.
      return currentNominal
    }
    // Return if no extensions are available
    if self.requestedExtensions.isEmpty {
      log("No extensions to bind.")
      return currentNominal
    }

    log("Initiating extension binding.")

    // It's up to us to bind all required extensions
    while let extensionDecl = self.requestedExtensions.first {
      // We remove at the end of the loop because we want nested syntax-resolution
      // requests to see that we're actively trying to bind this extension.
      defer { self.requestedExtensions.remove(extensionDecl) }

      var invalidatedExtensions: OrderedSet<ExtensionDeclSyntax> = withLogging(
        request: "Binding `\(extensionDecl._memberlessDescription)`",
        describe: { (invalidatedExtensions: SymbolTable3.InvalidatedExtensions) in
          "Invalidated: \(invalidatedExtensions.map(\._memberlessDescription))"
        },
        perform: {
          // Resolve, tracking dependencies
          //
          // Note: We don't add these dependencies to our dependencies since
          // this is considered a completely separate type resolution. We
          // track these dependencies in the symbol table's corresponding
          // extension state.
          var extensionDependencies = [ExtensionBindingResult.Dependency]()
          let extendedTypeResult = $0.resolveExtendedTypeSyntax(
            extensionDecl: extensionDecl,
            memberDependencies: &extensionDependencies
          )

          // Register in the symbol table
          let bindingResult: Result<SymbolTable3.InvalidatedExtensions, SymbolTable3.ExtensionBindingFailure> =
            $0.symbolTable.bindExtension(
              extensionDecl,
              // Only get the name
              to: extendedTypeResult.map(\.name),
              dependencies: extensionDependencies
            )

          // Handle failures

          switch bindingResult {
          case .success(let success):
            return success
          case .failure(let failure):
            // Ensure we handle future failure types
            switch failure {
            // TODO: Reduce possible failures (e.g. nonRegisteredSyntaxRoot should go)
            // (e.g. invalidated/binding modes may be able to simplify)
            //
            // Explanation:
            // .nonRegisteredSyntaxRoot: We got this extension from the symbol table, which gets extensions from files
            // .cannotFixNonInvalidated: We request binding, not fixing invalidated extensions, so this shouldn't happen
            // .cannotBindInvalidated: We track invalidated extensions separately so this shoudln't happen
            // .alreadyResolved: The queueing step should not have enqueued already-resolved extensions
            // .boundToUnresolvedName: We checked for this at the start of this function
            // .bindingBeforeFixingInvalidatedExtensions: The loop below should fix invalidated extensions after each pass.
            case .nonRegisteredSyntaxRoot, .cannotFixNonInvalidated, .cannotBindInvalidated, .alreadyResolved,
              .boundToUnresolvedName, .bindingBeforeFixingInvalidatedExtensions:
              fatalError(
                "[SwiftLexicalLookup] Internal error: Unexpected failure when attempting to bind extension: \(failure); extension: \(extensionDecl.trimmedDescription)"
              )
            }
          }
        }
      )

      // Fix invalidated extensions
      while let invalidatedExtensionDecl = invalidatedExtensions.first {
        // TODO: Figure out if it's actually possible for an invalidated extension
        // to transitively reintroduce itself (i.e. if `invalidatedExtensions` could be
        // an array instead of a set where we just pop the first invalidated extension)
        defer { invalidatedExtensions.remove(invalidatedExtensionDecl) }

        // Re-resolve with dependency tracking
        var invalidatedExtensionDependencies = [ExtensionBindingResult.Dependency]()
        let extendedTypeResult = withLogging(
          request: "Fixing invalidated `\(invalidatedExtensionDecl._memberlessDescription)`",
          describe: \._debugDescription,
          perform: {
            $0.resolveExtendedTypeSyntax(
              extensionDecl: invalidatedExtensionDecl,
              memberDependencies: &invalidatedExtensionDependencies
            )
          }
        )

        // Register in the symbol table
        let nestedBindingResult: Result<SymbolTable3.InvalidatedExtensions, SymbolTable3.ExtensionBindingFailure> =
          symbolTable.fixInvalidatedExtension(
            extensionDecl,
            // Only get the name
            to: extendedTypeResult.map(\.name),
            dependencies: invalidatedExtensionDependencies
          )

        // Process failures
        let nestedInvalidatedExtensions: SymbolTable3.InvalidatedExtensions
        switch nestedBindingResult {
        case .success(let success):
          nestedInvalidatedExtensions = success
        case .failure(let failure):
          // Ensure we handle future failure types
          switch failure {
          // TODO: Reduce possible failures (e.g. nonRegisteredSyntaxRoot should go)
          // (e.g. invalidated/binding modes may be able to simplify)
          //
          // Explanation:
          // .nonRegisteredSyntaxRoot: We got this extension from the symbol table, which gets extensions from files
          // .cannotFixNonInvalidated: We're processing extensions returned by `SymbolTable`'s
          //   `bindExtension` and `fixInvalidatedExtension` which should be invalidated.
          // .cannotBindInvalidated: We requested fixing; not binding.
          // .alreadyResolved: The queueing step should not have enqueued already-resolved extensions
          // .boundToUnresolvedName: We checked for this at the start of this function
          // .bindingBeforeFixingInvalidatedExtensions: We're fixing invalidated extensions, so this shouldn't happen.
          case .nonRegisteredSyntaxRoot, .cannotFixNonInvalidated, .cannotBindInvalidated, .alreadyResolved,
            .boundToUnresolvedName, .bindingBeforeFixingInvalidatedExtensions:
            fatalError(
              "[SwiftLexicalLookup] Internal error: Unexpected failure when attempting to fix invalidated extension: \(failure); extension: \(extensionDecl.trimmedDescription)"
            )
          }
        }

        // Enqueue invalidated extensions
        invalidatedExtensions.formUnion(nestedInvalidatedExtensions)
      }
    }

    // After binding all extensions, get the new nominal type
    guard let finalizedNominal = symbolTable.typeState[name] else {
      // We checked the nominal type is regsitered at the start.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Nominal type unexpectedly removed from symbol table after binding extensions."
      )
    }

    return finalizedNominal
  }
}
