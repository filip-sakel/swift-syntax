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

import Foundation
import SwiftParser
import SwiftSyntax
import XCTest

// TODO: Switch to @_spi(Experimental) eventually
@_spi(Experimental) @testable import SwiftLexicalLookup

// This is a prsed DeclRefExpr *epxression*
// assertLookup(inNominalType: "struct MyStruct { \(foundBy: "myFunc(a:)", static: true)static func myFunc(a: Int) {} ")
// assertLookup(usingSource: "struct MyStruct: MyProto {}", "protocol MyProto { (1)func a() }",
//              Query("MyStruct", of: "a()", withSuper: true): ["(1)"]
//              Query("MyStruct.Type", of "()"): [.implicit(.memberwise)]

// assertLookup(usingSource: """
// struct MyStruct: MyProto {
//   \(typeRef: "MyStruct/funcA()")
//   func funcA() {}
//
//   \(typeRef: "MyStruct.Type/init(hi:)", "MyStruct.Type/_(hi:)", "MyStruct.Type/init")
//   init(hi: Int) {}
//
//   \("MyStruct.Type/init(hey:)", "MyStruct.Type/init")
//   init(hey: Int) {}
//
//   \("MyStruct/[a:b:]")
//   subscript(a: Int, b: Int) -> Int { 5 }
// }
// protocol MyProto {
//   \("MyProto/myFunc(a:)".config(kind: .static()),
//     "MyStruct/myFunc(a:)".config(kind: .static(), supertypes: true))
//   static func myFunc(a: Int) {}
// }
// """)

struct QualifiedLookupSource: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  // enum Expectation: ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral {
  //   case referenceMarker(Character)
  //   // case `Self`
  //
  //   init(unicodeScalarLiteral value: Character) {
  //     self = .referenceMarker(value)
  //   }
  //   init(extendedGraphemeClusterLiteral value: Character) {
  //     self = .referenceMarker(value)
  //   }
  // }

  // Returns string of error messages; empty if valid.
  static func parseType(_ type: TypeSyntax, file: StaticString, line: UInt) -> UnresolvedTypeRef? {
    // // Parse as a type
    // let typeSyntax = TypeSyntax(stringLiteral: typeName)
    // We only allow identifier, member and (potentially) metatype syntax.
    // switch type.as(TypeSyntaxEnum.self) {
    // case .identifierType: break
    // case .memberType(let memberType):
    //   // Check base
    //   parseType(memberType.baseType, file: file, line: line)
    //   // No generics for now
    //   if memberType.genericArgumentClause != nil {
    //     XCTFail("Invalid type '\(type.trimmedDescription)': Generic arguments not supported (yet).")
    //   }
    // case .metatypeType(let metatypeType):
    //   // Check base
    //   parseType(metatypeType.baseType, file: file, line: line)
    // default:
    //   XCTFail("Invalid type '\(type.trimmedDescription)': Type kind '\(type.kind)' isn't supported; only identifier, member and metatype types are supported.")
    // }
    do {
      return try UnresolvedTypeRef.fromTypeSyntax(type).get()
    } catch {
      XCTFail("Couldn't parse type: '\(error)'", file: file, line: line)
      return nil
    }
  }
  static func parseDeclRefName(_ exprSyntax: ExprSyntax, file: StaticString, line: UInt) -> DeclNameRef? {
    func parseArgument(i: Int, label: TokenSyntax?, expression: ExprSyntax) -> Identifier? {
      guard let label = label else {
        XCTFail(
          "Couldn't parse decl name reference: Argument at position \(i) not provided.",
          file: file,
          line: line
        )
        return nil
      }

      if !expression.is(MissingExprSyntax.self) {
        XCTFail(
          "Invalid parse decl name reference: unexpectedly found expression for argument at position \(i); please don't provide an expression for the name",
          file: file,
          line: line
        )
      }

      // E.g. "(myIdentifier:)"
      if let identifier = Identifier(validating: label) {
        return identifier
      }
      // E.g. "(_:)"
      else if label.tokenKind == .wildcard {
        return nil
      }
      // Invalid
      else {
        XCTFail(
          "Invalid decl name reference: Argument at position \(i) has invalid token kind \(label.tokenKind); expected '_' or identifier.",
          file: file,
          line: line
        )
        return nil
      }
    }

    // TODO: Implement macros / module selectors
    switch exprSyntax.as(ExprSyntaxEnum.self) {
    // Identifier with no arg list or nonempty arg list (other case is parsed as func call expr)
    case .declReferenceExpr(let declReferenceExpr):
      let moduleIdentifier: Identifier? = (declReferenceExpr.moduleSelector?.moduleName).flatMap({
        moduleName -> Identifier? in
        guard let identifier = Identifier(validating: moduleName) else {
          XCTFail(
            "Couldn't parse declaration refernece: Invalid module name of kind '\(moduleName.tokenKind)'",
            file: file,
            line: line
          )
          return nil
        }
        return identifier
      })
      guard let identifier = Identifier(validating: declReferenceExpr.baseName) else {
        XCTFail(
          "Couldn't parse declaration refernece: Invalid declaration name of kind '\(declReferenceExpr.baseName.tokenKind)'",
          file: file,
          line: line
        )
        return nil
      }

      return DeclNameRef(
        moduleIdentifier: moduleIdentifier,
        coreName: .identifier(
          identifier: identifier,
          // TODO: Implement macros
          macro: nil,
          args: declReferenceExpr.argumentNames?.arguments.enumerated().map({ i, arg in
            parseArgument(i: i, label: arg.name, expression: ExprSyntax(MissingExprSyntax()))
          })
        )
      )
    // Subscripts
    case .subscriptCallExpr(let subscriptCallExpr):
      guard subscriptCallExpr.calledExpression.is(DiscardAssignmentExprSyntax.self) else {
        XCTFail(
          "Couldn't parse declaration reference: Found subscript call expression without '_' as the base; try renaming base to '_'",
          file: file,
          line: line
        )
        return nil
      }
      return DeclNameRef(
        coreName: .subscript(
          args: subscriptCallExpr.arguments.enumerated().map({ i, arg in
            parseArgument(i: i, label: arg.label, expression: arg.expression)
          })
        )
      )
    // Unnamed functions
    case .functionCallExpr(let funcCallExpr):
      switch funcCallExpr.calledExpression.as(ExprSyntaxEnum.self) {
      case .declReferenceExpr(let declReferenceExpr) where declReferenceExpr.argumentNames == nil:
        let moduleIdentifier: Identifier? = (declReferenceExpr.moduleSelector?.moduleName).flatMap({
          moduleName -> Identifier? in
          guard let identifier = Identifier(validating: moduleName) else {
            XCTFail(
              "Couldn't parse declaration refernece: Invalid module name of kind '\(moduleName.tokenKind)'",
              file: file,
              line: line
            )
            return nil
          }
          return identifier
        })
        guard let identifier = Identifier(validating: declReferenceExpr.baseName) else {
          XCTFail(
            "Couldn't parse declaration refernece: Invalid declaration name of kind '\(declReferenceExpr.baseName.tokenKind)'",
            file: file,
            line: line
          )
          return nil
        }
        return DeclNameRef(
          moduleIdentifier: moduleIdentifier,
          coreName: .identifier(identifier: identifier, macro: nil, args: [])
        )

      case .discardAssignmentExpr:
        return DeclNameRef(
          coreName: .unnamedCall(
            args: funcCallExpr.arguments.enumerated().map({ i, arg in
              parseArgument(i: i, label: arg.label, expression: arg.expression)
            })
          )
        )
      default:
        XCTFail(
          "Couldn't parse declaration reference: Found function call expression without '_' as its name; try removing the expression from the arguments",
          file: file,
          line: line
        )
        return nil
      }
    default:
      XCTFail(
        "Couldn't parse declaration reference: The valid syntaxes are: '_(arg1: ... argN:)' or 'identifier(arg1: ... argN:)' or '[arg1: ... argN:]'",
        file: file,
        line: line
      )
      return nil
    }
  }

  // Expectation of the form `<TypeSyntax>/<DeclRefName>`
  // struct TypeLookupExpectation: ExpressibleByStringLiteral {
  //   // enum Failure: Error, CustomStringConvertible {
  //   //   case invalidComponentCount, invalidTypeBase, invalidDeclRef
  //   //
  //   //   var description: String {
  //   //     "Expected"
  //   //   }
  //   // }
  //
  //   let contents: (typeBase: TypeSyntax, declName: DeclNameRef)?
  //
  //   init(stringLiteral qualifiedName: String, file: StaticString = #file, line: UInt = #line) {
  //     // Extract components
  //     let components = qualifiedName.split(separator: "/")
  //     guard components.count == 2 else {
  //       XCTFail("Invalid qualified name: Expected name of the form '<type>/<decl ref name>' but either '/' is missing or the type/decl name is empty.", file: file, line: line)
  //       contents = nil
  //     }
  //     // Parse syntax
  //     let typeSyntax = TypeSyntax(stringLiteral: components[0].description)
  //     let declSyntax = DeclSyntax(stringLiteral: components[1].description)
  //
  //     // Validate syntax
  //     parseType(typeSyntax, file: file, line: line)
  //     parseDeclRefName(declSyntax, file: file, line: line)
  //   }
  // }
  struct DeclLookupExpectation {
    let declRef: DeclNameRef?
    var memberKind: MemberKind = .default
    let file: StaticString
    let line: UInt

    static func decl(
      _ stringLiteral: String,
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      let exprSyntax = ExprSyntax(stringLiteral: stringLiteral)
      return DeclLookupExpectation(
        declRef: parseDeclRefName(exprSyntax, file: file, line: line),
        file: file,
        line: line
      )
    }
    static func decl(
      exact ref: DeclNameRef,
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(declRef: ref, file: file, line: line)
    }
    static func named(
      _ name: StaticString,
      args optionalArgs: [StaticString?]? = nil,
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(
        declRef: DeclNameRef(
          coreName: .identifier(
            identifier: Identifier(canonicalName: name),
            macro: nil,
            args: optionalArgs?.map({ (argName: StaticString?) -> Identifier? in
              argName.map({ Identifier(canonicalName: $0) })
            })
          )
        ),
        file: file,
        line: line
      )
    }
    // TODO: Add macro
    static func `deinit`(
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(
        declRef: DeclNameRef(
          coreName: .deinit
        ),
        file: file,
        line: line
      )
    }
    /// Creates an `init` declaration reference. Automatically configures lookup to
    /// look for static declarations.
    static func `init`(
      _ optionalArgs: [StaticString?]?,
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(
        declRef: DeclNameRef(
          coreName: .`init`(
            args: optionalArgs?.map({ (argName: StaticString?) -> Identifier? in
              argName.map({ Identifier(canonicalName: $0) })
            })
          )
        ),
        memberKind: .includeAllMembers,
        file: file,
        line: line
      )
    }
    static func unnamed(
      _ args: [StaticString],
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(
        declRef: DeclNameRef(
          coreName: .unnamedCall(args: args.map({ Optional(Identifier(canonicalName: $0)) }))
        ),
        file: file,
        line: line
      )
    }

    static func `subscript`(
      _ args: [StaticString],
      file: StaticString = #file,
      line: UInt = #line
    ) -> DeclLookupExpectation {
      DeclLookupExpectation(
        declRef: DeclNameRef(
          coreName: .subscript(args: args.map({ Optional(Identifier(canonicalName: $0)) }))
        ),
        file: file,
        line: line
      )
    }

    /// Looks only for static declarations.
    func `static`() -> DeclLookupExpectation {
      var copy = self
      copy.memberKind = .includeStatic
      return copy
    }
  }
  enum Component {
    case str(String)
    case expectations([DeclLookupExpectation], file: StaticString, line: UInt)
  }

  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.str(literal))
    }
    mutating func appendInterpolation(
      _ expectations: DeclLookupExpectation...,
      file: StaticString = #file,
      line: UInt = #line
    ) {
      components.append(.expectations(expectations, file: file, line: line))
    }
    // mutating func appendInterpolation(
    //   declGroupRef: expectations: Expectation...,
    //   file: StaticString = #file,
    //   line: UInt = #line
    // ) {
    //
    // }
  }

  /// The source with all markers removed
  let source: String
  /// A map from positions in the string to a list of expectations for the declaration at that location.
  let positionsToExpectations: [String.Index: (expectations: [DeclLookupExpectation], file: StaticString, line: UInt)]

  // /// A dictionary mapping markers (symbol referenced from `expectations`)
  // /// to a valid index in `source`.
  // let markerToIndexMap: [Character: String.Index]
  // /// A collection of expectations when performing lookup at the given
  // /// index.
  // let positionsAndExpectations: [(fromIndex: String.Index, expecting: [DeclLookupExpectation], file: StaticString, line: UInt)]

  // /// Records duplicate markers found in source (markers should be unique)
  // let duplicateMarkers: Set<Character>

  init(stringInterpolation: Interpolation) {
    // let components = stringInterpolation.components
    //
    // let markers = components.flatMap { component -> [Character] in
    //   // Only expectations generate markers
    //   guard case .expectations(let expectations, _, _) = component else {
    //     return []
    //   }
    //   return expectations.compactMap({ expectation in
    //     guard case .referenceMarker(let marker) = expectation else { return nil }
    //     return marker
    //   })
    // }
    //
    // var source = ""
    // var markerToIndexMap = [Character: String.Index]()
    // var positionsAndExpectations = [
    //   (fromIndex: String.Index, expecting: [Expectation], file: StaticString, line: UInt)
    // ]()
    //
    // // Test diagnostics
    // var duplicateMarkers = Set<Character>()
    //
    // for component in components {
    //   switch component {
    //   case .str(let str):
    //     // Add each character to the source, unless it's a marker
    //     for char in str {
    //       if !markers.contains(char) {  // .contains is O(n) but we should have few markers
    //         // Append normal characters
    //         source.append(char)
    //       } else {
    //         // If it's a marker, check it's not a duplicate and record the end index
    //         if markerToIndexMap[char] != nil { duplicateMarkers.insert(char) }
    //         markerToIndexMap[char] = source.endIndex
    //       }
    //     }
    //   case .expectations(let expectations, let file, let line):
    //     // If it's an expectation, record the position BEFORE the end.
    //     //
    //     // E.g. In "myFunc\(to: "🅰️")", after processing "myFunc", the
    //     // endIndex would point to past the end of the string. So by taking the
    //     // index before the end, we now refer to "c".
    //     positionsAndExpectations.append(
    //       (
    //         fromIndex: source.index(before: source.endIndex),
    //         expecting: expectations,
    //         file: file, line: line
    //       )
    //     )
    //   }
    // }
    //
    // self.source = source
    // self.markerToIndexMap = markerToIndexMap
    // self.positionsAndExpectations = positionsAndExpectations
    // // Tets validation
    // self.duplicateMarkers = duplicateMarkers

    var source = ""
    var positionsToExpectations = [
      String.Index: (expectations: [DeclLookupExpectation], file: StaticString, line: UInt)
    ]()
    for component in stringInterpolation.components {
      switch component {
      case .str(let str): source.append(str)
      case .expectations(let declExpectations, let file, let line):
        // Get the endIndex so we refer to the token after the expectation. E.g. with '\(.decl(exact: .deinit)) deinit {}'
        // we'll refer directly to the `deinit`.
        //
        // Diagnose existing expectation (we allow only one per source index)
        if let existingExpectation = positionsToExpectations[source.endIndex] {
          XCTFail(
            "[Lookup Failure] Second expectation for same source index is prohibited (original expectation at \(existingExpectation.file):\(existingExpectation.line))",
            file: file,
            line: line
          )
          continue
        }
        // Save expectation
        positionsToExpectations[source.endIndex] = (declExpectations, file: file, line: line)
      }
    }

    self.source = source
    self.positionsToExpectations = positionsToExpectations
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

final class TestQualifiedLookup: XCTestCase {
  /// Check each of the `\(toType: ...)`-suffixed `<Type>.<member>`
  /// names map to the correct member declarations.
  ///
  /// Each declaration-reference name suffixed with a '\(toDecl: ...)' so-called
  /// expectation must be valid type syntax identifier type syntax or member type
  /// syntax consisting solely of other member type syntax or identifier type nodes.
  ///
  /// Further, each marker should be attached right in front of the introducer keyword
  /// of the named declaration it identifies. For instance:
  ///   public 🟥MyStruct {
  ///     @MainActor static private 🟩func myFunc() {}
  ///   }
  func assertTypeMemberLookup(
    _ lookupSource: QualifiedLookupSource,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    var parser = Parser(lookupSource.source)
    let sourceFile = SourceFileSyntax.parse(from: &parser)

    // // Ensure markers are unique
    // XCTAssert(
    //   lookupSource.duplicateMarkers.isEmpty,
    //   "Unexpectedly found duplicate markers \(Array(lookupSource.duplicateMarkers))",
    //   file: file,
    //   line: line
    // )

    /// IMPORTANT: Only use for `lookupSource.source` and `sourceFile`.
    func sourcePosition(of index: String.Index) -> AbsolutePosition {
      AbsolutePosition(
        utf8Offset: lookupSource.source.distance(
          from: lookupSource.source.startIndex,
          to: index
        )
      )
    }

    // // Extract declarations identifier by each marker
    // var markerToDecl = [Character: any NamedDeclSyntax]()
    // for (marker, sourceIndex) in lookupSource.markerToIndexMap {
    //   // The assertion expects this to be an introducer token
    //   guard let introducerToken = sourceFile.token(at: sourcePosition(of: sourceIndex)) else {
    //     XCTFail(
    //       "[Internal Error] Unexpectedly couldn't find token for marker '\(marker)'",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   // Since this is an introducer, the named declaration should be its parent; try to cast it.
    //   guard let introducerParent = introducerToken.parent else {
    //     XCTFail(
    //       "Marker '\(marker)' points to token without parent. Ensure marker is placed before the named declaration's introducer keyword, like 'struct'.",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //   guard let namedDecl = introducerParent.asProtocol((any NamedDeclSyntax).self) else {
    //     XCTFail(
    //       "Marker '\(marker)' points to token whose parent isn't a named declaration. Ensure marker is placed before the named declaration's introducer keyword, like 'struct'.",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   markerToDecl[marker] = namedDecl
    // }
    //
    // // Validate each expectation
    // let symbolTable = SymbolTable(sourceFile: sourceFile)
    // print("Found symbol table globals:", symbolTable.globalGroups)
    // for (sourceIndex, expectations, file, line) in lookupSource.positionsAndExpectations {
    //   // === Validate Test === \\
    //
    //   // --- Test Markers ---
    //   // Check expectations refer to valid markers
    //   enum ExpectationDecl {
    //     case decl(any NamedDeclSyntax, marker: Character)
    //   }
    //   let expectationDecls = expectations.compactMap({ expectation -> ExpectationDecl? in
    //     switch expectation {
    //     case .referenceMarker(let marker):
    //       // Ensure marker is valid
    //       guard lookupSource.markerToIndexMap[marker] != nil else {
    //         XCTFail(
    //           "Expectation requires lookup to produce result to nonexistent marker \(marker).",
    //           file: file,
    //           line: line
    //         )
    //         return nil
    //       }
    //
    //       // Get valid declaration
    //       guard let decl = markerToDecl[marker] else {
    //         return nil  // Diagnosed when generating `markerToDecl`
    //       }
    //
    //       return ExpectationDecl.decl(decl, marker: marker)
    //     }
    //   })
    //
    //   // --- Extract Syntax for Lookup ---
    //   // Get all identifier tokens separated by dots
    //   guard let memberToken = sourceFile.token(at: sourcePosition(of: sourceIndex)) else {
    //     XCTFail(
    //       "[Internal Error] Unexpectedly couldn't find token to look up for expectation",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   // Ensure token is an identifier (this is where we'll do lookup)
    //   guard let memberIdentifier = memberToken.identifier else {
    //     XCTFail(
    //       "Expected tested token to be an identifier, but got \(memberToken.tokenKind) instead.",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //   guard let baseDeclRef = memberToken.parent?.as(DeclReferenceExprSyntax.self) else {
    //     XCTFail(
    //       "Expected tested token's parent to be a 'DeclReferenceExprSyntax', but got \(String(describing: memberToken.parent?.kind)).",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   // The given declaration reference should be part of a MemberAccessExprSyntax with a valid base
    //   // E.g., "TypeA.myFunc` or `TypeA.TypeB` or `TypeA.TypeB.funcA`.
    //   guard
    //     let memberAccessExpr = baseDeclRef.parent?.as(MemberAccessExprSyntax.self),
    //     let memberAccessBase = memberAccessExpr.base
    //   else {
    //     // TODO: Consider other test case
    //     // 2. The given declaration may be a standalone declaration (we assume it's a type here
    //     //    to test the base type lookup)
    //     //    TODO: Look into expanding this as general name lookup
    //     XCTFail(
    //       "Expected tested token's grandparent to be a 'MemberAccessExprSyntax' with a *valid* base, but got syntax type \(String(describing: baseDeclRef.parent?.kind)).",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   guard Syntax(memberAccessExpr.base) != Syntax(baseDeclRef) else {
    //     XCTFail(
    //       "Expectation cannot refer to the base of a member access expression. This may be caused from a bare-type lookup, e.g. `MyStruct\\(references: ...)`.",
    //       file: file,
    //       line: line
    //     )
    //     continue
    //   }
    //
    //   // Reinterpret the member-access base as a member type expression
    //   // (we assume it's a type for this test)
    //   let typeSyntax: TypeSyntax = "\(raw: memberAccessBase.description)"
    //
    //   // === Test Lookup === \\
    //
    //   // Perform lookup
    //   let foundDecls = symbolTable.lookupMember(
    //     withName: DeclNameRef(coreName: .identifier(identifier: memberIdentifier)),
    //     inType: typeSyntax,
    //     atLocation: memberToken.position,
    //     options: SymbolTable.LookupOptions.qualifiedDefault
    //   )
    //
    //   // Check expectations match
    //   print("Found decls:", foundDecls)
    //   var idsToFoundDecl = Dictionary(grouping: foundDecls, by: \.id).mapValues({ decls in
    //     guard let decl = decls.first, decls.count == 1 else {
    //       fatalError(
    //         "[Internal Error] Unexpectedly found multiple declarations with id \(String(describing: decls.first?.id))"
    //       )
    //     }
    //     return decl
    //   })
    //   for expectation in expectationDecls {
    //     switch expectation {
    //     case .decl(let expectedDecl, let marker):
    //       // Ensure lookup surfaced expected declaration
    //       XCTAssert(
    //         idsToFoundDecl[expectedDecl.id] != nil,
    //         "Lookup of `\(typeSyntax.trimmed)/\(memberIdentifier.name)` [id: \(expectedDecl.id)] didn't return declaration '\(marker)' [id: \(idsToFoundDecl[expectedDecl.id])].",
    //         file: file,
    //         line: line
    //       )
    //       // Check declaration off the list
    //       idsToFoundDecl[expectedDecl.id] = nil
    //     }
    //   }
    //
    //   // Ensure lookup didn't give us more than expected
    //   if !idsToFoundDecl.isEmpty {
    //     for (_, decl) in idsToFoundDecl {
    //       XCTFail(
    //         "Lookup of `\(typeSyntax.trimmed)/\(memberIdentifier.name)` found non-expected declaration [id: \(decl.id)] of type '\(decl.kind)': \n`\(decl.description)`",
    //         file: file,
    //         line: line
    //       )
    //     }
    //   }
    // }

    var sharedDeclGroup: DeclGroupSyntaxType? = nil
    struct Pair<A: Hashable, B: Hashable>: Hashable { let a: A, b: B }
    var namesToExpectations = [Pair<DeclNameRef, MemberKind>: [(ValueDeclSyntax, file: StaticString, line: UInt)]]()

    for (sourceIndex, (expectations, file, line)) in lookupSource.positionsToExpectations {
      // The assertion expects this to be an introducer token
      guard let introducerToken = sourceFile.token(at: sourcePosition(of: sourceIndex)) else {
        XCTFail(
          "[Internal Error] Unexpectedly couldn't find token for expectation.",
          file: file,
          line: line
        )
        continue
      }

      // We expect the parent to be a ValueDeclSyntax
      guard let valueDecl = introducerToken.parent?.as(ValueDeclSyntax.self) else {
        XCTFail(
          "Invalid expectation placement: The parent of the token after the expectation isn't a value declaration; instead got '\(String(reflecting: introducerToken.parent?.kind))'.",
          file: file,
          line: line
        )
        continue
      }
      // print(">>Found value decl '\(valueDecl.trimmedDescription)'")

      // Find the implicit decl-group parent
      func declGroupParent(of syntax: Syntax) -> DeclGroupSyntaxType? {
        guard let parent = syntax.parent else { return nil }
        return parent.as(DeclGroupSyntaxType.self) ?? declGroupParent(of: parent)
      }
      guard let declGroup = declGroupParent(of: Syntax(valueDecl)) else {
        XCTFail(
          "Invalid expectation placement: No group-declaration parent for the tested value declaration '\(valueDecl.trimmed)'",
          file: file,
          line: line
        )
        continue
      }

      // Update and ensure everyone uses the same declGroup
      if sharedDeclGroup == nil {
        sharedDeclGroup = declGroup
      } else if let sharedDeclGroup, sharedDeclGroup.id != declGroup.id {
        XCTFail(
          "Only one group declaration allowed but found at least two with types '\(sharedDeclGroup.type?.trimmedDescription ?? "_"))' and '\(declGroup.type?.trimmedDescription ?? "_")' ('\(sharedDeclGroup.trimmedDescription)' and '\(declGroup.trimmedDescription)')",
          file: file,
          line: line
        )
      }

      // Register each expectation for the respective name
      for expectation in expectations {
        // Skip lookup if reference is undefined (diagnosed earlier)
        guard let name = expectation.declRef else { continue }

        // Register expectation for this name
        namesToExpectations[Pair(a: name, b: expectation.memberKind), default: []].append(
          (decl: valueDecl, file: expectation.file, line: expectation.line)
        )
      }
    }

    // Ensure we got at least one shared group
    guard let sharedDeclGroup else {
      XCTFail("No valid expectations found", file: file, line: line)
      return
    }
    // print(">>Found decl group: '\(sharedDeclGroup.trimmedDescription)'")

    // Perform lookup
    let symbolTable = SymbolTable(sourceFile: sourceFile)
    for (nameAndMemberKind, expectations) in namesToExpectations {
      let (name, memberKind) = (nameAndMemberKind.a, nameAndMemberKind.b)
      // print(">>Looking for name \(name.debugDescription)")

      let foundDecls = symbolTable.lookupMember(
        withName: name,
        inDeclGroup: sharedDeclGroup,
        fromLocation: AbsolutePosition(utf8Offset: 0),
        memberKind: memberKind
      )

      // Cross out matched decls and diagnose unmatched
      var unmatchedDecls = Set(foundDecls)
      for (expectedDecl, file, line) in expectations {
        guard unmatchedDecls.contains(expectedDecl) else {
          XCTFail(
            "[Lookup Failure] Lookup `\(sharedDeclGroup.type?.trimmedDescription ?? "_")`/\(name.debugDescription) \(memberKind) didn't find expected declaration (name: \(expectedDecl.declName.debugDescription), kind: \(expectedDecl.kind), id: \(expectedDecl.id.hashValue)).",
            file: file,
            line: line
          )
          continue
        }
        // Cross out matched
        unmatchedDecls.remove(expectedDecl)
      }

      // Diagnose unmatched
      for unmatchedDecl in unmatchedDecls {
        XCTFail(
          "[Lookup Failure] Lookup `\(sharedDeclGroup.type?.trimmedDescription ?? "_")`/\(name.debugDescription) \(memberKind) found unexpcted declarations (id: \(unmatchedDecl.id.hashValue)): ```\(unmatchedDecl.trimmedDescription)```",
          file: file,
          line: line
        )
      }
    }
  }

  func testCodeBlockSimpleCase() {
    // TODO: Implement type-lookup helper first.
    // assertTypeMemberLookup(
    //   """
    //   🅰️struct MyStruct {
    //     🅱️func hello() {}
    //
    //     struct TypeB {}
    //
    //     func hi() {
    //       MyStruct.TypeB\(references: "🅰️").hello\(references: "🅱️")
    //     }
    //   }
    //   """
    // )
    assertTypeMemberLookup(
      """
      struct MyStruct {
        var \(.named("a"))a,
            \(.named("b"))b: Int

        \(.named("hello", args: []),
          .named("hello"))
        func hello() {}

        // Init can be referenced as <Type>.init, <Type>.init(), <Type>()
        \(.`init`([]),
          .`init`(nil),
          .unnamed([]).static())
        init() {}

        // References: <myValue>.callAsFunction, <myValue>.callAsFunction(), <myValue>()
        \(.named("callAsFunction", args: []),
          .named("callAsFunction"),
          .unnamed([]))
        func callAsFunction() {}

        // When `callAsFunction` is static, it exhibits no special behavior
        static
        \(.named("callAsFunction", args: []).static())
        func callAsFunction () {}

        \(.deinit())
        deinit {}
      }
      """
    )
  }

  // TODO: Test lookup of an associated type and how it interacts with MyProto.Type, etc.

  // TODO: Test multiple variables/patterns and finding those, e.g., var a, b, c: Int {}, etc.

  // TODO: Test function-like parameters with firstName="_", variadic arguments, trailing closures, etc.

  // TODO: Test nested and non-nested macro lookup

  // TODO: Test cycles, e.g. struct A { typealias Element = B.Element }; struct B { typealias Element = A }
  // typealias A = B; typealias B = A. Or protocol A: B {}; protocol B: A {}

  // TODO: Handle lookup in struct nested inside function, e.g. func hi() { struct Hello { var a }; Hello().a }

  // TODO: Think about isolation use cases? (That seems more like type checking)

  // TODO: Macro test, e.g. @freestanding macro noargsButCallable() = ...; #closure(args)
}
