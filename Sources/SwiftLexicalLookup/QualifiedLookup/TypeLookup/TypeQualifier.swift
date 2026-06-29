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
  public let mainDecl: NominalTypeDeclSyntax2
  public let name: QualifiedTypeName
  public let originatingSyntax: TypeLikeSyntax

  public var debugDescription: String {
    "\(name) (\(mainDecl.kind))"
  }
}

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeQualifier {
  var logPrefix = [String]()

  func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // fatalError("Hi")
    print(logPrefix.map({ "[\($0)]" }).joined(), component, "[\(file):\(line)]")
  }

  mutating func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: inout TypeQualifier) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(&self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }

  public indirect enum Failure: Error {
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
    case cannotComposeNonClassOrProtocol(resolved: MemberLookupResult<ResolvedNominalTypeReference>)
    case noTypeMember(member: ImplicitTypeReferenceComponent, in: MemberLookupResult<NominalType>)

    // // TODO: Can we simplify to a single failure?
    // case invalidChildren([TypeSyntax: [Failure]])

    /// We can only extend structs/enums/classes/actors/protocols
    ///
    /// I.e. We can't extend tuples, functions, protocol compositions, metatypes, etc.
    case cannotExtendNonNominal(nonnominal: MemberLookupResult<ResolvedNominalTypeReference>)
    /// Child has error, so we can't qualify this type but we can't offer a useful diagnostic either.
    ///
    /// E.g.
    ///   typealias A = Encodable & Int.Type // ❌ error: non-protocol, non-class type 'Int.Type' cannot be used within a protocol-constrained type
    ///   func f(_: A) {} // No diagnostic here
    case invalidAliasedType(Failure)
    case invalidComposition([TypeSyntax: Failure])
    case other(any Error)

    /// We defer generic parameters/associated types to the type checker.
    case genericParameterOrAssociatedType

    /// Qualified lookup members had errors
    ///
    /// E.g.
    /// ```swift
    /// protocol A { typealias T = Undefined }
    /// class B<Generic> { typealias T = Generic }
    ///
    /// func f(_: (A & B).T)
    /// ```
    case invalidMembers([TypeLikeSyntax: Failure])

    // // In direct member lookup when members are invalid.
    // case invalidMembers([TypeLikeSyntax: Failure])

    // /// The extension in which the type we're looking up is
    // /// defined returned an error.
    // ///
    // /// extension Codable {
    // ///   struct MyStruct {
    // ///     func f(_: MyStruct) {} // <- Look up here
    // ///   }
    // /// }
    // /// In this case, `Codable`, i.e., `Encodable & Decodable` isn't nominal
    // /// and can't be extended.
    // case invalidBaseExtension(ExtensionDeclSyntax, failure: Failure)

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
    case invalidBaseType(Failure)

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

    // case noMemberType(PartiallyResolvedTypeIdentifier.Component, in: NominalType)
  }

  public private(set) var failures = [TypeSyntax: [Failure]]()
  var boundExtensions = [ExtensionDeclSyntax: ResolvedNominalTypeReference]()

  let symbolTable: SymbolTable3
  let configuredRegions: ConfiguredRegions?
  let _verbose: Bool
  let _checkNominalInCompositionIsClassOrProtocol = true

  public init(symbolTable: SymbolTable3, configuredRegions: ConfiguredRegions?, _verbose: Bool) {
    self.symbolTable = symbolTable
    self.configuredRegions = configuredRegions
    self._verbose = _verbose
  }

  // fileprivate mutating func _reduceResults(
  //   _ results: [TypeSyntax: Result<MemberLookupResult<MinimalNominal>, Failure>]
  // ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
  //   if results.isEmpty {}
  //   // Forward empty results
  //   guard let (_, firstResult) = results.first else {
  //     return Result.success(MemberLookupResult.memberResults([]))
  //   }
  //   // Forward single result (the rest of the functions handles compositions)
  //   guard results.count == 1 else {
  //     return firstResult
  //   }
  //
  //   // Handle compositions
  //   //
  //   // We handled tuples/functions above. Now, we assume we have a list of nominals.
  //   var nominalTypes = [MinimalNominal]()
  //   var invalidTypes = [TypeSyntax: [Failure]]()
  //
  //   for (typeSyntax, result) in results {
  //     // Simply log failures as other type results might succeed
  //     let lookupResult: MemberLookupResult<MinimalNominal>
  //     switch result {
  //     case .success(let result):
  //       lookupResult = result
  //     case .failure(let failure):
  //       self.failures[typeSyntax, default: []].append(.other(failure))
  //       continue
  //     }
  //
  //     switch lookupResult {
  //     // Cannot compose tuple/function types
  //     case .function, .tuple:
  //       invalidTypes[typeSyntax, default: []].append(Failure.cannotComposeNonClassOrProtocol(resolved: lookupResult))
  //     // Otherwise, combine members
  //     case .memberResults(let newTypes):
  //       nominalTypes.append(contentsOf: newTypes)
  //     }
  //   }
  //
  //   guard invalidTypes.isEmpty else {
  //     return Result.failure(.invalidChildren(invalidTypes))
  //   }
  //
  //   return Result.success(MemberLookupResult.memberResults(nominalTypes))
  // }
  //

  public mutating func resolveSyntax(
    typeSyntax: TypeSyntax
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(request: "Resolve syntax `\(typeSyntax.trimmedDescription)`", describe: \._debugDescription) {
      $0._resolveSyntax(typeSyntax: typeSyntax)
    }
  }

  public mutating func _resolveSyntax(
    typeSyntax: TypeSyntax,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // requester: Requester,
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // We assert the syntax *entered* into the API is in the symbol table.
    guard
      let fileRoot = typeSyntax.root.as(SourceFileSyntax.self),
      symbolTable.moduleMap[fileRoot] != nil
    else {
      return .failure(.syntaxNotInSymbolTable(rootKind: typeSyntax.root.kind))
    }

    // // Resolve type references (or return tuple/function)
    // let typeReferenceResults: [Result<PartiallyResolvedTypeIdentifier, LocalizedTypeResolutionFailure>]

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
        originatingSyntax: typeSyntax
      )
    case .success(.member(let baseTypeSyntax, .success(let memberComponent))):
      let baseTypeResult = resolveSyntax(typeSyntax: baseTypeSyntax)
      return resolveMember(
        baseType: baseTypeResult,
        firstTypeMember: ImplicitTypeReferenceComponent(from: memberComponent)
      )
    case .success(.composition(let constituentTypes)):
      // TODO: Record assumption that `consituentTypes` is unique.
      var syntaxToTypes = [TypeSyntax: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>]()
      for constituentTypeSyntax in constituentTypes {
        syntaxToTypes[constituentTypeSyntax] = resolveSyntax(typeSyntax: constituentTypeSyntax)
      }
      return reduceComposition(syntaxToTypes)
    case .failure(let failure):
      return Result.failure(Failure.other(failure))
    case .success(.member(base: _, .failure(let nameFailure))),
      .success(.typeIdentifier(.failure(let nameFailure))):
      return Result.failure(Failure.other(nameFailure))
    // case .memberResults(let typeReferences):
    //   typeReferenceResults = typeReferences
    }

    // // Single-type case
    // guard typeReferenceResults.count > 1 else {
    //   log("Partially resolved \(typeSyntax.trimmedDescription) to type reference \(firstTypeReferenceResult)")
    //   switch firstTypeReferenceResult {
    //   case .success(let typeReference):
    //     return resolveTypeReference(
    //       typeBaseComponent: ImplicitTypeReferenceComponent(from: typeReference),
    //       originatingSyntax: typeSyntax
    //     )
    //   case .failure(let resolutionFailure):
    //     return .failure(Failure.other(resolutionFailure))
    //   }
    // }

    // // Composition case
    //
    // // Look up the found type references
    // log("Partially resolved \(typeSyntax.trimmedDescription) to type references \(typeReferenceResults)")
    //
    // // Collect valid types and failures
    // var types = [ResolvedNominalTypeReference]()
    // var failures = [TypeSyntax: Failure]()
    // for typeReferenceResult in typeReferenceResults {
    //   // Extract the type reference or log error
    //   let typeReference: PartiallyResolvedTypeIdentifier
    //   switch typeReferenceResult {
    //   case .success(let success):
    //     typeReference = success
    //   case .failure(let localizedFailure):
    //     // Log failure but continue in case others succeed
    //     failures[typeSyntax] = Failure.other(localizedFailure)
    //     continue
    //   }
    //
    //   let childTypeSyntax = typeReference.lastComponent.introducingSyntax
    //   switch resolveTypeReferences(typeReference, originatingSyntax: typeSyntax) {
    //   // Only nominals are valid in compositions
    //   // TODO: Diagnose composing metatype but distinguish from `& Any`
    //   case .success(.memberResults(let nominals)):
    //     if _checkNominalInCompositionIsClassOrProtocol {
    //       switch (nominals.count, nominals.first?.mainDecl.kind) {
    //       // If we have one nominal, check it's a protocol or class.
    //       // If we have multiple, i.e., a composition, we've already  checked it recursively.
    //       case (1, .protocolDecl), (1, .classDecl), (2..., _):
    //         break
    //       // If we have no nominals, e.g., `Int.Type`, or a single nominal that's not
    //       // a struct/enum/actor, we throw an error
    //       default:
    //         failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
    //           resolved: .memberResults(nominals)
    //         )
    //       }
    //     }
    //     types.append(contentsOf: nominals)
    //   // Tuples/function
    //   case .success(.function(let argumentCount)):
    //     failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
    //       resolved: .function(argumentCount: argumentCount)
    //     )
    //   case .success(.tuple(let labels)):
    //     failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
    //       resolved: .tuple(labels: labels)
    //     )
    //   // Ignore if this particular type didn't contain the type member.
    //   // E.g.
    //   //   protocol A { typealias T = Int }
    //   //   protocol B {}
    //   //   let ab: (A & B).T // ✅
    //   case .failure(Failure.noTypeMember):
    //     continue
    //   case .failure(let resolutionFailure):
    //     failures[childTypeSyntax] = Failure.invalidChild(resolutionFailure)
    //   }
    // }
    //
    // // Stop even if we only have one failure
    // guard failures.isEmpty else {
    //   log("Resolved \(typeSyntax.trimmedDescription) to failures \(failures)")
    //   return Result.failure(Failure.invalidComposition(failures))
    // }
    //
    // // TODO: Ensure we got at least one type member
    //
    // log("Resolved \(typeSyntax.trimmedDescription) to types \(types))")
    // return Result.success(MemberLookupResult.memberResults(types))
  }

  func reduceComposition(
    _ syntaxToTypes: [TypeSyntax: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>]
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // Composition case

    // Look up the found type references
    // log("Partially resolved \(typeSyntax.trimmedDescription) to type references \(typeReferenceResults)")

    // Collect valid types and failures
    var anyTypeCounter = 0
    var types = [ResolvedNominalTypeReference]()
    var failures = [TypeSyntax: Failure]()
    // for typeReferenceResult in typeReferenceResults {
    for (childTypeSyntax, childTypeResult) in syntaxToTypes {
      // // Extract the type reference or log error
      // let typeReference: PartiallyResolvedTypeIdentifier
      // switch typeReferenceResult {
      // case .success(let success):
      //   typeReference = success
      // case .failure(let localizedFailure):
      //   // Log failure but continue in case others succeed
      //   failures[typeSyntax] = Failure.other(localizedFailure)
      //   continue
      // }

      // let childTypeSyntax = typeReference.lastComponent.introducingSyntax
      // switch resolveTypeReference(typeBaseComponent: typeReference, originatingSyntax: typeSyntax) {
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
            failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
              resolved: .memberResults(nominals)
            )
          }
        }
        types.append(contentsOf: nominals)
      // Tuples/function
      case .success(.function(let argumentCount)):
        failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
          resolved: .function(argumentCount: argumentCount)
        )
      case .success(.tuple(let labels)):
        failures[childTypeSyntax] = Failure.cannotComposeNonClassOrProtocol(
          resolved: .tuple(labels: labels)
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
        failures[childTypeSyntax] = resolutionFailure
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

  fileprivate mutating func resolveExtendedTypeSyntax(
    extensionDecl: ExtensionDeclSyntax
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    withLogging(
      request: "Extended type syntax `\(extensionDecl.extendedType.trimmedDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveExtendedTypeSyntax(extensionDecl: extensionDecl)
    }
  }

  /// Resolve the given type syntax from an extension declaration
  /// to a single nominal type.
  ///
  /// Note that we only diagnose extending tuples/functions and compositions
  /// (e.g. `Codable = Encodable & Decodable`). However, we don't diagnose
  /// things like extending an existential (e.g. `extension any Collection`).
  fileprivate mutating func _resolveExtendedTypeSyntax(
    extensionDecl: ExtensionDeclSyntax
  ) -> Result<ResolvedNominalTypeReference, Failure> {
    // Throw if syntax resolution fails
    let lookupResult: MemberLookupResult<ResolvedNominalTypeReference>
    switch resolveSyntax(typeSyntax: extensionDecl.extendedType) {
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

  fileprivate mutating func resolveTypeReference(
    typeBaseComponent: ImplicitTypeReferenceComponent,
    originatingSyntax: TypeSyntax
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Type reference `\(typeBaseComponent.debugDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveTypeReference(
        typeBaseComponent: typeBaseComponent,
        originatingSyntax: originatingSyntax
      )
    }
  }

  fileprivate mutating func _resolveTypeReference(
    // _ typeReference: PartiallyResolvedTypeIdentifier,
    typeBaseComponent: ImplicitTypeReferenceComponent,
    originatingSyntax: TypeSyntax
      // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
      // requester: Requester,
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // log("[For syntax \(originatingSyntax.trimmedDescription)] Resolving ref '\(typeReference)'")

    // Get the base type
    // let (optionalModule, typeName) = (typeBaseComponent.module, typeBaseComponent.base.name)

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
        configuredRegions: configuredRegions
      )
    }
    // log(
    //   "[For syntax \(originatingSyntax.trimmedDescription)] Partially resolved base '\(typeName.name)' to  `\(baseLookupResults)`"
    // )

    // Find first matching type declaration
    // TODO: Merge lookup/skip logic if possible
    for lookupResult in baseLookupResults {
      // The enclosing type
      let enclosingTypeResult: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>
      // False if we can return the enclosing type itself; true if we need to
      // perform qualified lookup and return a type member.
      let lookForSelectedMember: Bool

      switch lookupResult {
      case .lookInsideType(let typeDecl, let findSelectedMember):
        enclosingTypeResult = resolveTypeDecl(
          baseTypeDecl: typeDecl,
          baseTypeLikeSyntax: typeBaseComponent.introducingSyntax,
          // memberChain: memberChainPrefix + typeReference.memberChain.map(ImplicitTypeReferenceComponent.init(from:)),
          // originatingSyntax: originatingSyntax
        )
        lookForSelectedMember = findSelectedMember
      case .lookInsideExtension(let extensionDecl, let findSelectedMember):
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
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl) {
        case .success(let type):
          enclosingTypeResult = Result.success(MemberLookupResult.memberResults([type]))
        case .failure(let failure):
          return .failure(failure)
        }
        lookForSelectedMember = findSelectedMember
      case .lookForGenericParameters(let extensionDecl):
        // Resolve extended type
        let baseType: ResolvedNominalTypeReference
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl) {
        case .success(let type):
          baseType = type
        case .failure(let failure):
          return Result.failure(Failure.invalidBaseType(failure))
        }

        // Check for generic parameters
        // TODO: Should we diagnose
        guard let genericParameter = baseType.mainDecl.findGenericParameters(withName: typeBaseComponent.name).first
        else { continue }
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
        firstTypeMember: typeBaseComponent
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

  fileprivate mutating func resolveTypeDecl(
    baseTypeDecl: TypeDeclSyntax,
    baseTypeLikeSyntax: TypeLikeSyntax
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Decl \(baseTypeDecl.kind) `\(baseTypeDecl.name.trimmedDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveTypeDecl(
        baseTypeDecl: baseTypeDecl,
        baseTypeLikeSyntax: baseTypeLikeSyntax
      )
    }
  }

  /// Resolve the given type declaration produced by the given `baseTypeLikeSyntax`.
  /// Then, resolve the given members. This subrequest was initiated by a request
  /// to resolve a ``originatingSyntax``.
  ///
  /// For instance:
  ///   protocol A {}
  ///   protocol B {}
  ///   let ab: A & B // <- Initial look up here
  /// In this example, we'll find the type references "A" and "B" produced by
  /// the `A` and `B` type syntax in the variable declaration. Once we perform
  /// unqualified lookup and figure out that "A" refers to `protocol A`, we call
  /// `resolveTypeDecl` with `protocol A` as the base type declaration, `A` as
  /// the type syntax (from the `let` declaration), with an empty member chain
  /// and `A & B` as the originating syntax.
  fileprivate mutating func _resolveTypeDecl(
    baseTypeDecl: TypeDeclSyntax,
    baseTypeLikeSyntax: TypeLikeSyntax,
    // memberChain: [ImplicitTypeReferenceComponent],
    // originatingSyntax: TypeSyntax
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // log(
    //   "[For syntax \(originatingSyntax)] Resolving decl kind \(baseTypeDecl.kind) `\(baseTypeDecl.trimmedDescription)` with chain \(memberChain)"
    // )

    // We mainly handle nominal types; type aliases are trivially recursive, and we skip
    // associated types and generic parameters
    let nominalDecl: NominalTypeDeclSyntax2
    if let nominalTypeDecl = baseTypeDecl.as(NominalTypeDeclSyntax2.self) {
      nominalDecl = nominalTypeDecl
    } else if let typeAlias = baseTypeDecl.as(TypeAliasDeclSyntax.self) {
      log(
        "Partially resolved to type alias = \(typeAlias.initializer.value)."
      )

      let aliasedResult = resolveSyntax(typeSyntax: typeAlias.initializer.value)
      // Map error so that callers don't think this type decl has an issue (the type alias is diagnosed separately)
      return aliasedResult.mapError(Failure.invalidAliasedType(_:))
    } else { /* else if it's an associated type or generic parameter */
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name.trimmedDescription)'] Declaration type doesn't have members."
      // )
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
      return .failure(.other(NominalTypeDeclSyntax2.ChainResolutionFailure.invalidIdentifier(invalidIdentifier)))
    }

    switch typeChain {
    case .resolved(let qualifiedTypeName):
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name.trimmedDescription)'] Resolved to type chain \(qualifiedTypeName.debugDescription)"
      // )

      return Result.success(
        MemberLookupResult.memberResults([
          ResolvedNominalTypeReference(
            mainDecl: nominalDecl,
            name: qualifiedTypeName,
            originatingSyntax: baseTypeLikeSyntax
          )
        ])
      )
    case .partiallyResolved(let partiallyResolvedName):
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name.trimmedDescription)'] Partially resolved to type chain \(partiallyResolvedName.debugDescription)."
      // )

      // Resolve the base extension and resolve the type chain
      let qualifiedBaseResult = resolveExtendedTypeSyntax(extensionDecl: partiallyResolvedName.base)
      let module: Identifier? = nil  // TODO: Find the actual module
      switch qualifiedBaseResult {
      case .success(let resolvedExtendedBaseNominal):
        let resolvedBaseNominal = partiallyResolvedName.resolve(
          resolvedBase: resolvedExtendedBaseNominal,
          originatingSyntax: baseTypeLikeSyntax,
          module: module
        )
        return Result.success(
          MemberLookupResult.memberResults([resolvedBaseNominal])
        )
      case .failure(let failure):
        return Result.failure(Failure.invalidBaseType(failure))
      }
    }
  }

  fileprivate mutating func resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    firstTypeMember: ImplicitTypeReferenceComponent
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    withLogging(
      request: "Member `\(firstTypeMember.debugDescription)`",
      describe: \._debugDescription
    ) {
      $0._resolveMember(baseType: baseType, firstTypeMember: firstTypeMember)
    }
  }

  fileprivate mutating func _resolveMember(
    baseType: Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure>,
    firstTypeMember: ImplicitTypeReferenceComponent
  ) -> Result<MemberLookupResult<ResolvedNominalTypeReference>, Failure> {
    // // Return if we don't have type members
    // guard let firstTypeMember = memberChain.first else {
    //   log(
    //     "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name.trimmedDescription)'] Resolved to \(baseLookupResult)."
    //   )
    //   return baseLookupResult
    // }
    // let remainingMemberChain = Array(memberChain.dropFirst())
    // log(
    //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name.trimmedDescription)'] Partially resolved base to \(baseLookupResult._debugDescription) with next base \(firstTypeMember) with chain \(remainingMemberChain)."
    // )

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

    // Perform qualified type lookup
    //
    // We collect all types so the type checker can check if members of
    // compositions actually resolve to the same type. For instance:
    //   protocol A { typealias T = Int }
    //   final class B { typealias T = [String].Index /* i.e. Int */ }
    //   protocol C { typealias T = Int }
    //   typealias ABC = A & B & C
    //   let a: ABC.T // ✅ T resolves to `Int` in both cases
    // Of course, if we change the class' alias to `typealias T = String`,
    // the compiler will complain that `ABC.T` is ambiguous.
    //
    // Also, we collect all failures for better diagnostics, instead
    // of diagnosing just one error at a time.
    var results = [TypeDeclSyntax: MemberLookupResult<ResolvedNominalTypeReference>]()
    var failures = [TypeLikeSyntax: Failure]()
    var nominalBaseTypes = [NominalType]()
    for baseType in baseTypes {
      let (mainDecl, name) = (baseType.mainDecl, baseType.name)
      // We'll collect the result, nominal base type, and type syntax
      let memberResult:
        Result<(typeDecl: TypeDeclSyntax, result: MemberLookupResult<ResolvedNominalTypeReference>)?, Failure>
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

      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name)' & qualified '\(name.debugDescription)'] Requesting extension binding."
      // )

      // Bind extensions and construct a nominal type.
      // We ignore failures since they're from non-matching extensions and diagnosed separately
      let (extensions, _) = bindExtensions(
        matchingForName: name,
        resolvedFrom: firstTypeMember.introducingSyntax
      )
      let nominalBaseType = NominalType(
        qualifiedName: name,
        mainDecl: mainDecl,
        redeclarations: [],
        extensions: extensions
      )
      nominalBaseTypes.append(nominalBaseType)
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name)' & qualified '\(name.debugDescription)'] Bound extensions \(extensions)."
      // )

      // Perform direct type lookup
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
        configuredRegions: configuredRegions,
        _verbose: _verbose
      )
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name)' & qualified '\(name.debugDescription) & extensions: \(extensions)'] Direct lookup yielded: \(typeDeclsResult._debugSyntaxDescription)."
      // )

      // Get the referenced type decl (and address failures)
      let memberTypeDecl: TypeDeclSyntax
      switch typeDeclsResult {
      case .success(let typeDecls):
        // Skip this nominal type if it didn't contain said type member.
        //
        // E.g. In `(Encodable & Collection<Int>).Element`, `Encodable` may not have an `Element`
        // type member.
        guard let firstTypeDecl = typeDecls.first else {
          memberResult = Result.success(nil)
          continue
        }
        // Cannot have multiple type declarations named the same.
        // E.g.
        //   typealias A = Int
        //   typealias A = Bool
        //   let a: A // ❌ ambiguous
        // TODO: Ensure we're not shadowing; I think
        // we can only shadow type decls from external modules
        guard typeDecls.count == 1 else {
          memberResult = Result.failure(Failure.ambiguousTypeDecl(typeDecls))
          continue
        }

        memberTypeDecl = firstTypeDecl
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
      // log(
      //   "[For syntax \(originatingSyntax) & \(baseTypeDecl.kind) '\(baseTypeDecl.name)' & qualified '\(name)'] Resolved type member \(firstTypeMember) to \(memberTypeDecl.trimmedDescription)."
      // )

      // Resolve this type declaration and add it to the results
      memberResult = resolveTypeDecl(
        baseTypeDecl: memberTypeDecl,
        baseTypeLikeSyntax: firstTypeMember.introducingSyntax,
        // memberChain: remainingMemberChain,
        // originatingSyntax: originatingSyntax
      ).map({ result in Optional((typeDecl: memberTypeDecl, result: result)) })
    }

    // If there are failures, give up.
    //
    // We can see this in the compiler because writing the following, we only
    // get an error for the alias:
    //   protocol ValidProto { typealias IntAlias = Int }
    //
    //   typealias InvalidAlias = Int.Type.InvalidMember // ❌ No member 'InvalidMember'
    //   typealias Composition = ValidProto & InvalidAlias
    //   let a: Composition.IntAlias = "" // ✅ No errors yet
    // It's only when we use a valid composition that we get an error, e.g.:
    //   typealias Composition = ValidProto & Any
    //   let a: Composition.IntAlias = "" // ❌ Cannot value of type 'String' to specified type 'Int'
    guard failures.isEmpty else {
      // TODO: Throw the right failure
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

  mutating func bindExtensions(
    matchingForName nameQuery: QualifiedTypeName,
    resolvedFrom originatingSyntax: TypeLikeSyntax
      // TODO: We don't technically need the `failures` result for the API; only for debugging.
  ) -> (matches: [SourceFileSyntax: [ExtensionDeclSyntax]], failures: [ExtensionDeclSyntax: Failure]) {
    // TODO: Wrap the type syntax in a SymbolTableSyntax<TypeSyntax> that guarantees this
    guard let file = originatingSyntax.root.as(SourceFileSyntax.self) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly had to resolve type syntax whose root isn't a source file."
      )
    }
    let allExtensionDecls: [SourceFileSyntax: [ExtensionDeclSyntax]] = symbolTable.findAllExtensions(
      accessibleFrom: file,
      configuredRegions: configuredRegions
    )
    var matches = [SourceFileSyntax: [ExtensionDeclSyntax]]()
    var failures = [ExtensionDeclSyntax: Failure]()
    for (file, extensionDecls) in allExtensionDecls {
      for extensionDecl in extensionDecls {
        let extendedType: ResolvedNominalTypeReference

        // Resolve the extended type (cached by ``resolveSyntax``)
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl) {
        case .success(let nominalType):
          extendedType = nominalType
        case .failure(let failure):
          failures[extensionDecl] = failure
          continue
        }

        if extendedType.name == nameQuery { matches[file, default: []].append(extensionDecl) }
      }
    }

    return (matches, failures)
  }
}
