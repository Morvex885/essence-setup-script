//! Network admission (П4): one-time codes, resume tokens, steps 1–3 of a
//! network `session open`, the throttle of failed attempts and the limits
//! of not yet authorized connections.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use rand::RngCore;
use rand::rngs::OsRng;
use rc_core::error::{RcError, Result};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

/// Lifetime of a one-time code (`web link`).
pub const TICKET_TTL: Duration = Duration::from_secs(300);
/// A resume token unused this long expires.
pub const RESUME_IDLE: Duration = Duration::from_secs(12 * 3600);
/// Resume tokens kept at once; the least recently used one goes first.
pub const MAX_RESUME: usize = 64;
/// Longest pause before a network `session open`.
const MAX_THROTTLE: Duration = Duration::from_secs(30);

/// Before authorization: the longest message, requests in flight,
/// unauthorized connections at once and their lifetime.
pub const PREAUTH_MESSAGE: usize = 64 << 10;
pub const PREAUTH_IN_FLIGHT: usize = 4;
pub const MAX_UNAUTHORIZED: usize = 32;
pub const PREAUTH_TIMEOUT: Duration = Duration::from_secs(60);
/// After authorization: requests in flight per network connection.
pub const IN_FLIGHT: usize = 32;

/// Tokens are looked up by their SHA-256: the secret itself is neither kept
/// nor compared byte by byte.
type Digest32 = [u8; 32];

fn digest(token: &str) -> Digest32 {
    Sha256::digest(token.as_bytes()).into()
}

/// 32 bytes from the OS generator, hex.
fn new_token() -> (Zeroizing<String>, Digest32) {
    let mut bytes = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(&mut bytes[..]);
    let token = Zeroizing::new(hex::encode(&bytes[..]));
    let digest = digest(&token);
    (token, digest)
}

/// What an `access-token` turned out to be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token {
    Absent,
    Resume,
    Ticket,
    /// Given, but neither a live resume token nor a live code.
    Invalid,
}

/// One-time codes (issue time) and resume tokens (last use), in memory only.
#[derive(Default)]
pub struct Tokens {
    tickets: HashMap<Digest32, Instant>,
    resume: HashMap<Digest32, Instant>,
}

impl Tokens {
    pub fn issue_ticket(&mut self, now: Instant) -> Zeroizing<String> {
        self.expire(now);
        let (token, digest) = new_token();
        self.tickets.insert(digest, now);
        token
    }

    pub fn issue_resume(&mut self, now: Instant) -> Zeroizing<String> {
        self.expire(now);
        while self.resume.len() >= MAX_RESUME {
            let Some(oldest) = self.resume.iter().min_by_key(|(_, used)| **used).map(|(digest, _)| *digest) else { break };
            self.resume.remove(&oldest);
        }
        let (token, digest) = new_token();
        self.resume.insert(digest, now);
        token
    }

    /// Classifies a token: a resume token is refreshed, a code is spent.
    pub fn check(&mut self, token: &str, now: Instant) -> Token {
        self.expire(now);
        let digest = digest(token);
        if let Some(used) = self.resume.get_mut(&digest) {
            *used = now;
            return Token::Resume;
        }
        if self.tickets.remove(&digest).is_some() {
            return Token::Ticket;
        }
        Token::Invalid
    }

    /// The password changed (or every authorization was reset).
    pub fn clear(&mut self) {
        self.tickets.clear();
        self.resume.clear();
    }

    fn expire(&mut self, now: Instant) {
        self.tickets.retain(|_, issued| now.saturating_duration_since(*issued) < TICKET_TTL);
        self.resume.retain(|_, used| now.saturating_duration_since(*used) < RESUME_IDLE);
    }
}

/// Inputs of steps 1–3 besides the password check itself.
#[derive(Clone, Copy, Debug)]
pub struct Gate {
    pub network: bool,
    pub token: Token,
    pub password_set: bool,
    /// The listener the connection came through is loopback-only.
    pub loopback: bool,
}

pub fn invalid_access_token() -> RcError {
    RcError::new("auth_failed", "Неверный или просроченный код доступа.").with_extra("secret", "access-token")
}

pub fn access_token_required() -> RcError {
    RcError::new("auth_required", "Требуется код доступа: essence-rc web link.").with_extra("secret", "access-token")
}

/// Steps 1–3 of `session open`; `Ok(resumed)`. The script password is
/// checked (step 2) unless a resume token admitted the connection; local
/// connections ignore `access-token`.
pub fn admit(gate: Gate, verify_password: impl FnOnce() -> Result<()>) -> Result<bool> {
    let token = if gate.network { gate.token } else { Token::Absent };
    // 1.
    if token == Token::Invalid {
        return Err(invalid_access_token());
    }
    let resumed = token == Token::Resume;
    // 2.
    if !resumed {
        verify_password()?;
    }
    // 3. A loopback panel without a password lets in only holders of a code.
    if gate.network && !resumed && !gate.password_set && gate.loopback && token != Token::Ticket {
        return Err(access_token_required());
    }
    Ok(resumed)
}

/// How a finished network `session open` moves the failure counter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenOutcome {
    /// `auth_failed`, `vault_password_invalid`: one more failure.
    Failed,
    /// Authorized by the password or a code: the counter restarts.
    Proven,
    Neutral,
}

pub fn outcome(code: Option<&str>, authorized: bool, resumed: bool) -> OpenOutcome {
    match code {
        Some("auth_failed" | "vault_password_invalid") => OpenOutcome::Failed,
        _ if authorized && !resumed => OpenOutcome::Proven,
        _ => OpenOutcome::Neutral,
    }
}

/// The pause before a network `session open` after `failures` failures in a row.
pub fn throttle(failures: u32) -> Duration {
    match failures.checked_sub(3) {
        None => Duration::ZERO,
        Some(step) if step >= 5 => MAX_THROTTLE,
        Some(step) => Duration::from_secs(1 << step).min(MAX_THROTTLE),
    }
}

pub fn advance(failures: u32, outcome: OpenOutcome) -> u32 {
    match outcome {
        OpenOutcome::Failed => failures.saturating_add(1),
        OpenOutcome::Proven => 0,
        OpenOutcome::Neutral => failures,
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn steps_one_to_three_decide_admission() {
        use Token::{Absent, Invalid, Resume, Ticket};
        /// (network, token, password set, password proven, loopback) → result, password checked
        type Case = ((bool, Token, bool, bool, bool), Result<bool, &'static str>, bool);
        let cases: &[Case] = &[
            // Local: the token is ignored, the password decides.
            ((false, Absent, false, true, true), Ok(false), true),
            ((false, Invalid, true, true, true), Ok(false), true),
            ((false, Resume, true, false, true), Err("auth_failed"), true),
            ((false, Absent, true, false, false), Err("auth_failed"), true),
            // Network, resume token: no password, any listener.
            ((true, Resume, true, false, true), Ok(true), false),
            ((true, Resume, false, false, false), Ok(true), false),
            // Network, a bad token fails before the password.
            ((true, Invalid, true, true, true), Err("auth_failed"), false),
            ((true, Invalid, false, true, false), Err("auth_failed"), false),
            // Network, loopback without a password: a code is required.
            ((true, Absent, false, true, true), Err("auth_required"), true),
            ((true, Ticket, false, true, true), Ok(false), true),
            // Network, a non-loopback panel without a password is open.
            ((true, Absent, false, true, false), Ok(false), true),
            // Network, password set: it is required, with or without a code.
            ((true, Absent, true, true, true), Ok(false), true),
            ((true, Absent, true, false, true), Err("auth_failed"), true),
            ((true, Ticket, true, false, true), Err("auth_failed"), true),
            ((true, Ticket, true, true, false), Ok(false), true),
        ];
        for &((network, token, password_set, proven, loopback), expected, checks) in cases {
            let checked = Cell::new(false);
            let result = admit(Gate { network, token, password_set, loopback }, || {
                checked.set(true);
                if proven { Ok(()) } else { Err(RcError::new("auth_failed", "Неверный пароль запуска.")) }
            });
            let case = (network, token, password_set, proven, loopback);
            assert_eq!(result.as_ref().map_err(|error| error.code).copied(), expected, "{case:?}");
            assert_eq!(checked.get(), checks, "password checked: {case:?}");
            if let Err(error) = result
                && error.message.contains("код доступа")
            {
                assert_eq!(error.extra["secret"], "access-token", "{case:?}");
            }
        }
    }

    #[test]
    fn codes_are_single_use_and_expire() {
        let start = Instant::now();
        let mut tokens = Tokens::default();
        let code = tokens.issue_ticket(start);
        assert_eq!(code.len(), 64);
        assert!(code.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_eq!(tokens.check(&code, start), Token::Ticket);
        assert_eq!(tokens.check(&code, start), Token::Invalid, "spent");
        let late = tokens.issue_ticket(start);
        assert_eq!(tokens.check(&late, start + TICKET_TTL), Token::Invalid, "expired");
        assert_ne!(tokens.issue_ticket(start).as_str(), tokens.issue_ticket(start).as_str());
    }

    #[test]
    fn resume_tokens_live_while_used_and_the_oldest_is_evicted() {
        let start = Instant::now();
        let mut tokens = Tokens::default();
        let resume = tokens.issue_resume(start);
        let later = start + RESUME_IDLE - Duration::from_secs(1);
        assert_eq!(tokens.check(&resume, later), Token::Resume);
        assert_eq!(tokens.check(&resume, later + RESUME_IDLE - Duration::from_secs(1)), Token::Resume, "use refreshes");
        assert_eq!(tokens.check(&resume, later + RESUME_IDLE * 3), Token::Invalid, "idle expiry");

        let mut tokens = Tokens::default();
        let first = tokens.issue_resume(start);
        let kept: Vec<_> = (1..MAX_RESUME as u64).map(|i| tokens.issue_resume(start + Duration::from_secs(i))).collect();
        let at = start + Duration::from_secs(100);
        // Using the first makes the second the oldest.
        assert_eq!(tokens.check(&first, at), Token::Resume);
        let newest = tokens.issue_resume(at);
        assert_eq!(tokens.check(&kept[0], at), Token::Invalid, "evicted");
        assert_eq!(tokens.check(&first, at), Token::Resume);
        assert_eq!(tokens.check(&newest, at), Token::Resume);
        assert_eq!(tokens.check(&kept[1], at), Token::Resume);
        tokens.clear();
        assert_eq!(tokens.check(&first, at), Token::Invalid, "cleared");
    }

    #[test]
    fn the_throttle_doubles_from_the_third_failure_up_to_thirty_seconds() {
        let delays: Vec<u64> = (0..10).map(|failures| throttle(failures).as_secs()).collect();
        assert_eq!(delays, [0, 0, 0, 1, 2, 4, 8, 16, 30, 30]);
        assert_eq!(throttle(u32::MAX), MAX_THROTTLE);
    }

    #[test]
    fn only_a_proof_resets_the_failure_counter() {
        assert_eq!(outcome(Some("auth_failed"), false, false), OpenOutcome::Failed);
        // A wrong vault password counts even though the connection is authorized.
        assert_eq!(outcome(Some("vault_password_invalid"), true, false), OpenOutcome::Failed);
        assert_eq!(outcome(None, true, false), OpenOutcome::Proven);
        assert_eq!(outcome(Some("source_failed"), true, false), OpenOutcome::Proven);
        assert_eq!(outcome(None, true, true), OpenOutcome::Neutral, "a resume token proves nothing");
        assert_eq!(outcome(Some("auth_required"), false, false), OpenOutcome::Neutral);
        assert_eq!(advance(4, OpenOutcome::Failed), 5);
        assert_eq!(advance(4, OpenOutcome::Proven), 0);
        assert_eq!(advance(4, OpenOutcome::Neutral), 4);
    }
}
