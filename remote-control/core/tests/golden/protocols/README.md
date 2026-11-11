# Protocol golden fixtures

Captured from the Bash builders and parsers in `common/` by
`tests/ci/capture_protocol_goldens.sh`. The Rust port (step 7) must reproduce
`stdout` byte-for-byte, and `rc` exactly, for each case.

## Layout

One file per source module (`uri`, `hy2`, `vless-tcp`, `vless-grpc`,
`vless-xhttp`, `iptables-dnat`, `listener-users`):

```
{"module": "...", "cases": [
  {"function", "case", "invoke", "args": [...], "globals": {...},
   "stdin_b64", "stdout_b64", "stderr_b64", "rc"}
]}
```

- `stdin_b64`: `null` when the function is called without stdin.
- `stdout_b64` / `stderr_b64`: raw bytes, base64 (CRLF and non-UTF-8 survive).
- `invoke` differs from `function` only for wrappers: `w_server_port`
  (prints `server=`/`port=` from `URI_SERVER`/`URI_PORT`), `w_sync` (stdout is
  the resulting config file), `w_apply_dnat` / `w_remove_dnat` /
  `w_persist_dnat` (stdout is the recorded command log).
- `globals` for `_sync_listener_users` holds the input config under
  `config_yaml` (`null` when the file is absent).

Cases are sorted by `(function, case)`. The file is pretty-printed with
`jq -S`.

## Regenerate

```
tests/ci/capture_protocol_goldens.sh            # writes this directory
GOLDEN_OUT=/tmp/x tests/ci/capture_protocol_goldens.sh   # alternate output
```

Requirements: bash 4+, `jq`, GNU `base64`, `sed`, a `C.UTF-8` locale.

## Determinism

Two consecutive runs produce identical output (`diff -r` clean). Sources of
variation that were removed or pinned:

- Locale: `LANG=C.UTF-8` is pinned. `${#var}` and `od` depend on it.
- `mktemp` paths in `_sync_listener_users` never reach stdout (the file is
  replaced in place).
- `iptables`, `sysctl`, `netfilter-persistent`, `sed`/`grep` on
  `/etc/sysctl.conf` are shadowed by functions that log argv, so no host state is read or written.
- The parsers split query params with `read -ra` (no globbing), so the result
  does not depend on cwd. Each case still runs in an empty temp dir.
- `_sync_listener_users` runs against a copy of `common/listener-users.sh`
  in which `/etc/mihomo/config.yaml` is replaced by a temp path. The copy is not
  written back to `common/`.

## Fixed in Bash before capture

- Bracketed IPv6 (`[2001:db8::1]:443`) parses to server `2001:db8::1` (unbracketed,
  as mihomo YAML and iptables expect). URI builders bracket IPv6 hosts.
- A trailing `\r` (CRLF input) no longer leaks into the last parsed field.
- `_parse_proxy_uri` accepts input without a trailing newline.
- `_build_vless_users_yaml` / `_build_hy2_users_yaml` keep a last line without
  a trailing newline and strip CR.
- `_normalize_vless_xhttp_proxy_yaml` handles CRLF blocks and keeps their line endings.
- A URI without a port gives an empty port (previously the host).
- An unknown VLESS transport returns 1 (previously 0).
- Query params are no longer subject to pathname globbing.
- Userinfo is split at the last `@`, so a raw `@` in a password survives.
- IPv6 DNAT remotes use `ip6tables`, `net.ipv6.conf.all.forwarding` and an
  `[addr]:port` destination (apply and remove); `netfilter-persistent` saves both.
- DNAT apply/remove reject an empty `local_port` (rc 1, no firewall calls).
- VLESS TCP/gRPC and Hysteria2 URI builders percent-encode user fields
  (uuid, password, sni, pbk, sid, serviceName, obfs-password, fragment).
- Client YAML `name:` escapes `\`, `"`, CR and LF inside the double quotes.
- `_build_vless_tcp_exit_yaml` with an explicitly empty flow omits `flow:`
  (only an unset flow defaults to `xtls-rprx-vision`).
- `_sync_listener_users` fails without touching the file when
  `# client-users-end` or the block end marker is missing.

## Not captured

- `_ask_*` interactive prompts (tty-driven).
- `_persist_dnat_rules` without `netfilter-persistent` (would call `apt`).
- Real `iptables` / `sysctl` effects.
