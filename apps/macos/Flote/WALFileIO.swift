// WAL sidecar I/O helper - Sprint 3 Data Loss Resilience
import Foundation

struct WALFileIO {

    // MARK: - Atomic write with WAL sidecar
    //
    // Write sequence (D5 User-approved pattern):
    //   1. Write data to <url>.wal  (Data.write atomic = OS-level rename)
    //   2. fsync the .wal file      (guarantee bytes reach disk before rename)
    //   3. Rename .wal → <url>      (POSIX atomic move - crash-safe)
    //
    // If the process dies between steps 1-2 and step 3, the .wal file survives
    // on disk and safeRead() will recover from it on the next launch.

    static func atomicWrite(to url: URL, data: Data) throws {
        let walURL = url.appendingPathExtension("wal")

        // Step 1: write data to .wal (Data.write atomic uses a temp file + rename internally)
        try data.write(to: walURL, options: [.atomic])

        // Step 1b: tighten .wal permissions to 0600 BEFORE fsync, so the
        // bytes that hit the platter are already user-only-readable.
        // Best-effort: if chmod fails we still proceed (better to lose
        // permission tightening than to drop user data).
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: walURL.path
        )

        // Step 2: fsync so the .wal bytes are durable before we rename
        let fd = open(walURL.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }

        // Step 3: atomic move .wal → main file (replaces any existing main)
        // N-5: surface removeItem failures instead of swallowing with `try?`.
        // If we kept silently failing here on a FAT volume or permission-restricted
        // path, the subsequent moveItem would refuse to overwrite the existing main
        // file and the .wal sidecar would stay on disk — safeRead() would then keep
        // promoting it on every launch while the user's latest edits never reach
        // the main file. Throwing lets PersistenceService log the failure and
        // surface a save error.
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: walURL, to: url)
        // At this point .wal no longer exists; main file is up-to-date.
        // Set 0600 on the final main file as well (move preserves the wal's
        // mode but APFS/Xcode behavior can differ — be explicit).
        try? fm.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - Safe read with WAL fallback
    //
    // Priority order (D5 spec):
    //   The presence of a .wal file means atomicWrite was interrupted between
    //   step 1 (wal flushed to disk) and step 3 (rename to main). In that
    //   window, main still holds the PREVIOUS commit — .wal is the newer,
    //   durably-written data we were promoting. So when both files exist we
    //   must prefer .wal; the sidecar disappears only after a successful
    //   rename. Preferring main in that window would silently return stale
    //   data.
    //
    //   (a) .wal present & non-empty   → use .wal (crash recovery), repair main
    //   (b) .wal missing, main present → use main (normal path)
    //   (c) both missing/empty         → return nil

    static func safeRead(from url: URL) -> Data? {
        let walURL = url.appendingPathExtension("wal")
        let fm = FileManager.default

        // (a) .wal exists → it's the most recent durable write
        if let walData = try? Data(contentsOf: walURL), !walData.isEmpty {
            NSLog("[Flote] WALFileIO: recovering from .wal sidecar (interrupted write) for %@", url.lastPathComponent)
            // Best-effort promote: write wal's bytes back to main so the next
            // load is a clean no-wal path. Swallow errors (we already have
            // the data in-hand), but log them so repeated wal fallback is
            // visible.
            do {
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                try fm.moveItem(at: walURL, to: url)
            } catch {
                NSLog("[Flote] WALFileIO: wal → main promote failed: %@", String(describing: error))
            }
            return walData
        }

        // (b) Normal path: main file only
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }

        // (c) Nothing available
        return nil
    }
}
