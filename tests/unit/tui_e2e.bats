#!/usr/bin/env bats
# Сквозные сценарии TUI: настоящий entrypoint без аргументов в installed-layout,
# ввод через stdin, заглушки ssh/scp/ssh-keyscan/curl/gh, временный HOME.
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env

    export APP="$BATS_TEST_TMPDIR/app"
    export HOME="$BATS_TEST_TMPDIR/home"
    export BIN="$BATS_TEST_TMPDIR/bin"
    export REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common" "$BIN" "$HOME"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$PROJECT_ROOT/VERSION" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/remote-control/tui" "$APP/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"
    local tool
    for tool in curl ssh scp ssh-keyscan; do
        printf '#!/bin/bash\nexit 1\n' > "$BIN/$tool"
        chmod +x "$BIN/$tool"
    done
    # gh: глобальный вход test-owner, токен для изолированного профиля,
    # репозиторий «не найден», пока его не создаст repo create.
    export GH_REPO_STATE_FILE="$BATS_TEST_TMPDIR/repo-created"
    cat > "$BIN/gh" <<'EOF'
#!/bin/bash
profile="${GH_CONFIG_DIR:-}"
case "$1 $2" in
    "auth token") printf 'ghp_FixtureToken_test-owner\n' ;;
    "auth login")
        IFS= read -r token || exit 1
        mkdir -p "$profile" && printf 'user: test-owner\noauth_token: %s\n' "$token" > "$profile/hosts.yml"
        ;;
    "auth git-credential")
        printf 'username=test-owner\npassword=ghp_FixtureToken_test-owner\n'
        ;;
    "api user") printf 'test-owner\n' ;;
    "repo view")
        [[ -f "$GH_REPO_STATE_FILE" ]] || { printf 'repository not found\n' >&2; exit 1; }
        printf '{"visibility":"PRIVATE"}\n'
        ;;
    "repo create") touch "$GH_REPO_STATE_FILE"; printf '{"visibility":"PRIVATE"}\n' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$BIN/gh"
    export PATH="$BIN:$PATH"
    export RC_DIR="$HOME/.config/remote-control-essence"
    unset RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD
    unset CONFIG_DIR CONFIG_JSON TEMPLATES_DIR GENERATED_DIR SCRIPT_DIR

    git init --bare -b main "$REMOTE" >/dev/null
    git config --global user.name test
    git config --global user.email test@example.invalid
    git config --global url."file://$REMOTE".insteadOf \
        "https://github.com/test-owner/essence-remote-control-config.git"
}

teardown() {
    pkill -f "$APP/remote-control-essence.sh serve" 2>/dev/null || true
    teardown_test_env
}

# tui INPUT — TUI без аргументов, ввод — строка INPUT.
tui() {
    run bash -c 'printf "%b" "$1" | "$0"' "$APP/remote-control-essence.sh" "$1"
    output=$(printf '%s' "$output" | sed -E 's/\x1b\[[0-9;]*m//g')
}

# После каждого сценария: процесса serve этого приложения и блокировки нет.
assert_clean_exit() {
    ! pgrep -f "$APP/remote-control-essence.sh serve" >/dev/null || { echo "serve остался"; return 1; }
    [ ! -e "$RC_DIR/.rc-lock" ] || { echo ".rc-lock остался"; return 1; }
}

@test "first run: local configuration, a new group from the dashboard, clean exit" {
    tui '1\ng\na\nLAB\n0\n0\n'
    assert_success
    assert_output --partial 'Первый запуск'
    assert_output --partial 'Remote Control v'
    jq -e 'any(.groups[]; .name == "LAB")' "$RC_DIR/config.json"
    assert_clean_exit
}

@test "first run: choosing Выход exits with 0, creates no configuration and leaves no serve" {
    tui '0\n'
    assert_success
    assert_output --partial 'Первый запуск'
    [ ! -e "$RC_DIR/config.json" ]
    assert_clean_exit
}

@test "script password: three wrong passwords open the recovery menu, 0 exits with 1" {
    "$APP/remote-control-essence.sh" source init-local < /dev/null >/dev/null 2>&1
    run bash -c 'printf "%s" "{\"password\":\"right-pass\"}" | "$0" self password-set --secrets-stdin' \
        "$APP/remote-control-essence.sh"
    assert_success
    tui 'wrong-1\nwrong-2\nwrong-3\n0\n'
    [ "$status" -eq 1 ]
    assert_output --partial 'Неверный пароль запуска.'
    assert_output --partial 'Восстановление доступа'
    [[ "$output" != *'Remote Control v'* ]]
    [[ "$output" != *wrong-1* ]]
    assert_clean_exit
}

@test "GitHub plaintext first run creates the repository and reopens without questions" {
    # Аккаунт 1, создать репозиторий, хранение без шифрования, согласие на план.
    tui '2\n1\ny\n2\ny\n0\n'
    assert_success
    jq -e 'type == "object" and .type == "github" and .private_verified == true' "$RC_DIR/source.json"
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    git --git-dir="$REMOTE" show main:config.json | jq -e '.schema_version == 2' >/dev/null
    assert_output --partial 'Источник: GitHub test-owner/essence-remote-control-config'
    assert_clean_exit

    tui '0\n'
    assert_success
    assert_output --partial 'Remote Control v'
    [[ "$output" != *'Первый запуск'* && "$output" != *'Аккаунт GitHub'* ]]
    assert_clean_exit
}

# Consumer-level PTY regressions. Python is a test driver, not a product dependency.
_pty_regression() {
    command -v python3 >/dev/null 2>&1 || skip "python3 нужен для PTY regression"
    "$APP/remote-control-essence.sh" source init-local --json </dev/null >/dev/null 2>&1
    run python3 - "$APP" "$RC_DIR" "$BATS_TEST_TMPDIR" "$1" <<'PY'
import os, sys, pathlib, json, pty, select, time, termios, fcntl, struct, re, shutil
app, rc, base = map(pathlib.Path, sys.argv[1:4])
scenario = sys.argv[4]
if scenario == "nano" and not shutil.which("nano"):
    sys.exit(77)
tmp = base / "pty-tmp"
tmp.mkdir()
config = rc / "config.json"
data = json.loads(config.read_text())
data["nodes"] = [{"id":"11111111111111111111111111111111", "name":"node",
    "ip":"192.0.2.1", "port":22, "user":"root", "auth":"key", "identity":"system",
    "secret_id":None, "tag":"t", "aliases":{}}]
config.write_text(json.dumps(data))
editor = base / "editor"
editor.write_text("""#!/bin/bash
trap 'exit 130' INT
stty -echo -icanon min 1 time 0
printf 'EDITOR_READY %s\\n' "$1"
IFS= read -r -n 1 key
case "$PTY_SCENARIO" in
    editor-fail) exit 7 ;;
    *) printf '# edited\\n' >> "$1" ;;
esac
""")
editor.chmod(0o755)
ssh = pathlib.Path(os.environ["BIN"]) / "ssh"
ssh.write_text("""#!/bin/bash
case " $* " in
    *" -t "*)
        stty -echo -icanon -isig min 1 time 0
        echo SHELL_READY
        key=$(dd bs=1 count=1 2>/dev/null)
        if [[ "$key" == $'\\003' ]]; then
            echo SHELL_CTRL_C
            key=$(dd bs=1 count=1 2>/dev/null)
        fi
        echo SHELL_FINISHED
        [[ "$PTY_SCENARIO" != shell-fail ]]
        ;;
    *"echo ok"*)
        if [[ "$PTY_SCENARIO" == slow-* ]]; then
            touch "$PTY_BASE/started"
            sleep 2
            touch "$PTY_BASE/completed"
        fi
        echo ok
        ;;
    *"printf 'MISSING'"*) printf 'PRESENT\\n%s\\n' "$(cat "$PTY_APP/VERSION")" ;;
    *) exit 0 ;;
esac
""")
ssh.chmod(0o755)
env = dict(os.environ, TMPDIR=str(tmp), TERM="xterm-256color", LC_ALL="C.UTF-8",
    EDITOR="nano" if scenario == "nano" else str(editor), PTY_SCENARIO=scenario,
    PTY_BASE=str(base), PTY_APP=str(app))
env.pop("VISUAL", None)
if scenario == "slow-timeout":
    env["SSH_RUN_TIMEOUT"] = "1"
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/bash", ["/bin/bash", "-c",
        'umask 002; before=$(stty -g); "$1"; code=$?; after=$(stty -g); '
        'printf "\\nPTY_EXIT=%s\\n" "$code"; '
        '[[ "$before" == "$after" ]] && echo TTY_RESTORED || echo TTY_DIRTY; exit "$code"',
        "_", str(app / "remote-control-essence.sh")], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 80, 0, 0))
raw = b""
cursor = 0
def wait_for(text, timeout=12):
    global raw, cursor
    target = text.encode()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pos = raw.find(target, cursor)
        if pos >= 0:
            cursor = pos + len(target)
            return
        if select.select([fd], [], [], .1)[0]:
            try:
                part = os.read(fd, 65536)
            except OSError:
                break
            if not part:
                break
            raw += part
    raise AssertionError("Missing " + text + "\n" + raw.decode(errors="replace"))
def send(text):
    os.write(fd, text.encode())
def menu(key):
    send(key + "\r")
    wait_for("Выберите действие:")
try:
    wait_for("Выберите действие:")
    if scenario.startswith("editor-") or scenario == "nano":
        menu("m")
        menu("1")
        send("e\r")
        if scenario == "nano":
            wait_for("edit.yaml")
            send("\x18")
        else:
            wait_for("EDITOR_READY ")
            deadline = time.monotonic() + 2
            paths = []
            while not paths and time.monotonic() < deadline:
                paths = list(tmp.glob("*/rc-template.*/edit.yaml"))
            assert len(paths) == 1, paths
            edit = paths[0]
            assert edit.stat().st_mode & 0o777 == 0o600
            assert (edit.parent / "orig.yaml").stat().st_mode & 0o777 == 0o600
            assert edit.parent.stat().st_mode & 0o777 == 0o700
            send("\x03" if scenario == "editor-int" else "x")
        if scenario != "editor-int":
            wait_for("Выберите действие:")
            if scenario == "editor-fail":
                assert "Редактор завершился с ошибкой.".encode() in raw
                assert not (rc / "templates/default.yaml").exists()
            elif scenario == "editor-ok":
                assert (rc / "templates/default.yaml").read_bytes().endswith(b"# edited\n")
            menu("0")
            menu("0")
            send("0\r")
    else:
        menu("n")
        menu("1")
        if scenario.startswith("shell-"):
            send("o\r")
            wait_for("SHELL_READY")
            if scenario == "shell-int":
                send("\x03")
                wait_for("SHELL_CTRL_C")
            send("x")
            wait_for("SHELL_FINISHED")
            wait_for("Выберите действие:")
        else:
            send("k\r")
            deadline = time.monotonic() + 8
            while not (base / "started").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            assert (base / "started").exists()
            if scenario == "slow-int":
                send("\x03")
            wait_for("Выберите действие:")
            if scenario == "slow-timeout":
                assert not (base / "completed").exists()
                assert "Не удалось подключиться".encode() in raw
            else:
                assert (base / "completed").exists(), "Child interrupted before completion"
                assert "Соединение установлено".encode() in raw
        menu("0")
        menu("0")
        send("0\r")
    expected = 130 if scenario == "editor-int" else 0
    wait_for("PTY_EXIT=" + str(expected))
    wait_for("TTY_RESTORED")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == expected, status
    assert not list(tmp.iterdir()), list(tmp.iterdir())
    print(scenario + ": completed, tty restored, temporary files removed")
finally:
    if pid is not None:
        try:
            os.killpg(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    os.close(fd)
PY
    [ "$status" -ne 77 ] || skip "nano не установлен"
    assert_success
    assert_clean_exit
}

@test "PTY editor: INT restores tty and removes private files under umask 002" {
    _pty_regression editor-int
}

@test "PTY editor: normal edited import restores tty and removes private files" {
    _pty_regression editor-ok
}

@test "PTY editor: failure restores tty and removes private files" {
    _pty_regression editor-fail
}

@test "PTY editor: real nano exits normally without holding serve descriptors" {
    _pty_regression nano
}

@test "PTY shell: normal dirty tty is restored" {
    _pty_regression shell-ok
}

@test "PTY shell: failed dirty tty is restored and the card survives" {
    _pty_regression shell-fail
}

@test "PTY shell: remote Ctrl+C remains interactive and returns to the card" {
    _pty_regression shell-int
}

@test "PTY command: slow control completes through the real timeout executable" {
    _pty_regression slow-control
}

@test "PTY command: terminal Ctrl+C does not interrupt timeout or its child" {
    _pty_regression slow-int
}

@test "PTY command: deadline still stops a hanging child and reports failure" {
    _pty_regression slow-timeout
}
