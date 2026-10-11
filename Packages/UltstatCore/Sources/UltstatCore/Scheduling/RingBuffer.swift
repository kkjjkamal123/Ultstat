/// Fixed-capacity history of `Float` samples. Storage is allocated once; `append` never allocates.
public struct RingBuffer: Sendable, Equatable {
    public let capacity: Int
    @usableFromInline var storage: [Float]
    @usableFromInline var head = 0          // index of the next write
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    public mutating func append(_ value: Float) {
        storage[head] = value
        head = head + 1 == capacity ? 0 : head + 1
        if count < capacity { count += 1 }
    }

    public var last: Float? {
        guard count > 0 else { return nil }
        return storage[head == 0 ? capacity - 1 : head - 1]
    }

    /// Oldest-to-newest traversal without materialising an array.
    @inlinable
    public func forEach(_ body: (Float) throws -> Void) rethrows {
        let start = count < capacity ? 0 : head
        for i in 0..<count {
            let idx = start + i
            try body(storage[idx < capacity ? idx : idx - capacity])
        }
    }

    public var values: [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        forEach { out.append($0) }
        return out
    }

    public var max: Float? {
        guard count > 0 else { return nil }
        var m = -Float.infinity
        forEach { if $0 > m { m = $0 } }
        return m
    }

    public mutating func removeAll() {
        head = 0
        count = 0
    }
}
