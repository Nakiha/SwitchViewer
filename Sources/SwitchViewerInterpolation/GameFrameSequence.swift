/// Frame IDs stay increasing when a live change reduces the interpolation multiplier.
/// Reserve the complete old group so its retired callbacks cannot reuse a new ID.
/// Multiples preserve the legacy 2× parity used by existing trace readers.
public struct GameFrameSequence {
    private var reservedThrough: UInt64 = 0
    public init() {}
    public mutating func next(multiplier: InterpolationMultiplier) -> UInt64 {
        let stride = UInt64(multiplier.rawValue)
        let original = (reservedThrough / stride + 1) * stride
        reservedThrough = original + stride - 1
        return original
    }
}
