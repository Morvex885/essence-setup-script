use std::{collections::BTreeMap, io, sync::mpsc::{self, Receiver, Sender}, thread::{self, JoinHandle}};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use zeroize::Zeroizing;
use crate::*;

fn line(value: Value) -> Zeroizing<String> { Zeroizing::new(value.to_string()) }
fn hello(version: &str) -> Value { json!({"event":"hello","protocol":3,"version":version,"origin":"local"}) }
fn next(from_client: &Receiver<Zeroizing<String>>) -> Value { serde_json::from_str(&from_client.recv().unwrap()).unwrap() }

/// A daemon script on the other end of `from_channels`; join the handle to
/// surface its assertions.
fn fake(script: impl FnOnce(Sender<Zeroizing<String>>, Receiver<Zeroizing<String>>) + Send + 'static) -> (DaemonClient, JoinHandle<()>) {
    let (to_client, incoming) = mpsc::channel();
    let (outgoing, from_client) = mpsc::channel();
    to_client.send(line(hello("9"))).unwrap();
    let script = thread::spawn(move || script(to_client, from_client));
    (DaemonClient::from_channels(incoming, outgoing).unwrap(), script)
}

fn send(client: &mut dyn Client, words: &[&str], progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
    let words = argv(words);
    client.send(Request::new(&words, &Secrets::default(), &Input::default()), progress)
}

#[test]
fn logs_ids_secrets_input_env_and_exit() {
    let (mut client, script) = fake(|to_client, from_client| {
        assert_eq!(next(&from_client), json!({"id":1,"argv":["status"],"secrets":{"password":"p"},"input":{"file":"x"},"env":{"SSH_AUTH_SOCK":"/agent"}}));
        to_client.send(line(json!({"id":1,"event":"log","level":"info","text":"working"}))).unwrap();
        to_client.send(line(json!({"id":1,"ok":true,"data":{},"sync":"pushed"}))).unwrap();
        assert_eq!(next(&from_client), json!({"id":2,"argv":["status"]}), "empty secrets, input and env are omitted");
        to_client.send(line(json!({"id":2,"ok":false,"error":{"code":"panic","message":"x"},"exit":2}))).unwrap();
        assert!(from_client.recv().is_err(), "close() ends the connection");
    });
    assert_eq!(client.hello(), &Hello { version: "9".into(), origin: Origin::Local, listener: None, exe: None, persistent: false });
    let (mut secrets, mut input) = (Secrets::default(), Input::default());
    secrets.insert("password", "p");
    input.insert("file", Zeroizing::new("x".to_owned()));
    let env = BTreeMap::from([("SSH_AUTH_SOCK".to_owned(), "/agent".to_owned())]);
    let words = argv(&["status"]);
    let mut logs = vec![];
    let reply = client.send(Request { argv: &words, secrets: &secrets, input: &input, env: Some(&env) },
        &mut |p| if let Progress::Log(l) = p { logs.push(l.clone()) }).unwrap();
    assert!(reply.ok);
    assert_eq!(reply.sync, "pushed");
    assert_eq!(reply.exit, None);
    assert_eq!(logs, reply.logs);
    assert_eq!(logs, [Log { level: "info".into(), text: "working".into() }]);
    let failure = send(&mut client, &["status"], &mut |_| {}).unwrap();
    assert_eq!((failure.code(), failure.exit), ("panic", Some(2)));
    client.close().unwrap();
    script.join().unwrap();
}

/// A slow daemon: the log arrives at once, the reply only later; the caller
/// gets timer ticks in between, so the UI can redraw while it waits.
#[test]
fn slow_reply_ticks_while_in_flight() {
    let (mut client, script) = fake(|to_client, from_client| {
        next(&from_client);
        to_client.send(line(json!({"id":1,"event":"log","level":"info","text":"working"}))).unwrap();
        thread::sleep(std::time::Duration::from_secs(1));
        to_client.send(line(json!({"id":1,"ok":true,"data":{}}))).unwrap();
    });
    let mut events = vec![];
    let reply = send(&mut client, &["status"], &mut |p| events.push(match p { Progress::Log(l) => l.text.clone(), Progress::Tick => "tick".into() })).unwrap();
    assert!(reply.ok);
    let first_tick = events.iter().position(|e| e == "tick").expect("ticks while the reply is pending");
    assert_eq!(events[..first_tick], ["working".to_owned()], "the log event is delivered before any wait");
    assert!(events.iter().filter(|e| *e == "tick").count() >= 5, "{events:?}");
    script.join().unwrap();
}

#[test]
fn disconnect_mid_request_is_core_exit() {
    let (mut client, script) = fake(|to_client, from_client| {
        next(&from_client);
        to_client.send(line(json!({"id":1,"event":"log","level":"info","text":"working"}))).unwrap();
    });
    let error = send(&mut client, &["status"], &mut |_| {}).err().unwrap();
    assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    assert_eq!(error.to_string(), "Ядро remote-control завершилось.");
    script.join().unwrap();
    assert_eq!(send(&mut client, &["status"], &mut |_| {}).err().unwrap().kind(), io::ErrorKind::UnexpectedEof, "a dead connection fails at once");
}

#[test]
fn foreign_and_unknown_messages_are_skipped_in_order() {
    let (mut client, script) = fake(|to_client, from_client| {
        next(&from_client);
        for message in [
            json!({"event":"activity","state":"start","command":"group list","origin":"network"}),
            json!({"id":7,"event":"log","level":"info","text":"foreign"}),
            json!({"id":1,"event":"novel","x":1}),
            json!({"id":1,"event":"log","level":"info","text":"a"}),
            json!({"id":1,"event":"output","data":"aGk="}),
            json!({"id":1,"event":"log","level":"warn","text":"b"}),
            json!({"id":1,"ok":true,"data":{"n":1}}),
        ] { to_client.send(line(message)).unwrap(); }
        next(&from_client);
        to_client.send(line(json!({"id":99,"ok":true,"data":{}}))).unwrap();
    });
    let mut seen = vec![];
    let reply = send(&mut client, &["group", "list"], &mut |p| if let Progress::Log(l) = p { seen.push(l.text.clone()) }).unwrap();
    assert_eq!(seen, ["a", "b"]);
    assert_eq!(reply.logs.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), ["a", "b"]);
    assert_eq!(reply.data, json!({"n":1}));
    let error = send(&mut client, &["status"], &mut |_| {}).err().unwrap();
    assert_eq!((error.kind(), error.to_string().as_str()), (io::ErrorKind::InvalidData, "Неверный id ответа демона"));
    script.join().unwrap();
}

#[test]
fn hello_must_come_first_with_protocol_3() {
    let (to_client, incoming) = mpsc::channel();
    to_client.send(line(json!({"event":"hello","protocol":2,"version":"9"}))).unwrap();
    let error = DaemonClient::from_channels(incoming, mpsc::channel().0).err().unwrap();
    assert_eq!((error.kind(), error.to_string().as_str()), (io::ErrorKind::InvalidData, "Несовместимый протокол демона: 2."));

    let (to_client, incoming) = mpsc::channel::<Zeroizing<String>>();
    drop(to_client);
    assert_eq!(DaemonClient::from_channels(incoming, mpsc::channel().0).err().unwrap().kind(), io::ErrorKind::UnexpectedEof);
}

#[derive(Default)]
struct TestTerminal { events: Option<Box<dyn Fn(TermEvent) + Send>>, written: Vec<u8>, stopped: bool }
impl TerminalIo for TestTerminal {
    fn term(&self) -> String { "xterm-256color".into() }
    fn size(&self) -> (u16, u16) { (80, 24) }
    fn start(&mut self, events: Box<dyn Fn(TermEvent) + Send>) -> io::Result<()> {
        events(TermEvent::Input(Zeroizing::new(b"ls\n".to_vec())));
        events(TermEvent::Resize { cols: 100, rows: 30 });
        self.events = Some(events);
        Ok(())
    }
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.written.extend_from_slice(data);
        if self.written.ends_with(b"bye") { (self.events.as_ref().unwrap())(TermEvent::Closed); }
        Ok(())
    }
    fn stop(&mut self) { self.stopped = true; }
}

#[test]
fn terminal_exchange_relays_output_input_resize_and_close() {
    let (mut client, script) = fake(|to_client, from_client| {
        let request = next(&from_client);
        assert_eq!(request["argv"], json!(["node", "shell", "--name", "n1"]));
        assert_eq!(request["terminal"], json!({"term":"xterm-256color","cols":80,"rows":24}));
        to_client.send(line(json!({"id":1,"event":"log","level":"info","text":"Подключение"}))).unwrap();
        to_client.send(line(json!({"id":1,"event":"terminal","state":"open"}))).unwrap();
        assert_eq!(next(&from_client), json!({"id":1,"stdin":STANDARD.encode("ls\n")}));
        assert_eq!(next(&from_client), json!({"id":1,"resize":{"cols":100,"rows":30}}));
        to_client.send(line(json!({"id":1,"event":"output","data":STANDARD.encode("hello bye")}))).unwrap();
        assert_eq!(next(&from_client), json!({"id":1,"close":true}));
        to_client.send(line(json!({"id":1,"event":"log","level":"info","text":"SSH-сессия завершена."}))).unwrap();
        to_client.send(line(json!({"id":1,"ok":true,"data":{}}))).unwrap();
    });
    let mut terminal = TestTerminal::default();
    let words = argv(&["node", "shell", "--name", "n1"]);
    let (secrets, input) = (Secrets::default(), Input::default());
    let reply = client.terminal(Request::new(&words, &secrets, &input), &mut terminal, &mut |_| {}).unwrap();
    assert!(reply.ok);
    assert_eq!(reply.logs.len(), 2);
    assert_eq!(terminal.written, b"hello bye");
    assert!(terminal.stopped);
    script.join().unwrap();
}

#[test]
fn scripted_client_counts_terminal_steps_and_records_names() {
    let mut client = ScriptedClient::new([Step::send(argv(&["template", "import"]), Reply::success(json!({}))),
        Step::terminal(argv(&["node", "shell"]), Reply::success(json!({})))]);
    assert_eq!(client.hello(), &Hello { version: "test".into(), origin: Origin::Local, listener: None, exe: None, persistent: false });
    let mut input = Input::default();
    input.insert("file", Zeroizing::new("mode: rule\n".to_owned()));
    let words = argv(&["template", "import"]);
    assert!(client.send(Request::new(&words, &Secrets::default(), &input), &mut |_| {}).unwrap().ok);
    assert_eq!(client.input_names, [vec!["file".to_owned()]]);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| client.assert_finished()));
    assert!(result.is_err(), "an unused terminal step is not finished");
    let mut terminal = TestTerminal::default();
    let words = argv(&["node", "shell"]);
    assert!(client.terminal(Request::new(&words, &Secrets::default(), &Input::default()), &mut terminal, &mut |_| {}).unwrap().ok);
    assert!(terminal.stopped);
    client.assert_finished();
}

#[test]
#[should_panic(expected = "terminal request")]
fn scripted_terminal_step_does_not_answer_send() {
    let mut client = ScriptedClient::new([Step::terminal(argv(&["node", "shell"]), Reply::success(json!({})))]);
    let _ = send(&mut client, &["node", "shell"], &mut |_| {});
}

#[cfg(unix)]
mod local {
    use std::{io::{BufRead, BufReader, Write}, os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}}, path::Path, time::Duration};
    use super::*;

    fn runtime() -> tempfile::TempDir {
        let dir = tempfile::Builder::new().prefix("rc").tempdir_in("/tmp").unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        dir
    }

    #[test]
    fn connect_local_reads_large_lines_and_checks_version_and_exe() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let listener = UnixListener::bind(&endpoint.socket).unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut writer = stream.try_clone().unwrap();
            writeln!(writer, "{}", json!({"event":"hello","protocol":3,"version":"9","origin":"local","exe":"/opt/essence-rc","persistent":true})).unwrap();
            let mut request = String::new();
            BufReader::new(stream).read_line(&mut request).unwrap();
            assert_eq!(serde_json::from_str::<Value>(&request).unwrap()["argv"], json!(["status"]));
            let big = "x".repeat(300 << 10);
            writeln!(writer, "{}", json!({"id":1,"event":"log","level":"output","text":big})).unwrap();
            writeln!(writer, "{}", json!({"id":1,"ok":true,"data":{}})).unwrap();
            for version in ["1", "9"] {
                let (mut stream, _) = listener.accept().unwrap();
                writeln!(stream, "{}", json!({"event":"hello","protocol":3,"version":version,"origin":"local","exe":"/opt/essence-rc"})).unwrap();
            }
        });
        let mut client = DaemonClient::connect_local(&endpoint, None, Some("9"), Some(Path::new("/opt/essence-rc"))).unwrap();
        assert_eq!(client.hello().exe.as_deref(), Some(Path::new("/opt/essence-rc")));
        assert!(client.hello().persistent);
        let reply = send(&mut client, &["status"], &mut |_| {}).unwrap();
        assert_eq!(reply.logs[0].text.len(), 300 << 10);
        client.close().unwrap();
        let error = DaemonClient::connect_local(&endpoint, None, Some("2"), None).err().unwrap();
        assert_eq!(error.to_string(), "Запущен демон другой версии (1). Остановите его: essence-rc daemon stop.");
        let error = DaemonClient::connect_local(&endpoint, None, Some("9"), Some(Path::new("/opt/other"))).err().unwrap();
        assert_eq!(error.to_string(), "Запущен демон другой версии (9). Остановите его: essence-rc daemon stop.");
        server.join().unwrap();
    }

    #[test]
    fn absent_daemon_without_spawn_is_not_found() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        assert_eq!(DaemonClient::connect_local(&endpoint, None, None, None).err().unwrap().kind(), io::ErrorKind::NotFound);
    }

    #[test]
    fn unsafe_runtime_dir_is_refused_before_connecting() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let _listener = UnixListener::bind(&endpoint.socket).unwrap();
        std::fs::set_permissions(runtime.path(), std::fs::Permissions::from_mode(0o750)).unwrap();
        assert_eq!(DaemonClient::connect_local(&endpoint, None, None, None).err().unwrap().kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn failed_spawn_reports_journal_tail_with_data_dir_and_cwd() {
        let runtime = runtime();
        let endpoint = endpoint_in(&runtime.path().join("run"), Path::new("/data")).unwrap();
        let spawn = SpawnDaemon {
            exe: "/bin/sh".into(),
            args: vec!["-c".into(), r#"echo "$ESSENCE_RC_DATA_DIR $(pwd) $EXTRA" >&2; exit 3"#.into()],
            env: vec![("EXTRA".into(), "extra".into())],
        };
        let error = DaemonClient::connect_local(&endpoint, Some(&spawn), None, None).err().unwrap();
        assert_eq!(error.to_string(), "Не удалось запустить демон essence-rc.\n/data / extra");
        assert_eq!(std::fs::metadata(&endpoint.log).unwrap().permissions().mode() & 0o777, 0o600);
    }

    /// One accepted connection of a fake daemon on a real socket.
    struct Peer { reader: BufReader<UnixStream>, writer: UnixStream }
    impl Peer {
        fn accept(listener: &UnixListener, version: &str) -> Self {
            let (stream, _) = listener.accept().unwrap();
            let mut peer = Peer { reader: BufReader::new(stream.try_clone().unwrap()), writer: stream };
            peer.send(json!({"event":"hello","protocol":3,"version":version,"origin":"local"}));
            peer
        }
        fn send(&mut self, value: Value) { writeln!(self.writer, "{value}").unwrap(); }
        fn recv(&mut self) -> Option<Value> {
            let mut line = String::new();
            (self.reader.read_line(&mut line).unwrap() > 0).then(|| serde_json::from_str(&line).unwrap())
        }
        /// Answers the next request, which must have `argv`.
        fn answer(&mut self, argv: Value, reply: Value) {
            let request = self.recv().expect("a request");
            assert_eq!(request["argv"], argv);
            let mut reply = reply;
            reply["id"] = request["id"].clone();
            self.send(reply);
        }
    }

    /// A spawn that only leaves a marker: these tests must never start a daemon.
    fn marker_spawn(runtime: &Path) -> (SpawnDaemon, std::path::PathBuf) {
        let marker = runtime.join("spawned");
        (SpawnDaemon { exe: "/bin/sh".into(), args: vec!["-c".into(), format!("touch '{}'; exit 1", marker.display())], env: vec![] }, marker)
    }

    #[test]
    fn other_version_idle_on_demand_is_stopped_and_reconnected() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let (spawn, marker) = marker_spawn(runtime.path());
        let listener = UnixListener::bind(&endpoint.socket).unwrap();
        let server = thread::spawn(move || {
            let mut old = Peer::accept(&listener, "1");
            old.answer(json!(["daemon", "status"]), json!({"ok":true,"data":{"persistent":false,"clients":[{"origin":"local","since_s":0}],"terminals":[]}}));
            old.answer(json!(["daemon", "stop"]), json!({"ok":true,"data":{"stopping":true}}));
            drop(old);
            let mut new = Peer::accept(&listener, "9");
            assert!(new.recv().is_none(), "the new connection is only closed");
        });
        let mut client = DaemonClient::connect_local(&endpoint, Some(&spawn), Some("9"), None).unwrap();
        assert_eq!(client.hello().version, "9");
        client.close().unwrap();
        server.join().unwrap();
        assert!(!marker.exists(), "a listening daemon is never spawned anew");
    }

    #[test]
    fn other_version_with_activity_is_refused_without_stop() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let (spawn, _) = marker_spawn(runtime.path());
        let listener = UnixListener::bind(&endpoint.socket).unwrap();
        let busy = [
            json!({"persistent":true,"clients":[{}],"terminals":[]}),
            json!({"persistent":false,"clients":[{},{}],"terminals":[]}),
            json!({"persistent":false,"clients":[{}],"terminals":["n1"]}),
        ];
        let server = thread::spawn(move || for data in busy {
            let mut peer = Peer::accept(&listener, "1");
            peer.answer(json!(["daemon", "status"]), json!({"ok":true,"data":data}));
            assert!(peer.recv().is_none(), "no daemon stop is sent");
        });
        for _ in 0..3 {
            let error = DaemonClient::connect_local(&endpoint, Some(&spawn), Some("9"), None).err().unwrap();
            assert_eq!(error.to_string(), "Запущен демон другой версии (1) с активными клиентами. Остановите его: essence-rc daemon stop.");
        }
        server.join().unwrap();
    }

    #[test]
    fn daemon_stopping_reconnects_and_retries_once() {
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let listener = UnixListener::bind(&endpoint.socket).unwrap();
        let server = thread::spawn(move || {
            let mut stopping = Peer::accept(&listener, "9");
            stopping.answer(json!(["group", "list"]), json!({"ok":false,"error":{"code":"daemon_stopping","message":"Демон останавливается. Повторите команду."},"exit":1}));
            drop(stopping);
            let mut fresh = Peer::accept(&listener, "9");
            fresh.answer(json!(["group", "list"]), json!({"ok":true,"data":{"n":2}}));
        });
        let mut client = DaemonClient::connect_local(&endpoint, None, Some("9"), None).unwrap();
        let reply = send(&mut client, &["group", "list"], &mut |_| {}).unwrap();
        assert!(reply.ok);
        assert_eq!(reply.data, json!({"n":2}));
        server.join().unwrap();
    }

    #[test]
    fn held_lock_without_socket_waits_instead_of_spawning() {
        use std::os::fd::AsRawFd;
        let runtime = runtime();
        let endpoint = endpoint_in(runtime.path(), Path::new("/data")).unwrap();
        let (spawn, marker) = marker_spawn(runtime.path());
        let lock = std::fs::File::create(&endpoint.lock).unwrap();
        // SAFETY: the descriptor is owned by `lock`.
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        let waiting = endpoint.clone();
        let client = thread::spawn(move || DaemonClient::connect_local(&waiting, Some(&spawn), None, None));
        thread::sleep(Duration::from_millis(400));
        assert!(!client.is_finished(), "the client waits for the starting daemon");
        let listener = UnixListener::bind(&endpoint.socket).unwrap();
        let peer = Peer::accept(&listener, "9");
        drop(lock);
        let client = client.join().unwrap().unwrap();
        assert_eq!(client.hello().version, "9");
        assert!(!marker.exists(), "a held lock means a daemon is starting: never spawn");
        drop(peer);
    }
}
