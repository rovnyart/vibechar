//! A small, bounded recipe language. Model output is data, never executable code.
use crate::{session::Session, TextEdit};
use serde::{
    de::{self, MapAccess, Visitor},
    Deserialize, Deserializer, Serialize,
};
use serde_json::{value::RawValue, Value};
use std::{collections::BTreeMap, fmt, ops::Range, sync::mpsc, thread};

pub const MAX_SOURCE: usize = 256 * 1024;
pub const MAX_OUTPUT: usize = 1024 * 1024;
pub const MAX_EXAMPLE: usize = 4096;
pub const MAX_RULE: usize = 16 * 1024;
const MAX_ROW: usize = 16 * 1024;
const MAX_ROWS: usize = 4096;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Input {
    Line,
    Delimited,
    Json,
    Env,
    Unsupported,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    Text,
    Json,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Case {
    Keep,
    Upper,
    Lower,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Encoding {
    Text,
    Json,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Part {
    pub field: String,
    pub casing: Case,
    pub trim: bool,
    pub encoding: Encoding,
    pub prefix: String,
    pub suffix: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Recipe {
    pub version: u32,
    pub input: Input,
    pub delimiter: String,
    pub format: Format,
    pub parts: Vec<Part>,
}

// Preserve JSON scalar lexemes, including huge numbers, and reject duplicate keys.
struct JsonFields(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for JsonFields {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct FieldsVisitor;
        impl<'de> Visitor<'de> for FieldsVisitor {
            type Value = JsonFields;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object with distinct fields")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut fields = BTreeMap::new();
                while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    if fields.len() >= 64 || fields.insert(key, value).is_some() {
                        return Err(de::Error::custom("ambiguous or oversized object"));
                    }
                }
                Ok(JsonFields(fields))
            }
        }
        deserializer.deserialize_map(FieldsVisitor)
    }
}
struct Field {
    text: String,
    json: String,
    string: bool,
}
impl Field {
    fn string(text: String) -> Self {
        Self {
            json: serde_json::to_string(&text).unwrap(),
            text,
            string: true,
        }
    }
    fn raw(value: &RawValue) -> Result<Self, &'static str> {
        let raw = value.get();
        if raw.starts_with('"') {
            Ok(Self {
                text: serde_json::from_str(raw).map_err(|_| "Unreadable JSON string")?,
                json: raw.into(),
                string: true,
            })
        } else if raw.starts_with(['{', '[']) {
            Err("Nested objects/arrays need a different rule")
        } else {
            Ok(Self {
                text: raw.into(),
                json: raw.into(),
                string: false,
            })
        }
    }
}

impl Recipe {
    pub fn parse(json: &str) -> Result<Self, &'static str> {
        if json.len() > MAX_RULE {
            return Err("The proposed rule is too large.");
        }
        let recipe: Self =
            serde_json::from_str(json).map_err(|_| "The model returned an invalid rule.")?;
        if recipe.version != 1 {
            return Err("Unsupported recipe version.");
        }
        if recipe.input == Input::Unsupported {
            return Err("This example needs more than a structural rule. Try Rewrite Selection.");
        }
        if recipe.parts.is_empty() || recipe.parts.len() > 12 {
            return Err("Use a rule with 1–12 field parts.");
        }
        if recipe.input == Input::Delimited {
            if recipe.delimiter.is_empty()
                || recipe.delimiter.len() > 16
                || recipe.delimiter.contains(['\r', '\n'])
            {
                return Err("Invalid delimiter in the proposed rule.");
            }
        } else if !recipe.delimiter.is_empty() {
            return Err("Only delimited input accepts a delimiter.");
        }
        for part in &recipe.parts {
            if part.field.is_empty()
                || part.field.len() > 128
                || part.prefix.len() > 256
                || part.suffix.len() > 256
                || part.prefix.contains(['\r', '\n'])
                || part.suffix.contains(['\r', '\n'])
            {
                return Err("The rule exceeds the supported per-row format.");
            }
            if recipe.format == Format::Json && part.encoding != Encoding::Json {
                return Err("JSON output must preserve field types. Text-to-number guessing is unsupported.");
            }
        }
        Ok(recipe)
    }
    fn fields(&self, row: &str) -> Result<BTreeMap<String, Field>, &'static str> {
        if row.len() > MAX_ROW {
            return Err("Row exceeds 16 KiB");
        }
        let mut fields = BTreeMap::new();
        match self.input {
            Input::Line => {
                fields.insert("$".into(), Field::string(row.into()));
            }
            Input::Delimited => {
                let values: Vec<_> = row.split(&self.delimiter).take(65).collect();
                if values.len() > 64 {
                    return Err("Too many delimited fields");
                }
                for (index, value) in values.iter().enumerate() {
                    fields.insert(index.to_string(), Field::string((*value).into()));
                }
                fields.insert(
                    "last".into(),
                    Field::string(values.last().unwrap().to_string()),
                );
            }
            Input::Env => {
                let (key, value) = row.split_once('=').ok_or("Not a key=value row")?;
                let key = key.trim();
                if key.is_empty()
                    || !key.bytes().enumerate().all(|(i, b)| {
                        b == b'_' || b.is_ascii_alphabetic() || i > 0 && b.is_ascii_digit()
                    })
                {
                    return Err("Not an environment key");
                }
                fields.insert("key".into(), Field::string(key.into()));
                fields.insert("value".into(), Field::string(value.into()));
            }
            Input::Json => {
                let object: JsonFields = serde_json::from_str(row)
                    .map_err(|_| "Not a flat JSON object with distinct keys")?;
                for (key, value) in object.0 {
                    if let Ok(value) = Field::raw(&value) {
                        fields.insert(
                            format!("/{}", key.replace('~', "~0").replace('/', "~1")),
                            value,
                        );
                    }
                }
            }
            Input::Unsupported => return Err("Unsupported input"),
        }
        Ok(fields)
    }
    pub fn render(&self, row: &str) -> Result<String, &'static str> {
        let fields = self.fields(row)?;
        let mut output = String::new();
        for part in &self.parts {
            let field = fields
                .get(&part.field)
                .ok_or("A required field is missing or unsupported")?;
            if !field.string && (part.trim || part.casing != Case::Keep) {
                return Err("Type conversion is ambiguous");
            }
            let text = if part.trim {
                field.text.trim()
            } else {
                &field.text
            };
            let text = match part.casing {
                Case::Keep => text.into(),
                Case::Lower => text.to_lowercase(),
                Case::Upper => text.to_uppercase(),
            };
            let value = if part.encoding == Encoding::Text {
                text
            } else if !part.trim && part.casing == Case::Keep {
                field.json.clone()
            } else {
                serde_json::to_string(&text).unwrap()
            };
            if output.len() + part.prefix.len() + value.len() + part.suffix.len() > MAX_ROW {
                return Err("Result row exceeds 16 KiB");
            }
            output.push_str(&part.prefix);
            output.push_str(&value);
            output.push_str(&part.suffix);
        }
        if output.contains(['\r', '\n']) {
            return Err("Multiline output is unsupported in this pass");
        }
        if self.format == Format::Json && serde_json::from_str::<de::IgnoredAny>(&output).is_err() {
            return Err("The output is not valid JSON");
        }
        if self.format == Format::Json
            && output.trim_start().starts_with('{')
            && serde_json::from_str::<JsonFields>(&output).is_err()
        {
            return Err("JSON output has ambiguous or too many keys");
        }
        Ok(output)
    }
    pub fn validate_example(&self, before: &str, after: &str) -> Result<(), &'static str> {
        if after.is_empty()
            || after.len() > MAX_EXAMPLE
            || after.contains(['\r', '\n'])
            || before == after
        {
            return Err("Change one nonempty example row first (up to 4 KiB).");
        }
        if self
            .render(before)
            .map_err(|_| "The rule cannot read this example.")?
            != after
        {
            return Err("The rule doesn't reproduce your example exactly. Nothing was applied.");
        }
        if self.format != Format::Json
            && after.trim_start().starts_with(['{', '['])
            && serde_json::from_str::<de::IgnoredAny>(after).is_ok()
        {
            return Err(
                "Structured JSON output must use typed JSON fields, without guessed conversions.",
            );
        }
        // Catch obvious partial memorization: unreferenced example fields in literals.
        let fields = self.fields(before).map_err(|_| "Unsupported example.")?;
        for value in fields.values() {
            if self
                .parts
                .iter()
                .filter_map(|p| fields.get(&p.field))
                .any(|v| v.text.trim() == value.text.trim())
                || value.text.trim().len() < 2
            {
                continue;
            }
            if self.parts.iter().any(|p| {
                p.prefix.contains(value.text.trim()) || p.suffix.contains(value.text.trim())
            }) {
                return Err("The rule hardcodes an example field. Show a more specific example.");
            }
        }
        Ok(())
    }
    pub fn summary(&self) -> String {
        let input = match self.input {
            Input::Line => "Whole row",
            Input::Delimited => "Delimited fields",
            Input::Json => "JSON fields",
            Input::Env => "Environment fields",
            Input::Unsupported => "Unsupported",
        };
        let fields: Vec<_> = self.parts.iter().map(|p| p.field.as_str()).collect();
        format!(
            "{input} {} → {}",
            fields.join(", "),
            if self.format == Format::Json {
                "JSON"
            } else {
                "text"
            }
        )
    }
    pub fn explain(&self) -> String {
        let mut text = self.summary() + "\n\n";
        if self.input == Input::Delimited {
            text.push_str(&format!("Split each row on {:?}.\n\n", self.delimiter));
        }
        for (index, part) in self.parts.iter().enumerate() {
            text.push_str(&format!(
                "{}. Read {}\n   {} · {}{}\n",
                index + 1,
                part.field,
                match part.casing {
                    Case::Keep => "Keep case",
                    Case::Lower => "Lowercase",
                    Case::Upper => "Uppercase",
                },
                if part.encoding == Encoding::Json {
                    "preserve JSON type"
                } else {
                    "plain text"
                },
                if part.trim {
                    " · trim outer whitespace"
                } else {
                    ""
                }
            ));
            if !part.prefix.is_empty() {
                text.push_str(&format!("   Add before: {:?}\n", part.prefix));
            }
            if !part.suffix.is_empty() {
                text.push_str(&format!("   Add after: {:?}\n", part.suffix));
            }
            text.push('\n');
        }
        text.push_str(
            "Join these parts for each row. Check Skipped for rows the rule couldn't process.",
        );
        text
    }
}

#[derive(Clone)]
pub struct Capture {
    document: u64,
    revision: u64,
    range: Range<usize>,
    source: String,
    pub before: String,
    pub example_line: usize,
    pub records: usize,
    replay: bool,
}
fn rows(source: &str) -> impl Iterator<Item = (&str, &str)> {
    source.split_inclusive('\n').map(|row| {
        if let Some(row) = row.strip_suffix("\r\n") {
            (row, "\r\n")
        } else if let Some(row) = row.strip_suffix('\n') {
            (row, "\n")
        } else {
            (row, "")
        }
    })
}
impl Capture {
    pub fn new(session: &Session, range: Range<usize>) -> Result<Self, &'static str> {
        Self::from_selection(session, range, false)
    }
    pub fn for_replay(session: &Session, range: Range<usize>) -> Result<Self, &'static str> {
        Self::from_selection(session, range, true)
    }
    fn from_selection(
        session: &Session,
        range: Range<usize>,
        replay: bool,
    ) -> Result<Self, &'static str> {
        if session.active().is_private() {
            return Err("Private tabs cannot use saved recipes or teach AI examples.");
        }
        let doc = &session.active().document;
        if range.is_empty() || range.start > range.end || range.end > doc.len_chars() {
            return Err("Select complete lines.");
        }
        let text = doc.checkpoint_text();
        if range.start > 0 && text.char(range.start - 1) != '\n' {
            return Err("Start the selection at a line boundary.");
        }
        if range.end < text.len_chars()
            && text.char(range.end - 1) != '\n'
            && text.char(range.end) != '\n'
            && text.char(range.end) != '\r'
        {
            return Err("Select complete lines through the final record.");
        }
        if range.end < text.len_chars()
            && text.char(range.end - 1) == '\r'
            && text.char(range.end) == '\n'
        {
            return Err("Don't split a CRLF line ending.");
        }
        if text.slice(range.clone()).len_bytes() > MAX_SOURCE {
            return Err("Select up to 256 KiB for Do the Rest.");
        }
        let source = text.slice(range.clone()).to_string();
        let all: Vec<_> = rows(&source).collect();
        if all.len() > MAX_ROWS {
            return Err("Select up to 4,096 lines.");
        }
        let nonblank: Vec<_> = all
            .iter()
            .enumerate()
            .filter(|(_, r)| !r.0.trim().is_empty())
            .collect();
        if nonblank.is_empty() || !replay && nonblank.len() < 2 {
            if replay {
                return Err("Select at least one nonblank row.");
            }
            return Err("Select at least two nonblank rows: an example and the rest.");
        }
        let (example_line, first) = nonblank[0];
        if !replay && first.0.len() > MAX_EXAMPLE {
            return Err("Use an example row up to 4 KiB.");
        }
        let before = first.0.to_owned();
        let records = nonblank.len();
        Ok(Self {
            document: doc.id(),
            revision: doc.revision(),
            range,
            source,
            before,
            example_line: example_line + 1,
            records,
            replay,
        })
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn is_current(&self, session: &Session) -> bool {
        !session.active().is_private()
            && session.active().document.id() == self.document
            && session.active().document.revision() == self.revision
    }
    pub fn plan(&self, recipe: Recipe, after: &str) -> Result<Plan, &'static str> {
        recipe.validate_example(&self.before, after)?;
        self.plan_rows(recipe)
    }
    fn plan_rows(&self, recipe: Recipe) -> Result<Plan, &'static str> {
        let mut result = String::new();
        let mut stats = Stats::default();
        for (index, (row, ending)) in rows(&self.source).enumerate() {
            if row.trim().is_empty() {
                stats.blank += 1;
                result.push_str(row);
            } else {
                match recipe.render(row) {
                    Ok(output) => {
                        stats.matched += 1;
                        if output != row {
                            stats.changed += 1;
                        };
                        result.push_str(&output);
                    }
                    Err(reason) => {
                        stats.skipped += 1;
                        if stats.issues.len() < 8 {
                            stats.issues.push(Issue {
                                line: index + 1,
                                reason,
                            });
                        }
                        result.push_str(row);
                    }
                }
            }
            result.push_str(ending);
            if result.len() > MAX_OUTPUT {
                return Err("Result exceeds 1 MiB. Select fewer rows.");
            }
        }
        Ok(Plan {
            capture: self.clone(),
            recipe,
            result,
            stats,
        })
    }
}
#[derive(Default, Serialize)]
pub struct Stats {
    pub matched: usize,
    pub changed: usize,
    pub skipped: usize,
    pub blank: usize,
    pub issues: Vec<Issue>,
}
#[derive(Serialize)]
pub struct Issue {
    pub line: usize,
    pub reason: &'static str,
}
pub struct Plan {
    capture: Capture,
    pub recipe: Recipe,
    pub result: String,
    pub stats: Stats,
}
impl Plan {
    pub fn apply(&self, session: &mut Session) -> Result<(bool, Range<usize>), &'static str> {
        if !self.capture.is_current(session) {
            return Err("Text changed. Select the rows again to make a new preview.");
        }
        if self.stats.matched < if self.capture.replay { 1 } else { 2 } {
            return Err(if self.capture.replay {
                "The rule did not match any selected rows."
            } else {
                "The rule must match at least one row beyond the example."
            });
        }
        let start = self.capture.range.start;
        let changed = session
            .active_mut()
            .document
            .replace_many(&[TextEdit {
                range: self.capture.range.clone(),
                text: self.result.clone(),
            }])
            .map_err(|_| "The target is no longer available.")?;
        Ok((changed, start..start + self.result.chars().count()))
    }
}
pub struct Job {
    receiver: mpsc::Receiver<Result<Plan, &'static str>>,
    result: Option<Result<Plan, &'static str>>,
}
impl Job {
    pub fn start(capture: Capture, json: String, after: String) -> Result<Self, &'static str> {
        Self::spawn(capture, json, Some(after))
    }
    pub fn replay(capture: Capture, json: String) -> Result<Self, &'static str> {
        if !capture.replay {
            return Err("Capture a selection for saved recipe replay first.");
        }
        Self::spawn(capture, json, None)
    }
    fn spawn(capture: Capture, json: String, after: Option<String>) -> Result<Self, &'static str> {
        let (sender, receiver) = mpsc::sync_channel(1);
        thread::Builder::new()
            .name("vibechar-recipe".into())
            .spawn(move || {
                let plan = Recipe::parse(&json).and_then(|recipe| match after {
                    Some(after) => capture.plan(recipe, &after),
                    None => capture.plan_rows(recipe),
                });
                let _ = sender.send(plan);
            })
            .map_err(|_| "Couldn't start the local recipe worker.")?;
        Ok(Self {
            receiver,
            result: None,
        })
    }
    pub fn poll(&mut self) -> Option<&Result<Plan, &'static str>> {
        if self.result.is_none() {
            self.result = match self.receiver.try_recv() {
                Ok(r) => Some(r),
                Err(mpsc::TryRecvError::Empty) => None,
                Err(_) => Some(Err("The local recipe worker stopped.")),
            };
        }
        self.result.as_ref()
    }
    pub fn take(&mut self) -> Option<Result<Plan, &'static str>> {
        self.poll();
        self.result.take()
    }
}

/// Single schema for the provider, validation fixtures and future versioned storage.
pub fn schema() -> Value {
    fn object(properties: Value) -> Value {
        let required: Vec<_> = properties.as_object().unwrap().keys().cloned().collect();
        serde_json::json!({"type":"object","properties":properties,"required":required,"additionalProperties":false})
    }
    let part = object(serde_json::json!({
        "field":{"type":"string"},"casing":{"type":"string","enum":["keep","upper","lower"]},
        "trim":{"type":"boolean"},"encoding":{"type":"string","enum":["text","json"]},
        "prefix":{"type":"string"},"suffix":{"type":"string"}
    }));
    object(serde_json::json!({
        "version":{"type":"integer","enum":[1]},"input":{"type":"string","enum":["line","delimited","json","env","unsupported"]},
        "delimiter":{"type":"string"},"format":{"type":"string","enum":["text","json"]},"parts":{"type":"array","items":part}
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn part(field: &str, prefix: &str, suffix: &str) -> Part {
        Part {
            field: field.into(),
            casing: Case::Keep,
            trim: false,
            encoding: Encoding::Text,
            prefix: prefix.into(),
            suffix: suffix.into(),
        }
    }
    fn recipe(input: Input, delimiter: &str, parts: Vec<Part>) -> Recipe {
        Recipe {
            version: 1,
            input,
            delimiter: delimiter.into(),
            format: Format::Text,
            parts,
        }
    }
    fn check(recipe: Recipe, before: &str, after: &str, unseen: &str, expected: &str) {
        let recipe = Recipe::parse(&serde_json::to_string(&recipe).unwrap()).unwrap();
        recipe.validate_example(before, after).unwrap();
        assert_eq!(recipe.render(unseen).unwrap(), expected);
    }
    #[test]
    fn ten_structural_examples_generalize_to_unseen_records() {
        check(
            recipe(
                Input::Line,
                "",
                vec![part("$", "https://example.com/u/", "")],
            ),
            "42",
            "https://example.com/u/42",
            "007",
            "https://example.com/u/007",
        );
        let mut p = part("$", "", "");
        p.casing = Case::Upper;
        check(
            recipe(Input::Line, "", vec![p]),
            "hello",
            "HELLO",
            "straße",
            "STRASSE",
        );
        let mut p = part("$", "", "");
        p.casing = Case::Lower;
        check(
            recipe(Input::Line, "", vec![p]),
            "HELLO",
            "hello",
            "ΟΣ",
            "ος",
        );
        let mut p = part("$", "", "");
        p.trim = true;
        check(recipe(Input::Line, "", vec![p]), " a ", "a", "\tβ  ", "β");
        check(
            recipe(
                Input::Delimited,
                "|",
                vec![part("0", "- ", " <"), part("1", "", ">")],
            ),
            "Ada|a@x",
            "- Ada <a@x>",
            "Bob|b@y",
            "- Bob <b@y>",
        );
        check(
            recipe(
                Input::Delimited,
                ",",
                vec![part("0", "", ";"), part("1", "", ";"), part("2", "", "")],
            ),
            "a,b,c",
            "a;b;c",
            "x,y,z",
            "x;y;z",
        );
        check(
            recipe(
                Input::Json,
                "",
                vec![
                    part("/name", "", " — https://example.com/u/"),
                    part("/id", "", ""),
                ],
            ),
            r#"{"id":42,"name":"Anna"}"#,
            "Anna — https://example.com/u/42",
            r#"{"id":900719925474099312345,"name":"Боб"}"#,
            "Боб — https://example.com/u/900719925474099312345",
        );
        let mut p = part("/n", "", "");
        p.encoding = Encoding::Json;
        let mut r = recipe(Input::Json, "", vec![p]);
        r.format = Format::Json;
        check(
            r,
            r#"{"n":1e400}"#,
            "1e400",
            r#"{"n":900719925474099312345}"#,
            "900719925474099312345",
        );
        let (mut a, mut b) = (part("key", "{", ":"), part("value", "", "}"));
        a.encoding = Encoding::Json;
        b.encoding = Encoding::Json;
        let mut r = recipe(Input::Env, "", vec![a, b]);
        r.format = Format::Json;
        check(
            r,
            "COUNT=001",
            r#"{"COUNT":"001"}"#,
            "OTHER=a=b",
            r#"{"OTHER":"a=b"}"#,
        );
        let mut p = part("$", "", "");
        p.encoding = Encoding::Json;
        let mut r = recipe(Input::Line, "", vec![p]);
        r.format = Format::Json;
        check(r, "a", r#""a""#, "Bob \"B\"", r#""Bob \"B\"""#);
        check(
            recipe(Input::Delimited, "/", vec![part("last", "", "")]),
            "a/b/c",
            "c",
            "x/y",
            "y",
        );
    }
    #[test]
    fn ambiguous_types_constants_duplicates_and_unknown_fields_are_rejected() {
        let mut p = part("value", "{\"n\":", "}");
        p.encoding = Encoding::Text;
        let r = recipe(Input::Env, "", vec![p]);
        assert!(r.validate_example("X=001", "{\"n\":001}").is_ok()); // Text output is not misrepresented as valid JSON.
        assert!(r.validate_example("X=42", "{\"n\":42}").is_err());
        let r = recipe(Input::Json, "", vec![part("/name", "", " /42")]);
        assert!(r
            .validate_example(r#"{"name":"Anna","id":42}"#, "Anna /42")
            .is_err());
        assert!(r.render(r#"{"name":"A","name":"B"}"#).is_err());
        assert!(Recipe::parse(
            r#"{"version":1,"input":"unsupported","delimiter":"","format":"text","parts":[]}"#
        )
        .is_err());
        assert!(Recipe::parse(
            r#"{"version":99,"input":"line","delimiter":"","format":"text","parts":[]}"#
        )
        .is_err());
        assert!(Recipe::parse(
            r#"{"version":1,"input":"line","delimiter":"","format":"text","parts":[],"code":"run"}"#
        )
        .is_err());
        let mut r = recipe(Input::Line, "", vec![part("$", "", "")]);
        r.format = Format::Json;
        assert!(Recipe::parse(&serde_json::to_string(&r).unwrap()).is_err());
    }
    #[test]
    fn batch_keeps_skips_blanks_endings_and_outside_bytes_and_undoes_once() {
        let source = "outside\n{\"id\":1}\r\nnot json\n\r\n{\"id\":2}\nend";
        let mut session = Session::new(source, None);
        let from = source.find('{').unwrap();
        let to = source.rfind("end").unwrap();
        let capture = Capture::new(&session, from..to).unwrap();
        let rule = recipe(Input::Json, "", vec![part("/id", "u", "")]);
        let plan = capture.plan(rule, "u1").unwrap();
        assert_eq!(
            (
                plan.stats.matched,
                plan.stats.changed,
                plan.stats.skipped,
                plan.stats.blank
            ),
            (2, 2, 1, 1)
        );
        assert_eq!(plan.stats.issues[0].line, 2);
        plan.apply(&mut session).unwrap();
        assert_eq!(
            session.active().document.text(),
            "outside\nu1\r\nnot json\n\r\nu2\nend"
        );
        assert!(plan.apply(&mut session).is_err());
        session.active_mut().document.undo().unwrap();
        assert_eq!(session.active().document.text(), source);
        assert!(!capture.is_current(&session));
    }
    #[test]
    fn privacy_stale_partial_lines_and_limits_fail_before_mutation() {
        let mut session = Session::new("one\ntwo\n", None);
        assert!(Capture::new(&session, 1..8).is_err());
        assert!(Capture::new(&session, 0..2).is_err());
        let capture = Capture::new(&session, 0..8).unwrap();
        assert_eq!((capture.before.as_str(), capture.records), ("one", 2));
        assert!(capture
            .plan(recipe(Input::Line, "", vec![part("$", "", "")]), "one")
            .is_err());
        session.open_private();
        assert!(Capture::new(&session, 0..1).is_err());
        assert!(!capture.is_current(&session));
        let source = format!("a\n{}", "b".repeat(MAX_SOURCE));
        let session = Session::new(&source, None);
        assert!(Capture::new(&session, 0..source.len()).is_err());
        let session = Session::new("x\r\ny\r\n", None);
        assert!(Capture::new(&session, 0..2).is_err());
    }
    #[test]
    fn schema_and_worker_use_the_same_validated_language() {
        assert_eq!(schema()["additionalProperties"], false);
        let session = Session::new("one\ntwo", None);
        let capture = Capture::new(&session, 0..7).unwrap();
        let rule = recipe(Input::Line, "", vec![part("$", "- ", "")]);
        let mut job = Job::start(
            capture,
            serde_json::to_string(&rule).unwrap(),
            "- one".into(),
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while job.poll().is_none() {
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(job.take().unwrap().unwrap().result, "- one\n- two");
    }
    #[test]
    fn delimiter_aliases_do_not_look_like_hardcoded_values() {
        let r = recipe(
            Input::Delimited,
            "|",
            vec![part("1", "https://example.com/", "")],
        );
        r.validate_example("name|com", "https://example.com/com")
            .unwrap();
        assert_eq!(r.render("other|net").unwrap(), "https://example.com/net");
    }
    #[test]
    fn no_other_match_and_excessive_results_cannot_apply() {
        let mut session = Session::new("{\"id\":1}\ninvalid", None);
        let capture = Capture::new(&session, 0..session.active().document.len_chars()).unwrap();
        let plan = capture
            .plan(recipe(Input::Json, "", vec![part("/id", "u", "")]), "u1")
            .unwrap();
        assert_eq!(plan.stats.matched, 1);
        assert!(plan.apply(&mut session).is_err());
        let source = std::iter::repeat_n("a".repeat(1000), 1000)
            .collect::<Vec<_>>()
            .join("\n");
        let session = Session::new(&source, None);
        assert!(Capture::new(&session, 0..source.len()).is_err());
        let source = std::iter::repeat_n("a".repeat(100), 2000)
            .collect::<Vec<_>>()
            .join("\n");
        let session = Session::new(&source, None);
        let capture = Capture::new(&session, 0..source.len()).unwrap();
        let r = recipe(
            Input::Line,
            "",
            vec![part("$", &"x".repeat(256), &"y".repeat(256))],
        );
        assert!(capture
            .plan(
                r,
                &format!("{}{}{}", "x".repeat(256), "a".repeat(100), "y".repeat(256))
            )
            .is_err());
    }
    #[test]
    fn saved_replay_accepts_one_row_and_skips_an_unmatched_first_row() {
        let rule = recipe(Input::Json, "", vec![part("/id", "user/", "")]);
        let json = serde_json::to_string(&rule).unwrap();
        for (source, expected, skipped) in [
            (
                "{\"id\":900719925474099312345}",
                "user/900719925474099312345",
                0,
            ),
            ("invalid\r\n{\"id\":7}\r\n\n", "invalid\r\nuser/7\r\n\n", 1),
        ] {
            let mut session = Session::new(source, None);
            let capture = Capture::for_replay(&session, 0..source.chars().count()).unwrap();
            let mut job = Job::replay(capture, json.clone()).unwrap();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while job.poll().is_none() {
                assert!(std::time::Instant::now() < deadline);
                thread::sleep(std::time::Duration::from_millis(1));
            }
            let plan = job.take().unwrap().unwrap();
            assert_eq!((plan.stats.changed, plan.stats.skipped), (1, skipped));
            assert_eq!(plan.result, expected);
            plan.apply(&mut session).unwrap();
            session.active_mut().document.undo().unwrap();
            assert_eq!(session.active().document.text(), source);
            session.active_mut().document.redo().unwrap();
            assert_eq!(session.active().document.text(), expected);
        }
    }
    #[test]
    fn replay_keeps_privacy_staleness_limits_and_no_match_protection() {
        let mut session = Session::new("no match", None);
        let capture = Capture::for_replay(&session, 0..8).unwrap();
        let plan = capture
            .plan_rows(recipe(Input::Json, "", vec![part("/id", "u", "")]))
            .unwrap();
        assert_eq!(plan.stats.matched, 0);
        assert!(plan.apply(&mut session).is_err());
        let plan = capture
            .plan_rows(recipe(Input::Line, "", vec![part("$", "- ", "")]))
            .unwrap();
        session
            .active_mut()
            .document
            .replace_many(&[TextEdit {
                range: 0..0,
                text: "!".into(),
            }])
            .unwrap();
        assert!(plan.apply(&mut session).is_err());
        session.open_private();
        assert!(Capture::for_replay(&session, 0..1).is_err());
        let session = Session::new(" \n\t", None);
        assert!(Capture::for_replay(&session, 0..3).is_err());
        let session = Session::new("x\r\ny", None);
        assert!(Capture::for_replay(&session, 0..2).is_err());
        let source = "a".repeat(MAX_SOURCE + 1);
        let session = Session::new(&source, None);
        assert!(Capture::for_replay(&session, 0..source.len()).is_err());
        let source = "a".repeat(MAX_EXAMPLE + 1);
        let mut session = Session::new(&source, None);
        assert!(Capture::new(&session, 0..source.len()).is_err());
        let capture = Capture::for_replay(&session, 0..source.len()).unwrap();
        capture
            .plan_rows(recipe(Input::Line, "", vec![part("$", "- ", "")]))
            .unwrap()
            .apply(&mut session)
            .unwrap();
        assert_eq!(session.active().document.text(), format!("- {source}"));
    }
}
