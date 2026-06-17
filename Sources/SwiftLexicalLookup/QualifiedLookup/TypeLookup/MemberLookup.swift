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

enum TypeLookupState {

}

enum Request {
  case resolveIdentifiers([PartiallyResolvedTypeIdentifier])
  case resolveBase(base: TypeSyntax, sourceFile: SourceFileSyntax, memberNames: [Identifier])
  case resolveAlias(TypeSyntax)
  case resolveQualifiedType(qualifiedType: QualifiedTypeName)
}

enum VisitMembersFailure: Error {
  case chainResolutionFailure(NominalTypeDeclSyntax2.ChainResolutionFailure)
  case typeResolutionFailure(ReducingTypeResolutionFailure)
}

extension SyntaxProtocol {
  /// Visit type members from this source location
  func visitMembers<Value>(
    of typeSyntax: TypeSyntax,
    at position: (fileID: SourceFileSyntax, position: AbsolutePosition),
    failures: inout [TypeResolutionFailure],
    map: (_ member: ValueDeclSyntax) -> (Value?, continue: Bool)
  ) -> Result<MemberLookupResult<Value>, VisitMembersFailure> {
    // Resolve type; throw on failure
    let resolutionResult: MemberLookupResult<PartiallyResolvedTypeIdentifier>
    switch typeSyntax.resolve(failures: &failures) {
    case .success(let result):
      resolutionResult = result
    case .failure(let failure):
      return .failure(.typeResolutionFailure(failure))
    }

    // Handle function/tuple cases
    let types: [PartiallyResolvedTypeIdentifier]
    switch resolutionResult {
    case .function(let argumentCount):
      return .success(.function(argumentCount: argumentCount))
    case .tuple(let labels):
      return .success(.tuple(labels: labels))
    case .memberResults(let typeResults):
      types = typeResults
    }

    // Check types
    // TODO: Make non-recursive
    var requests = [Request]()
    for type in types {
      switch type {
      case .base(let optionalModule, let typeName):
        // Look up base type
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
        // We skip associated types and generic parameters
        if let nominalType = foundType.as(NominalTypeDeclSyntax2.self) {
          // Get the type chain
          let typeChain: ChainResult
          switch nominalType.findTypeChain(module: nil) {
          case .success(let result):
            typeChain = result
          case .failure(let failure):
            return .failure(.chainResolutionFailure(failure))
          }
          // Add the relevant request
          switch typeChain {
          case .resolved(let qualifiedTypeName):
            requests.append(.resolveQualifiedType(qualifiedType: qualifiedTypeName))
          case .partiallyResolved(let partiallyResolvedName):
            requests.append(.resolveBase(
              base: partiallyResolvedName.base,
              sourceFile: position.fileID,
              memberNames: partiallyResolvedName.memberNames
            ))
          }
        } else if let typeAlias = foundType.as(TypeAliasDeclSyntax.self) {
          requests.append(.resolveAlias(typeAlias.initializer.value))
        }

      case .member(let bases, let module, let typeName):

      }
    }

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
