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

typealias MinimalNominal = (mainDecl: NominalTypeDeclSyntax2, name: QualifiedTypeName)

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookup) public struct TypeQualifier {
  enum Failure: Error {
    case cannotComposeTupleOrFunction
    case noTupleOrFunctionTypeMembers
    case cannotExtendNonNominal(ExtensionDeclSyntax)
    case other(any Error)
  }

  var failures = [Failure]()
  var boundExtensions = [ExtensionDeclSyntax: MinimalNominal]()

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
        // Simply log failures  as other type results might succeed
        let lookupResult: MemberLookupResult<MinimalNominal>
        switch resolveTypeReferences(typeIdentifier) {
        case .success(let result):
          lookupResult = result
        case .failure(let failure):
          self.failures.append(.other(failure))
        }

        switch (result, lookupResult) {
        // Handle initial assignment
        case (nil, let lookupResult):
          result = lookupResult
        // Cannot compose tuple/function types
        case (_, .function), (_, .tuple):
          return .failure(Failure.cannotComposeTupleOrFunction)
        case (.function, _), (.tuple, _):
          return .failure(Failure.cannotComposeTupleOrFunction)
        // Otherwise, combine members
        case (.memberResults(let currentTypes), .memberResults(let newTypes)):
          result = MemberLookupResult.memberResults(currentTypes + newTypes)
        }
      }
      return Result.success(result ?? MemberLookupResult.memberResults([]))
    }
  }

  fileprivate mutating func resolveTypeReferences(
    _ typeReference: PartiallyResolvedTypeIdentifier,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // requester: Requester,
  ) -> Result<MemberLookupResult<MinimalNominal>, Failure> {
    var results = [MemberLookupResult<QualifiedTypeName>]()
    // Get the base type
    let (optionalModule, typeName) = typeReference.base

    // Perfom unqualified lookup up to find the base type's declaration
    let foundType: TypeDeclSyntax
    if let module = optionalModule {
      // Top-level unqualified lookup in external module
      //
      // Top-level means that we look for declarations at the file scope of the
      // external module. For instance:
      //   // MyModule>MyFile.swift
      //   extension Int {
      //     func f() { MyModule::f() } // ❌ Member `f` not imported through `MyModule`
      //   }
      foundType = findExternalTopLevelUnqualifiedType(module: module, topLevelName: typeName, fromFileWithID: position.fileID)
    } else {
      // Scoped unqualified lookup in this module
      foundType = findUnqualifiedType(name: typeName, at: position)
    }

    // We only handle type aliases and nominal types (we skip associated types and generic parameters)
    let baseLookupResult: Result<MemberLookupResult<MinimalNominal>, Failure>
    if let typeAlias = foundType.as(TypeAliasDeclSyntax.self) {
      baseLookupResult = resolveSyntax(typeSyntax: typeAlias.initializer.value)
    } else if let nominalDecl = foundType.as(NominalTypeDeclSyntax2.self) {
      baseLookupResult = resolveNominalDecl(nominalDecl: nominalDecl).map({ MemberLookupResult.memberResults([$0]) })
    } else {
      // No members for generic parameters and associated types
      return .success(MemberLookupResult.memberResults([]))
    }

    // Return if we don't have type members
    guard let firstTypeMember = typeReference.memberChain.first else {
      return baseLookupResult
    }

    // Recursively find type members
    //
    // First, extract the base qualified types
    let baseTypes: [MinimalNominal]
    switch baseLookupResult {
    case .success(.memberResults(let types)):
      baseTypes = types
    // Tuple/function don't have type members
    case .success(.function), .success(.tuple):
      return .failure(.noTupleOrFunctionTypeMembers)
    // Nothing smart we can do here
    case .failure(let failure):
      return .failure(failure)
    }
    // Perform qualified type lookup
    for (mainDecl, name) in baseTypes {
      let extensions = bindExtensions(matchingForName: name)
      let nominalType = NominalType(
        qualifiedName: name,
        mainDecl: mainDecl,
        redeclarations: [],
        extensions: extensions
      )
      let typeDecls: [TypeDeclSyntax] = nominalType.declGroups.flatMap({ declGroup in
        declGroup.findDirectTypes(matching: firstTypeMember)
      })
      // TODO: Call resolveNominalDecl
    }
  }

  mutating func resolveNominalDecl(nominalDecl: NominalTypeDeclSyntax2) -> Result<MinimalNominal, Failure> {
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
      return Result.success(
        MemberLookupResult.memberResults([(mainDecl: nominalDecl, name: qualifiedTypeName)])
      )
    case .partiallyResolved(let partiallyResolvedName):
      let qualifiedBaseResults = resolveSyntax(typeSyntax: partiallyResolvedName.base)
      let module: Identifier? = nil // TODO: Find the actual module
      // TODO: Keep track of the main decl
      return qualifiedBaseResults.map({ qualifiedBaseResult in
        qualifiedBaseResult.mapMembers({ qualifiedBase in
          partiallyResolvedName.resolve(resolvedBase: qualifiedBase, module: module)
        })
      })
    }
  }

  mutating func bindExtensions(matchingForName nameQuery: QualifiedTypeName) -> [ExtensionDeclSyntax] {
    let extensionDecls: [ExtensionDeclSyntax] = symbolTable.extensions(for: file)
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
        case .failure(let failure):
          failures.append(failure)
          continue
        }
      }

      if extendedType.name == nameQuery { matches.append(extensionDecl) }
    }
  }

  fileprivate func resolveQualifiedType(
    _ qualifiedType: QualifiedTypeName,
    _ tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    queue: inout [Request]
  ) -> Result<MemberLookupResult<Void>, VisitMembersFailure> {
    // Find (extended) nominal type

  }

  fileprivate mutating resolveRequester(_ requester: Requester, types: [NominalType]) {
    switch requester {
    case .originalRequest:
      // Return types
    case .toBindExtensions(lookForType: QualifiedTypeName, requester: Requester):
      // TODO: How do we resolve a `bindExtensions`; this is supposed to find qualified types;
      // how do we supply it with nominal types?
    }
  }

  /// Visit type members from this source location
  func visitMembers<Value>(
    of typeSyntax: TypeSyntax,
    at position: (fileID: SourceFileSyntax, position: AbsolutePosition),
    failures: inout [TypeResolutionFailure],
    map: (_ member: ValueDeclSyntax) -> (Value?, continue: Bool)
  ) -> Result<MemberLookupResult<Value>, VisitMembersFailure> {

    // Check types
    // TODO: Make non-recursive
    var requests = [Request]()

    // Resolve type chain for this source location

  }


  func getTypeMembers() {
    visitMembers(
      of: partiallyResolvedName.base,
      at: (partiallyResolvedName.sourceFile, AbsolutePosition(utf8Offset: 0)),
      failures: &failures,
      map: { member -> (TypeDeclSyntax?, continue: Bool) in
        // Only look at type declarations
        guard let typeDecl = member.as(TypeDeclSyntax.self) else { return (nil, true) }
        // If we're looking for a specific type member, check it matches
        if let memberTypeName = partiallyResolvedName.members.first,
          memberTypeName != Identifier(validating: typeDecl.name)
        {
          return (nil, true)
        }
        return (typeDecl, continue: true)
      }
    )
  }
}
