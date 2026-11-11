//! Replays the Bash protocol goldens (`tests/golden/protocols/*.json`, see
//! the README there) against the Rust port in `rc_core::protocols`: stdout
//! bytes and rc must match, and stderr for the URI parsers' notes and warnings.

use std::path::Path;
use std::process::Command;

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use rc_core::protocols::dnat::{Dnat, PERSIST_SCRIPT};
use rc_core::protocols::hy2::{self, Hy2, Hy2Listener};
use rc_core::protocols::uri::{self, ExitProxy, UriError};
use rc_core::protocols::vless_xhttp::{self, NginxListener};
use rc_core::protocols::{listener_users, vless_grpc, vless_tcp, Vless, VlessListener};
use serde_json::Value;

const MODULES: [&str; 7] = ["uri", "hy2", "vless-tcp", "vless-grpc", "vless-xhttp", "iptables-dnat", "listener-users"];

struct Case {
    function: String,
    name: String,
    invoke: String,
    args: Vec<String>,
    globals: Value,
    stdin: String,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    rc: i64,
}

impl Case {
    fn arg(&self, index: usize) -> &str {
        self.args.get(index).map_or("", String::as_str)
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

fn decode(value: &Value) -> Vec<u8> {
    STANDARD.decode(value.as_str().expect("base64 string")).expect("valid base64")
}

fn load(module: &str) -> Vec<Case> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/protocols").join(format!("{module}.json"));
    let file: Value = serde_json::from_slice(&std::fs::read(&path).expect("golden file")).expect("golden JSON");
    assert_eq!(file["module"], module);
    file["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .map(|case| Case {
            function: case["function"].as_str().unwrap().to_owned(),
            name: case["case"].as_str().unwrap().to_owned(),
            invoke: case["invoke"].as_str().unwrap().to_owned(),
            args: case["args"].as_array().unwrap().iter().map(|a| a.as_str().unwrap().to_owned()).collect(),
            globals: case["globals"].clone(),
            stdin: if case["stdin_b64"].is_null() {
                String::new()
            } else {
                String::from_utf8(decode(&case["stdin_b64"])).expect("UTF-8 stdin")
            },
            stdout: decode(&case["stdout_b64"]),
            stderr: decode(&case["stderr_b64"]),
            rc: case["rc"].as_i64().unwrap(),
        })
        .collect()
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

/// Runs node shell text with the capture script's stubs (argv logged as
/// `cmd [arg]...`) and returns the log, as the `w_*_dnat` wrappers do.
fn stubbed(script: &str) -> Outcome {
    let program = format!(
        r#"DNAT_LOG=$(mktemp) || exit 99
dnat_rec() {{ printf '%s' "$1"; shift; local a; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; }}
iptables() {{ dnat_rec iptables "$@" >> "$DNAT_LOG"; }}
ip6tables() {{ dnat_rec ip6tables "$@" >> "$DNAT_LOG"; }}
sysctl() {{ dnat_rec sysctl "$@" >> "$DNAT_LOG"; }}
netfilter-persistent() {{ dnat_rec netfilter-persistent "$@" >> "$DNAT_LOG"; }}
apt-get() {{ dnat_rec apt-get "$@" >> "$DNAT_LOG"; }}
grep() {{
    if [[ "$*" == *"/etc/sysctl.conf"* ]]; then
        dnat_rec grep "$@" >> "$DNAT_LOG"
        [[ "$1" == "-q" ]]
        return
    fi
    command grep "$@"
}}
sed() {{
    if [[ "$*" == *"/etc/sysctl.conf"* ]]; then dnat_rec sed "$@" >> "$DNAT_LOG"; return 0; fi
    command sed "$@"
}}
node_script() {{
{script}}}
node_script
rc=$?
cat "$DNAT_LOG"
rm -f "$DNAT_LOG"
exit "$rc"
"#
    );
    let output = Command::new("bash").arg("-c").arg(program).env("LANG", "C.UTF-8").output().expect("bash");
    Outcome { stdout: output.stdout, rc: output.status.code().unwrap_or(-1).into(), stderr: Some(output.stderr) }
}

/// `Vless` from argument positions `[name, server, port, uuid, sni, public_key, short_id]`.
fn vless(case: &Case, fields: [usize; 7]) -> Vless<'_> {
    let [name, server, port, uuid, sni, public_key, short_id] = fields.map(|i| case.arg(i));
    Vless { name, server, port, uuid, sni, public_key, short_id }
}

/// `name listen port username uuid <extra> dest private_key short_id sni proxy`
/// (`extra` = service/path; absent for TCP).
fn listener(case: &Case, extra: bool) -> VlessListener<'_> {
    let o = usize::from(extra);
    VlessListener {
        name: case.arg(0),
        listen: case.arg(1),
        port: case.arg(2),
        username: case.arg(3),
        uuid: case.arg(4),
        dest: case.arg(5 + o),
        private_key: case.arg(6 + o),
        short_id: case.arg(7 + o),
        sni: case.arg(8 + o),
        proxy: case.arg(9 + o),
    }
}

/// `name server port pass [sni skip_verify obfs]`; empty skip → `true`.
fn hy2_endpoint(case: &Case) -> Hy2<'_> {
    let skip_cert_verify = match case.arg(5) {
        "" | "true" => true,
        "false" => false,
        other => panic!("{}: unexpected skip_verify {other:?}", case.name),
    };
    Hy2 {
        name: case.arg(0),
        server: case.arg(1),
        port: case.arg(2),
        password: case.arg(3),
        sni: case.arg(4),
        skip_cert_verify,
        obfs_password: case.arg(6),
    }
}

fn replay(case: &Case) -> Outcome {
    let a = |i| case.arg(i);
    match (case.function.as_str(), case.invoke.as_str()) {
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
        ("_parse_proxy_uri", _) => parsed(uri::parse_proxy_uri(a(0), &case.stdin), "\n"),

        ("_build_hy2_listener_yaml", _) => ok(hy2::listener_yaml(&Hy2Listener {
            name: a(0),
            port: a(1),
            user: a(2),
            password: a(3),
            proxy: a(4),
            obfs_password: a(5),
        })),
        ("_build_hy2_client_yaml", _) => ok(hy2::client_yaml(&hy2_endpoint(case))),
        ("_build_hy2_exit_yaml", _) => ok(hy2::exit_yaml(&hy2_endpoint(case))),
        ("_build_hy2_uri", _) => ok(hy2::uri(&Hy2 {
            name: "",
            server: a(1),
            port: a(2),
            password: a(0),
            sni: a(3),
            skip_cert_verify: true,
            obfs_password: a(4),
        })),

        ("_build_vless_tcp_listener_yaml", _) => ok(vless_tcp::listener_yaml(&listener(case, false))),
        ("_build_vless_tcp_client_yaml", _) => ok(vless_tcp::client_yaml(&vless(case, [0, 1, 2, 3, 4, 5, 6]))),
        ("_build_vless_tcp_uri", _) => ok(vless_tcp::uri(&vless(case, [6, 1, 2, 0, 3, 4, 5]))),
        ("_build_vless_tcp_exit_yaml", _) => ok(vless_tcp::exit_yaml(
            &vless(case, [0, 1, 2, 3, 4, 5, 6]),
            case.args.get(7).map_or(vless_tcp::FLOW, String::as_str),
            a(8),
        )),

        ("_build_vless_grpc_listener_yaml", _) => ok(vless_grpc::listener_yaml(&listener(case, true), a(5))),
        ("_build_vless_grpc_client_yaml", _) => ok(vless_grpc::client_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5))),
        ("_build_vless_grpc_uri", _) => ok(vless_grpc::uri(&vless(case, [7, 1, 2, 0, 3, 5, 6]), a(4))),
        ("_build_vless_grpc_exit_yaml", _) => ok(vless_grpc::exit_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5), a(8))),

        ("_build_vless_xhttp_listener_yaml", _) => ok(vless_xhttp::listener_yaml(&listener(case, true), a(5))),
        ("_build_vless_xhttp_nginx_listener_yaml", _) => ok(vless_xhttp::nginx_listener_yaml(&NginxListener {
            name: a(0),
            listen: a(1),
            port: a(2),
            username: a(3),
            uuid: a(4),
            path: a(5),
            proxy: a(6),
        })),
        // Legacy alias: certificate/key ($7/$8) ignored, proxy is $9.
        ("_build_vless_xhttp_tls_listener_yaml", _) => ok(vless_xhttp::nginx_listener_yaml(&NginxListener {
            name: a(0),
            listen: a(1),
            port: a(2),
            username: a(3),
            uuid: a(4),
            path: a(5),
            proxy: a(8),
        })),
        ("_build_vless_xhttp_client_yaml", _) => ok(vless_xhttp::client_yaml(&vless(case, [0, 1, 2, 3, 4, 6, 7]), a(5))),
        ("_build_vless_xhttp_uri", _) => ok(vless_xhttp::uri(&vless(case, [7, 1, 2, 0, 3, 5, 6]), a(4))),
        ("_build_vless_xhttp_exit_yaml", _) => ok(vless_xhttp::exit_yaml(&vless(case, [0, 1, 2, 3, 4, 7, 8]), a(5), a(6))),
        ("_normalize_vless_xhttp_proxy_yaml", _) => ok(vless_xhttp::normalize_proxy_yaml(&case.stdin)),

        ("_apply_dnat_rules", "w_apply_dnat") => dnat_script(dnat(case).apply_script()),
        ("_remove_dnat_rules", "w_remove_dnat") => dnat_script(dnat(case).remove_script()),
        ("_persist_dnat_rules", "w_persist_dnat") => stubbed(PERSIST_SCRIPT),

        ("_build_vless_users_yaml", _) => ok(listener_users::vless_users_yaml(a(0), listener_users::parse_user_lines(&case.stdin))),
        ("_build_hy2_users_yaml", _) => ok(listener_users::hy2_users_yaml(listener_users::parse_user_lines(&case.stdin))),
        ("_sync_listener_users", "w_sync") => match case.globals["config_yaml"].as_str() {
            None => Outcome { stdout: Vec::new(), rc: 1, stderr: None },
            Some(config) => match listener_users::sync(config, a(0), a(1)) {
                Some(updated) => ok(updated),
                None => Outcome { stdout: config.as_bytes().to_vec(), rc: 1, stderr: None },
            },
        },

        (function, invoke) => panic!("{}: no Rust mapping for {function} via {invoke}", case.name),
    }
}

fn dnat(case: &Case) -> Dnat<'_> {
    Dnat { name: case.arg(0), remote: case.arg(1), remote_port: case.arg(2), local_port: case.arg(3) }
}

fn dnat_script(script: Option<String>) -> Outcome {
    match script {
        Some(script) => stubbed(&script),
        None => Outcome { stdout: Vec::new(), rc: 1, stderr: Some(Vec::new()) },
    }
}

#[test]
fn rust_port_matches_bash_goldens() {
    let mut failures = Vec::new();
    let mut total = 0;
    for module in MODULES {
        // DNAT cases run the generated script under a POSIX bash; on Windows
        // `bash` is the WSL launcher. The scripts only ever run on Linux nodes.
        if cfg!(windows) && module == "iptables-dnat" { continue; }
        for case in load(module) {
            total += 1;
            let outcome = replay(&case);
            let expected = &case.stdout;
            if &outcome.stdout != expected || outcome.rc != case.rc {
                failures.push(format!(
                    "{module}/{}: rc {} (want {})\n  got:  {:?}\n  want: {:?}",
                    case.name,
                    outcome.rc,
                    case.rc,
                    String::from_utf8_lossy(&outcome.stdout),
                    String::from_utf8_lossy(&expected)
                ));
            } else if let Some(stderr) = outcome.stderr.filter(|stderr| *stderr != case.stderr) {
                failures.push(format!(
                    "{module}/{}: stderr\n  got:  {:?}\n  want: {:?}",
                    case.name,
                    String::from_utf8_lossy(&stderr),
                    String::from_utf8_lossy(&case.stderr)
                ));
            }
        }
    }
    assert!(total > 0);
    assert!(failures.is_empty(), "{} of {total} golden cases differ:\n{}", failures.len(), failures.join("\n"));
    eprintln!("{total} golden cases replayed");
}
