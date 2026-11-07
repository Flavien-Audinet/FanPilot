import Foundation
import IOKit

/// Lecture du SMC (lecture seule : l'écriture passe par le helper root).
final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        guard smc_open(&conn) == KERN_SUCCESS else { return nil }
    }

    deinit { smc_close(conn) }

    func read(_ key: String) -> Double? {
        var v = SMCValue()
        guard smc_read(conn, key, &v) == KERN_SUCCESS else { return nil }
        var d = 0.0
        return smc_value_to_double(&v, &d) ? d : nil
    }

    /// Lecture complète (renvoie aussi taille/type pour les lectures rapides suivantes).
    func readValue(_ key: String) -> SMCValue? {
        var v = SMCValue()
        return smc_read(conn, key, &v) == KERN_SUCCESS ? v : nil
    }

    /// Relit une valeur déjà connue en un seul appel noyau.
    func refresh(_ v: inout SMCValue) -> Double? {
        guard smc_read_fast(conn, &v) == KERN_SUCCESS else { return nil }
        var d = 0.0
        return smc_value_to_double(&v, &d) ? d : nil
    }

    func type(of key: String) -> String? {
        var v = SMCValue()
        guard smc_read(conn, key, &v) == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: v.type) { String(decoding: $0.prefix(4), as: UTF8.self) }
    }

    func allKeys() -> [String] {
        let n = smc_key_count(conn)
        var keys: [String] = []
        keys.reserveCapacity(Int(n))
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<n where smc_key_at_index(conn, i, &buf) == KERN_SUCCESS {
            keys.append(String(cString: buf))
        }
        return keys
    }
}
