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
@_spi(_QualifiedLookup) public struct MinimalNominal: Sendable, Hashable, CustomDebugStringConvertible {
  public let mainDecl: NominalTypeDeclSyntax2
  public let name: QualifiedTypeName

  public var debugDescription: String {
    "\(name) (\(mainDecl.kind))"
  }
}

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeQualifier {
  func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    print("\(file):\(line)", component)
  }

  public indirect enum Failure: Error {
    /// Only protocol, class and composition types can form compositions.
    ///
    /// I.e. We don't allow structs/enums/actors, functions, tuples.
    case cannotComposeNonClassOrProtocol(resolved: MemberLookupResult<MinimalNominal>)
    case noTypeMember(member: Identifier, in: MemberLookupResult<NominalType>)
    // TODO: Can we simplify to a single failure?
    case invalidChildren([TypeSyntax: [Failure]])
    /// We can only extend structs/enums/classes/actors/protocols
    ///
    /// I.e. We can't extend tuples, functions, protocol compositions, metatypes, etc.
    case cannotExtendNonNominal(ExtensionDeclSyntax, nonnominal: MemberLookupResult<NominalType>)
    /// Child has error, so we can't qualify this type but we can't offer a useful diagnostic either.
    ///
    /// E.g.
    ///   typealias A = Encodable & Int.Type // ❌ error: non-protocol, non-class type 'Int.Type' cannot be used within a protocol-constrained type
    ///   func f(_: A) {} // No diagnostic here
    case invalidChild(Failure)
    case invalidComposition([TypeSyntax: Failure])
    case other(any Error)

    // case noMemberType(PartiallyResolvedTypeIdentifier.Component, in: NominalType)
  }

  public private(set) var failures = [TypeSyntax: [Failure]]()
  var boundExtensions = [ExtensionDeclSyntax: MinimalNominal]()

  let symbolTable: SymbolTable3
  let configuredRegions: ConfiguredRegions?
  let _verbose: Bool
  let _checkNominalInCompositionIsClassOrProtocol = true

  public init(symbolTable: SymbolTable3, configuredRegions: ConfiguredRegions?, _verbose: Bool) {
    self.symbolTable = symbolTable
    self.configuredRegions = configuredRegions
    self._verbose = _verbose
  }

  // /// Adds the given result to a collective result.
  // ///
  // /// Returns critical error if one occurs. These occur when we can't compose with tuples/functions.
  // // TODO: Consider returning a Bool and having callers throw
  // fileprivate mutating func addResult(
  //   _ result: Result<MemberLookupResult<MinimalNominal>, Failure>,
  //   to collectiveResult: inout MemberLookupResult<MinimalNominal>?
  // ) -> Failure? {
  //   // Simply log failures as other type results might succeed
  //   let lookupResult: MemberLookupResult<MinimalNominal>
  //   switch result {
  //   case .success(let result):
  //     lookupResult = result
  //   case .failure(let failure):
  //     self.failures.append(.other(failure))
  //     return nil
  //   }
  //
  //   switch (collectiveResult, lookupResult) {
  //   // Initial assignment
  //   case (nil, let lookupResult):
  //     collectiveResult = lookupResult
  //   // Cannot compose tuple/function types
  //   case (_, .function), (_, .tuple):
  //     return Failure.cannotComposeNonClassOrProtocol(syntax: TypeSyntax)
  //   case (.function, _), (.tuple, _):
  //     return Failure.cannotComposeTupleOrFunction
  //   // Otherwise, combine members
  //   case (.memberResults(let currentTypes), .memberResults(let newTypes)):
  //     collectiveResult = MemberLookupResult.memberResults(currentTypes + newTypes)
  //   }
  //
  //   // No failures
  //   return nil
  // }
  fileprivate mutating func _reduceResults(
    _ results: [TypeSyntax: Result<MemberLookupResult<MinimalNominal>, Failure>]
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    if results.isEmpty {}
    // Forward empty results
    guard let (_, firstResult) = results.first else {
      return Result.success(MemberLookupResult.memberResults([]))
    }
    // Forward single result (the rest of the functions handles compositions)
    guard results.count == 1 else {
      return firstResult
    }

    // Handle compositions
    //
    // We handled tuples/functions above. Now, we assume we have a list of nominals.
    var nominalTypes = [MinimalNominal]()
    var invalidTypes = [TypeSyntax: [Failure]]()

    for (typeSyntax, result) in results {
      // Simply log failures as other type results might succeed
      let lookupResult: MemberLookupResult<MinimalNominal>
      switch result {
      case .success(let result):
        lookupResult = result
      case .failure(let failure):
        self.failures[typeSyntax, default: []].append(.other(failure))
        continue
      }

      switch lookupResult {
      // Cannot compose tuple/function types
      case .function, .tuple:
        invalidTypes[typeSyntax, default: []].append(Failure.cannotComposeNonClassOrProtocol(resolved: lookupResult))
      // Otherwise, combine members
      case .memberResults(let newTypes):
        nominalTypes.append(contentsOf: newTypes)
      }
    }

    guard invalidTypes.isEmpty else {
      return Result.failure(.invalidChildren(invalidTypes))
    }

    return Result.success(MemberLookupResult.memberResults(nominalTypes))
  }

  public mutating func resolveSyntax(
    typeSyntax: TypeSyntax,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // requester: Requester,
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    log("Resolving syntax: \(typeSyntax.trimmedDescription)")

    // Resolve type references (or return tuple/function)
    let isComposition: Bool
    let typeReferenceResults: [Result<PartiallyResolvedTypeIdentifier, LocalizedTypeResolutionFailure>]
    switch typeSyntax.partiallyResolve() {
    case .function(let argumentCount):
      log("Resolved \(typeSyntax.trimmedDescription) to .function")
      return Result.success(.function(argumentCount: argumentCount))
    case .tuple(let labels):
      log("Resolved \(typeSyntax.trimmedDescription) to .tuple")
      return Result.success(.tuple(labels: labels))
    case .memberResults(let typeReferences):
      typeReferenceResults = typeReferences
    }

    // Empty type case
    guard let firstTypeReferenceResult = typeReferenceResults.first else {
      log("Resolved \(typeSyntax.trimmedDescription) to empty type")
      return Result.success(.memberResults([]))
    }

    // Single-type case
    guard typeReferenceResults.count > 1 else {
      log("Partially resolved \(typeSyntax.trimmedDescription) to type reference \(firstTypeReferenceResult)")
      switch firstTypeReferenceResult {
      case .success(let typeReference):
        return resolveTypeReferences(typeReference, originatingSyntax: typeSyntax)
      case .failure(let resolutionFailure):
        return .failure(Failure.other(resolutionFailure))
      }
    }

    // Composition case

    // Look up the found type references
    log("Partially resolved \(typeSyntax.trimmedDescription) to type references \(typeReferenceResults)")

    // Collect valid types and failures
    var types = [MinimalNominal]()
    var failures = [TypeSyntax: Failure]()
    for typeReferenceResult in typeReferenceResults {
      // Extract the type reference or log error
      let typeReference: PartiallyResolvedTypeIdentifier
      switch typeReferenceResult {
      case .success(let success):
        typeReference = success
      case .failure(let localizedFailure):
        // Log failure but continue in case others succeed
        failures[typeSyntax] = Failure.other(localizedFailure)
        continue
      }

      let childTypeSyntax = typeReference.typeSyntax
      switch resolveTypeReferences(typeReference, originatingSyntax: typeSyntax) {
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
      case .failure(let resolutionFailure):
        failures[childTypeSyntax] = Failure.invalidChild(resolutionFailure)
      }
    }

    // Stop even if we only have one failure
    guard failures.isEmpty else {
      log("Resolved \(typeSyntax.trimmedDescription) to failures \(failures.mapValues(\.trimmedDescription))")
      return Result.failure(Failure.invalidComposition(failures))
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
    extensionDecl: ExtensionDeclSyntax
  ) -> Result<MinimalNominal, Failure> {
    // Throw if syntax resolution fails
    let lookupResult: MemberLookupResult<MinimalNominal>
    switch resolveSyntax(typeSyntax: extensionDecl.extendedType) {
    case .success(let result):
      lookupResult = result
    case .failure(let failure):
      return .failure(failure)
    }

    // Extract nominal types (tuples/functions aren't nominal)
    let memberResults: [MinimalNominal]
    switch lookupResult {
    case .memberResults(let results):
      memberResults = results
    case .function, .tuple:
      return .failure(.cannotExtendNonNominal(extensionDecl))
    }

    // Extensions type syntax should resolve to exactly one nominal type
    guard let nominalType = memberResults.first, memberResults.count == 1 else {
      return .failure(.cannotExtendNonNominal(extensionDecl))
    }

    return .success(nominalType)
  }

  fileprivate mutating func resolveTypeReferences(
    _ typeReference: PartiallyResolvedTypeIdentifier,
    originatingSyntax: TypeSyntax
      // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
      // requester: Requester,
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    log("[For syntax \(originatingSyntax.trimmedDescription)] Resolving ref '\(typeReference)'")

    // Get the base type
    let (optionalModule, typeName) = (typeReference.base.module, typeReference.base.name)

    // Perfom unqualified lookup up to find the base type's declaration
    //
    // e.g.
    //   extension String.UTF8View { <- Resolve
    //     struct A { // <- Resolve
    //       struct B {} // <- Look up here
    //     }
    //   }
    let baseLookupResults: [UnqualifiedTypeLookupResult]
    if let module = optionalModule {
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
      baseLookupResults = originatingSyntax.findUnqualifiedType(typeName, configuredRegions: configuredRegions)
    }
    log(
      "[For syntax \(originatingSyntax.trimmedDescription)] Partially resolved base '\(typeName.name)' to  `\(baseLookupResults)`"
    )

    // Find first matching type declaration
    // TODO: Merge lookup/skip logic if possible
    for lookupResult in baseLookupResults {
      switch lookupResult {
      case .lookInsideType(let typeDecl, let selectMember):
        // An array with the selectMember, or empty if not provided
        let memberChainPrefix = selectMember.map({ [$0] }) ?? []

        let typeLookupResult = resolveTypeDecl(
          typeDecl: typeDecl,
          memberChain: memberChainPrefix + typeReference.memberChain,
          originatingSyntax: originatingSyntax
        )
        // We skip only if the lookup succeeded but found no matching types
        // (i.e. we didn't find any types not because the underlying type declaration has an error
        // but because this type has no such member)
        if case Result.success(MemberLookupResult.memberResults([])) = typeLookupResult {
          continue
        }
        return typeLookupResult
      case .lookInsideExtension(let extensionDecl, let selectMember):
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
        let enclosingType: MinimalNominal
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl) {
        case .success(let type):
          enclosingType = type
        case .failure(let failure):
          return .failure(failure)
        }

        // An array with the selectMember, or empty if not provided
        let memberChainPrefix = selectMember.map({ [$0] }) ?? []

        let typeLookupResult = resolveTypeDecl(
          typeDecl: TypeDeclSyntax(enclosingType.mainDecl),
          memberChain: memberChainPrefix + typeReference.memberChain,
          // Resolve from the location of the extension declaration
          originatingSyntax: extensionDecl.extendedType
        )
        // Skip logic like above
        if case Result.success(MemberLookupResult.memberResults([])) = typeLookupResult {
          continue
        }
        return typeLookupResult
      case .lookForGenericParameters(let extensionDecl):
        // Resolve extended type
        let baseType: MinimalNominal
        switch resolveExtendedTypeSyntax(extensionDecl: extensionDecl) {
        case .success(let type):
          baseType = type
        case .failure(let failure):
          return .failure(failure)
        }

        // Check for generic parameters
        // TODO: Should we diagnose
        guard let genericParameter = baseType.mainDecl.findGenericParameters(withName: typeName).first else { continue }
        // Forward to the type-declaration resolver
        let typeLookupResult = resolveTypeDecl(
          typeDecl: TypeDeclSyntax(genericParameter),
          memberChain: typeReference.memberChain,
          originatingSyntax: originatingSyntax
        )
        // Skip logic like above
        if case Result.success(MemberLookupResult.memberResults([])) = typeLookupResult {
          continue
        }
        return typeLookupResult
      case .lookInModule:
        // TODO: Handle
        break
      case .lookInImports:
        // TODO: Handle
        break
      }
    }

    // No type matched
    return .success(.memberResults([]))
  }

  mutating func resolveTypeDecl(
    typeDecl: TypeDeclSyntax,
    memberChain: [PartiallyResolvedTypeIdentifier.Component],
    originatingSyntax: TypeSyntax
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    log(
      "[For syntax \(originatingSyntax)] Resolving decl kind \(typeDecl.kind) `\(typeDecl.trimmedDescription)` with chain \(memberChain)"
    )

    // We only handle type aliases and nominal types (we skip associated types and generic parameters)
    let baseLookupResult: Result<MemberLookupResult<MinimalNominal>, Failure>
    if let nominalDecl = typeDecl.as(NominalTypeDeclSyntax2.self) {
      // Get the type chain
      let typeChain: ChainResult
      switch nominalDecl.findTypeChain(module: nil) {
      case .success(let result):
        typeChain = result
      case .failure(let failure):
        return .failure(.other(failure))
      }

      switch typeChain {
      case .resolved(let qualifiedTypeName):
        log(
          "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Resolved to type chain \(qualifiedTypeName.debugDescription)"
        )

        baseLookupResult = Result.success(
          MemberLookupResult.memberResults([MinimalNominal(mainDecl: nominalDecl, name: qualifiedTypeName)])
        )
      case .partiallyResolved(let partiallyResolvedName):
        log(
          "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Partially resolved to type chain \(partiallyResolvedName.debugDescription)."
        )

        let qualifiedBaseResults = resolveSyntax(typeSyntax: partiallyResolvedName.base)
        let module: Identifier? = nil  // TODO: Find the actual module
        baseLookupResult = qualifiedBaseResults.map({ qualifiedBaseResult in
          qualifiedBaseResult.mapMembers({ qualifiedBase in
            partiallyResolvedName.resolve(resolvedBase: qualifiedBase, module: module)
          })
        })
      }
    } else if let typeAlias = typeDecl.as(TypeAliasDeclSyntax.self) {
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Partially resolved to type alias with syntax \(typeAlias.initializer.value)."
      )
      baseLookupResult = resolveSyntax(typeSyntax: typeAlias.initializer.value)
    } else {
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Declaration type doesn't have members."
      )
      // No members for generic parameters and associated types
      return .success(MemberLookupResult.memberResults([]))
    }

    // Return if we don't have type members
    guard let firstTypeMember = memberChain.first else {
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Resolved to \(baseLookupResult)."
      )
      return baseLookupResult
    }
    let remainingMemberChain = Array(memberChain.dropFirst())
    log(
      "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name.trimmedDescription)'] Partially resolved base to \(baseLookupResult._debugDescription) with next base \(firstTypeMember) with chain \(remainingMemberChain)."
    )

    // Recursively find type members
    //
    // First, extract the base qualified types
    let baseTypes: [MinimalNominal]
    switch baseLookupResult {
    case .success(.memberResults(let types)):
      baseTypes = types
    // Tuples/functions don't have type members
    case .success(.function), .success(.tuple):
      return .failure(.noTupleOrFunctionTypeMembers)
    // Nothing smart we can do here
    case .failure(let failure):
      return .failure(failure)
    }
    // Perform qualified type lookup
    var result: MemberLookupResult<MinimalNominal>? = nil
    for baseType in baseTypes {
      let (mainDecl, name) = (baseType.mainDecl, baseType.name)
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name)' & qualified '\(name.debugDescription)'] Requesting extension binding."
      )
      let extensions = bindExtensions(matchingForName: name, resolvedFrom: originatingSyntax)
      let nominalType = NominalType(
        qualifiedName: name,
        mainDecl: mainDecl,
        redeclarations: [],
        extensions: extensions
      )
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name)' & qualified '\(name.debugDescription)'] Bound extensions \(extensions)."
      )

      // TODO: Figure out imported modules
      guard let file = originatingSyntax.root.as(SourceFileSyntax.self) else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Unexpectedly had to resolve type syntax whose root isn't a source file."
        )
      }
      let lookupPosition = (file: file, position: originatingSyntax.position)
      let typeDeclsResult = nominalType.findMemberTypes(
        component: firstTypeMember,
        lookupPosition: lookupPosition,
        importedModules: [],
        moduleMap: symbolTable.moduleMap,
        configuredRegions: configuredRegions,
        _verbose: _verbose
      )
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name)' & qualified '\(name.debugDescription) & extensions: \(extensions)'] Direct lookup yielded: \(typeDeclsResult._debugSyntaxDescription)."
      )
      let memberTypeDecl: TypeDeclSyntax
      switch typeDeclsResult {
      case .success(let typeDecls):
        // Skip this nominal type if it didn't contain said type member.
        //
        // E.g. In `(Encodable & Collection<Int>).Element`, `Encodable` may not have an `Element`
        // type member.
        //
        // TODO: Think about whether we need to diagnose multiple type decls here
        guard let firstDecl = typeDecls.first else { continue }

        // Select the first declaration (others might be shadowed or redeclarations we don't diagnose here)
        memberTypeDecl = firstDecl
      case .failure(let failure):
        failures.append(.other(failure))
        continue
      }
      log(
        "[For syntax \(originatingSyntax) & \(typeDecl.kind) '\(typeDecl.name)' & qualified '\(name)'] Resolved type member \(firstTypeMember) to \(memberTypeDecl.trimmedDescription)."
      )

      // Resolve this type declaration and add it to the results
      if let criticalFailure = addResult(
        resolveTypeDecl(
          typeDecl: memberTypeDecl,
          memberChain: remainingMemberChain,
          originatingSyntax: originatingSyntax
        ),
        to: &result
      ) {
        return .failure(criticalFailure)
      }
    }

    return Result.success(result ?? MemberLookupResult.memberResults([]))
  }

  // mutating func resolveNominalDecl(nominalDecl: NominalTypeDeclSyntax2) -> Result<MinimalNominal, Failure> {
  //   // Get the type chain
  //   let typeChain: ChainResult
  //   switch nominalDecl.findTypeChain(module: nil) {
  //   case .success(let result):
  //     typeChain = result
  //   case .failure(let failure):
  //     return .failure(.other(failure))
  //   }
  //
  //   switch typeChain {
  //   case .resolved(let qualifiedTypeName):
  //     return Result.success(
  //       MemberLookupResult.memberResults([(mainDecl: nominalDecl, name: qualifiedTypeName)])
  //     )
  //   case .partiallyResolved(let partiallyResolvedName):
  //     let qualifiedBaseResults = resolveSyntax(typeSyntax: partiallyResolvedName.base)
  //     let module: Identifier? = nil // TODO: Find the actual module
  //     // TODO: Keep track of the main decl
  //     return qualifiedBaseResults.map({ qualifiedBaseResult in
  //       qualifiedBaseResult.mapMembers({ qualifiedBase in
  //         partiallyResolvedName.resolve(resolvedBase: qualifiedBase, module: module)
  //       })
  //     })
  //   }
  // }

  mutating func bindExtensions(
    matchingForName nameQuery: QualifiedTypeName,
    resolvedFrom originatingSyntax: TypeSyntax
  ) -> [SourceFileSyntax: [ExtensionDeclSyntax]] {
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
    for (file, extensionDecls) in allExtensionDecls {
      for extensionDecl in extensionDecls {
        let extendedType: MinimalNominal

        // Check cache
        if let type = boundExtensions[extensionDecl] {
          extendedType = type
        } else {
          // Cache miss; resolve type
          switch resolveSyntax(typeSyntax: extensionDecl.extendedType) {
          case .success(.memberResults(let extendedTypes)):
            guard let type = extendedTypes.first, extendedTypes.count == 1 else {
              failures.append(.cannotExtendNonNominal(extensionDecl))
              continue
            }
            extendedType = type
          case .success(.function), .success(.tuple):
            failures.append(.cannotExtendNonNominal(extensionDecl))
            continue
          case .failure(let failure):
            failures.append(failure)
            continue
          }
        }

        if extendedType.name == nameQuery { matches[file, default: []].append(extensionDecl) }
      }
    }

    return matches
  }
}
