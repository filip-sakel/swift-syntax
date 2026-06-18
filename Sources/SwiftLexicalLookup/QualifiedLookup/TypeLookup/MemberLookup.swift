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

enum BaseRequest {
  // Resolve the given type syntax, potentially with additional type members at the end.
  //
  // E.g. Imagine
  //    typealias A = any Collection<Int>
  //    func f(_: A.Element) {} // Look up `A.Element` here
  // In this case, after resolving the type alias `A` to be the `any Collection<Int>`
  // syntax, we then need to look up the `Element` type member within.
  case resolveSyntax(
    syntax: TypeSyntax,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // toResolveExtensionType: [QualifiedTypeName]
  )

  /// Resolve the given partial type identifiers.
  case resolveIdentifiers(
    [PartiallyResolvedTypeIdentifier],
    // qualifiedTypeTarget: QualifiedTypeName?,
    // toResolveExtensionType: [QualifiedTypeName]
  )
  // case resolveBase(base: TypeSyntax, sourceFile: SourceFileSyntax, memberNames: [Identifier])

  // We've found a qualified type; now we perform lookup in the type and its extensions.
  //
  // We're either looking for more members on the type, or the type plus all the tail types.
  // An example of where this request occurs with tail types is the following:
  //   func f(_: (any Collection<Int>).Element) // Look up `(any Collection<Int>).Element)` here
  // In this example, we'd first generate a `resolveSyntax` request on `any Collection<Int>` with
  // a single `Element` tail type. The syntax would then call `.resolveIdentifiers` on `Collection.Element`.
  // Then, we resolve the base type to `Swift::Collection` so we issue a `.resolveQualifiedType` request
  // looking for the `Element` tail type in `Swift::Colection`.
  case resolveQualifiedType(
    mainDecl: NominalTypeDeclSyntax2,
    qualifiedType: QualifiedTypeName,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    // toResolveExtensionType: [QualifiedTypeName]
  )
}

/// The reason for which we want to resolve this type syntax
/// to a set of nominal types.
indirect enum Requester {
  case toResolveType
  case toResolveTypeAlias(requester: Requester)
  case toResolveTypeMembers(components: [PartiallyResolvedTypeIdentifier.Component])
  case toQualifyType(partiallyQualified: PartiallyResolvedNominalTypeChain, requester: Requester)
  case toQualifyExtendedType(toType: QualifiedTypeName, requester: Requester)
}
// struct Request {
//   let base: Base
//   let tailTypes: [PartiallyResolvedTypeIdentifier.Component]
// }
fileprivate typealias Request = (task: BaseRequest, requester: Requester) //(base: BaseRequest, tailTypes: [PartiallyResolvedTypeIdentifier.Component])


enum VisitMembersFailure: Error {
  case noTypeMembersInTupleAndFunction
  case chainResolutionFailure(NominalTypeDeclSyntax2.ChainResolutionFailure)
  case typeResolutionFailure(ReducingTypeResolutionFailure)
}

protocol MemberVisitorProtocol {
  // mutating func visit(decl: ValueDeclSyntax)
  mutating func visit(type: NominalType)
  // mutating func visit(type: QualifiedTypeName)
}
struct MemberVisitor<Visitor: MemberVisitorProtocol> {
  // var visitor: Visitor
  var failures: [VisitMembersFailure]
  let moduleMap: [SyntaxIdentifier: Identifier?]
  let lookupPosition: (file: SourceFileSyntax, position: AbsolutePosition)

  fileprivate mutating func processRequest(
    request: Request, queue: inout [Request]
  ) -> /*Result<MemberLookupResult<QualifiedTypeName>, VisitMembersFailure> {*/ Result<MemberLookupResult<NominalType>, VisitMembersFailure> { //Result<MemberLookupResult<Void>, VisitMembersFailure> {
    switch request {
    case .resolveSyntax(let typeSyntax, let tailTypes, let qualifiedTypeFilter):
      return resolveSyntax(typeSyntax: typeSyntax, tailTypes: tailTypes, queue: &queue)
    case .resolveIdentifiers(let typeIdentifiers):
      return resolveTypeReferences(typeIdentifiers, queue: &queue)
    case .resolveQualifiedType(let mainDecl, let qualifiedType, let tailTypes):
      // FIXME: How do we resolve extensions recursively?
      // TBF, extensions must strictly resolve to nominal types
      return resolveQualifiedType(qualifiedType, tailTypes, queue: &queue)
    }
  }

  fileprivate mutating func resolveSyntax(
    typeSyntax: TypeSyntax,
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    requester: Requester,
    queue: inout [Request]
  ) -> Result<MemberLookupResult<Void>, VisitMembersFailure>? {
    // Resolve type; throw on failure
    let resolutionResult: MemberLookupResult<PartiallyResolvedTypeIdentifier>
    var failures = [TypeResolutionFailure]()
    defer { self.failures.append(contentsOf: failures.map(VisitMembersFailure.typeResolutionFailure)) }
    switch typeSyntax.resolve(failures: &failures) {
    case .success(let result):
      resolutionResult = result
    case .failure(let failure):
      return .failure(.typeResolutionFailure(failure))
    }

    switch (resolutionResult, requester) {
    // .function and .tuple are only valid without result types
    case (.function(let argumentCount), .originalRequest):
      return .success(.function(argumentCount: argumentCount))
    case (.tuple(let labels), .originalRequest):
      return .success(.tuple(labels: labels))
    // Diagnose if we have tail types on non-nominal types with no type members
    case (.function, _), (.tuple, _):
      return .failure(.noTypeMembersInTupleAndFunction)
    // Issue requests for the underlying type identifiers
    case (.memberResults(let typeResults), let requester):
      // let expectsSingleResult = switch requester {
      // case .toBindExtension, .toQualifyType: return true
      // case .originalRequest, .toResolveTypeAlias
      // }
      queue.append((
        // task: .resolveIdentifiers(typeResults.map({ result in
        //   result.addingComponents(tailTypes)
        // })),
        task: .resolveIdentifiers(typeResults),
        requester: requester
      ))
    }
  }

  fileprivate mutating func resolveTypeReferences(
    _ typeReferences: [PartiallyResolvedTypeIdentifier],
    // tailTypes: [PartiallyResolvedTypeIdentifier.Component],
    requester: Requester,
    queue: inout [Request]
  ) -> Result<MemberLookupResult<Void>, VisitMembersFailure> {
    for typeReference in typeReferences {
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
      if let typeAlias = foundType.as(TypeAliasDeclSyntax.self) {
        // queue.append(.resolveSyntax(typeAlias.initializer.value, tailTypes: typeReference.memberChain))
        queue.append((
          task: .resolveSyntax(syntax: typeAlias.initializer.value),
          requester: .toResolveTypeAlias(requester: requester)
        ))
        continue
      }

      // We only need to worry about nominal types now
      guard let nominalType = foundType.as(NominalTypeDeclSyntax2.self) else { continue }

      // Get the type chain
      let typeChain: ChainResult
      switch nominalType.findTypeChain(module: nil) {
      case .success(let result):
        typeChain = result
      case .failure(let failure):
        return .failure(.chainResolutionFailure(failure))
      }

      // Add the relevant request
      // TODO: Check if just adding tail types is the right approach. Could we be more direct and just go to the parent each time?
      switch (typeChain, requester) {
      case (.resolved(let qualifiedTypeName),
            .toQualifyType(let partiallyQualified, let originalRequester)):
        // TODO: Figure out how to pass module
        let module: Identifier? = nil
        partiallyQualified.resolve(resolvedBase: qualifiedTypeName, module: module)
      case (.resolved(let qualifiedTypeName), ):

        queue.append((
          task: BaseRequest.resolveQualifiedType(
            qualifiedType: qualifiedTypeName,
            tailTypes: typeReference.memberChain
          ),
          requester:
        ))
      case .partiallyResolved(let partiallyResolvedName):
        // queue.append(.resolveBase(
        //   base: partiallyResolvedName.base,
        //   sourceFile: position.fileID,
        //   memberNames: partiallyResolvedName.memberNames,
        //   tailTypes: typeReference.memberChain
        // ))

        let chainComponents: [PartiallyResolvedTypeIdentifier.Component] = partiallyResolvedName.memberNames.map({
          (module: nil, name: $0)
        })
        queue.append(BaseRequest.resolveSyntax(
          partiallyResolvedName.base,
          tailTypes: chainComponents + typeReference.memberChain
        ))
      }
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
