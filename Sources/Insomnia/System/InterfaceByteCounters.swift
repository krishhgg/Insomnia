import Darwin
import Foundation

/// Read-only 64-bit interface counters. No subprocess, packet capture, extra
/// installation or administrator access. Count one physical interface only,
/// never add VPN/tunnel counters to its traffic.
enum InterfaceByteCounters {
    enum Failure: Error {
        case interfaceMissing
        case system(Int32)
        case malformedResponse
    }

    static func read(interfaceName: String, timestamp: TimeInterval) throws -> InterfaceByteSample {
        let index = if_nametoindex(interfaceName)
        guard index > 0, let argument = Int32(exactly: index) else { throw Failure.interfaceMissing }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, argument]
        // The interface list can grow between the size query and the read.
        for _ in 0..<3 {
            var count = 0
            guard sysctl(&mib, u_int(mib.count), nil, &count, nil, 0) == 0 else {
                throw Failure.system(errno)
            }
            guard count > 0, count <= 16 * 1024 * 1024 else { throw Failure.malformedResponse }
            var bytes = [UInt8](repeating: 0, count: count)
            let result = bytes.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &count, nil, 0)
            }
            if result != 0 {
                let code = errno
                if code == ENOMEM { continue }
                throw Failure.system(code)
            }
            guard count <= bytes.count else { throw Failure.malformedResponse }
            return try decode(Data(bytes.prefix(count)), index: index, timestamp: timestamp)
        }
        throw Failure.system(ENOMEM)
    }

    /// Validate message boundaries before reading a header. Kept separate so
    /// malformed responses and 64-bit amounts can be tested without sysctl.
    static func decode(_ data: Data, index: UInt32, timestamp: TimeInterval) throws -> InterfaceByteSample {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard raw.count - offset >= 4 else { throw Failure.malformedResponse }
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= raw.count - offset else { throw Failure.malformedResponse }
                let version = raw[offset + 2]
                let type = raw[offset + 3]
                if type == RTM_IFINFO2 {
                    guard version == RTM_VERSION, length >= MemoryLayout<if_msghdr2>.size else {
                        throw Failure.malformedResponse
                    }
                    let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(header.ifm_index) == index {
                        return InterfaceByteSample(interfaceIndex: index,
                            received: header.ifm_data.ifi_ibytes,
                            sent: header.ifm_data.ifi_obytes,
                            timestamp: timestamp)
                    }
                }
                offset += length
            }
            throw Failure.interfaceMissing
        }
    }
}
