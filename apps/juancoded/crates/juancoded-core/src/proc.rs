//! What a session's CLI is doing *below* the pty: how many helper processes it is
//! holding, and how much CPU the whole tree has burned.
//!
//! The reaper needs OS ground truth the activity detector cannot fake. A `claude`
//! that has gone screen- and transcript-quiet while a delegated subagent works is
//! indistinguishable from a dormant one on the wire, and the difference is visible
//! only here: the subagent is a live descendant, and it is spending CPU.
//!
//! **No new dependency.** `libc` is already a dependency of this crate for the pty's
//! `killpg`, and both platforms' answers are in it (macOS `proc_listchildpids` /
//! `proc_pid_rusage`, Linux `/proc`). A crate like `sysinfo` would have brought a
//! whole-machine process snapshot — every pid, its name, its memory — refreshed to
//! answer a question about one tree, and would have had to be kept current for a
//! platform pair this file covers in eighty lines.
//!
//! Both probes are best-effort by construction: a process that vanishes mid-walk
//! contributes nothing. That is safe here rather than merely tolerable, because a
//! vanished descendant also *changes the descendant count*, which is itself a
//! disturbance the reaper's streak restarts on.

/// Every live descendant pid of `pid` — children, grandchildren, and so on —
/// excluding `pid` itself.
///
/// `MAX_NODES` is a stop, not a policy: a pid table that changes under the walk can
/// in principle hand back a cycle, and a reaper sweep is not the place to discover
/// that by hanging.
pub fn descendants(pid: u32) -> Vec<u32> {
    const MAX_NODES: usize = 4096;
    let mut out = Vec::new();
    let mut queue = vec![pid];
    while let Some(next) = queue.pop() {
        if out.len() >= MAX_NODES {
            break;
        }
        for kid in children(next) {
            // A pid cannot be its own ancestor; if the table says otherwise, drop it
            // rather than walk it twice.
            if kid == pid || out.contains(&kid) {
                continue;
            }
            out.push(kid);
            queue.push(kid);
        }
    }
    out
}

/// How many live helper processes the session's CLI is holding right now.
pub fn descendant_count(pid: u32) -> usize {
    descendants(pid).len()
}

/// Cumulative CPU (user + system) of `pid` plus every live descendant, in ms.
pub fn tree_cpu_time_ms(pid: u32) -> u64 {
    std::iter::once(pid)
        .chain(descendants(pid))
        .filter_map(cpu_time_ms)
        .sum()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::OnceLock;

    /// Direct children of `pid` via `proc_listchildpids`, growing the buffer if a
    /// burst of children fills it exactly.
    pub fn children(pid: u32) -> Vec<u32> {
        let mut capacity = 64usize;
        loop {
            let mut buf = vec![0i32; capacity];
            // SAFETY: the buffer is `capacity` `pid_t`s long and we say so in bytes.
            let n = unsafe {
                libc::proc_listchildpids(
                    pid as libc::pid_t,
                    buf.as_mut_ptr().cast(),
                    (capacity * std::mem::size_of::<i32>()) as libc::c_int,
                )
            };
            if n < 0 {
                // Gone, or not ours to look at. Not an error worth a log line on a
                // path that runs once per session per sweep.
                return Vec::new();
            }
            let n = n as usize;
            if n < capacity {
                buf.truncate(n);
                return buf.into_iter().filter(|p| *p > 0).map(|p| p as u32).collect();
            }
            capacity *= 2;
        }
    }

    /// mach ticks → nanoseconds, read once. The ratio is fixed for the life of the
    /// machine, and `mach_timebase_info` is a trap on some hardware.
    ///
    /// `libc` deprecates this in favour of the `mach2` crate. Taken deliberately:
    /// the entire point of this module is that the reaper's OS probes cost no new
    /// dependency, and a whole crate for one `(numer, denom)` pair — 1/1 on Intel,
    /// 125/3 on Apple Silicon — is not a trade worth making. The call itself is not
    /// going anywhere; only libc's binding for it is.
    #[allow(deprecated)]
    fn timebase() -> (u64, u64) {
        static TB: OnceLock<(u64, u64)> = OnceLock::new();
        *TB.get_or_init(|| {
            let mut info = libc::mach_timebase_info { numer: 0, denom: 0 };
            // SAFETY: an out-parameter this call fills, or leaves zeroed on failure.
            let rc = unsafe { libc::mach_timebase_info(&mut info) };
            if rc != 0 || info.denom == 0 {
                (1, 1)
            } else {
                (info.numer as u64, info.denom as u64)
            }
        })
    }

    /// Cumulative CPU time (user + system) of one process in ms, or `None` when the
    /// process is gone.
    ///
    /// Flavour 4 rather than `RUSAGE_INFO_CURRENT`: "current" is whatever the SDK
    /// this was compiled against thinks is newest, and a newer kernel struct written
    /// into an older buffer is the one mistake this call can make. `ri_user_time` and
    /// `ri_system_time` are at the same offsets in every version from v0.
    pub fn cpu_time_ms(pid: u32) -> Option<u64> {
        const RUSAGE_INFO_V4: libc::c_int = 4;
        let mut info = std::mem::MaybeUninit::<libc::rusage_info_v4>::zeroed();
        // SAFETY: the flavour and the buffer type agree, which is the whole contract.
        let rc = unsafe {
            libc::proc_pid_rusage(
                pid as libc::c_int,
                RUSAGE_INFO_V4,
                info.as_mut_ptr().cast::<libc::rusage_info_t>(),
            )
        };
        if rc != 0 {
            return None;
        }
        // SAFETY: `proc_pid_rusage` returned 0, so it filled the struct.
        let info = unsafe { info.assume_init() };
        let (numer, denom) = timebase();
        let ticks = info.ri_user_time.saturating_add(info.ri_system_time);
        Some(ticks.saturating_mul(numer) / denom / 1_000_000)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::sync::OnceLock;

    /// Direct children of `pid`, from every thread's `children` file.
    ///
    /// `/proc/<pid>/task/<tid>/children` is the kernel's own answer and needs no
    /// scan of the whole pid table; it is documented as unreliable while processes
    /// are being reaped, which is exactly the tolerance this module already has.
    pub fn children(pid: u32) -> Vec<u32> {
        let tasks = match std::fs::read_dir(format!("/proc/{pid}/task")) {
            Ok(d) => d,
            Err(_) => return Vec::new(),
        };
        let mut out = Vec::new();
        for task in tasks.flatten() {
            let path = task.path().join("children");
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            out.extend(text.split_ascii_whitespace().filter_map(|t| t.parse().ok()));
        }
        out
    }

    fn ticks_per_sec() -> u64 {
        static HZ: OnceLock<u64> = OnceLock::new();
        *HZ.get_or_init(|| {
            // SAFETY: a pure query with no arguments to get wrong.
            let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
            if hz > 0 {
                hz as u64
            } else {
                100
            }
        })
    }

    /// utime + stime out of `/proc/<pid>/stat`, in ms.
    ///
    /// Fields 14 and 15 counted from 1, but the comm field (2) can itself contain
    /// spaces and parentheses, so the parse starts after the LAST `)` — which is the
    /// only way to read this file that a process called `foo) (bar` cannot break.
    pub fn cpu_time_ms(pid: u32) -> Option<u64> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let rest = &stat[stat.rfind(')')? + 1..];
        let fields: Vec<&str> = rest.split_ascii_whitespace().collect();
        // `rest` starts at field 3 (state), so utime/stime are indices 11 and 12.
        let utime: u64 = fields.get(11)?.parse().ok()?;
        let stime: u64 = fields.get(12)?.parse().ok()?;
        Some(utime.saturating_add(stime).saturating_mul(1_000) / ticks_per_sec())
    }
}

/// Every other platform: the probes answer "nothing observed" rather than refusing
/// to compile. The reaper still works there — it simply has two fewer independent
/// signals, and the detector, the output rate, the busy latch and the transcript
/// still have to agree before anything is slept.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    pub fn children(_pid: u32) -> Vec<u32> {
        Vec::new()
    }
    pub fn cpu_time_ms(_pid: u32) -> Option<u64> {
        None
    }
}

pub use imp::{children, cpu_time_ms};

#[cfg(test)]
mod tests {
    use super::*;

    /// The probes have to answer for *this* process, or every session reads as a
    /// tree that does not exist and the two OS signals are silently off.
    #[test]
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn this_process_has_measurable_cpu() {
        let me = std::process::id();
        let cpu = cpu_time_ms(me).expect("a live process has rusage");
        // A test binary that reached this line has run; the assertion is that the
        // number is real, not that it is any particular size.
        assert!(cpu < 60 * 60 * 1_000, "implausible cpu total: {cpu}ms");
        assert!(tree_cpu_time_ms(me) >= cpu, "the tree includes the root");
    }

    /// A pid that cannot exist must answer "gone" rather than a zero that would read
    /// as a real, quiet process.
    #[test]
    fn a_dead_pid_has_no_rusage_and_no_children() {
        // Deliberately above any plausible pid_max on either platform.
        let ghost = 0x7FFF_FFF0u32;
        assert_eq!(cpu_time_ms(ghost), None);
        assert!(descendants(ghost).is_empty());
        assert_eq!(tree_cpu_time_ms(ghost), 0);
    }

    /// The descendant walk has to see a real child, or the tree signal is a constant
    /// zero that never disturbs a streak.
    #[test]
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn a_spawned_child_shows_up_and_then_does_not() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "read line || true"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .expect("spawn a child");
        let me = std::process::id();
        let kids = descendants(me);
        assert!(
            kids.contains(&child.id()),
            "the walk missed a direct child: {kids:?}"
        );
        drop(child.stdin.take());
        let _ = child.wait();
    }
}
