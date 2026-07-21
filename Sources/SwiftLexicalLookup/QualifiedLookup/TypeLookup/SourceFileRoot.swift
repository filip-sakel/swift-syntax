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

struct SourceFileRoot<Node: SyntaxProtocol> {
  /// Invariant: Must always be a node whose `root` is a `SourceFileSyntax`
  private(set) var node: Node

  private init(_unchecked: __shared Node) { self.node = _unchecked }
  private init?(_checked node: __shared some SyntaxProtocol) {
    // Root must be source file
    guard node._syntaxNode.root.is(SourceFileSyntax.self) else { return nil }

    guard let node = Node(node) else { return nil }
    self.init(_unchecked: node)
  }
}

extension SourceFileRoot: SyntaxProtocol {
  init?(_ node: __shared some SyntaxProtocol) {
    self.init(_checked: node)
  }

  init?(_ node: __shared Node) {
    self.init(_checked: node)
  }

  /// Attempts to cast the current syntax node to a given specialized syntax type,
  /// maintaing the `SourceFileRoot` wrapper.
  ///
  /// - Returns: An instance of the specialized type, or `nil` if the cast fails.
  func `as`<S: SyntaxProtocol>(_ syntaxType: S.Type) -> SourceFileRoot<S>? {
    guard let castNode = node.as(S.self) else { return nil }
    return SourceFileRoot<S>(_unchecked: castNode)
  }

  var _syntaxNode: Syntax { node._syntaxNode }

  static var structure: SyntaxNodeStructure {
    Node.structure
  }

  var fileRoot: SourceFileSyntax {
    // By `_syntaxNode` invariant
    node.root.cast(SourceFileSyntax.self)
  }
}

extension SourceFileRoot: Equatable where Node: Equatable {}
extension SourceFileRoot: Hashable where Node: Hashable {}
extension SourceFileRoot: SyntaxHashable where Node: SyntaxHashable {}
