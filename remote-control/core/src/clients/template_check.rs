//! `template check`: a template is checked as every client config it can
//! produce. Each variant (no group, then every marker tag) is the template
//! filtered like `process`; a variant must keep a `proxies:` anchor, parse as
//! YAML and match the mihomo config schema (MetaCubeX meta-json-schema,
//! `core/schemas`). Problems carry source line numbers; a problem found in
//! every variant is reported once without a variant.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use saphyr::{LoadableYamlNode, MarkedYaml, Marker, Scalar, YamlData};
use serde_json::{Map, Number, Value, json};

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::request_input::Input;

use super::templates::{self, file_name, marker_blocks, process_lines};

/// Problems beyond this many are dropped (`truncated`).
const LIMIT: usize = 200;
/// Schema messages are cut to this many characters.
const MESSAGE_CHARS: usize = 200;

static SCHEMA: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/schemas/meta-json-schema.json"));

/// Draft-07 from the schema's `$schema`; patterns use the default
/// fancy-regex engine (the schema has lookaheads); formats are not checked.
static VALIDATOR: LazyLock<jsonschema::Validator> = LazyLock::new(|| {
    let schema: Value = serde_json::from_str(SCHEMA).expect("embedded mihomo schema is JSON");
    jsonschema::options().should_validate_formats(false).build(&schema).expect("embedded mihomo schema compiles")
});

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Problem {
    pub line: usize,
    pub column: usize,
    /// `error` or `warning`.
    pub level: &'static str,
    pub code: &'static str,
    pub message: String,
    /// JSON pointer of a `schema` problem.
    pub path: Option<String>,
    /// The variant's group tag (empty — the variant without groups); `None`
    /// — the problem is in every variant.
    pub variant: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Variant {
    /// `None` — a group without marker blocks.
    pub tag: Option<String>,
    /// Source line ranges (1-based, inclusive) the variant drops.
    pub dropped: Vec<(usize, usize)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// Sorted by position, at most `LIMIT`.
    pub problems: Vec<Problem>,
    pub truncated: bool,
    /// Counts of every problem, including the truncated ones.
    pub errors: usize,
    pub warnings: usize,
    pub variants: Vec<Variant>,
}

fn problem(line: usize, column: usize, level: &'static str, code: &'static str, message: String) -> Problem {
    Problem { line, column, level, code, message, path: None, variant: None }
}

/// Check a template against the groups that exist (names of marker tags).
pub fn check(content: &str, groups: &[String]) -> Report {
    let mut problems = Vec::new();
    let mut tags: Vec<String> = Vec::new();
    for block in marker_blocks(content) {
        if block.close.is_none() {
            problems.push(problem(block.open, 1, "error", "marker_unclosed",
                format!("Блок маркера {} не закрыт.", block.tags.join("/"))));
        }
        for tag in block.tags {
            if !groups.contains(&tag) {
                problems.push(problem(block.open, 1, "warning", "marker_unknown_group",
                    format!("Маркер {tag}: группы с таким именем нет.")));
            }
            if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
    }
    let total = content.split_inclusive('\n').count();
    let names: Vec<Option<String>> = std::iter::once(None).chain(tags.into_iter().map(Some)).collect();
    let mut variants = Vec::with_capacity(names.len());
    let mut found: Vec<Vec<Problem>> = Vec::with_capacity(names.len());
    for tag in names {
        let kept = process_lines(content, tag.as_deref().unwrap_or(""));
        variants.push(Variant { tag: tag.clone(), dropped: dropped(&kept, total) });
        found.push(check_variant(&kept));
    }
    merge(&mut problems, &variants, found);
    problems.sort_by(|a, b| (a.line, a.column, a.level).cmp(&(b.line, b.column, b.level)));
    let errors = problems.iter().filter(|p| p.level == "error").count();
    let warnings = problems.len() - errors;
    let truncated = problems.len() > LIMIT;
    problems.truncate(LIMIT);
    Report { problems, truncated, errors, warnings, variants }
}

/// Source line ranges not kept.
fn dropped(kept: &[(usize, &str)], total: usize) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut next = 1;
    for line in kept.iter().map(|(line, _)| *line).chain(std::iter::once(total + 1)) {
        if line > next {
            ranges.push((next, line - 1));
        }
        next = line + 1;
    }
    ranges
}

/// A problem of every variant is reported once; others once per variant.
fn merge(problems: &mut Vec<Problem>, variants: &[Variant], found: Vec<Vec<Problem>>) {
    let key = |p: &Problem| (p.line, p.column, p.code, p.message.clone());
    let shared: BTreeSet<_> = found.first().map(|first| first.iter().map(key)
        .filter(|k| found.iter().all(|list| list.iter().any(|p| key(p) == *k)))
        .collect()).unwrap_or_default();
    let mut reported = BTreeSet::new();
    for (variant, list) in variants.iter().zip(found) {
        for mut problem in list {
            let k = key(&problem);
            if shared.contains(&k) {
                if reported.insert(k) {
                    problems.push(problem);
                }
            } else {
                problem.variant = Some(variant.tag.clone().unwrap_or_default());
                problems.push(problem);
            }
        }
    }
}

/// Source position of a 1-based line / 0-based column of the variant text.
fn source_position(kept: &[(usize, &str)], marker: &Marker) -> (usize, usize) {
    let line = match kept.get(marker.line().saturating_sub(1)) {
        Some((line, _)) => *line,
        None => kept.last().map_or(1, |(line, _)| *line),
    };
    (line, marker.col() + 1)
}

fn check_variant(kept: &[(usize, &str)]) -> Vec<Problem> {
    let mut problems = Vec::new();
    if !kept.iter().any(|(_, line)| *line == "proxies:") {
        problems.push(problem(1, 1, "error", "proxies",
            "Нет строки «proxies:» — конфиг клиента не будет сгенерирован.".into()));
    }
    let mut text = String::new();
    for (_, line) in kept {
        text.push_str(line);
        text.push('\n');
    }
    let documents = match MarkedYaml::load_from_str(&text) {
        Ok(documents) => documents,
        Err(error) => {
            let (line, column) = source_position(kept, error.marker());
            problems.push(problem(line, column, "error", "yaml", format!("Ошибка YAML: {}.", error.info())));
            return problems;
        }
    };
    let root = documents.first();
    let mut instance = root.map_or(Value::Null, to_json);
    if let Some(proxies) = instance.get_mut("proxies") && proxies.is_null() {
        *proxies = Value::Array(Vec::new());
    }
    for error in VALIDATOR.iter_errors(&instance) {
        let path = error.instance_path().as_str().to_owned();
        let marker = root.map_or_else(Marker::default, |root| locate(root, &path));
        let (line, column) = source_position(kept, &marker);
        let message: String = error.to_string().chars().take(MESSAGE_CHARS).collect();
        problems.push(Problem { path: Some(path), ..problem(line, column.max(1), "warning", "schema", message) });
    }
    problems
}

fn untagged<'a, 'n>(mut node: &'a MarkedYaml<'n>) -> &'a MarkedYaml<'n> {
    while let YamlData::Tagged(_, inner) = &node.data {
        node = inner;
    }
    node
}

/// A mapping key as the string mihomo sees.
fn key_text(node: &MarkedYaml<'_>) -> Option<String> {
    match &untagged(node).data {
        YamlData::Value(scalar) => Some(match scalar {
            Scalar::Null => "null".into(),
            Scalar::Boolean(value) => value.to_string(),
            Scalar::Integer(value) => value.to_string(),
            Scalar::FloatingPoint(value) => value.to_string(),
            Scalar::String(value) => value.to_string(),
        }),
        YamlData::Representation(value, ..) => Some(value.to_string()),
        _ => None,
    }
}

fn is_merge_key(node: &MarkedYaml<'_>) -> bool {
    key_text(node).as_deref() == Some("<<")
}

/// The mappings a `<<` value merges, in priority order.
fn merge_sources<'a, 'n>(value: &'a MarkedYaml<'n>) -> Vec<&'a MarkedYaml<'n>> {
    match &untagged(value).data {
        YamlData::Mapping(_) => vec![untagged(value)],
        YamlData::Sequence(items) => items.iter().map(untagged).filter(|item| item.data.is_mapping()).collect(),
        _ => Vec::new(),
    }
}

fn to_json(node: &MarkedYaml<'_>) -> Value {
    match &untagged(node).data {
        YamlData::Value(scalar) => match scalar {
            Scalar::Null => Value::Null,
            Scalar::Boolean(value) => Value::Bool(*value),
            Scalar::Integer(value) => Value::Number((*value).into()),
            Scalar::FloatingPoint(value) => Number::from_f64(value.into_inner()).map_or(Value::Null, Value::Number),
            Scalar::String(value) => Value::String(value.to_string()),
        },
        YamlData::Sequence(items) => Value::Array(items.iter().map(to_json).collect()),
        YamlData::Mapping(entries) => {
            let mut object = Map::new();
            let mut merged = Vec::new();
            for (key, value) in entries {
                if is_merge_key(key) {
                    merged.extend(merge_sources(value));
                } else if let Some(key) = key_text(key) {
                    object.insert(key, to_json(value));
                }
            }
            // Explicit keys win, then earlier merge sources over later ones.
            for source in merged {
                if let Value::Object(fields) = to_json(source) {
                    for (key, value) in fields {
                        object.entry(key).or_insert(value);
                    }
                }
            }
            Value::Object(object)
        }
        _ => Value::Null,
    }
}

/// The child of a node for one JSON pointer segment (explicit keys, then
/// merged mappings).
fn child<'a, 'n>(node: &'a MarkedYaml<'n>, segment: &str) -> Option<&'a MarkedYaml<'n>> {
    match &untagged(node).data {
        YamlData::Sequence(items) => segment.parse::<usize>().ok().and_then(|index| items.get(index)),
        YamlData::Mapping(entries) => entries.iter()
            .find(|(key, _)| !is_merge_key(key) && key_text(key).as_deref() == Some(segment))
            .map(|(_, value)| value)
            .or_else(|| entries.iter().filter(|(key, _)| is_merge_key(key))
                .flat_map(|(_, value)| merge_sources(value))
                .find_map(|source| child(source, segment))),
        _ => None,
    }
}

/// Start of the node at a JSON pointer, or of its nearest present ancestor.
fn locate(root: &MarkedYaml<'_>, pointer: &str) -> Marker {
    let mut node = root;
    for segment in pointer.split('/').skip(1) {
        let segment = segment.replace("~1", "/").replace("~0", "~");
        match child(node, &segment) {
            Some(next) => node = next,
            None => break,
        }
    }
    node.span.start
}

/// `template check (--name T | --file PATH)`: read-only.
pub fn command(session: &mut Session, invocation: &Invocation, input: &Input) -> Result<Value> {
    let name = invocation.value("name").filter(|name| !name.is_empty()).map(file_name);
    let stored;
    let content = match (input.get("file"), &name) {
        (Some(content), _) => content,
        (None, Some(name)) => {
            stored = templates::require(&session.state, name)?.content;
            stored.as_str()
        }
        (None, None) => return Err(RcError::new("usage", "Укажите шаблон: --name T или --file PATH.")),
    };
    let groups: Vec<String> = session.state.load_config()?.groups.into_iter().map(|group| group.name).collect();
    let report = check(content, &groups);
    Ok(json!({
        "name": name,
        "errors": report.errors,
        "warnings": report.warnings,
        "truncated": report.truncated,
        "problems": report.problems.iter().map(|p| json!({
            "line": p.line, "column": p.column, "level": p.level, "code": p.code,
            "message": p.message, "path": p.path, "variant": p.variant,
        })).collect::<Vec<_>>(),
        "variants": report.variants.iter().map(|v| json!({"tag": v.tag, "dropped": v.dropped})).collect::<Vec<_>>(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::templates::{TemplateSource, builtin, list};
    use crate::nodes::testing::{fingerprint, invocation, session};

    fn groups() -> Vec<String> {
        ["ROUTER", "PC", "MOBILE"].map(String::from).to_vec()
    }

    fn codes(report: &Report) -> Vec<(usize, &'static str, Option<&str>)> {
        report.problems.iter().map(|p| (p.line, p.code, p.variant.as_deref())).collect()
    }

    #[test]
    fn builtin_templates_have_no_errors() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = session(root.path());
        let names = list(&session.state).unwrap();
        assert!(!names.is_empty());
        for (name, source) in names {
            assert_eq!(source, TemplateSource::Builtin);
            let report = check(builtin(&name).unwrap(), &groups());
            assert_eq!(report.errors, 0, "{name}: {:?}", report.problems);
            assert_eq!(report.warnings, 0, "{name}: {:?}", report.problems);
        }
    }

    #[test]
    fn missing_proxies_anchor_is_an_error_of_every_variant() {
        let report = check("mode: rule\n", &groups());
        assert_eq!(codes(&report), [(1, "proxies", None)]);
        assert_eq!((report.errors, report.warnings, report.truncated), (1, 0, false));
        assert_eq!(report.variants, [Variant { tag: None, dropped: vec![] }]);
        // `proxies: []` is not an anchor for the generator.
        assert_eq!(codes(&check("proxies: []\n", &groups())), [(1, "proxies", None)]);
        // An empty `proxies:` is not a schema problem.
        assert!(check("proxies:\nmode: rule\n", &groups()).problems.is_empty());
    }

    #[test]
    fn broken_yaml_inside_a_block_points_at_the_source_line_of_its_variant() {
        let content = "proxies:\n# --- PC ---\nmode: rule\nport: a: b\n# --- PC ---\nlog-level: info\n";
        let report = check(content, &groups());
        assert_eq!(codes(&report), [(4, "yaml", Some("PC"))], "{:?}", report.problems);
        assert_eq!(report.problems[0].level, "error");
        assert_eq!(report.variants, [
            Variant { tag: None, dropped: vec![(2, 5)] },
            Variant { tag: Some("PC".into()), dropped: vec![(2, 2), (5, 5)] },
        ]);
        // Broken outside blocks: one problem for every variant, line and column of the source.
        let report = check("a: 1\n# --- PC ---\nb: 2\n# --- PC ---\nproxies:\nfoo: [1,\n", &groups());
        assert_eq!(codes(&report), [(6, "yaml", None)], "{:?}", report.problems);
        let duplicate = check("proxies:\nmode: rule\nmode: global\n", &groups());
        assert_eq!(codes(&duplicate), [(3, "yaml", None)]);
        assert!(duplicate.problems[0].message.contains("duplicated key"));
    }

    #[test]
    fn markers_unclosed_and_unknown_groups() {
        let report = check("proxies:\n# --- GHOST/PC ---\nx: 1\n# --- GHOST/PC ---\n# --- ROUTER ---\ny: 2\n", &groups());
        assert_eq!(codes(&report), [(2, "marker_unknown_group", None), (5, "marker_unclosed", None)]);
        assert_eq!(report.problems[0].message, "Маркер GHOST: группы с таким именем нет.");
        assert_eq!(report.problems[1].message, "Блок маркера ROUTER не закрыт.");
        assert_eq!((report.errors, report.warnings), (1, 1));
        let tags: Vec<_> = report.variants.iter().map(|v| v.tag.as_deref()).collect();
        assert_eq!(tags, [None, Some("GHOST"), Some("PC"), Some("ROUTER")]);
    }

    #[test]
    fn schema_problems_carry_the_path_and_the_node_position() {
        let content = "proxies:\nbase: &base\n  enable: true\ndns:\n  <<: *base\n  ipv6: 3\nmode: foo\nproxy-groups:\n  - name: g\n    type: bogus\n";
        let report = check(content, &groups());
        let schema: Vec<_> = report.problems.iter().map(|p| (p.line, p.column, p.path.as_deref())).collect();
        assert_eq!(schema, [(6, 9, Some("/dns/ipv6")), (7, 7, Some("/mode")), (9, 5, Some("/proxy-groups/0"))],
            "{:?}", report.problems);
        assert!(report.problems.iter().all(|p| p.level == "warning" && p.code == "schema" && p.message.chars().count() <= 200));
        // A merged key wins below explicit ones and is located in its anchor.
        let merged = check("proxies:\nbase: &base\n  enable: 7\ndns:\n  <<: *base\n", &groups());
        assert_eq!(merged.problems.iter().map(|p| (p.line, p.path.as_deref())).collect::<Vec<_>>(), [(3, Some("/dns/enable"))]);
        assert!(check("proxies:\nbase: &base\n  enable: 7\ndns:\n  <<: *base\n  enable: true\n", &groups())
            .problems.iter().all(|p| p.path.as_deref() != Some("/dns/enable")));
    }

    #[test]
    fn problems_are_limited() {
        let content: String = std::iter::once("proxies:\n".to_owned())
            .chain((0..250).map(|i| format!("# --- G{i} ---\n# --- G{i} ---\n"))).collect();
        let report = check(&content, &groups());
        assert_eq!((report.problems.len(), report.truncated, report.warnings), (LIMIT, true, 250));
    }

    #[test]
    fn command_checks_a_stored_template_or_the_input_without_writing() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let before = fingerprint(root.path());
        let stored = command(&mut session, &invocation(&["template", "check", "--name", "default"]), &Input::default()).unwrap();
        assert_eq!((stored["name"].clone(), stored["errors"].clone(), stored["problems"].clone()), (json!("default.yaml"), json!(0), json!([])));
        assert_eq!(stored["variants"][0], json!({"tag": null, "dropped": [[30, 39], [49, 51], [80, 88], [113, 123], [155, 158], [392, 394], [398, 401]]}));
        let mut input = Input::default();
        input.insert("file", "mode: rule\n".to_owned().into()).unwrap();
        let file = command(&mut session, &invocation(&["template", "check"]), &input).unwrap();
        assert_eq!(file, json!({"name": null, "errors": 1, "warnings": 0, "truncated": false,
            "problems": [{"line": 1, "column": 1, "level": "error", "code": "proxies",
                "message": "Нет строки «proxies:» — конфиг клиента не будет сгенерирован.", "path": null, "variant": null}],
            "variants": [{"tag": null, "dropped": []}]}));
        let usage = command(&mut session, &invocation(&["template", "check"]), &Input::default()).unwrap_err();
        assert_eq!((usage.code, usage.message.as_str()), ("usage", "Укажите шаблон: --name T или --file PATH."));
        assert_eq!(command(&mut session, &invocation(&["template", "check", "--name", "ghost"]), &Input::default()).unwrap_err().code, "not_found");
        assert_eq!(fingerprint(root.path()), before);
    }
}
