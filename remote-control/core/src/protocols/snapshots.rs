//! Snapshots of the v1 Bash protocol builders and parsers: every case of the
//! former golden JSON files captured from the Bash sources (inputs,
//! stdout bytes, rc and, for the URI parsers, stderr), replayed against the
//! Rust port. The Bash sources are gone; these cases pin the byte format.

use super::hy2::{self, Hy2, Hy2Listener};
use super::uri::{self, ExitProxy, UriError};
use super::vless_xhttp::{self, NginxListener};
use super::{Vless, VlessListener, listener_users, vless_grpc, vless_tcp};

mod hy2_cases;
mod listener_users_cases;
mod uri_cases;
mod vless_grpc_cases;
mod vless_tcp_cases;
mod vless_xhttp_cases;

/// One captured call: the v1 function (and its wrapper), arguments, stdin,
/// the listener-users config file and the expected outputs.
struct Case {
    function: &'static str,
    invoke: &'static str,
    name: &'static str,
    args: &'static [&'static str],
    stdin: &'static str,
    config_yaml: Option<&'static str>,
    stdout: &'static [u8],
    stderr: &'static [u8],
    rc: i64,
}

impl Case {
    fn arg(&self, index: usize) -> &'static str {
        self.args.get(index).copied().unwrap_or("")
    }
}

struct Outcome {
    stdout: Vec<u8>,
    rc: i64,
    /// Compared only when the port produces the same diagnostics.
    stderr: Option<Vec<u8>>,
}

fn ok(text: String) -> Outcome {
    Outcome { stdout: text.into_bytes(), rc: 0, stderr: None }
}

/// v1 `info`/`warn` lines (common.sh colours).
fn info(text: &str) -> String {
    format!("  \x1b[0;36m[*]\x1b[0m {text}\n")
}

fn warn(text: &str) -> String {
    format!("  \x1b[1;33m[!]\x1b[0m {text}\n")
}

/// Parsers print an empty line and their notes on stderr. An unknown scheme
/// is warned on stderr; other errors are warned on stdout, an unknown
/// transport after its note, percent-coding errors before anything else.
fn parsed(result: Result<ExitProxy, UriError>, stderr_prefix: &str) -> Outcome {
    match result {
        Ok(exit) => {
            let notes: String = exit.notes.iter().map(|note| info(note)).collect();
            Outcome { stdout: exit.yaml.into_bytes(), rc: 0, stderr: Some(format!("{stderr_prefix}\n{notes}").into_bytes()) }
        }
        Err(error) => {
            let message = warn(&error.to_string());
            let (stdout, stderr) = match &error {
                UriError::UnknownScheme => (String::new(), format!("{stderr_prefix}{message}")),
                UriError::UnknownTransport { note, .. } => (message, format!("{stderr_prefix}\n{}", info(note))),
                _ => (message, stderr_prefix.to_owned()),
            };
            Outcome { stdout: stdout.into_bytes(), rc: 1, stderr: Some(stderr.into_bytes()) }
        }
    }
}

/// `Vless` from argument positions `[name, server, port, uuid, sni, public_key, short_id]`.
fn vless(case: &Case, fields: [usize; 7]) -> Vless<'static> {
    let [name, server, port, uuid, sni, public_key, short_id] = fields.map(|i| case.arg(i));
    Vless { name, server, port, uuid, sni, public_key, short_id }
}

/// `name listen port username uuid <extra> dest private_key short_id sni proxy`
/// (`extra` = service/path; absent for TCP).
fn listener(case: &Case, extra: bool) -> VlessListener<'static> {
    let o = usize::from(extra);
    VlessListener {
        name: case.arg(0), listen: case.arg(1), port: case.arg(2), username: case.arg(3), uuid: case.arg(4),
        dest: case.arg(5 + o), private_key: case.arg(6 + o), short_id: case.arg(7 + o), sni: case.arg(8 + o),
        proxy: case.arg(9 + o),
    }
}

/// `name server port pass [sni skip_verify obfs]`; empty skip → `true`.
fn hy2_endpoint(case: &Case) -> Hy2<'static> {
    let skip_cert_verify = match case.arg(5) {
        "" | "true" => true,
        "false" => false,
        other => panic!("{}: unexpected skip_verify {other:?}", case.name),
    };
    Hy2 {
        name: case.arg(0), server: case.arg(1), port: case.arg(2), password: case.arg(3), sni: case.arg(4),
        skip_cert_verify, obfs_password: case.arg(6),
    }
}

fn replay(case: &Case) -> Outcome {
    let a = |i| case.arg(i);
    match (case.function, case.invoke) {
        ("_uri_percent_encode", _) => ok(uri::percent_encode(a(0))),
        ("_uri_percent_decode", _) => match uri::percent_decode(a(0)) {
            Some(bytes) => Outcome { stdout: bytes, rc: 0, stderr: None },
            None => Outcome { stdout: Vec::new(), rc: 1, stderr: None },
        },
        ("_parse_server_port_from_uri", "w_server_port") => {
            let parsed = uri::server_port(a(0));
            ok(format!("server={}\nport={}\n", parsed.server, parsed.port))
        }
        ("_parse_vless_uri_to_exit", _) => parsed(uri::parse_vless_uri(a(0), a(1)), ""),
        ("_parse_hy2_uri_to_exit", _) => parsed(uri::parse_hy2_uri(a(0), a(1)), ""),
        ("_parse_proxy_uri", _) => parsed(uri::parse_proxy_uri(a(0), case.stdin), "\n"),

        ("_build_hy2_listener_yaml", _) => ok(hy2::listener_yaml(&Hy2Listener {
            name: a(0), port: a(1), user: a(2), password: a(3), proxy: a(4), obfs_password: a(5),
            certificate: "", private_key: "",
        })),
        ("_build_hy2_client_yaml", _) => ok(hy2::client_yaml(&hy2_endpoint(case))),
        ("_build_hy2_exit_yaml", _) => ok(hy2::exit_yaml(&hy2_endpoint(case))),
        ("_build_hy2_uri", _) => ok(hy2::uri(&Hy2 {
            name: "", server: a(1), port: a(2), password: a(0), sni: a(3), skip_cert_verify: true, obfs_password: a(4),
        })),

        ("_build_vless_tcp_listener_yaml", _) => ok(vless_tcp::listener_yaml(&listener(case, false))),
        ("_build_vless_tcp_client_yaml", _) => ok(vless_tcp::client_yaml(&vless(case, [0, 1, 2, 3, 4, 5, 6]))),
        ("_build_vless_tcp_uri", _) => ok(vless_tcp::uri(&vless(case, [6, 1, 2, 0, 3, 4, 5]))),
        ("_build_vless_tcp_exit_yaml", _) => ok(vless_tcp::exit_yaml(
            &vless(case, [0, 1, 2, 3, 4, 5, 6]),
            case.args.get(7).copied().unwrap_or(vless_tcp::FLOW),
            a(8),
        )),

        ("_build_vless_grpc_listener_yaml", _) => ok(vless_grpc::listener_yaml(&listener(case, true), a(5))),
        ("_build_vless_grpc_client_yaml", _) => ok(vless_grpc::client_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5))),
        ("_build_vless_grpc_uri", _) => ok(vless_grpc::uri(&vless(case, [7, 1, 2, 0, 3, 5, 6]), a(4))),
        ("_build_vless_grpc_exit_yaml", _) => ok(vless_grpc::exit_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5), a(8))),

        ("_build_vless_xhttp_listener_yaml", _) => ok(vless_xhttp::listener_yaml(&listener(case, true), a(5))),
        ("_build_vless_xhttp_nginx_listener_yaml", _) => ok(vless_xhttp::nginx_listener_yaml(&NginxListener {
            name: a(0), listen: a(1), port: a(2), username: a(3), uuid: a(4), path: a(5), proxy: a(6),
        })),
        // Legacy alias: certificate/key ($7/$8) ignored, proxy is $9.
        ("_build_vless_xhttp_tls_listener_yaml", _) => ok(vless_xhttp::nginx_listener_yaml(&NginxListener {
            name: a(0), listen: a(1), port: a(2), username: a(3), uuid: a(4), path: a(5), proxy: a(8),
        })),
        ("_build_vless_xhttp_client_yaml", _) => ok(vless_xhttp::client_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5))),
        ("_build_vless_xhttp_uri", _) => ok(vless_xhttp::uri(&vless(case, [7, 1, 2, 0, 3, 5, 6]), a(4))),
        ("_build_vless_xhttp_exit_yaml", _) => ok(vless_xhttp::exit_yaml(&vless(case, [0, 1, 2, 3, 4, 7, 8]), a(5), a(6))),
        ("_normalize_vless_xhttp_proxy_yaml", _) => ok(vless_xhttp::normalize_proxy_yaml(case.stdin)),

        ("_build_vless_users_yaml", _) => ok(listener_users::vless_users_yaml(a(0), listener_users::parse_user_lines(case.stdin))),
        ("_build_hy2_users_yaml", _) => ok(listener_users::hy2_users_yaml(listener_users::parse_user_lines(case.stdin))),
        ("_sync_listener_users", "w_sync") => match case.config_yaml {
            None => Outcome { stdout: Vec::new(), rc: 1, stderr: None },
            Some(config) => match listener_users::sync(config, a(0), a(1)) {
                Some(updated) => ok(updated),
                None => Outcome { stdout: config.as_bytes().to_vec(), rc: 1, stderr: None },
            },
        },

        (function, invoke) => panic!("{}: no Rust mapping for {function} via {invoke}", case.name),
    }
}

fn check(module: &str, cases: &[Case]) {
    assert!(!cases.is_empty());
    let mut failures = Vec::new();
    for case in cases {
        let outcome = replay(case);
        if outcome.stdout != case.stdout || outcome.rc != case.rc {
            failures.push(format!("{module}/{}: rc {} (want {})\n  got:  {:?}\n  want: {:?}", case.name, outcome.rc, case.rc,
                String::from_utf8_lossy(&outcome.stdout), String::from_utf8_lossy(case.stdout)));
        } else if let Some(stderr) = outcome.stderr.filter(|stderr| stderr != case.stderr) {
            failures.push(format!("{module}/{}: stderr\n  got:  {:?}\n  want: {:?}", case.name,
                String::from_utf8_lossy(&stderr), String::from_utf8_lossy(case.stderr)));
        }
    }
    assert!(failures.is_empty(), "{} of {} snapshot cases differ:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

#[test]
fn uri() { check("uri", uri_cases::CASES) }

#[test]
fn hy2() { check("hy2", hy2_cases::CASES) }

#[test]
fn vless_tcp() { check("vless-tcp", vless_tcp_cases::CASES) }

#[test]
fn vless_grpc() { check("vless-grpc", vless_grpc_cases::CASES) }

#[test]
fn vless_xhttp() { check("vless-xhttp", vless_xhttp_cases::CASES) }

#[test]
fn listener_users() { check("listener-users", listener_users_cases::CASES) }
