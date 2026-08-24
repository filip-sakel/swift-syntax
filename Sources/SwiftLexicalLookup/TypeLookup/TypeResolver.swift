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

// TODO: Remove Glibc import
@preconcurrency import Glibc
import SwiftIfConfig
import SwiftSyntax

/// Finds the main declaration and qualified name of the nominal types
/// to which the the given type syntax refers.
@_spi(_QualifiedLookupTests)
public struct TypeResolver {
  var logPrefix = [String]()

  fileprivate mutating func log(_ component: Any, file: StaticString = #file, line: UInt = #line) {
    guard _verbose else { return }
    // Keep log text separately
    let newLine = "\(logPrefix.map({ "[\($0)]" }).joined()) \(component)\n"
    // Print new line
    print(newLine)
    // TODO: Remove
    fflush(stdout)
  }

  fileprivate mutating func withLogging<T>(
    request: String,
    describe: (T) -> String,
    perform action: (_ mutableSelf: inout TypeResolver) -> T,
    file: StaticString = #file,
    line: UInt = #line
  ) -> T {
    if let nestingLimit = self._logNestingLimit, logPrefix.count >= nestingLimit {
      fflush(stdout)
      fatalError(
        "Exceeded log nesting limit of \(nestingLimit), suggesting there's an infinite loop. If you think this is a mistake, you may change the limit in `TypeQualifier`."
      )
    }
    logPrefix.append(request)
    log("Resolving...", file: file, line: line)
    let result = action(&self)
    log("Resolved \(describe(result))", file: file, line: line)
    logPrefix.removeLast()
    return result
  }

  public typealias Failure = TypeResolutionFailure<
    GlobalTypeName, ResolvedTypeSyntax
  >
  public typealias TypeResult<ResolvedType> = Result<ResolvedType, Failure>

  let symbolTable: SymbolTable

  var visitedTypeSyntax: OrderedSet<Attached<TypeSyntax>> = []
  var dependencyTracker: DependencyTracker = DependencyTracker()

  let _verbose: Bool
  /// The number of `withLogging` calls we can nest. Useful for debugging infinite loops
  /// that otherwise fill up standard output and become illegible.
  let _logNestingLimit: Int?
  let _checkNominalInCompositionIsClassOrProtocol = true

  public init(symbolTable: SymbolTable, _verbose: Bool, _logNestingLimit: Int? = nil) {
    self.symbolTable = symbolTable
    self._verbose = _verbose
    self._logNestingLimit = _logNestingLimit
  }

  /// Gets the module of an an attached node. Assumes the file is registered;
  /// traps otherwise.
  func extractModule<S: SyntaxProtocol>(syntax: Attached<S>) -> ModuleName {
    guard let module = symbolTable.moduleMap[syntax.fileRoot] else {
      // Should be checked upon entrance in `resolveSyntax`
      fatalError("[SwiftLexicalLookup] Internal error: Unexpectedly found unregistered file: ```\(syntax.fileRoot)```")
    }
    return module
  }
  /// Gets the configured regions of an an attached node's file. Assumes the
  /// file is registered; traps otherwise.
  func extractConfiguredRegions<S: SyntaxProtocol>(syntax: Attached<S>) -> ConfiguredRegions? {
    guard case .success(let fileConfiguredRegions) = symbolTable.getConfiguredRegions(forFile: syntax.fileRoot) else {
      // Should be checked upon entrance in `resolveSyntax`
      fatalError("[SwiftLexicalLookup] Internal error: Unexpectedly found unregistered file: ```\(syntax.fileRoot)```")
    }
    return fileConfiguredRegions
  }
}

// MARK: Type Syntax

extension TypeResolver {
  public mutating func resolveSyntax(
    typeSyntax: Attached<TypeSyntax>
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    withLogging(
      request: "Resolve syntax `\(typeSyntax.trimmedDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveSyntax(typeSyntax: typeSyntax) }
    )
  }

  /// Implements `resolveSyntax`
  public mutating func _resolveSyntax(
    typeSyntax: Attached<TypeSyntax>
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    // Ensure we're not forming a cycle
    if let existingSyntaxIndex = visitedTypeSyntax.firstIndex(of: typeSyntax) {
      // We might have valid references before the actual cycle; chop those off
      // to isolate the cycle.
      //
      // E.g.:
      //   typealias A = B
      //   typealias B = A
      //   func f(_: A) // <- Lookup here
      // Starting from `A`, `visitedTypeSyntax` would be:
      //   [
      //     A // from f(_: A),
      //     B // from typealias A = B
      //     A // from typealias B = A
      //   ]
      // And we isolate to the cycle [B, A]
      let isolatedCycle = Array(visitedTypeSyntax[existingSyntaxIndex...])
      return .failure(Failure.cyclicalTypeReference(cycle: isolatedCycle.map(\.node)))
    }
    // Append this type syntax
    visitedTypeSyntax.append(typeSyntax)
    defer { visitedTypeSyntax.remove(typeSyntax) }

    // We assert the file root is registered in the symbol table.
    guard
      symbolTable.moduleMap[typeSyntax.fileRoot] != nil,
      case .success(let fileConfiguredRegions) = symbolTable.getConfiguredRegions(forFile: typeSyntax.fileRoot)
    else {
      return .failure(Failure.syntaxNotInSymbolTable(typeSyntax.fileRoot))
    }
    // Further, if given `configuredRegions`, ensure the given syntax is active.
    if let fileConfiguredRegions,
      fileConfiguredRegions.isActive(typeSyntax.node) != .active
    {
      return .failure(Failure.syntaxInDisabledRegion)
    }

    // Partially resolve the type and handle each case accordingly
    let partialType: Result<PartiallyResolvedType, PartialTypeResolutionFailure> = typeSyntax.partiallyResolve()
    switch partialType {
    case .success(.anyType):
      return Result.success(ResolvedType.anyType)
    case .success(.tuple(let labels)):
      return Result.success(.tuple(labels: labels))
    case .success(.typeIdentifier(.success(let component))):
      return resolveUnqualifiedReference(typeComponent: ImplicitTypeReferenceComponent(from: component))
    case .success(.metatype(let baseTypeSyntax)):
      let baseTypeResult = resolveSyntax(typeSyntax: baseTypeSyntax)
      // Wrap the base type/failure and return
      switch baseTypeResult {
      case .success(let baseType):
        return Result.success(ResolvedType.metatype(base: baseType))
      case .failure(let baseFailure):
        return Result.failure(Failure.invalidBaseType(baseFailure))
      }
    case .success(.member(let baseTypeSyntax, .success(let memberComponent))):
      let baseTypeResult = resolveSyntax(typeSyntax: baseTypeSyntax)
      return resolveMember(baseType: baseTypeResult, typeMember: ImplicitTypeReferenceComponent(from: memberComponent))
    case .success(.composition(let childTypes)):
      var syntaxToTypes = [
        (
          childSyntax: Attached<TypeSyntax>,
          childResult: Result<ResolvedType<ResolvedTypeSyntax>, Failure>
        )
      ]()
      for childTypeSyntax in childTypes {
        let childResult = resolveSyntax(typeSyntax: childTypeSyntax)
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

  /// Combines the given types into one type result.
  func reduceComposition(
    _ syntaxToTypes: [(
      childSyntax: Attached<TypeSyntax>,
      childResult: Result<ResolvedType<ResolvedTypeSyntax>, Failure>
    )]
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    // Collect valid types and failures
    var anyTypeCounter = 0
    var types = [ResolvedTypeSyntax]()
    var failures = [(TypeSyntax, Failure)]()
    for (childTypeSyntax, childTypeResult) in syntaxToTypes {
      switch childTypeResult {
      // Only nominals are valid in compositions
      case .success(.nominalTypes(let nominals)):
        if _checkNominalInCompositionIsClassOrProtocol {
          switch (nominals.count, nominals.first?.type.mainDecl.kind) {
          // If we have one nominal, check it's a protocol or class.
          // If we have multiple, i.e., a composition, we've already  checked it recursively.
          case (1, .protocolDecl), (1, .classDecl), (2..., _):
            break
          // If we have no nominals, e.g., `Int.Type`, or a single nominal that's not
          // a struct/enum/actor, we throw an error
          default:
            failures.append(
              (
                childSyntax: childTypeSyntax.node,
                childFailure: Failure.cannotComposeNonClassOrProtocol(
                  resolved: .nominalTypes(nominals)
                )
              )
            )
          }
        }
        // Append types we don't already have
        for nominal in nominals {
          // This search takes linear time but we don't expect compositions to
          // reference a large number of nominal types.
          guard !types.contains(where: { $0.type.mainDecl == nominal.type.mainDecl }) else {
            continue
          }
          types.append(nominal)
        }
      // Tuples/function
      case .success(.function(let argumentCount)):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: Failure.cannotComposeNonClassOrProtocol(
              resolved: .function(argumentCount: argumentCount)
            )
          )
        )
      case .success(.tuple(let labels)):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: Failure.cannotComposeNonClassOrProtocol(
              resolved: .tuple(labels: labels)
            )
          )
        )
      case .success(.metatype(let base)):
        failures.append(
          (
            childSyntax: childTypeSyntax.node,
            childFailure: Failure.cannotComposeNonClassOrProtocol(resolved: .metatype(base: base))
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
            childSyntax: childTypeSyntax.node,
            childFailure: resolutionFailure
          )
        )
      }
    }

    // Stop even if we only have one failure
    guard failures.isEmpty else {
      return Result.failure(Failure.invalidComposition(failures))
    }

    // We get `anyType` only when all the child types are `any`,
    // and have at least one children.
    //
    // We need to check we have more than one children because,
    // for instance, `Int.Type` returns an empty array which
    // doesn't equal the `Any` type.
    if anyTypeCounter > 0, anyTypeCounter == syntaxToTypes.count {
      return Result.success(ResolvedType.anyType)
    }

    return Result.success(ResolvedType.nominalTypes(types))
  }
}

// MARK: Unqualified References

extension TypeResolver {
  /// Resolves the given type reference (an optional module selector +
  /// the type-name identifier) by performing unqualified lookup.
  ///
  /// E.g. The syntax `A & MyModule::B` will issue two `resolveUnqualifiedReference`
  /// calls: one for `A` and one for `MyModule::B`. Type members are handled
  /// in other functions.
  ///
  /// Note: We don't resolve generic parameters.
  fileprivate mutating func resolveUnqualifiedReference(
    typeComponent: ImplicitTypeReferenceComponent
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    return withLogging(
      request: "Type reference `\(typeComponent.debugDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveUnqualifiedReference(typeComponent: typeComponent) }
    )
  }

  enum DeclContext {
    case declGroup(Attached<DeclGroupSyntaxType>)
    case codeBlock(Attached<CodeBlockItemListSyntax>)

    fileprivate var syntax: Syntax {
      switch self {
      case .declGroup(let syntax):
        return Syntax(syntax.node)
      case .codeBlock(let syntax):
        return Syntax(syntax.node)
      }
    }
  }
  func _describeDeclContext(_ declContext: DeclContext) -> String {
    switch declContext {
    case .declGroup(let declGroup):
      return declGroup._memberlessDescription
    case .codeBlock(let codeBlock):
      guard let sourceFileScope = codeBlock.parent?.as(SourceFileSyntax.self) else {
        // `codeBlock.parent` shouldn't be `nil` in a valid program because of `Attached<_>`
        return "<\(codeBlock.parent?.parent?.kind ?? .missing)>"
      }
      return symbolTable.debugFileMap.describeFileID(sourceFileScope.node.id)
    }
  }

  /// Implements `resolveUnqualifiedReference`
  fileprivate mutating func _resolveUnqualifiedReference(
    typeComponent: ImplicitTypeReferenceComponent
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    // Perfom unqualified lookup up to find the base type's declaration
    //
    // e.g.
    //   extension String.UTF8View { <- Resolve
    //     struct A { // <- Resolve
    //       struct B {} // <- Look up here
    //     }
    //   }
    let lookupResults: [UnqualifiedTypeLookupResult]
    if let module = typeComponent.module {
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
      lookupResults = typeComponent.introducingSyntax.findUnqualifiedType(
        typeComponent.name,
        configuredRegions: extractConfiguredRegions(syntax: typeComponent.introducingSyntax)
      )
    }

    log("Lookup results: \(lookupResults.map(\.debugDescription))")

    // Find first matching type declaration
    for lookupResult: UnqualifiedTypeLookupResult in lookupResults {
      // The enclosing type, and whether to look for the selected member.
      //
      // `lookForSelectedMember` is false if we can return the enclosing type
      // itself; true if we need to perform qualified lookup and return a type
      // member.
      let enclosingTypeResult: Result<ResolvedType<ResolvedTypeSyntax>, Failure>
      let lookForSelectedMember: Bool

      // TODO: Use withLogging
      logPrefix.append("Trying \(lookupResult._describeSuccinctly(lookedUpName: typeComponent.name))")
      defer { logPrefix.removeLast() }

      switch lookupResult {
      case .nonNestedTypeDecl(let typeDecl, redeclarations: _, let parentCodeBlock):
        enclosingTypeResult = resolveTypeDecl(
          typeDecl: typeDecl,
          declContext: DeclContext.codeBlock(parentCodeBlock),
          originatingSyntax: typeComponent.introducingSyntax
        )
        lookForSelectedMember = false
      case .lookForMember(let declGroupParent, let lookForSelf):
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
        enclosingTypeResult = resolveDeclGroup(
          declGroup: declGroupParent,
          originatingSyntax: typeComponent.introducingSyntax
        ).map({ ResolvedType.nominalTypes([$0]) })
        // To find the member
        lookForSelectedMember = !lookForSelf

      case .genericParameters(firstMatch: _, redeclarations: _, genericClause: _):
        // TODO: Should we throw if we get redeclarations?
        // (do the same in `.lookForGenericParameters`)
        return .failure(.genericParameterOrAssociatedType)

      case .lookForGenericParameters(let extensionDecl):
        // TODO: Implement logging for all unqualified lookup results
        let matchingGenericParameterResult: Result<GenericParameterSyntax?, Failure> = withLogging(
          request: "Generic parameters",
          describe: { result in
            result.map({ $0?.trimmedDescription })._debugDescription
          },
          perform: {
            // Resolve extended type
            let baseType: GenericResolvedTypeSyntax<GlobalNominalTypeRef>
            switch $0.bindExtension(extensionDecl) {
            case .success(let type):
              baseType = type
            case .failure(let failure):
              return Result.failure(Failure.invalidBaseType(failure))
            }

            // Get first matching generic parameter
            let matchingGenericParameter = baseType.type.mainDecl.node.findGenericParameters(
              withName: typeComponent.name
            ).first
            return .success(matchingGenericParameter)
          }
        )

        // Get the generic parameter (continue if we got no generic parameters;
        // forward failures)
        switch matchingGenericParameterResult {
        case .success(_?):
          break
        case .success(nil):
          continue
        case .failure(let failure):
          return .failure(failure)
        }

        // We don't resolve generic parameters (same as ``resolveTypeDecl``).
        enclosingTypeResult = Result.failure(.genericParameterOrAssociatedType)
        lookForSelectedMember = false
      case .lookInModule:
        // TODO: Handle
        continue
      }

      // Whether we have to look for a member or not, we can't succeed without
      // knowing the enclosing type
      let enclosingType: ResolvedType<ResolvedTypeSyntax>
      switch (enclosingTypeResult, lookForSelectedMember) {
      case (.success(let result), _):
        enclosingType = result
      // Continue to next scope if unqualified lookup didn't find the type in this scope
      case (.failure(.noTypeInScope), _):
        continue
      // Return failure directly if we're not looking for the selected member
      case (.failure(let failure), false):
        return Result.failure(failure)
      // Otherwise, wrap in a '.invalidBaseType'
      case (.failure(let failure), true):
        return Result.failure(Failure.invalidBaseType(failure))
      }

      // If we don't have to look for a member, return
      if !lookForSelectedMember { return Result.success(enclosingType) }

      // Look for the member
      let memberTypeResult: Result<ResolvedType<ResolvedTypeSyntax>, Failure> = resolveMember(
        baseType: Result.success(enclosingType),
        typeMember: typeComponent
      )

      // Get the type member
      let memberType: ResolvedType<ResolvedTypeSyntax>
      switch memberTypeResult {
      case .success(let result):
        memberType = result
      // Continue like above
      case .failure(.noTypeMember):
        continue
      // Note: `resolveMember` wraps the underlying error in ``Failure.invalidMembers``
      case .failure(let failure):
        return Result.failure(failure)
      }

      return Result.success(memberType)
    }

    // No type matched
    return Result.failure(Failure.noTypeInScope)
  }

  fileprivate mutating func resolveDeclGroup(
    declGroup: Attached<DeclGroupSyntaxType>,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedTypeSyntax> {
    withLogging(
      request: "Decl group `\(declGroup._memberlessDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveDeclGroup(declGroup: declGroup, originatingSyntax: originatingSyntax) }
    )
  }

  /// Helper for `resolveDeclGroup`
  fileprivate func _findDeclContext(ofDeclGroup node: Attached<DeclGroupSyntaxType>) -> DeclContext {
    var currentAncestor: Attached<Syntax>? = node.parent
    while let ancestor = currentAncestor {
      if let codeBlockScope = ancestor.as(CodeBlockItemListSyntax.self),
        // `#if` aren't true scopes
        codeBlockScope.parent?.is(IfConfigClauseSyntax.self) != true
      {
        return DeclContext.codeBlock(codeBlockScope)
      } else if let declGroupScope = ancestor.as(DeclGroupSyntaxType.self) {
        return DeclContext.declGroup(declGroupScope)
      } else {
        currentAncestor = ancestor.parent
      }
    }
    // Shouldn't happen because `Attached<DeclGroupSyntaxType>` has
    // a `SourceFileSyntax` root that we should have run into.
    fatalError(
      "[SwiftLexicalLookup] Internal error: Unexpectedly didn't find declaration context of attached decl group `\(node._memberlessDescription)`."
    )
  }

  fileprivate mutating func _resolveDeclGroup(
    declGroup: Attached<DeclGroupSyntaxType>,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedTypeSyntax> {
    let declContext: DeclContext = _findDeclContext(ofDeclGroup: declGroup)

    log("Found decl context `\(_describeDeclContext(declContext))` containing `\(declGroup._memberlessDescription)`")

    if let nominalTypeDecl = declGroup.as(NominalTypeDeclSyntax.self) {
      return resolveNominalTypeDecl(
        nominalDecl: nominalTypeDecl,
        declContext: declContext,
        originatingSyntax: originatingSyntax
      )

    } else if let extensionDecl = declGroup.as(ExtensionDeclSyntax.self) {
      guard
        case .codeBlock(let fileStatements) = declContext,
        fileStatements.node == extensionDecl.fileRoot.statements
      else {
        return .failure(Failure.extensionNotAtFileScope(extensionDecl: extensionDecl.node))
      }
      // Wrap the global reference
      return bindExtension(extensionDecl).map(ResolvedTypeSyntax.init(globalTypeReference:))
    } else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Expected decl group to be either a nominal type or extension decl; instead found \(declGroup.kind)."
      )
    }
  }

  /// Resolves the nominal-type declaration in the given declaration context.
  fileprivate mutating func resolveNominalTypeDecl(
    nominalDecl: Attached<NominalTypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedTypeSyntax> {
    withLogging(
      request: "Nominal `\(nominalDecl._memberlessDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveNominalTypeDecl(
          nominalDecl: nominalDecl,
          declContext: declContext,
          originatingSyntax: originatingSyntax
        )
      }
    )
  }

  /// Finds the member type-decl of a nominal base type.
  ///
  /// A helper for `resolveNominalTypeDecl` and `resolveMember`.
  fileprivate mutating func findNominalTypeMemberDecl(
    resolvedNominalBaseType: NominalTypeRef,
    memberName: Identifier,
    memberIntroducingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)?> {
    // Perform direct type lookup and mark dependency
    //
    // First, get the module
    let introducingModule = extractModule(syntax: memberIntroducingSyntax)
    // Look up
    let memberTypeDeclsResult:
      Result<
        [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)],
        TypeGraph.QualifiedTypeLookupFailure
      > =
        symbolTable.findMemberType(
          baseType: resolvedNominalBaseType,
          memberTypeName: memberName,
          introducingTypeSyntax: memberIntroducingSyntax,
          introducingModule: introducingModule,
          dependencyTracker: &dependencyTracker
        )

    // Handle failures
    let memberTypeDecls: [(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)]
    switch memberTypeDeclsResult {
    case .success(let success):
      memberTypeDecls = success
    case .failure(.unregisteredFileRoot):
      // We check that the root is a source file in the symbol table
      // at the top of ``resolveSyntax``.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Unexpectedly asked to resolve a type declaration whose root isn't a file or a file not registered in the symbol table."
      )
    case .failure(.invalidBase):
      fatalError(
        "[SwiftLexicalLookup] Internal error: Base type \(resolvedNominalBaseType) was unexpectedly invalid."
      )
    }

    // Process the results
    //
    // 1. Return `nil` if no such declaration exists.
    guard let firstTypeDecl = memberTypeDecls.first else {
      return Result.success(nil)
    }
    // 2. Cannot have multiple type declarations named the same.
    //    E.g.
    //    struct A {
    //      typealias B = Int
    //      typealias B = Bool
    //      let b: B // ❌ ambiguous
    //    }
    // TODO: Add ability to disambiguite shadowing/fileprivate
    guard memberTypeDecls.count == 1 else {
      // TODO: Find more efficient solution (perhaps force `symbolTable.findMembers` to sort for us).
      return Result.failure(
        Failure.ambiguousTypeDecl(symbolTable.sortDeclarations(memberTypeDecls.map(\.typeDecl)).map(\.node))
      )
    }
    // There's just one member; return that
    return Result.success(firstTypeDecl)
  }

  /// Implements `resolveNominalTypeDecl`
  fileprivate mutating func _resolveNominalTypeDecl(
    nominalDecl: Attached<NominalTypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedTypeSyntax> {
    assert(
      declContext.syntax.range.contains(nominalDecl.node.range),
      "[SwiftLexicalLookup] Internal error: Decl context doesn't contain declaration."
    )

    guard let declName = Identifier(validating: nominalDecl.node.name) else {
      return .failure(Failure.invalidNameToken(nominalDecl.node.name))
    }

    // Extract file info
    let file = nominalDecl.fileRoot
    let module = extractModule(syntax: nominalDecl)
    let declFileConfiguredRegions = extractConfiguredRegions(syntax: nominalDecl)

    switch declContext {
    case .codeBlock(let codeBlockScope):
      let isGlobal: Bool = codeBlockScope.node == file.statements

      // Gather type decls with the same name
      var scopeTypeDecls = [TypeDeclSyntax]()
      codeBlockScope.node._visitDirectMembers(
        configuredRegions: extractConfiguredRegions(syntax: codeBlockScope),
        visit: { valueDecl in
          guard
            let typeDecl = valueDecl.as(TypeDeclSyntax.self),
            typeDecl.name.identifier == declName
          else {
            return
          }
          scopeTypeDecls.append(typeDecl)
        }
      )
      // If we're at top-level, consider other internal declarations
      if isGlobal {
        // TODO: Look in the module, and add those decls
        // IMPORTANT: Make sure results are correctly sorted
      }

      // Diagnose redeclarations
      guard scopeTypeDecls == [TypeDeclSyntax(nominalDecl.node)] else {
        // Results are already sorted from lookup
        return .failure(Failure.ambiguousTypeDecl(scopeTypeDecls))
      }

      // Register the type
      let resolvedReferenceResult =
        symbolTable.registerNominalType(
          topScopeMainDecl: nominalDecl,
          declName: declName,
          declFileConfiguredRegions: declFileConfiguredRegions,
          declModule: module,
          isGlobal: isGlobal,
          originatingSyntax: originatingSyntax
        ) as Result<ResolvedTypeSyntax, TypeGraph.NominalRegistrationFailure>

      // Extract reference, or trap
      let resolvedReference: ResolvedTypeSyntax
      switch resolvedReferenceResult {
      case .success(let success):
        resolvedReference = success
      case .failure(let registrationFailure):
        switch registrationFailure {
        // Reasoning: We just checked for redeclarations
        case .cannotRegisterRedeclaration:
          fatalError(
            "[SwiftLexicalLookup] Internal error: While registering top-scope `\(nominalDecl._memberlessDescription)`: \(registrationFailure)"
          )
        }
      }

      return .success(resolvedReference)
    case .declGroup(let declGroupParent):
      // Find the base type
      let baseResult: Result<ResolvedTypeSyntax, Failure> = resolveDeclGroup(
        declGroup: declGroupParent,
        originatingSyntax: originatingSyntax
      )
      // Extract the type, or throw
      let baseType: ResolvedTypeSyntax
      switch baseResult {
      case .success(let success):
        baseType = success
      case .failure(let failure):
        return .failure(Failure.invalidBaseType(failure))
      }

      // Find this nominal declaration through qualified lookup
      let resolvedBase: ResolvedTypeSyntax
      switch resolveType(typeReference: baseType) {
      case .success(let success):
        resolvedBase = success
      case .failure(let failure):
        return .failure(Failure.invalidBaseType(failure))
      }
      let memberResult:
        Result<(declGroupParent: Attached<DeclGroupSyntaxType>, typeDecl: Attached<TypeDeclSyntax>)?, Failure>
      do {
        // Don't track dependencies (only extensions track dependencies)
        let dependencyTracker = self.dependencyTracker
        self.dependencyTracker = DependencyTracker()
        defer { self.dependencyTracker = dependencyTracker }

        memberResult = findNominalTypeMemberDecl(
          resolvedNominalBaseType: resolvedBase.type,
          memberName: declName,
          memberIntroducingSyntax: Attached<TypeLikeSyntax>(nominalDecl),
        )
      }

      // Ensure we exist under the right decl group and there are no duplicates
      switch memberResult {
      case .success((declGroupParent, Attached<TypeDeclSyntax>(nominalDecl))?):
        break
      case .success(let unexpectedResult):
        // We should have diagnosed an ambiguity if there was a different
        // nominal decl or we couldn't find a member
        fatalError(
          "[SwiftLexicalLookup] Internal error: Qualified lookup of \(baseType._succinctDescription) > '\(declName.name)' unexpectedly returned `\(unexpectedResult.debugDescription)`"
        )
      case .failure(let failure):
        return .failure(failure)
      }

      // Register the type
      let resolvedReferenceResult =
        symbolTable.registerNominalType(
          nestedMainDecl: nominalDecl,
          declName: declName,
          declFileConfiguredRegions: declFileConfiguredRegions,
          declModule: module,
          baseDeclGroup: declGroupParent,
          baseType: baseType,
          originatingSyntax: originatingSyntax
        ) as Result<ResolvedTypeSyntax, TypeGraph.NestedNominalRegistrationFailure>

      // Extract the reference, or trap
      let resolvedReference: ResolvedTypeSyntax
      switch resolvedReferenceResult {
      case .success(let success):
        resolvedReference = success
      case .failure(let registrationFailure):
        switch registrationFailure {
        // Reasoning:
        // .cannotRegisterRedeclaration -> We just checked for redeclarations
        // .baseNotRegistered, .baseDeclGroupUnbound -> We should have a valid base from the recursive step
        case .other(.cannotRegisterRedeclaration), .baseNotRegistered, .baseDeclGroupUnbound:
          fatalError(
            "[ewiftLexicalLookup] Internal error: While registering '\(baseType._succinctDescription)' > '\(nominalDecl._memberlessDescription)': \(registrationFailure)"
          )
        }
      }

      return .success(resolvedReference)
    }
  }

  /// Resolve the given type declaration produced by the given `baseTypeDecl`.
  /// This subrequest was initiated by a request to resolve a ``originatingSyntax``.
  ///
  /// This requests explicitly doesn't resolve associated types and generic-parameter
  /// declarations.
  fileprivate mutating func resolveTypeDecl(
    typeDecl: Attached<TypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    withLogging(
      request: "Decl \(typeDecl.kind) `\(typeDecl.node.name.trimmedDescription)`",
      describe: \._debugDescription,
      perform: {
        $0._resolveTypeDecl(typeDecl: typeDecl, declContext: declContext, originatingSyntax: originatingSyntax)
      }
    )
  }

  /// Implements `resolveTypeDecl`
  fileprivate mutating func _resolveTypeDecl(
    typeDecl: Attached<TypeDeclSyntax>,
    declContext: DeclContext,
    originatingSyntax: Attached<TypeLikeSyntax>
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    assert(
      declContext.syntax.range.contains(typeDecl.node.range),
      "[SwiftLexicalLookup] Internal error: Decl context doesn't contain declaration."
    )

    // We mainly handle nominal types; type aliases are trivially recursive, and we skip
    // associated types and generic parameters
    if let nominalTypeDecl = typeDecl.as(NominalTypeDeclSyntax.self) {
      // Resolve the main nominal-type decl and wrap it in `MemberLookupResult.memberResults`
      return resolveNominalTypeDecl(
        nominalDecl: nominalTypeDecl,
        declContext: declContext,
        originatingSyntax: originatingSyntax
      ).map({ ResolvedType.nominalTypes([$0]) })
    } else if let typeAlias = typeDecl.as(TypeAliasDeclSyntax.self) {
      let aliasedTypeSyntax = typeAlias.node.initializer.value
      log(
        "Found aliased type `\(aliasedTypeSyntax)`"
      )

      let aliasedResult: Result<ResolvedType<ResolvedTypeSyntax>, Failure> = resolveSyntax(
        typeSyntax: typeAlias.initializerValue
      )
      // Wrap in a failure unless we're part of a cycle
      switch aliasedResult {
      case .success(let success):
        return Result.success(success)
      case .failure(let failure):
        // If we're part of the cycle, return the cycle
        if let nestedCycle = failure.nestedCycle, nestedCycle.contains(aliasedTypeSyntax) {
          return Result.failure(Failure.cyclicalTypeReference(cycle: nestedCycle))
        }
        // Wrapping the failure indicates the type alias itself isn't the
        // problem; the referenced type is the problem (diagnosed separately).
        return Result.failure(Failure.invalidAliasedType(failure))
      }
    } else { /* else if it's an associated type or generic parameter */
      // No members for generic parameters and associated types
      return Result.failure(Failure.genericParameterOrAssociatedType)
    }
  }
}

// MARK: Member Lookup

extension TypeResolver {
  /// Resolves the given member reference of the provided, resolved base type,
  /// recording our dependencies on qualified-lookup queries.
  ///
  /// Note: The base type might have redeclarations, in which case we return
  /// the appropriate error.
  fileprivate mutating func resolveMember(
    baseType: Result<ResolvedType<ResolvedTypeSyntax>, Failure>,
    typeMember: ImplicitTypeReferenceComponent
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    // Describe the base type(s)
    let baseDescription: String
    switch baseType {
    case .success(ResolvedType.nominalTypes(let baseTypes)):
      baseDescription = baseTypes.map(\.type._succinctDescription).joined(separator: " & ")
    case .success(_):
      baseDescription = "<non-nominal>"
    case .failure:
      baseDescription = "<failure>"
    }

    return withLogging(
      request:
        "Member `\(baseDescription)` > `\(typeMember.debugDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveMember(baseType: baseType, typeMember: typeMember) }
    )
  }

  /// Implements `resolveMember`
  fileprivate mutating func _resolveMember(
    baseType: Result<ResolvedType<ResolvedTypeSyntax>, Failure>,
    typeMember: ImplicitTypeReferenceComponent
  ) -> TypeResult<ResolvedType<ResolvedTypeSyntax>> {
    // Get base type(s), or throw (can't resolve anything without the base)
    let rawBaseType: ResolvedType<ResolvedTypeSyntax>
    switch baseType {
    case .success(let success): rawBaseType = success
    case .failure(let failure): return Result.failure(failure)
    }

    // Extract nominal type or composition thereof
    let baseTypes: [ResolvedTypeSyntax]
    switch rawBaseType {
    // Accept nominals (count == 1) or compositions (count > 1).
    //
    // 'Compositions' of count == 0 (e.g. `Int.Type`) have no nominal types
    // and are automatically diagnosed at the end of the function.
    case .nominalTypes(let types):
      baseTypes = types
    case ResolvedType.anyType:
      return Result.failure(Failure.noTypeMember(member: typeMember, in: ResolvedType.anyType))
    case ResolvedType.function(let argumentCount):
      return Result.failure(
        Failure.noTypeMember(member: typeMember, in: ResolvedType.function(argumentCount: argumentCount))
      )
    case ResolvedType.tuple(let labels):
      return Result.failure(Failure.noTypeMember(member: typeMember, in: ResolvedType.tuple(labels: labels)))
    case ResolvedType.metatype(let base):
      return Result.failure(
        Failure.noTypeMember(member: typeMember, in: ResolvedType.metatype(base: base))
      )
    }

    // Perform qualified type lookup and mark the dependencies
    //
    // Note: We collect all types and failures.
    //
    // This approach allows the type checker can check if members of
    // compositions actually resolve to the same type. For instance:
    //   protocol A { typealias T = Int }
    //   final class B { typealias T = [String].Index /* i.e. Int */ }
    //   protocol C { typealias T = Int }
    //   typealias ABC = A & B & C
    //   let a: ABC.T // ✅ T resolves to `Int` in both cases
    // Of course, if we change the class' alias to `typealias T = String`,
    // the compiler will complain that `ABC.T` is ambiguous.
    //
    // Also, collecting all failures surfaces all errors at once for better
    // diagnostics.
    var visitedDecls = Set<Attached<TypeDeclSyntax>>()
    var declsAndResults = [(decl: Attached<TypeDeclSyntax>, result: ResolvedType<ResolvedTypeSyntax>)]()
    var failures = [(Attached<TypeLikeSyntax>, Failure)]()
    var nominalBaseTypes = [ResolvedTypeSyntax]()

    for baseType in baseTypes {
      // We'll collect the result, and type syntax
      //
      // We rely on definite initialization to ensure `memberResult` is
      // initialized exactly once, ensuring each member produces exactly one
      // result.
      let memberResult:
        Result<
          (typeDecl: Attached<TypeDeclSyntax>, result: ResolvedType<ResolvedTypeSyntax>)?,
          Failure
        >
      logPrefix.append("Base `\(baseType._succinctDescription)`")
      defer {
        logPrefix.removeLast()
        switch memberResult {
        case Result.success((let memberTypeDecl, let memberResult)?):
          // Add if not already added
          guard visitedDecls.insert(memberTypeDecl).inserted else { break }
          declsAndResults.append((memberTypeDecl, memberResult))
        case Result.success(nil):
          // No results; continue in case next one has a result.
          break
        case Result.failure(let failure):
          failures.append((typeMember.introducingSyntax, failure))
        }
      }

      // Bind extensions and construct a nominal type.
      // We ignore failures since they're from non-matching extensions and diagnosed separately
      let nominalBaseType: ResolvedTypeSyntax
      switch resolveType(typeReference: baseType) {
      case .success(let success):
        nominalBaseType = success
      case .failure(let failure):
        memberResult = Result.failure(failure)
        continue
      }
      nominalBaseTypes.append(nominalBaseType)

      // Get the member decl
      let memberTypeDeclResult = findNominalTypeMemberDecl(
        resolvedNominalBaseType: nominalBaseType.type,
        memberName: typeMember.name,
        memberIntroducingSyntax: typeMember.introducingSyntax
      )
      log("Type members matching '\(typeMember.name.name)': \(memberTypeDeclResult._debugDescription)")
      // Collect; skip if it doesn't exist; throw on failure
      let (memberDeclGroupParent, memberTypeDecl): (Attached<DeclGroupSyntaxType>, Attached<TypeDeclSyntax>)
      switch memberTypeDeclResult {
      case .success(let success?):
        (memberDeclGroupParent, memberTypeDecl) = success
      case .success(nil):
        // Skip if no such member exists, e.g.: in `(Encodable & Collection<Int>).Element`,
        // `Encodable` may not have an `Element` type member.
        memberResult = Result.success(nil)
        continue
      case .failure(let failure):
        memberResult = Result.failure(failure)
        continue
      }

      // Resolve this type declaration and add it to the results
      memberResult = resolveTypeDecl(
        typeDecl: memberTypeDecl,
        declContext: DeclContext.declGroup(memberDeclGroupParent),
        originatingSyntax: typeMember.introducingSyntax
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
      return Result.failure(
        Failure.invalidMembers(failures.map({ (typeSyntax, failure) in (typeSyntax.node, failure) }))
      )
    }

    // Diagnose if we get no results
    // E.g. `(Any & Sendable).MyType` yields no results for either `Any.MyType` or
    //   `Sendable.MyType`; hence, `MyType` isn't a member of `Any & Sendable`.
    guard let (_, firstResult) = declsAndResults.first else {
      return Result.failure(
        Failure.noTypeMember(
          member: typeMember,
          in: ResolvedType.nominalTypes(nominalBaseTypes)
        )
      )
    }
    // TODO: Ensure we're properly shadowing and not giving false-positive errors
    guard declsAndResults.count == 1 else {
      return Result.failure(
        Failure.ambiguousTypeDecl(declsAndResults.map(\.decl.node))
      )
    }

    return Result.success(firstResult)
  }
}

// MARK: Extended-Type Syntax

extension TypeResolver {
  /// Resolve the given type syntax from an extension declaration
  /// to a single nominal type. Should be called on a newly initialized
  /// `TypeResolver` instance.
  ///
  /// Note that we only diagnose extending tuples/functions and compositions
  /// (e.g. `Codable = Encodable & Decodable`). However, we don't diagnose
  /// things like extending an existential (e.g. `extension any Collection`).
  mutating func resolveExtendedTypeSyntax(
    extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> TypeResult<GenericResolvedTypeSyntax<GlobalNominalTypeRef>> {
    withLogging(
      request: "Extended type syntax `\(extensionDecl.extendedType.trimmedDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveExtendedTypeSyntax(extensionDecl: extensionDecl) }
    )
  }

  /// Implements `resolveExtendedTypeSyntax`
  mutating func _resolveExtendedTypeSyntax(
    extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> TypeResult<GenericResolvedTypeSyntax<GlobalNominalTypeRef>> {
    guard visitedTypeSyntax == [] else {
      fatalError(
        "[SwiftLexicalLookup] Internal error: Resolve extended type syntax should only be called on a fresh `TypeResolver` instance."
      )
    }

    // Ensure extension is at file scope
    let declContext = _findDeclContext(ofDeclGroup: Attached<DeclGroupSyntaxType>(extensionDecl))
    guard
      case DeclContext.codeBlock(let scope) = declContext,
      scope.node == extensionDecl.fileRoot.statements
    else {
      return .failure(Failure.extensionNotAtFileScope(extensionDecl: extensionDecl.node))
    }

    let resolvedTypeResult = resolveSyntax(
      typeSyntax: extensionDecl.extendedType
    )
    // Throw if syntax resolution fails
    let resolvedType: ResolvedType<ResolvedTypeSyntax>
    switch resolvedTypeResult {
    case .success(let result):
      resolvedType = result
    case .failure(let failure):
      return .failure(failure)
    }

    // Extract a nominal type
    switch resolvedType {
    case .nominalTypes(let results):
      // We're expecting exactly one nominal type.
      // No types means non-nominal, e.g., `Int.Type` and compositions are
      // also not extensible, e.g., `Encodable & Decodable`.
      guard let nominalType = results.first, results.count == 1 else {
        return .failure(Failure.cannotExtendNonNominal(nonnominal: resolvedType))
      }
      // That types needs to be global (can't extended local types)
      let nominalRef = nominalType.type
      guard case .global(let globalNominalRef) = nominalRef.storage else {
        fatalError(
          "[SwiftLexicalLookup] Internal error: Extended type of top-level extension `\(extensionDecl._memberlessDescription)` unexpectedly evaluated to local type `\(nominalRef._succinctDescription)`."
        )
      }
      // Return global reference
      return .success(
        GenericResolvedTypeSyntax(
          type: globalNominalRef,
          syntax: nominalType.syntax
        )
      )
    // Functions/tuples/`Any`/metatypes aren't nominal
    case .function, .tuple, .anyType, .metatype:
      return .failure(.cannotExtendNonNominal(nonnominal: resolvedType))
    }
  }
}

// MARK: Resolve Extension / Nominal

extension TypeResolver {
  /// Resolve a qualified-type name to a nominal type with all accessible
  /// extensions bound.
  @_spi(_QualifiedLookupTests) public mutating func resolveType(
    typeReference: ResolvedTypeSyntax
  ) -> TypeResult<ResolvedTypeSyntax> {
    withLogging(
      request: "Extended nominal`\(typeReference._succinctDescription)`",
      describe: \._debugDescription,
      perform: { $0._resolveType(typeReference: typeReference) }
    )
  }

  /// Implements `resolveNominalType`
  fileprivate mutating func _resolveType(
    typeReference: ResolvedTypeSyntax
  ) -> TypeResult<ResolvedTypeSyntax> {
    // Skip extension binding for local declarations.
    //
    // For instance, there's no way to extend `A` in `func f() { struct A {} }`
    // since extensions may only be declared at the top level.
    guard case .global(let qualifiedGlobalRef) = typeReference.type.storage else {
      return .success(typeReference)
    }

    // Wrap the new reference in a `ResolvedNominalTypeReference`
    func wrapReference(_ nominalRef: NominalTypeRef) -> ResolvedTypeSyntax {
      ResolvedTypeSyntax(
        type: nominalRef,
        syntax: typeReference.syntax
      )
    }

    // Get the nominal type from the symbol table (or register accordingly)
    let currentNominalResult: Result<NominalTypeRef, TypeGraph.NominalTypeRefUpdateFailure> =
      symbolTable.typeGraph.updateNominalTypeReference(oldReference: typeReference.type)

    // Handle reregistration (we should diagnose reregistrations and not save them in the table)
    let currentNominal: NominalTypeRef
    switch currentNominalResult {
    case .success(let success):
      currentNominal = success
    case .failure(.removed):
      // If the reference changed, report those failures
      return .failure(Failure.noTypeInScope)
    }

    // Find all the extensions we need to bind
    let accessibleExtensions = symbolTable.findAllExtensions(
      accessibleFrom: typeReference.syntax.fileRoot
    )
    log("Accessible extensions: \(accessibleExtensions.map(\._memberlessDescription))")

    // Queue up the extensions that need binding
    let unadmittedExtensions: [Attached<ExtensionDeclSyntax>] = accessibleExtensions.filter({
      accessibleExtension in
      symbolTable.unresolvedExtensions[accessibleExtension.fileRoot, default: []].contains(accessibleExtension)
    })

    // Return if no extensions are available
    guard !unadmittedExtensions.isEmpty else {
      log("No extensions to bind.")
      return .success(wrapReference(currentNominal))
    }

    symbolTable.admitExtensions(unadmittedExtensions)

    // After binding all extensions, get the new nominal type
    guard
      case .success(let finalizedNominalRef) = symbolTable.typeGraph.updateNominalTypeReference(
        oldReference: NominalTypeRef(globalReference: qualifiedGlobalRef)
      )
    else {
      // We checked the nominal type is registered at the start.
      fatalError(
        "[SwiftLexicalLookup] Internal error: Nominal type unexpectedly removed from symbol table after binding extensions."
      )
    }

    return .success(wrapReference(finalizedNominalRef))
  }

  /// Returns the nominal-type reference with the extension's extended-type
  /// syntax as the originating syntax.
  @_spi(_QualifiedLookupTests) public mutating func bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> TypeResult<GenericResolvedTypeSyntax<GlobalNominalTypeRef>> {
    withLogging(
      request: "Binding extension `\(extensionDecl._memberlessDescription)`",
      describe: \._debugDescription,
      perform: { $0._bindExtension(extensionDecl) }
    )
  }

  fileprivate mutating func _bindExtension(
    _ extensionDecl: Attached<ExtensionDeclSyntax>
  ) -> TypeResult<GenericResolvedTypeSyntax<GlobalNominalTypeRef>> {
    if let alreadyBoundResult = symbolTable.getExtensionResolvedType(extensionDecl) {
      return alreadyBoundResult
    }

    symbolTable.admitExtensions([extensionDecl])

    // If there's not an existing extension-binding request, the extension
    // should be admitted. Otherwise, return a failure for now.
    guard let boundTypeResult = symbolTable.typeGraph.getExtensionResolvedType(extensionDecl) else {
      // The extension graph tracks dependencies so this result should be
      // invalidated and fixed after the primary extension-binding request
      // completes.
      return .failure(Failure.extensionNotBoundYet)
    }

    return boundTypeResult.map({ (globalReference, mainDecl) in
      GenericResolvedTypeSyntax<GlobalNominalTypeRef>(
        type: globalReference,
        syntax: Attached<TypeLikeSyntax>(extensionDecl.extendedType)
      )
    })
  }
}
