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

/// The minimal defining components of a nominal type: the main declaration and the qualified name.
/// Unlike ``NominalType``, doesn't include extensions.
typealias MinimalNominal = (mainDecl: NominalTypeDeclSyntax2, name: QualifiedTypeName)

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeQualifier {
  enum Failure: Error {
    case cannotComposeTupleOrFunction
    case noTupleOrFunctionTypeMembers
    case cannotExtendNonNominal(ExtensionDeclSyntax)
    case other(any Error)

    // case noMemberType(PartiallyResolvedTypeIdentifier.Component, in: NominalType)
  }

  var failures = [Failure]()
  var boundExtensions = [ExtensionDeclSyntax: MinimalNominal]()

  let symbolTable: SymbolTable3
  let configuredRegions: ConfiguredRegions

  /// Adds the given result to a collective result.
  ///
  /// Returns critical error if one occurs. These occur when we can't compose with tuples/functions.
  // TODO: Consider returning a Bool and having callers throw
  fileprivate mutating func addResult(
    _ result: Result<MemberLookupResult<MinimalNominal>, Failure>,
    to collectiveResult: inout MemberLookupResult<MinimalNominal>?
  ) -> Failure? {
    // Simply log failures as other type results might succeed
    let lookupResult: MemberLookupResult<MinimalNominal>
    switch result {
    case .success(let result):
      lookupResult = result
    case .failure(let failure):
      self.failures.append(.other(failure))
      return nil
    }

    switch (collectiveResult, lookupResult) {
    // Initial assignment
    case (nil, let lookupResult):
      collectiveResult = lookupResult
    // Cannot compose tuple/function types
    case (_, .function), (_, .tuple):
      return Failure.cannotComposeTupleOrFunction
    case (.function, _), (.tuple, _):
      return Failure.cannotComposeTupleOrFunction
    // Otherwise, combine members
    case (.memberResults(let currentTypes), .memberResults(let newTypes)):
      collectiveResult = MemberLookupResult.memberResults(currentTypes + newTypes)
    }

    // No failures
    return nil
  }

  fileprivate mutating func resolveSyntax(
    typeSyntax: TypeSyntax,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // requester: Requester,
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    // Resolve type; throw on failure
    let resolutionResult: MemberLookupResult<PartiallyResolvedTypeIdentifier>
    var failures = [TypeResolutionFailure]()
    defer { self.failures.append(contentsOf: failures.map(Failure.other)) }
    switch typeSyntax.resolve(failures: &failures) {
    case .success(let result):
      resolutionResult = result
    case .failure(let failure):
      return .failure(.other(failure))
    }

    switch resolutionResult {
    // .function and .tuple are only valid without result types
    case .function(let argumentCount):
      return .success(.function(argumentCount: argumentCount))
    case .tuple(let labels):
      return .success(.tuple(labels: labels))
    // Issue requests for the underlying type identifiers
    case .memberResults(let typeResults):
      var result: MemberLookupResult<MinimalNominal>? = nil
      for typeIdentifier in typeResults {
        if let criticalFailure = addResult(
          resolveTypeReferences(typeIdentifier, originatingSyntax: typeSyntax),
          to: &result
        ) {
          return .failure(criticalFailure)
        }

        // // Simply log failures  as other type results might succeed
        // let lookupResult: MemberLookupResult<MinimalNominal>
        // switch resolveTypeReferences(typeIdentifier) {
        // case .success(let result):
        //   lookupResult = result
        // case .failure(let failure):
        //   self.failures.append(.other(failure))
        // }
        //
        // switch (result, lookupResult) {
        // // Handle initial assignment
        // case (nil, let lookupResult):
        //   result = lookupResult
        // // Cannot compose tuple/function types
        // case (_, .function), (_, .tuple):
        //   return .failure(Failure.cannotComposeTupleOrFunction)
        // case (.function, _), (.tuple, _):
        //   return .failure(Failure.cannotComposeTupleOrFunction)
        // // Otherwise, combine members
        // case (.memberResults(let currentTypes), .memberResults(let newTypes)):
        //   result = MemberLookupResult.memberResults(currentTypes + newTypes)
        // }
      }
      return Result.success(result ?? MemberLookupResult.memberResults([]))
    }
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
    // Get the base type
    let (optionalModule, typeName) = typeReference.base

    // Perfom unqualified lookup up to find the base type's declaration
    // FIXME: We may get .lookForMembers->resolve parent->type-member lookup,
    // or .lookForGenericParameters->resolve extended syntax->find generic params!!
    // TODO: Think about whether we should have the base resolved (do we split cases for extended
    // types and plain lookForMembers if we still need to qualify both?) and if we do,
    // how do we connect it back to the original request
    //
    // e.g.
    //   extension String.UTF8View { <- Resolve
    //     struct A { // <- Resolve
    //       struct B {} // <- Look up here
    //     }
    //   }
    // how do we connect these resolves back?
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

    // Find first matching type declaration
    for lookupResult in baseLookupResults {
      switch lookupResult {
      case .lookInsideType(let typeDecl, let selectMember):
        // An array with the selectMember, or empty if not provided
        let memberChainPrefix = selectMember.map({ [$0] }) ?? []

        return resolveTypeDecl(
          typeDecl: typeDecl,
          memberChain: memberChainPrefix + typeReference.memberChain,
          originatingSyntax: originatingSyntax
        )
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

        return resolveTypeDecl(
          typeDecl: TypeDeclSyntax(enclosingType.mainDecl),
          memberChain: memberChainPrefix + typeReference.memberChain,
          // Resolve from the location of the extension declaration
          originatingSyntax: extensionDecl.extendedType
        )
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
        return resolveTypeDecl(
          typeDecl: TypeDeclSyntax(genericParameter),
          memberChain: typeReference.memberChain,
          originatingSyntax: originatingSyntax
        )
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
        baseLookupResult = Result.success(
          MemberLookupResult.memberResults([(mainDecl: nominalDecl, name: qualifiedTypeName)])
        )
      case .partiallyResolved(let partiallyResolvedName):
        let qualifiedBaseResults = resolveSyntax(typeSyntax: partiallyResolvedName.base)
        let module: Identifier? = nil  // TODO: Find the actual module
        baseLookupResult = qualifiedBaseResults.map({ qualifiedBaseResult in
          qualifiedBaseResult.mapMembers({ qualifiedBase in
            partiallyResolvedName.resolve(resolvedBase: qualifiedBase, module: module)
          })
        })
      }
    } else if let typeAlias = typeDecl.as(TypeAliasDeclSyntax.self) {
      baseLookupResult = resolveSyntax(typeSyntax: typeAlias.initializer.value)
    } else {
      // No members for generic parameters and associated types
      return .success(MemberLookupResult.memberResults([]))
    }

    // Return if we don't have type members
    guard let firstTypeMember = memberChain.first else {
      return baseLookupResult
    }
    let remainingMemberChain = Array(memberChain.dropFirst())

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
    for (mainDecl, name) in baseTypes {
      let extensions = bindExtensions(matchingForName: name, resolvedFrom: originatingSyntax)
      let nominalType = NominalType(
        qualifiedName: name,
        mainDecl: mainDecl,
        redeclarations: [],
        extensions: extensions
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
        configuredRegions: configuredRegions
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
  ) -> [ExtensionDeclSyntax] {
    // TODO: Wrap the type syntax in a SymbolTableSyntax<TypeSyntax> that guarantees this
    guard let file = originatingSyntax.root.as(SourceFileSyntax.self) else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly had to resolve type syntax whose root isn't a source file."
      )
    }
    let extensionDecls: [ExtensionDeclSyntax] = symbolTable.findAllExtensions(
      accessibleFrom: file,
      configuredRegions: configuredRegions
    )
    var matches = [ExtensionDeclSyntax]()
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

      if extendedType.name == nameQuery { matches.append(extensionDecl) }
    }

    return matches
  }
}
