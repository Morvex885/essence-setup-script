//! `template check`: a template is checked as every client config it can
//! produce. Each variant (no group, then every marker tag naming an existing
//! group) is the template filtered like `process`; a variant must keep a
//! `proxies:` anchor, parse as YAML and match the mihomo config schema
//! (MetaCubeX meta-json-schema, `core/schemas`). Problems carry source line
//! numbers; a problem found in every variant is reported once without a
//! variant. Tags without a group are never generated and only warned about.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use jsonschema::error::{TypeKind, ValidationErrorKind};
use jsonschema::types::JsonType;
use saphyr::{LoadableYamlNode, MarkedYaml, Marker, Scalar, YamlData};
use serde_json::{Map, Number, Value, json};

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::request_input::Input;

use super::templates::{self, file_name, marker_blocks, process_lines};

/// Problems beyond this many are dropped (`truncated`).
const LIMIT: usize = 200;
/// Variants checked at most, the one without groups included.
const MAX_VARIANTS: usize = 16;
/// Schema problems collected per request, all variants together.
const PROBLEM_BUDGET: usize = 1000;
/// JSON nodes given to the validator per request, all variants together.
const WORK_BUDGET: usize = 4_000_000;
/// Nesting of YAML collections at most; deeper is a `yaml` error before any
/// recursive step (the tree loader, `to_json`, `locate`, the validator).
const MAX_DEPTH: usize = 128;
/// A collection with more nodes than this is validated child by child.
const SPLIT_NODES: usize = 2000;
/// A mapping is split only with more entries than this (a map of names, not
/// a fixed set of keys whose siblings the schema may depend on).
const MAP_ENTRIES: usize = 64;
/// Messages are cut to this many characters.
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
    /// Problems were dropped: over `LIMIT`, or a variant had more than
    /// `VARIANT_PROBLEMS` schema problems (the counts are then lower bounds).
    pub truncated: bool,
    /// Distinct problems (line, column, code, message): a problem of several
    /// variants counts once.
    pub errors: usize,
    pub warnings: usize,
    pub variants: Vec<Variant>,
}

fn problem(line: usize, column: usize, level: &'static str, code: &'static str, message: String) -> Problem {
    Problem { line, column, level, code, message, path: None, variant: None }
}

type Key = (usize, usize, &'static str, String);

fn key(problem: &Problem) -> Key {
    (problem.line, problem.column, problem.code, problem.message.clone())
}

/// Check a template against the groups that exist (names of marker tags).
pub fn check(content: &str, groups: &[String]) -> Report {
    let mut problems = Vec::new();
    let mut tags: Vec<String> = Vec::new();
    for block in marker_blocks(content) {
        let label = block.tags.join("/");
        if block.close.is_none() {
            problems.push(problem(block.open, 1, "error", "marker_unclosed", format!("Блок маркера «{label}» не закрыт.")));
        }
        if block.tags.iter().any(String::is_empty) {
            problems.push(problem(block.open, 1, "warning", "marker_invalid",
                format!("Маркер «{label}»: пустое имя группы между «/».")));
        }
        for tag in block.tags.into_iter().filter(|tag| !tag.is_empty()) {
            if !groups.contains(&tag) {
                problems.push(problem(block.open, 1, "warning", "marker_unknown_group",
                    format!("Маркер «{tag}»: группы с таким именем нет.")));
            } else if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
    }
    if tags.len() >= MAX_VARIANTS {
        problems.push(problem(1, 1, "warning", "variants_limit", format!(
            "Проверены {MAX_VARIANTS} вариантов из {}: остальные группы маркеров не проверены.", tags.len() + 1)));
        tags.truncate(MAX_VARIANTS - 1);
    }
    let total = content.split_inclusive('\n').count();
    let mut variants = Vec::with_capacity(tags.len() + 1);
    let mut found: Vec<Vec<Problem>> = Vec::with_capacity(tags.len() + 1);
    let mut checked: HashMap<Vec<usize>, usize> = HashMap::new();
    let mut budget = Budget::default();
    // The variant without groups: no group is named "", so no block is kept.
    for (index, tag) in std::iter::once(None).chain(tags.into_iter().map(Some)).enumerate() {
        if budget.exhausted { break; }
        let kept = process_lines(content, tag.as_deref().unwrap_or(""));
        let numbers: Vec<usize> = kept.iter().map(|(line, _)| *line).collect();
        let list = match checked.get(&numbers) {
            // The same lines as a checked variant: the same problems.
            Some(&same) => found[same].clone(),
            None => {
                let list = check_variant(&kept, &mut budget);
                // A variant cut by the budget would look like it lacks the
                // problems of the others: only the first one is kept partial.
                if budget.exhausted && index > 0 { break; }
                checked.insert(numbers, found.len());
                list
            }
        };
        variants.push(Variant { tag, dropped: dropped(&kept, total) });
        found.push(list);
    }
    if budget.exhausted {
        problems.push(problem(1, 1, "warning", "check_limit",
            "Проверка остановлена: слишком много проблем или слишком большой шаблон; показаны не все.".into()));
    }
    let mut truncated = budget.exhausted;
    merge(&mut problems, &variants, found);
    problems.sort_by(|a, b| (a.line, a.column, a.level).cmp(&(b.line, b.column, b.level)));
    let mut distinct = HashSet::new();
    let (mut errors, mut warnings) = (0, 0);
    for problem in &problems {
        if distinct.insert(key(problem)) {
            if problem.level == "error" { errors += 1 } else { warnings += 1 }
        }
    }
    truncated |= problems.len() > LIMIT;
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
    // Variants each problem occurs in.
    let mut presence: HashMap<Key, usize> = HashMap::new();
    for list in &found {
        let mut seen = HashSet::new();
        for problem in list {
            let k = key(problem);
            if !seen.contains(&k) {
                seen.insert(k.clone());
                *presence.entry(k).or_default() += 1;
            }
        }
    }
    let mut reported = HashSet::new();
    for (variant, list) in variants.iter().zip(found) {
        for mut problem in list {
            let k = key(&problem);
            if presence.get(&k) == Some(&variants.len()) {
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

/// The request's share of work: schema problems and validated JSON nodes.
#[derive(Default)]
struct Budget {
    problems: usize,
    work: usize,
    exhausted: bool,
}

impl Budget {
    /// Spend on validating `nodes` nodes; `false` — nothing is left.
    fn spend(&mut self, nodes: usize) -> bool {
        self.work += nodes;
        if self.work > WORK_BUDGET { self.exhausted = true; }
        !self.exhausted
    }

    /// Count one problem; `false` — the problem budget is used up.
    fn take_problem(&mut self) -> bool {
        if self.problems >= PROBLEM_BUDGET { self.exhausted = true; }
        self.problems += 1;
        !self.exhausted
    }
}

/// Problems of one variant.
fn check_variant(kept: &[(usize, &str)], budget: &mut Budget) -> Vec<Problem> {
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
    if let Some(marker) = too_deep(&text) {
        let (line, column) = source_position(kept, &marker);
        problems.push(problem(line, column, "error", "yaml",
            format!("Ошибка YAML: вложенность глубже {MAX_DEPTH} уровней (с учётом ссылок *имя).")));
        return problems;
    }
    let documents = match MarkedYaml::load_from_str(&text) {
        Ok(documents) => documents,
        Err(error) => {
            let (line, column) = source_position(kept, error.marker());
            let message: String = format!("Ошибка YAML: {}.", error.info()).chars().take(MESSAGE_CHARS).collect();
            problems.push(problem(line, column, "error", "yaml", message));
            return problems;
        }
    };
    let root = documents.first();
    let mut instance = root.map_or(Value::Null, to_json);
    if let Some(proxies) = instance.get_mut("proxies") && proxies.is_null() {
        *proxies = Value::Array(Vec::new());
    }
    let mut found = Vec::new();
    schema_errors(&instance, budget, &mut found);
    for (path, what) in found {
        let marker = root.map_or_else(Marker::default, |root| locate(root, &path));
        let (line, column) = source_position(kept, &marker);
        let message = schema_message(&what, &path);
        problems.push(Problem { path: Some(path), ..problem(line, column.max(1), "warning", "schema", message) });
    }
    problems
}

/// The start of the first collection nested deeper than `MAX_DEPTH`,
/// counting what an alias expands to; read from parser events, without
/// recursion. A syntax error is left to the loader.
fn too_deep(text: &str) -> Option<Marker> {
    use saphyr_parser::{Event, Parser};
    // Open collections: (anchor id, height of the deepest child so far).
    let mut open: Vec<(usize, usize)> = Vec::new();
    // Height of each anchored collection (a scalar anchor has height 0).
    let mut heights: HashMap<usize, usize> = HashMap::new();
    for event in Parser::new_from_str(text) {
        let Ok((event, span)) = event else { return None };
        match event {
            Event::SequenceStart(anchor, _) | Event::MappingStart(anchor, _) => {
                if open.len() + 1 > MAX_DEPTH { return Some(span.start); }
                open.push((anchor, 0));
            }
            Event::SequenceEnd | Event::MappingEnd => {
                let Some((anchor, height)) = open.pop() else { continue };
                if anchor != 0 { heights.insert(anchor, height + 1); }
                if let Some(parent) = open.last_mut() { parent.1 = parent.1.max(height + 1); }
            }
            Event::Alias(anchor) => {
                let height = heights.get(&anchor).copied().unwrap_or(0);
                if open.len() + height > MAX_DEPTH { return Some(span.start); }
                if let Some(parent) = open.last_mut() { parent.1 = parent.1.max(height); }
            }
            _ => {}
        }
    }
    None
}

/// One step from a collection to a child.
#[derive(Clone)]
enum Step {
    Key(String),
    Index(usize),
}

fn pointer(steps: &[Step]) -> String {
    steps.iter().map(|step| match step {
        Step::Key(key) => format!("/{}", key.replace('~', "~0").replace('/', "~1")),
        Step::Index(index) => format!("/{index}"),
    }).collect()
}

/// Nodes of a JSON value (depth is bounded by `MAX_DEPTH`).
fn nodes(value: &Value) -> usize {
    1 + match value {
        Value::Array(items) => items.iter().map(nodes).sum(),
        Value::Object(fields) => fields.values().map(nodes).sum(),
        _ => 0,
    }
}

/// The outermost collections below the root worth splitting: more than
/// `SPLIT_NODES` nodes and several items (a sequence) or more than
/// `MAP_ENTRIES` entries (a mapping). Returns the node count of `value`.
fn large(value: &Value, steps: &mut Vec<Step>, found: &mut Vec<Vec<Step>>) -> usize {
    let start = found.len();
    let (size, splittable) = match value {
        Value::Array(items) => {
            let mut size = 1;
            for (index, item) in items.iter().enumerate() {
                steps.push(Step::Index(index));
                size += large(item, steps, found);
                steps.pop();
            }
            (size, items.len() > 1)
        }
        Value::Object(fields) => {
            let mut size = 1;
            for (key, field) in fields {
                steps.push(Step::Key(key.clone()));
                size += large(field, steps, found);
                steps.pop();
            }
            (size, fields.len() > MAP_ENTRIES)
        }
        _ => (1, false),
    };
    if !steps.is_empty() && splittable && size > SPLIT_NODES {
        found.truncate(start);
        found.push(steps.clone());
    }
    size
}

fn at_mut<'a>(mut value: &'a mut Value, steps: &[Step]) -> Option<&'a mut Value> {
    for step in steps {
        value = match (step, value) {
            (Step::Key(key), Value::Object(fields)) => fields.get_mut(key)?,
            (Step::Index(index), Value::Array(items)) => items.get_mut(*index)?,
            _ => return None,
        };
    }
    Some(value)
}

/// The children of a split collection the skeleton does not keep.
fn split_children(value: &Value) -> Vec<(Step, Value)> {
    match value {
        Value::Array(items) => items.iter().cloned().enumerate().map(|(index, item)| (Step::Index(index), item)).collect(),
        Value::Object(fields) => fields.iter().skip(MAP_ENTRIES).map(|(key, field)| (Step::Key(key.clone()), field.clone())).collect(),
        _ => Vec::new(),
    }
}

/// Schema problems `(JSON pointer, what is wrong)` of a document within the
/// budget. A large document is not given to the validator whole (its error
/// lists keep every anyOf branch): its large collections are cut to a
/// skeleton (a sequence keeps its first item, a mapping its first
/// `MAP_ENTRIES` entries), and every other child is validated in its
/// top-level key with that collection holding only this child.
fn schema_errors(document: &Value, budget: &mut Budget, out: &mut Vec<(String, String)>) {
    if !budget.spend(nodes(document)) || VALIDATOR.is_valid(document) { return; }
    let mut split = Vec::new();
    large(document, &mut Vec::new(), &mut split);
    if split.is_empty() {
        for error in VALIDATOR.iter_errors(document) {
            if !budget.take_problem() { return; }
            out.push((error.instance_path().as_str().to_owned(), schema_what(error.kind())));
        }
        return;
    }
    let mut skeleton = document.clone();
    let mut parts = Vec::with_capacity(split.len());
    // Items of split sequences come from their parts (the first one too).
    let mut sequences = Vec::new();
    for steps in &split {
        let Some(collection) = at_mut(&mut skeleton, steps) else { continue };
        parts.push((steps.clone(), split_children(collection)));
        match collection {
            Value::Array(items) => {
                items.truncate(1);
                sequences.push(format!("{}/", pointer(steps)));
            }
            Value::Object(fields) => {
                let kept: Map<String, Value> = std::mem::take(fields).into_iter().take(MAP_ENTRIES).collect();
                *fields = kept;
            }
            _ => {}
        }
    }
    let mut found = Vec::new();
    schema_errors(&skeleton, budget, &mut found);
    out.extend(found.into_iter().filter(|(path, _)| !sequences.iter().any(|prefix| path.starts_with(prefix.as_str()))));
    for (steps, children) in parts {
        let Some((Step::Key(top), below)) = steps.split_first().map(|(first, rest)| (first.clone(), rest)) else { continue };
        let base = pointer(&steps);
        for (step, child) in children {
            if budget.exhausted { return; }
            let mut subtree = skeleton.get(&top).cloned().unwrap_or(Value::Null);
            let (inner, original) = match &step {
                Step::Index(index) => (Value::Array(vec![child]), format!("{base}/{index}")),
                Step::Key(key) => (Value::Object(Map::from_iter([(key.clone(), child)])), format!("{base}{}", pointer(std::slice::from_ref(&step)))),
            };
            match at_mut(&mut subtree, below) {
                Some(slot) => *slot = inner,
                None => continue,
            }
            let part = Value::Object(Map::from_iter([(top.clone(), subtree)]));
            let shown = match &step { Step::Index(_) => format!("{base}/0"), Step::Key(_) => original.clone() };
            let mut found = Vec::new();
            schema_errors(&part, budget, &mut found);
            for (path, what) in found {
                let Some(rest) = path.strip_prefix(shown.as_str()).filter(|rest| rest.is_empty() || rest.starts_with('/')) else { continue };
                out.push((format!("{original}{rest}"), what));
            }
        }
    }
}

/// A Russian schema message: the place (the path) and what is wrong. Values
/// and unexpected keys of the checked template are never quoted (a template
/// may hold secrets, also as mis-indented keys); the place is the path of
/// keys the problem is at.
fn schema_message(what: &str, path: &str) -> String {
    let place = if path.is_empty() {
        "Конфиг".to_owned()
    } else {
        format!("«{}»", path[1..].replace("~1", "/").replace("~0", "~"))
    };
    format!("{place}: {what}.").chars().take(MESSAGE_CHARS).collect()
}

fn schema_what(kind: &ValidationErrorKind) -> String {
    match kind {
        ValidationErrorKind::Type { kind } => format!("ожидается {}", match kind {
            TypeKind::Single(single) => type_name(*single).to_owned(),
            TypeKind::Multiple(set) => set.iter().map(type_name).collect::<Vec<_>>().join(" или "),
        }),
        ValidationErrorKind::Enum { options } => format!("допустимые значения: {}", values(options)),
        ValidationErrorKind::Constant { expected_value } => format!("ожидается {}", values(expected_value)),
        ValidationErrorKind::Required { property } => format!("нет обязательного ключа «{}»", property.as_str().unwrap_or("?")),
        ValidationErrorKind::AdditionalProperties { unexpected } | ValidationErrorKind::UnevaluatedProperties { unexpected } =>
            format!("неизвестных ключей: {}", unexpected.len()),
        ValidationErrorKind::AnyOf { .. } | ValidationErrorKind::OneOfNotValid { .. } =>
            "значение не подходит ни под один допустимый вариант".to_owned(),
        ValidationErrorKind::OneOfMultipleValid { .. } => "значение подходит сразу под несколько вариантов".to_owned(),
        ValidationErrorKind::Minimum { limit } => format!("значение меньше {limit}"),
        ValidationErrorKind::Maximum { limit } => format!("значение больше {limit}"),
        ValidationErrorKind::ExclusiveMinimum { limit } => format!("значение должно быть больше {limit}"),
        ValidationErrorKind::ExclusiveMaximum { limit } => format!("значение должно быть меньше {limit}"),
        ValidationErrorKind::MinLength { limit } => format!("строка короче {limit} символов"),
        ValidationErrorKind::MaxLength { limit } => format!("строка длиннее {limit} символов"),
        ValidationErrorKind::MinItems { limit } => format!("в списке меньше {limit} элементов"),
        ValidationErrorKind::MaxItems { limit } => format!("в списке больше {limit} элементов"),
        ValidationErrorKind::MinProperties { limit } => format!("ключей меньше {limit}"),
        ValidationErrorKind::MaxProperties { limit } => format!("ключей больше {limit}"),
        ValidationErrorKind::Pattern { .. } | ValidationErrorKind::Format { .. } => "значение не соответствует формату".to_owned(),
        ValidationErrorKind::UniqueItems => "элементы списка повторяются".to_owned(),
        ValidationErrorKind::PropertyNames { .. } => "недопустимое имя ключа".to_owned(),
        ValidationErrorKind::FalseSchema => "ключ не допускается".to_owned(),
        _ => "значение не соответствует схеме mihomo".to_owned(),
    }
}

fn type_name(kind: JsonType) -> &'static str {
    match kind {
        JsonType::Null => "пустое значение",
        JsonType::Boolean => "true или false",
        JsonType::Integer => "целое число",
        JsonType::Number => "число",
        JsonType::String => "строка",
        JsonType::Array => "список",
        JsonType::Object => "словарь",
    }
}

/// Allowed schema values (not the checked ones): at most eight.
fn values(value: &Value) -> String {
    const SHOWN: usize = 8;
    let shown = |value: &Value| value.as_str().map_or_else(|| value.to_string(), |text| format!("«{text}»"));
    match value {
        Value::Array(items) => {
            let mut text = items.iter().take(SHOWN).map(shown).collect::<Vec<_>>().join(", ");
            if items.len() > SHOWN { text.push_str(", …"); }
            text
        }
        other => shown(other),
    }
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

/// `template check [--name T] [--file PATH]`: read-only. At least one is
/// given; with both the file content is checked and the name labels it.
pub fn command(session: &mut Session, invocation: &Invocation, input: &Input) -> Result<Value> {
    let name = invocation.value("name").filter(|name| !name.is_empty()).map(file_name);
    if let Some(name) = &name && !crate::validation::template_filename_valid(name) {
        return Err(templates::name_invalid());
    }
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
        assert_eq!(report.problems[0].message, "Маркер «GHOST»: группы с таким именем нет.");
        assert_eq!((report.errors, report.warnings), (1, 1));
        // A tag without a group is never generated: no variant for it.
        let tags: Vec<_> = report.variants.iter().map(|v| v.tag.as_deref()).collect();
        assert_eq!(tags, [None, Some("PC"), Some("ROUTER")]);
    }

    #[test]
    fn empty_tag_segments_are_invalid_and_never_a_variant() {
        for marker in ["PC//X", "PC/", "/PC"] {
            let content = format!("proxies:\n# --- {marker} ---\nmode: [\n# --- {marker} ---\n");
            let report = check(&content, &groups());
            let tags: Vec<_> = report.variants.iter().map(|v| v.tag.as_deref()).collect();
            assert_eq!(tags, [None, Some("PC")], "{marker}");
            // The variant without groups drops the block like any other.
            assert_eq!(report.variants[0].dropped, [(2, 4)], "{marker}");
            assert!(codes(&report).contains(&(2, "marker_invalid", None)), "{marker}: {:?}", report.problems);
            assert!(codes(&report).contains(&(3, "yaml", Some("PC"))), "{marker}: {:?}", report.problems);
        }
    }

    #[test]
    fn a_problem_of_several_variants_counts_once() {
        let report = check("proxies:\n# --- PC/MOBILE ---\nmode: [\n# --- PC/MOBILE ---\n", &groups());
        assert_eq!(codes(&report), [(3, "yaml", Some("PC")), (3, "yaml", Some("MOBILE"))]);
        assert_eq!((report.errors, report.warnings), (1, 0));
    }

    #[test]
    fn variants_are_limited() {
        let groups: Vec<String> = (0..100).map(|i| format!("G{i}")).collect();
        let content: String = std::iter::once("proxies:\n".to_owned())
            .chain(groups.iter().map(|g| format!("# --- {g} ---\nx{g}: 1\n# --- {g} ---\n"))).collect();
        let report = check(&content, &groups);
        assert_eq!(report.variants.len(), MAX_VARIANTS);
        assert_eq!(codes(&report).iter().filter(|(_, code, _)| *code == "variants_limit").count(), 1);
    }

    #[test]
    fn schema_messages_name_the_rule_not_the_value() {
        let secret = "s3cr3t-value";
        let content = format!("proxies:\nmode: {secret}\nallow-lan: {secret}\nproxy-groups:\n  - name: g\n    type: {secret}\n");
        let report = check(&content, &groups());
        assert_eq!(report.problems.len(), 3, "{:?}", report.problems);
        assert!(report.problems.iter().all(|p| p.code == "schema" && !p.message.contains(secret)), "{:?}", report.problems);
        assert!(report.problems.iter().all(|p| p.message.starts_with(&format!("«{}»", &p.path.as_deref().unwrap()[1..]))));
    }

    #[test]
    fn the_problem_budget_stops_the_check() {
        let content: String = std::iter::once("proxies:\nproxy-groups:\n".to_owned())
            .chain((0..PROBLEM_BUDGET + 5).map(|i| format!("  - {{name: g{i}, type: bogus}}\n"))).collect();
        let report = check(&content, &groups());
        assert!(report.truncated);
        assert!(codes(&report).iter().any(|(_, code, _)| *code == "check_limit"));
        assert!(report.warnings <= PROBLEM_BUDGET + 1, "{}", report.warnings);
    }

    #[test]
    fn a_large_list_is_validated_item_by_item_with_source_positions() {
        let bad = 437;
        let content: String = std::iter::once("proxies:\nproxy-groups:\n".to_owned())
            .chain((0..500).map(|i| format!("  - {{name: g{i}, type: {}, proxies: [DIRECT]}}\n", if i == bad { "bogus" } else { "select" })))
            .collect();
        let report = check(&content, &groups());
        let schema: Vec<_> = report.problems.iter().map(|p| (p.line, p.path.as_deref())).collect();
        let path = format!("/proxy-groups/{bad}");
        assert_eq!(schema, [(bad + 3, Some(path.as_str()))], "{:?}", report.problems);
        assert!(!report.truncated);
    }

    #[test]
    fn deep_nesting_is_a_yaml_error_before_any_recursion() {
        // Runs on a test thread (2 MiB stack, like the daemon's core thread).
        let deep = format!("proxies:\nx:\n  {}1\n", "- ".repeat(100_000));
        let report = check(&deep, &groups());
        assert_eq!(codes(&report), [(3, "yaml", None)], "{:?}", report.problems);
        let flow = format!("proxies:\nx: {}{}\n", "[".repeat(MAX_DEPTH - 2), "]".repeat(MAX_DEPTH - 2));
        assert!(check(&flow, &groups()).problems.iter().all(|p| p.code != "yaml"), "the limit itself is accepted");
        // Depth through aliases counts what they expand to.
        let inner = format!("{}1{}", "[".repeat(100), "]".repeat(100));
        let nested = format!("proxies:\na: &a {inner}\nb: {}*a{}\n", "[".repeat(60), "]".repeat(60));
        assert_eq!(codes(&check(&nested, &groups())), [(3, "yaml", None)], "the line of `b`");
    }

    #[test]
    fn anchors_aliases_and_merge_keys_are_expanded() {
        let content = "proxies:\nx-group: &group {name: g, type: select, proxies: [DIRECT]}\nx-groups: &groups [*group]\n\
            proxy-groups: *groups\nx-flag: &flag true\nx-dns: &dns {enable: true, ipv6: false}\ndns:\n  <<: *dns\n  listen: 0.0.0.0:53\nallow-lan: *flag\n";
        let report = check(content, &groups());
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        // A billion laughs is stopped by the loader's node budget, quickly.
        let mut laughs = vec!["proxies:".to_owned(), "a0: &a0 [lol,lol,lol,lol,lol,lol,lol,lol,lol,lol]".to_owned()];
        laughs.extend((1..9).map(|i| format!("a{i}: &a{i} [{}]", vec![format!("*a{}", i - 1); 10].join(","))));
        let started = std::time::Instant::now();
        let report = check(&(laughs.join("\n") + "\n"), &groups());
        assert_eq!(report.problems.iter().map(|p| p.code).collect::<Vec<_>>(), ["yaml"]);
        assert!(started.elapsed().as_secs() < 5);
    }

    #[test]
    fn unexpected_keys_are_counted_not_quoted() {
        let kind = ValidationErrorKind::AdditionalProperties { unexpected: vec!["hunter2".into(), "x".into()] };
        let message = schema_message(&schema_what(&kind), "/dns");
        assert!(!message.contains("hunter2") && message.contains('2'), "{message}");
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
        // With both, the input is checked and the name only labels the result.
        let both = command(&mut session, &invocation(&["template", "check", "--name", "default"]), &input).unwrap();
        assert_eq!((both["name"].clone(), both["errors"].clone()), (json!("default.yaml"), json!(1)));
        assert_eq!(fingerprint(root.path()), before);
    }
}
