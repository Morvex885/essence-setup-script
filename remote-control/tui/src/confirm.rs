//! One confirmation per frozen core plan; all decision-code flag names live here.
use std::io;
use crate::{app::Context, serve::{Reply, Secrets}, ui::{self, View}};
pub fn decision_flag(code: &str) -> Option<&'static str> {
    Some(match code {
        "repo_create_required"=>"--create-repo", "repo_private_required"=>"--make-private",
        "storage_mode_required"=>"--storage", "existing_config_action_required"=>"--existing",
        "key_provisioning_required"=>"--provision-keys", "cache_skip_required"=>"--without-cache",
        "target_replace_required"=>"--replace-target", "delete_scope_required"=>"--scope",
        "on_failure_required"=>"--on-failure", _=>return None,
    })
}
/// Set a decision without duplicate flags; `None` denotes a boolean flag.
pub fn set_flag(argv: &mut Vec<String>, flag: &str, value: Option<&str>) {
    if let Some(index) = argv.iter().position(|s| s==flag) {
        if let Some(value)=value { if index+1<argv.len() && !argv[index+1].starts_with("--") { argv[index+1]=value.into(); } else { argv.insert(index+1,value.into()); } }
    } else { argv.push(flag.into()); if let Some(value)=value { argv.push(value.into()); } }
}
/// Refusal returns the last (unsuccessful) reply, without sending a mutation.
/// `--force` is valid only inside this helper: the first call obtains its plan.
/// Like v1 `tui_run_confirmed`, a plan that changes more than twice stops.
pub fn run_confirmed(context: &mut Context<'_>, title: &str, question: &str, words: &[String], secrets: &Secrets) -> io::Result<Reply> {
    let reply = context.request(words,secrets)?;
    review_reply(context,title,question,words,secrets,reply,Some(2))
}
/// Review an already-obtained plan (e.g. a harden preflight). A bounded
/// replan policy is opt-in for screens whose command-specific parity requires it.
pub fn review_reply(context: &mut Context<'_>, title: &str, question: &str, words: &[String], secrets: &Secrets, mut reply: Reply, max_changes: Option<usize>) -> io::Result<Reply> {
    let mut base=words.to_vec();
    let mut changes=0;
    loop {
        if reply.ok || !matches!(reply.code(),"confirmation_required"|"plan_changed") { return Ok(reply); }
        if reply.code()=="plan_changed" {
            changes+=1;
            if max_changes.is_some_and(|limit|changes>limit) {
                context.ui.notice(ui::warn("План продолжает меняться. Действие не выполнено; повторите позже."));
                return Ok(reply);
            }
            context.ui.notice(ui::warn("План изменился. Проверьте его ещё раз."));
            // Harden freezes the selected port in argv. Only revise an already
            // present port; never introduce command-specific flags elsewhere.
            if base.iter().any(|word|word=="--port") {
                if let Some(port)=reply.error.get("port").filter(|port|!port.is_null()) {
                    let port=port.as_str().map(str::to_owned).unwrap_or_else(||port.to_string());
                    set_flag(&mut base,"--port",Some(&port));
                }
            }
        }
        let Some(token)=reply.error["plan_token"].as_str().filter(|s|!s.is_empty()).map(str::to_owned) else {
            // A broken plan is an operation failure, never a TUI crash.
            context.failed();
            return Ok(reply);
        };
        if !context.confirm(View::review(title,&reply.error["plan"]),question)? { return Ok(reply); }
        let mut confirmed=base.clone();
        set_flag(&mut confirmed,"--yes",None);
        set_flag(&mut confirmed,"--plan-token",Some(&token));
        reply=context.request(&confirmed,secrets)?;
    }
}
#[cfg(test)] mod tests {
    use super::*;
    use crate::{app::{Registry,ScriptedUi},serve::{argv,ScriptedClient}};
    fn plan(code:&str, token:&str)->Reply { Reply { error:serde_json::json!({"code":code,"plan_token":token,"plan":["Delete all targets"]}),..Reply::default() } }
    #[test] fn confirmation_refusal_and_changed_plan() {
        let words=argv(&["group","delete","--name","LAB"]);
        let mut yes=words.clone(); yes.extend(argv(&["--yes","--plan-token","one"]));
        let mut yes2=words.clone(); yes2.extend(argv(&["--yes","--plan-token","two"]));
        let registry=Registry{screens:vec![],github_wizard:None};
        let mut client=ScriptedClient::new([(words.clone(),plan("confirmation_required","one"))]);
        let mut ui=ScriptedUi::new(&[""]);
        assert!(!run_confirmed(&mut Context{client:&mut client,ui:&mut ui,registry:&registry},"Delete","Continue?",&words,&Secrets::default()).unwrap().ok);
        client.assert_finished();
        let mut client=ScriptedClient::new([(words.clone(),plan("confirmation_required","one")),(yes,plan("plan_changed","two")),(yes2,Reply::success(serde_json::Value::Null))]);
        let mut ui=ScriptedUi::new(&["Y","y"]);
        assert!(run_confirmed(&mut Context{client:&mut client,ui:&mut ui,registry:&registry},"Delete","Continue?",&words,&Secrets::default()).unwrap().ok);
        assert_eq!(ui.views.len(),2); client.assert_finished();
    }
    #[test] fn decision_flags_are_unique() {
        let mut words=vec![];
        let flag=decision_flag("key_provisioning_required").unwrap();
        set_flag(&mut words,flag,Some("no")); set_flag(&mut words,flag,Some("yes"));
        assert_eq!(words,argv(&["--provision-keys","yes"]));
        assert_eq!(decision_flag("auth_required"),None);
    }
    #[test] fn bounded_replans_stop_and_harden_revises_frozen_port() {
        let registry=Registry{screens:vec![],github_wizard:None};
        let words=argv(&["node","harden","--name","n","--port","22"]);
        let mut changed=plan("plan_changed","new");
        changed.error["port"]=serde_json::json!(2222);
        let mut client=ScriptedClient::new([(argv(&["node","harden","--name","n","--port","2222","--yes","--plan-token","new"]),Reply::success(serde_json::Value::Null))]);
        let mut ui=ScriptedUi::new(&["y"]);
        assert!(review_reply(&mut Context{client:&mut client,ui:&mut ui,registry:&registry},"Harden","Continue?",&words,&Secrets::default(),changed.clone(),Some(2)).unwrap().ok);
        client.assert_finished();
        let mut client=ScriptedClient::new([]);
        let mut ui=ScriptedUi::new(&["y"]);
        assert!(!review_reply(&mut Context{client:&mut client,ui:&mut ui,registry:&registry},"Harden","Continue?",&words,&Secrets::default(),changed,Some(0)).unwrap().ok);
        assert!(ui.views.is_empty());client.assert_finished();
    }
}
