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
import SwiftLexicalLookup
import SwiftSyntax
import XCTest

struct QualifiedLookupSource: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  enum Expectation: ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral {
    case referenceMarker(Character)
    case `Self`

    init(unicodeScalarLiteral value: Character) {
      self = .referenceMarker(value)
    }
    init(extendedGraphemeClusterLiteral value: Character) {
      self = .referenceMarker(value)
    }
  }
  enum Component {
    case str(String)
    case expectations([Expectation])
  }

  struct Interpolation: StringInterpolationProtocol {
    fileprivate var components: [Component]

    init(literalCapacity: Int, interpolationCount: Int) {
      components = []
    }
    mutating func appendLiteral(_ literal: String) {
      components.append(.str(literal))
    }
    mutating func appendInterpolation(to expectations: Expectation...) {
      components.append(.expectations(expectations))
    }
  }

  /// The source with all markers removed
  let source: String
  /// A dictionary mapping markers (symbol referenced from `expectations`)
  /// to a valid index in `source`.
  let markerToIndexMap: [Character: String.Index]
  /// Records if markers are unique (no duplicates found in source)
  let markersAreUnique: Bool
  /// A collection of expectations when performing lookup at the given
  /// index.
  let positionsAndExpectations: [(fromIndex: String.Index, expecting: [Expectation])]

  init(stringInterpolation: Interpolation) {
    let components = stringInterpolation.components

    let markers = components.flatMap { component -> [Character] in
      // Only expectations generate markers
      guard case .expectations(let expectations) = component else {
        return []
      }
      return expectations.compactMap({ expectation in
        guard case .referenceMarker(let marker) = expectation else { return nil }
        return marker
      })
    }
    let markerSet = Set(markers)
    self.markersAreUnique = markers.count == markerSet.count

    var source = ""
    var markerToIndexMap = [Character: String.Index]()
    var positionsAndExpectations = [(fromIndex: String.Index, expecting: [Expectation])]()

    for component in components {
      switch component {
      case .str(let str):
        // Add each character to the source, unless it's a marker
        for char in str {
          // If it's a marker, add the end index to the marker map
          if markers.contains(char) {
            markerToIndexMap[char] = source.endIndex
            // Otherwise, append and continue
          } else {
            source.append(char)
          }
        }
      case .expectations(let expectations):
        // If it's an expectation, record the position BEFORE the end.
        //
        // E.g. In "myFunc\(to: "🅰️")", after processing "myFunc", the
        // endIndex would point to past the end of the string. So by taking the
        // index before the end, we now refer to "c".
        positionsAndExpectations.append(
          (
            fromIndex: source.index(before: source.endIndex),
            expecting: expectations
          )
        )
      }
    }

    self.source = source
    self.markerToIndexMap = markerToIndexMap
    self.positionsAndExpectations = positionsAndExpectations
  }

  init(stringLiteral value: String) {
    // Just use the interpolation initializer
    var interpolation = Interpolation(literalCapacity: 1, interpolationCount: 0)
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }
}

final class TestQualifiedLookup: XCTestCase {

  func assertQualifiedLookup(
    _ source: QualifiedLookupSource,
  ) {

  }

  func testCodeBlockSimpleCase() {
    // TODO: Implement type-lookup helper first.
    assertQualifiedLookup(
      """
      🅰️struct MyStruct {
        🅱️static func hello() {}

        func hi() {
          MyStruct\(to: "🅰️").hello\(to: "🅱️")
        }
      }
      """
    )
  }
}
