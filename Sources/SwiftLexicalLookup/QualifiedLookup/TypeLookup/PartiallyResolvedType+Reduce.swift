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

@_spi(_QualifiedLookup) public struct PartiallyResolvedTypeIdentifier: Sendable, CustomDebugStringConvertible {
  struct Component: CustomDebugStringConvertible {
    let module: Identifier?
    let name: Identifier

    var debugDescription: String {
      let modulePrefix = if let module { "\(module.name)::" } else { "" }
      return "\(modulePrefix)\(name.name)"
    }
  }
  let base: Component
  private(set) var memberChain: [Component] = []
  /// The `TypeSyntax` from which we derived this type reference; used
  /// for targeted diagnostics.
  let typeSyntax: TypeSyntax

  // func addingComponent(_ newComponent: Component) -> PartiallyResolvedTypeIdentifier {
  //   PartiallyResolvedTypeIdentifier(
  //     base: base,
  //     memberChain: self.memberChain + [newComponent]
  //   )
  // }
  func addingComponents(_ newComponents: [Component], newTypeSyntax: TypeSyntax) -> PartiallyResolvedTypeIdentifier {
    PartiallyResolvedTypeIdentifier(
      base: base,
      memberChain: self.memberChain + newComponents,
      typeSyntax: newTypeSyntax
    )
  }

  public var debugDescription: String {
    "\(base.debugDescription)\(memberChain.map({ ".\($0.debugDescription)" }).joined())"
  }
}

// enum ReducingTypeResolutionFailure: Error {
//   /// Compositions are invalid when one of the components is a tuple
//   /// or function type.
//   ///
//   /// E.g., `let a: ((Int) -> Void) & Hashable)`, or
//   ///       `let b: (x: Int, y: Int) & CustomStringConvertible`
//   case invalidComposition(nonNominal: PartiallyResolvedType)
//
//   /// Non-nominal types have no type members
//   ///
//   /// E.g. `let a: ((Int) -> Void).MyType` ❌
//   ///      `let b: (a: Int, b: Int).a` ❌
//   case noTupleTypeMembers, noFunctionTypeMembers
//
//   /// No type member of the given name
//   ///
//   /// This error is thrown either when a type's members have different
//   /// names, or when the base type is empty (e.g., the base `Int.Type`
//   /// has no type members).
//   case noTypeMembers(in: [PartiallyResolvedType])
// }

// extension TypeSyntaxProtocol {
//   /// Reduces this array of resolved types to a lookup result, a union
//   /// of a function type, tuple type, or array of type identifiers.
//   // TODO: Consider integrating with TypeSyntaxProtocol.partiallyResolve for efficiency
//   func resolve(
//     failures: inout [TypeResolutionFailure]
//   ) -> Result<
//     MemberLookupResult<PartiallyResolvedTypeIdentifier>,
//     ReducingTypeResolutionFailure
//   > {
//     var types = [PartiallyResolvedType]()
//     self.partiallyResolve(types: &types, failures: &failures)
//
//     return types._reduceToIdentifiers()
//   }
// }
// extension [PartiallyResolvedType] {
//   /// Helper for ``TypeSyntaxProtocol/resolve``.
//   fileprivate func _reduceToIdentifiers() -> Result<
//     MemberLookupResult<PartiallyResolvedTypeIdentifier>,
//     ReducingTypeResolutionFailure
//   > {
//     // We get multiple types from compositions. It is invalid
//     // to compose functions/tuple with other types. Hence,
//     // the only way for functions/tuples to occur in valid code
//     // is if in a single-element array.
//     switch first {
//     case .function(let argumentCount):
//       return .success(MemberLookupResult.function(argumentCount: argumentCount))
//     case .tuple(let labels):
//       return .success(MemberLookupResult.tuple(labels: labels))
//     default: break
//     }
//
//     // Now, we should be left with only nominals (diagnose otherwise)
//     // TODO: Convert to loop instead of using recursion
//     var members = [PartiallyResolvedTypeIdentifier]()
//     for type in self {
//       switch type {
//       case .function, .tuple:
//         // Only valid case for functions/tuples handled above.
//         return .failure(ReducingTypeResolutionFailure.invalidComposition(nonNominal: type))
//       case .nominalIdentifier(let module, let name):
//         members.append(
//           PartiallyResolvedTypeIdentifier(
//             base: PartiallyResolvedTypeIdentifier.Component(module: module, name: name)
//           )
//         )
//       case .nominalMember(let bases, let module, let name):
//         // Throw if the base is invalid (we can't do anything smart)
//         let lookupResult: MemberLookupResult<PartiallyResolvedTypeIdentifier>
//         switch bases._reduceToIdentifiers() {
//         case .success(let result):
//           lookupResult = result
//         case .failure(let failure):
//           return .failure(failure)
//         }
//
//         switch lookupResult {
//         // Function and tuple types don't have type members
//         case .function:
//           return .failure(ReducingTypeResolutionFailure.noFunctionTypeMembers)
//         case .tuple:
//           return .failure(ReducingTypeResolutionFailure.noTupleTypeMembers)
//         case .memberResults(let baseMembers) where !baseMembers.isEmpty:
//           for baseMember in baseMembers {
//             members.append(
//               baseMember.addingComponents([
//                 PartiallyResolvedTypeIdentifier.Component(module: module, name: name)
//               ])
//             )
//           }
//         case .memberResults:  // where results.isEmpty
//           return .failure(ReducingTypeResolutionFailure.noTypeMembers(in: bases))
//         }
//       }
//     }
//
//     guard !members.isEmpty else {
//       // E.g. `Int.Type` resolves to `[]`, in which case we throw this error
//       return .failure(.noTypeMembers(in: self))
//     }
//
//     return .success(.memberResults(members))
//   }
// }
