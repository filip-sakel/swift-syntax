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

// TODO: Find more permenant solution that AI-slopped `OrderedSet`.
// TODO: Could we just assert uniqueness in debug?
//
/// No-dependency version of Swift Collections' `OrderedSet`.
internal struct OrderedSet<Element: Hashable> {
  private var _elements: [Element]
  private var _members: Set<Element>

  // MARK: - Init

  /// Creates an empty ordered set.
  public init() {
    _elements = []
    _members = []
  }

  /// Creates an empty ordered set with room for at least `minimumCapacity`
  /// elements without reallocating.
  public init(minimumCapacity: Int) {
    _elements = []
    _members = []
    _elements.reserveCapacity(minimumCapacity)
    _members.reserveCapacity(minimumCapacity)
  }

  /// Creates an ordered set from a sequence, keeping only the first
  /// occurrence of each element and preserving that occurrence's order.
  public init<S: Sequence>(_ sequence: S) where S.Element == Element {
    if let already = sequence as? OrderedSet<Element> {
      self = already
      return
    }
    _elements = []
    _members = []
    _elements.reserveCapacity(sequence.underestimatedCount)
    _members.reserveCapacity(sequence.underestimatedCount)
    for element in sequence where _members.insert(element).inserted {
      _elements.append(element)
    }
  }
}

// MARK: - ExpressibleByArrayLiteral

extension OrderedSet: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: Element...) {
    self.init(elements)
  }
}

// MARK: - RandomAccessCollection

extension OrderedSet: RandomAccessCollection {
  public typealias Index = Int
  public typealias Indices = Range<Int>
  public typealias SubSequence = Array<Element>.SubSequence

  public var startIndex: Int { _elements.startIndex }
  public var endIndex: Int { _elements.endIndex }

  public func index(after i: Int) -> Int { i + 1 }
  public func index(before i: Int) -> Int { i - 1 }
  public func index(_ i: Int, offsetBy distance: Int) -> Int { i + distance }

  public subscript(position: Int) -> Element { _elements[position] }
  public subscript(bounds: Range<Int>) -> SubSequence { _elements[bounds] }
}

// MARK: - Basic queries

extension OrderedSet {
  /// The underlying array of elements, in order. O(1).
  public var elements: [Element] { _elements }

  public var count: Int { _elements.count }
  public var isEmpty: Bool { _elements.isEmpty }

  /// - Complexity: O(1) average.
  public func contains(_ element: Element) -> Bool {
    _members.contains(element)
  }
}

// MARK: - Mutation

extension OrderedSet {
  /// Appends `element` to the end if it isn't already present.
  ///
  /// - Returns: `(true, indexOfElement)` if the element was newly inserted,
  ///   or `(false, indexOfExistingElement)` if it was already a member.
  /// - Complexity: Amortized O(1) if newly inserted; O(n) otherwise.
  @discardableResult
  public mutating func append(_ element: Element) -> (inserted: Bool, index: Int) {
    let (inserted, _) = _members.insert(element)
    if inserted {
      _elements.append(element)
      return (true, _elements.count - 1)
    }
    return (false, _elements.firstIndex(of: element)!)
  }

  /// Appends every new (not-yet-present) element of `sequence`, in order.
  ///
  /// - Returns: The number of elements that were newly inserted.
  @discardableResult
  public mutating func append<S: Sequence>(
    contentsOf sequence: S
  ) -> Int where S.Element == Element {
    var inserted = 0
    for element in sequence where append(element).inserted {
      inserted += 1
    }
    return inserted
  }

  /// Inserts `element` at `index` if it isn't already present.
  ///
  /// - Returns: `(true, index)` if newly inserted, or `(false, existingIndex)`
  ///   if `element` was already a member (in which case nothing is moved).
  /// - Complexity: O(n).
  @discardableResult
  public mutating func insert(_ element: Element, at index: Int) -> (inserted: Bool, index: Int) {
    if let existing = firstIndex(of: element) {
      return (false, existing)
    }
    _members.insert(element)
    _elements.insert(element, at: index)
    return (true, index)
  }

  /// Removes `element` if present.
  ///
  /// - Complexity: O(n).
  @discardableResult
  public mutating func remove(_ element: Element) -> Element? {
    guard _members.remove(element) != nil else { return nil }
    let index = _elements.firstIndex(of: element)!
    return _elements.remove(at: index)
  }

  /// Removes and returns the element at `index`.
  ///
  /// - Complexity: O(n).
  @discardableResult
  public mutating func remove(at index: Int) -> Element {
    let element = _elements.remove(at: index)
    _members.remove(element)
    return element
  }

  @discardableResult
  public mutating func removeFirst() -> Element { remove(at: 0) }

  @discardableResult
  public mutating func removeLast() -> Element { remove(at: count - 1) }

  public mutating func removeAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
    var removed: [Element] = []
    try _elements.removeAll { element in
      if try shouldBeRemoved(element) {
        removed.append(element)
        return true
      }
      return false
    }
    for element in removed { _members.remove(element) }
  }

  public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
    _elements.removeAll(keepingCapacity: keepCapacity)
    _members.removeAll(keepingCapacity: keepCapacity)
  }

  public mutating func reserveCapacity(_ minimumCapacity: Int) {
    _elements.reserveCapacity(minimumCapacity)
    _members.reserveCapacity(minimumCapacity)
  }
}

// MARK: - Permutations (order only; membership is untouched)

extension OrderedSet {
  public mutating func swapAt(_ i: Int, _ j: Int) {
    _elements.swapAt(i, j)
  }

  public mutating func sort() where Element: Comparable {
    _elements.sort()
  }

  public mutating func sort(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows {
    try _elements.sort(by: areInIncreasingOrder)
  }

  public mutating func reverse() {
    _elements.reverse()
  }

  public mutating func shuffle() {
    _elements.shuffle()
  }

  public mutating func shuffle<G: RandomNumberGenerator>(using generator: inout G) {
    _elements.shuffle(using: &generator)
  }
}

// MARK: - Set-algebra-like operations

extension OrderedSet {
  /// Elements of `self` followed by any new elements of `other`, in order.
  public func union<S: Sequence>(_ other: S) -> OrderedSet where S.Element == Element {
    var result = self
    result.append(contentsOf: other)
    return result
  }

  public mutating func formUnion<S: Sequence>(_ other: S) where S.Element == Element {
    append(contentsOf: other)
  }

  /// Elements of `self` that also appear in `other`, preserving `self`'s order.
  public func intersection<S: Sequence>(_ other: S) -> OrderedSet where S.Element == Element {
    let otherSet = (other as? Set<Element>) ?? Set(other)
    return OrderedSet(_elements.filter(otherSet.contains))
  }

  public mutating func formIntersection<S: Sequence>(_ other: S) where S.Element == Element {
    self = intersection(other)
  }

  /// Elements of `self` that do not appear in `other`, preserving order.
  public func subtracting<S: Sequence>(_ other: S) -> OrderedSet where S.Element == Element {
    let otherSet = (other as? Set<Element>) ?? Set(other)
    return OrderedSet(_elements.filter { !otherSet.contains($0) })
  }

  public mutating func subtract<S: Sequence>(_ other: S) where S.Element == Element {
    self = subtracting(other)
  }

  public func isSubset(of other: OrderedSet) -> Bool {
    _members.isSubset(of: other._members)
  }

  public func isSuperset(of other: OrderedSet) -> Bool {
    _members.isSuperset(of: other._members)
  }

  public func isDisjoint(with other: OrderedSet) -> Bool {
    _members.isDisjoint(with: other._members)
  }
}

// MARK: - filter (order-preserving, returns an OrderedSet)

extension OrderedSet {
  public func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> OrderedSet {
    OrderedSet(try _elements.filter(isIncluded))
  }
}

// MARK: - Equatable / Hashable

extension OrderedSet: Equatable {
  /// Order-sensitive, like `Array`'s `==` — not like `Set`'s.
  public static func == (lhs: OrderedSet, rhs: OrderedSet) -> Bool {
    lhs._elements == rhs._elements
  }
}

extension OrderedSet: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(_elements)
  }
}

// MARK: - CustomStringConvertible

extension OrderedSet: CustomStringConvertible {
  public var description: String {
    "[" + _elements.map { "\($0)" }.joined(separator: ", ") + "]"
  }
}

// MARK: - Sendable

extension OrderedSet: Sendable where Element: Sendable {}
