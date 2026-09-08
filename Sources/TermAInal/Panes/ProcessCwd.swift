import Darwin
import Foundation

/// Reads a process's working directory straight from the kernel.
///
/// Replaces `getCwd(pid)` in `main.ts`, which shelled out to `lsof` on every
/// call. `proc_pidinfo` answers from this process, so there is no subprocess
/// spawn per pane per query.
enum ProcessCwd {
    static func lookup(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }
}
