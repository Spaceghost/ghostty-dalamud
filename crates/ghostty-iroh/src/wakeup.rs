//! One readiness signal for the whole endpoint.
//!
//! `docs/IROH.md` ("No fd"): the crate owns an eventfd/pipe (POSIX) or a
//! manual-reset event (Windows) that the runtime signals whenever *anything*
//! became pollable — bytes arrived, a connect latched, a listener has a pending
//! accept. It is level-triggered and deliberately coarse: the agent loop pumps
//! everything each pass and never reads `revents`.
//!
//! Nothing here ever calls into the caller's module. The signal is polled.

use std::sync::atomic::{AtomicBool, Ordering};

pub struct Wakeup {
    /// True between a `signal()` and the next `drain()`. `wait_ms` reads this
    /// so an fd-less platform still shortens the caller's sleep.
    armed: AtomicBool,
    #[cfg(unix)]
    fds: Option<(i32, i32)>, // (read, write)
    #[cfg(windows)]
    event: Option<isize>, // HANDLE
}

// The raw fds/HANDLE are owned for the process lifetime of the Wakeup and only
// ever read/written with syscalls that are themselves thread-safe.
unsafe impl Send for Wakeup {}
unsafe impl Sync for Wakeup {}

impl Wakeup {
    #[cfg(unix)]
    pub fn new() -> Self {
        let mut fds = [0i32; 2];
        // SAFETY: fds is a valid 2-element array for the duration of the call.
        let rc = unsafe { libc::pipe(fds.as_mut_ptr()) };
        let fds = if rc == 0 {
            for fd in fds {
                // SAFETY: fd was just created by pipe().
                unsafe {
                    let flags = libc::fcntl(fd, libc::F_GETFL, 0);
                    libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
                    let fdflags = libc::fcntl(fd, libc::F_GETFD, 0);
                    libc::fcntl(fd, libc::F_SETFD, fdflags | libc::FD_CLOEXEC);
                }
            }
            Some((fds[0], fds[1]))
        } else {
            // No fd is a supported degraded mode: gi_wakeup_fd() returns -1 and
            // the caller falls back to gi_wait_ms()/its own cap.
            None
        };
        Self { armed: AtomicBool::new(false), fds }
    }

    #[cfg(windows)]
    pub fn new() -> Self {
        use windows_sys::Win32::System::Threading::CreateEventW;
        // SAFETY: null attributes, manual reset, initially unsignalled, no name.
        let h = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
        let event = if h.is_null() { None } else { Some(h as isize) };
        Self { armed: AtomicBool::new(false), event }
    }

    /// Called from runtime threads. Must never block and must be cheap when the
    /// signal is already armed.
    pub fn signal(&self) {
        if self.armed.swap(true, Ordering::SeqCst) {
            return;
        }
        #[cfg(unix)]
        if let Some((_, w)) = self.fds {
            let byte = 1u8;
            // SAFETY: w is a valid non-blocking pipe write end; a full pipe
            // returns EAGAIN, which is fine — the signal is already pending.
            unsafe {
                libc::write(w, std::ptr::addr_of!(byte).cast(), 1);
            }
        }
        #[cfg(windows)]
        if let Some(h) = self.event {
            use windows_sys::Win32::System::Threading::SetEvent;
            // SAFETY: h is a valid event handle owned by self.
            unsafe {
                SetEvent(h as _);
            }
        }
    }

    /// Called once per caller pass, from the caller's single thread.
    pub fn drain(&self) {
        self.armed.store(false, Ordering::SeqCst);
        #[cfg(unix)]
        if let Some((r, _)) = self.fds {
            let mut buf = [0u8; 64];
            loop {
                // SAFETY: r is a valid non-blocking fd, buf is ours.
                let n = unsafe { libc::read(r, buf.as_mut_ptr().cast(), buf.len()) };
                if n <= 0 {
                    break;
                }
            }
        }
        #[cfg(windows)]
        if let Some(h) = self.event {
            use windows_sys::Win32::System::Threading::ResetEvent;
            // SAFETY: h is a valid event handle owned by self.
            unsafe {
                ResetEvent(h as _);
            }
        }
    }

    pub fn armed(&self) -> bool {
        self.armed.load(Ordering::SeqCst)
    }

    #[cfg(unix)]
    pub fn raw_fd(&self) -> i32 {
        self.fds.map(|(r, _)| r).unwrap_or(-1)
    }

    #[cfg(not(unix))]
    pub fn raw_fd(&self) -> i32 {
        -1
    }

    #[cfg(windows)]
    pub fn raw_handle(&self) -> *mut std::ffi::c_void {
        self.event.map(|h| h as *mut std::ffi::c_void).unwrap_or(std::ptr::null_mut())
    }

    #[cfg(not(windows))]
    pub fn raw_handle(&self) -> *mut std::ffi::c_void {
        std::ptr::null_mut()
    }
}

impl Drop for Wakeup {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some((r, w)) = self.fds.take() {
            // SAFETY: both fds are owned by self and not used after this.
            unsafe {
                libc::close(r);
                libc::close(w);
            }
        }
        #[cfg(windows)]
        if let Some(h) = self.event.take() {
            use windows_sys::Win32::Foundation::CloseHandle;
            // SAFETY: h is owned by self and not used after this.
            unsafe {
                CloseHandle(h as _);
            }
        }
    }
}
