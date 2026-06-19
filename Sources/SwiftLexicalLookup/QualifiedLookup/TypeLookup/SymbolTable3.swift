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
  typealias Module = Identifier
  let moduleToSources: [Module: [SourceFileSyntax]]

  init(moduleToSources: [Module: [SourceFileSyntax]]) {
    self.moduleToSources = moduleToSources
  }

  private(set) lazy var moduleMap: [SourceFileSyntax: Module] = {
    var result = [SourceFileSyntax: Module]()
    for (module, sources) in moduleToSources {
      for source in sources {
        result[source] = module
      }
    }
    return result
  }()

}
