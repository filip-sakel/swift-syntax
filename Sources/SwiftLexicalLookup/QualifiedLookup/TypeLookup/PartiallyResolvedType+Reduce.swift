//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSyntax

// extension PartiallyResolvedType {
//   // Find the given name (all names if `nil`) of the given kind.
//   func visit<Result>(_ visit: (ValueDeclSyntax) -> Result) -> MemberLookupResult<Result> {
//     // TODO: Copy from direct lookup
//     // func matchInstanceMember(declName: DeclName) -> DeclName? {
//     //   guard kind.contains(.anyInstanceMember) else { return false }
//     //   guard try? name.tryMatch(declName) != nil else { return false }
//     //   return DeclName
//     // }
//
//     switch self {
//     case .function(let argumentCount):
//       return MemberLookupResult.function(argumentCount: argumentCount)
//     case .tuple(let labels):
//       return MemberLookupResult.tuple(labels: labels)
//     case .nominalIdentifier(let module, let name):
//     case
//     }
//   }
// }
indirect enum PartiallyResolvedTypeIdentifier {
  case base(module: Identifier?, name: Identifier)
  // Base shouldn't be an empty array
  case member(base: [PartiallyResolvedTypeIdentifier], module: Identifier?, name: Identifier)
  // // `nil` if `components` is empty.
  // init?(components: [(module: Identifier?, name: Identifier)]) {
  //   guard !components.isEmpty else { return nil }
  //   self.components = components
  // }
}

enum ReducingTypeResolutionFailure: Error {
  /// Compositions are invalid when one of the components is a tuple
  /// or function type.
  ///
  /// E.g., `let a: ((Int) -> Void) & Hashable)`, or
  ///       `let b: (x: Int, y: Int) & CustomStringConvertible`
  case invalidComposition(nonNominal: PartiallyResolvedType)

  /// Non-nominal types have no type members
  ///
  /// E.g. `let a: ((Int) -> Void).MyType` ❌
  ///      `let b: (a: Int, b: Int).a` ❌
  case invalidTypeMember(nonNonminal: PartiallyResolvedType)

  case noTypeMember
}

extension TypeSyntaxProtocol {
  func reducingPartialResolve(
    failures: inout [TypeResolutionFailure]
  ) -> Result<MemberLookupResult<PartiallyResolvedTypeIdentifier>, ReducingTypeResolutionFailure> {
    var types = [PartiallyResolvedType]()
    self.partiallyResolve(types: &types, failures: &failures)
  }
}
extension [PartiallyResolvedType] {
  // Returned result is nonempty
  // TODO: COnsider integrating with TypeSyntaxProtocol.partiallyResolve
  func reduceToIdentifiers() -> Result<
    MemberLookupResult<PartiallyResolvedTypeIdentifier>, ReducingTypeResolutionFailure
  > {
    return Result(catching: { () throws(ReducingTypeResolutionFailure) in
      // We get multiple types from compositions. It is invalid
      // to compose functions/tuple with other types. Hence,
      // the only way for functions/tuples to occur in valid code
      // is if in a single-element array.
      // switch first {
      // case .function(let argumentCount):
      //   return MemberLookupResult.function(argumentCount: argumentCount).function(argumentCount: argumentCount)
      // case .tuple(let labels):
      //   return MemberLookupResult.tuple(labels: labels)
      // default: break
      // }
      switch first {
      case .function(let argumentCount):
        return MemberLookupResult.function(argumentCount: argumentCount)
      case .tuple(let labels):
        return MemberLookupResult.tuple(labels: labels)
      case nil:
        // TODO: Special handling for empty types
        break
      default: break
      }

      // Now, we should be left with only nominals (diagnose otherwise)
      // TODO: Convert to loop instead of using recursion
      var members = [PartiallyResolvedTypeIdentifier]()
      for type in self {
        switch type {
        case .function, .tuple:
          throw ReducingTypeResolutionFailure.invalidComposition(nonNominal: type)
        case .nominalIdentifier(let module, let name):
          members.append(PartiallyResolvedTypeIdentifier.base(module: module, name: name))
        case .nominalMember(let bases, let module, let name):
          // Throw if the base is invalid (we can't do anything smart)
          let lookupResult = try bases.reduceToIdentifiers().get()
          switch lookupResult {
          // Function and tuple types don't have type members
          case .function, .tuple:
            // TODO: Find workaround
            throw ReducingTypeResolutionFailure.invalidTypeMember(nonNonminal: lookupResult)
          case .memberResults(let results) where !results.isEmpty:
            members.append(
              PartiallyResolvedTypeIdentifier.member(
                base: members,
                module: module,
                name: name
              )
            )
          case .memberResults:  // where results.isEmpty
            throw ReducingTypeResolutionFailure.noTypeMembers
          }
        }
      }
      guard !members.isEmpty else {
        // TODO
        fatalError("...")
      }
    })
  }
}
