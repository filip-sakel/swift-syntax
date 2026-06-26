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

@_spi(_QualifiedLookup) public final class SymbolTable3 {
  public typealias Module = Identifier
  let moduleToSources: [Module: [String: SourceFileSyntax]]

  enum TypeResolutionState {
    /// Indicates we started resolving this type syntax; helps us catch cycles.
    case startedResolving
    /// A cycle was detected.
    ///
    /// Two examples:
    /// 1.Type aliases:
    ///   typealias A = B
    ///   typealias B = A
    ///
    /// 2.Nested type aliases:
    ///   struct One { typealias A = Two.B }
    ///   struct Two { typealias B = One.A }
    case detectedCycle(cyclingSyntax: [TypeSyntax])
    /// We resolved the given type syntax.
    ///
    /// If successful, we have a function type, tuple type,
    /// a composition of nominal types, or a single nominal type.
    ///
    /// There are multiple causes of failure.
    case resolved(Result<MemberLookupResult<NominalType>, TypeQualifier.Failure>)
    /// If we resolved to a single nominal type, we can bind extensions and update
    /// the resolved type.
    ///
    /// Note that extensions cannot be resolved independently, so we need to
    /// keep track of extensions whose extended-syntax resolution depends on
    /// this type. Here's an example:
    ///   struct A {}
    ///   extension A.Inner {}
    ///   extension A { typealias Inner = A }
    /// In this example, we can't resolve `A.Inner` directly since it requires
    /// looking up the type `Inner` on `A`, which means `A` we have to bind
    /// all available extensions first. Through this example, we see why even
    /// seemingly unrelated extensions may be necessary to obtain an extended
    /// nominal type.
    ///
    /// Further, note that dependent extensions can depend on other dependent
    /// extensions (which eventually depend on a non-dependent extension). E.g.:
    ///   struct A {}
    ///   extension A.Inner {} // Depends on `A` having an `Inner` type member
    ///   extension A.Outer { struct Inner {} } // Depends on `A` having an `Outer` type member
    ///   extension A { typealias Outer = A } // Non-dependent extension
    /// Say we want to get the extended nominal type of `A`; we have to bind these
    /// three potential extensions. First, `A.Inner` expects a type member `Inner`;
    /// the main declaration doesn't give us that yet. So we check the next extension,
    /// but `A.Outer` depends on a type member `Outer`; we keep going. Finally, the
    /// last extension has no dependencies so we get a type `Outer`. Hence, we can
    /// make progress on `A.Outer` and resolve it, giving us `A.Inner`. Finally,
    /// we resolve `A.Inner` and don't bind it since the type is unrelated.
    ///
    /// Important: As we bind dependent extensions, we assume the members we found
    /// are unique. However,
    ///
    // TODO: Why does this give us an error?
    // struct A {}
    // extension A.Inner {} // - error: extension of type 'A.Inner' (aka 'A') must be declared as an extension of 'A'
    // extension A.Outer { typealias Inner = Self }
    // extension A { typealias Outer = A}
    case bindingPotentialExtension(
      resolved: NominalType,
      possibleExtensionQueue: [ExtensionDeclSyntax],
      currentlyBound: [ExtensionDeclSyntax],
      byAssumingMemberResolutions: [PartiallyResolvedTypeIdentifier.Component: MinimalNominal],
      dependentExtensionsStack: [PartiallyResolvedTypeIdentifier.Component: [ExtensionDeclSyntax]],
    )
  }
  internal var typeSyntaxCache: [TypeSyntax: TypeResolutionState]

  public init(moduleToSources: [Module: [String: SourceFileSyntax]]) {
    self.moduleToSources = moduleToSources
    self.typeSyntaxCache = [:]
  }

  private(set) lazy var moduleMap: [SourceFileSyntax: Module] = {
    var result = [SourceFileSyntax: Module]()
    for (module, sources) in moduleToSources {
      for source in sources.values {
        result[source] = module
      }
    }
    return result
  }()

}
