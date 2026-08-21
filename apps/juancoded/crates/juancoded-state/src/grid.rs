//! One resize authority per session.
//!
//! A session's pty is a single shared grid and several clients may view it at once —
//! the desktop pane, a phone, a screen viewer — each at its own size. Without
//! arbitration every attach and every resize wrote the grid last-write-wins, and two
//! differently-sized viewers made the CLI's TUI flap between their sizes, which is
//! the garble in juancode-1th and juancode-8llo.
//!
//! So: the first client to set the grid owns it until it disconnects, and a
//! non-owner's request is denied rather than queued. `desired` is remembered
//! separately from the pty's own size, because a resize can land before the CLI has
//! installed its SIGWINCH handler and has to be re-asserted once the TUI is up.

/// A connection's identity for arbitration purposes.
pub type ClientId = u64;

/// The one place a session's cols/rows live.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GridState {
    pub cols: u16,
    pub rows: u16,
    owner: Option<ClientId>,
    /// Whether `desired` still needs re-asserting at the pty (it was set while the
    /// pty was absent, or the write did not take).
    reapply: bool,
}

/// What a resize did. Three outcomes a client must handle differently: applied (it
/// reached the pty), denied (someone else owns the grid, so retrying is futile), and
/// neither (nothing to resize yet, so re-assert later).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResizeOutcome {
    pub applied: bool,
    pub denied: bool,
}

impl ResizeOutcome {
    pub const APPLIED: Self = Self {
        applied: true,
        denied: false,
    };
    pub const DENIED: Self = Self {
        applied: false,
        denied: true,
    };
    /// Nothing to resize: no session, or no live pty behind it.
    pub const NOTHING: Self = Self {
        applied: false,
        denied: false,
    };
}

impl GridState {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self {
            cols,
            rows,
            owner: None,
            reapply: false,
        }
    }

    pub fn owner(&self) -> Option<ClientId> {
        self.owner
    }

    pub fn needs_reapply(&self) -> bool {
        self.reapply
    }

    /// Whether `client` may drive the grid. Claims it when free or already theirs.
    pub fn request(&mut self, client: ClientId) -> bool {
        match self.owner {
            None => {
                self.owner = Some(client);
                true
            }
            Some(current) => current == client,
        }
    }

    /// Record the geometry the owner asked for. `applied` says whether it reached a
    /// live pty; when it did not, the grid stays marked for re-assertion.
    pub fn set(&mut self, cols: u16, rows: u16, applied: bool) {
        if cols > 0 && rows > 0 {
            self.cols = cols;
            self.rows = rows;
        }
        self.reapply = !applied;
    }

    /// The re-assert landed (or was no longer needed).
    pub fn settled(&mut self) {
        self.reapply = false;
    }

    /// Give up ownership held by `client`, so the next client's request can claim it.
    /// Returns whether anything was actually released.
    pub fn release(&mut self, client: ClientId) -> bool {
        if self.owner == Some(client) {
            self.owner = None;
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_client_claims_the_grid_and_the_second_is_denied() {
        let mut grid = GridState::new(80, 24);
        assert!(grid.request(1));
        assert!(grid.request(1), "the owner may keep driving");
        assert!(!grid.request(2));
        assert_eq!(grid.owner(), Some(1));
    }

    #[test]
    fn releasing_lets_the_next_client_take_over() {
        let mut grid = GridState::new(80, 24);
        assert!(grid.request(1));
        assert!(!grid.release(2), "a non-owner cannot release");
        assert!(grid.release(1));
        assert!(grid.request(2));
        assert_eq!(grid.owner(), Some(2));
    }

    #[test]
    fn a_resize_that_never_reached_a_pty_stays_marked_for_reassertion() {
        let mut grid = GridState::new(80, 24);
        grid.set(100, 30, false);
        assert_eq!((grid.cols, grid.rows), (100, 30));
        assert!(grid.needs_reapply());
        grid.settled();
        assert!(!grid.needs_reapply());
        grid.set(110, 32, true);
        assert!(!grid.needs_reapply());
    }

    #[test]
    fn a_zero_dimension_is_ignored_rather_than_stored() {
        let mut grid = GridState::new(80, 24);
        grid.set(0, 0, true);
        assert_eq!((grid.cols, grid.rows), (80, 24));
    }
}
