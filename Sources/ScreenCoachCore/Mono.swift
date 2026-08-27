import Darwin

/// Monotonic timing. Every latency number in this project comes from here so
/// that no stage is ever measured against a different clock than another.
///
/// `CLOCK_UPTIME_RAW` is mach_absolute_time already converted to nanoseconds:
/// monotonic, unaffected by NTP steps, and it does not tick while the machine
/// is asleep. `CGEventGetTimestamp` hands back *raw* mach units instead, so
/// `machToNs` exists to drag hardware event timestamps onto the same axis —
/// without it, "key press → frame in hand" would be comparing two clocks and
/// silently wrong on Apple Silicon (timebase there is 125/3, not 1/1).
public enum Mono {

    @inline(__always)
    public static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// Raw mach_absolute_time units → nanoseconds on the `nowNs` axis.
    public static func machToNs(_ mach: UInt64) -> UInt64 {
        // Split the multiply so a large mach value can't overflow: on Apple
        // Silicon numer/denom is 125/3, so a naive `mach * 125` overflows
        // 64 bits after ~4.7 years of uptime. Rare, but free to avoid.
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        guard numer != denom else { return mach }
        let whole = mach / denom
        let frac = mach % denom
        return whole * numer + (frac * numer) / denom
    }

    @inline(__always)
    public static func msSince(_ startNs: UInt64) -> Double {
        Double(nowNs() &- startNs) / 1_000_000
    }

    @inline(__always)
    public static func ms(from: UInt64, to: UInt64) -> Double {
        Double(to &- from) / 1_000_000
    }
}
