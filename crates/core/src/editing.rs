//! Explicit indentation/newline commands shared by native and terminal input.
use crate::{multi::Selection, Document, TextEdit};
use std::collections::BTreeSet;

pub const TAB_WIDTH: usize = 4;
const MAX_LINES: usize = 100_000;
const MAX_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy)]
pub enum Action {
    Tab,
    Outdent,
    Newline,
}

pub struct Plan {
    pub edits: Vec<TextEdit>,
    pub selections: Vec<Selection>,
}

impl Document {
    pub fn editing_plan(&self, selections: &[Selection], action: Action) -> Result<Plan, String> {
        for s in selections {
            if s.anchor > self.len_chars() || s.head > self.len_chars() {
                return Err("Invalid editing selection".into());
            }
        }
        let mut edits = Vec::new();
        let block = matches!(action, Action::Outdent)
            || matches!(action, Action::Tab) && selections.iter().any(|s| !s.range().is_empty());
        if block {
            let mut lines = BTreeSet::new();
            for s in selections {
                let r = s.range();
                let first = self.line_index(r.start);
                let mut last = self.line_index(r.end);
                if !r.is_empty() && last > first && r.end == self.line_start(last) {
                    last -= 1;
                }
                if last - first >= MAX_LINES {
                    return Err("Indent up to 100,000 lines at once".into());
                }
                lines.extend(first..=last);
                if lines.len() > MAX_LINES {
                    return Err("Indent up to 100,000 lines at once".into());
                }
            }
            for line in lines {
                let start = self.line_start(line);
                let removed = if matches!(action, Action::Outdent) {
                    let mut chars = self.text.slice(self.line_range(line)).chars();
                    match chars.next() {
                        Some('\t') => 1,
                        Some(' ') => {
                            1 + chars.take(TAB_WIDTH - 1).take_while(|c| *c == ' ').count()
                        }
                        _ => 0,
                    }
                } else {
                    0
                };
                if removed > 0 || matches!(action, Action::Tab) {
                    edits.push(TextEdit {
                        range: start..start + removed,
                        text: if matches!(action, Action::Tab) {
                            " ".repeat(TAB_WIDTH)
                        } else {
                            String::new()
                        },
                    });
                }
            }
        } else {
            let mut bytes = 0;
            for s in selections {
                let range = s.range();
                let text = if matches!(action, Action::Newline) {
                    let mut text = self.newline().to_owned();
                    for c in self
                        .text
                        .slice(self.line_start(self.line_index(range.start))..range.start)
                        .chars()
                        .take_while(|c| matches!(c, ' ' | '\t'))
                    {
                        text.push(c);
                        if text.len() > MAX_BYTES {
                            return Err("Indentation exceeds 8 MiB".into());
                        }
                    }
                    text
                } else {
                    " ".repeat(TAB_WIDTH - self.display_column(range.start) % TAB_WIDTH)
                };
                bytes += text.len();
                if bytes > MAX_BYTES {
                    return Err("Indentation exceeds 8 MiB".into());
                }
                edits.push(TextEdit { range, text });
            }
        }
        let mut deltas = Vec::with_capacity(edits.len() + 1);
        deltas.push(0isize);
        let inserted = edits
            .iter()
            .map(|edit| edit.text.chars().count())
            .collect::<Vec<_>>();
        for (edit, count) in edits.iter().zip(&inserted) {
            deltas.push(deltas.last().unwrap() + *count as isize - edit.range.len() as isize);
        }
        let map = |position: usize| {
            let i = edits.partition_point(|edit| edit.range.end < position);
            if let Some(edit) = edits.get(i) {
                if edit.range.start <= position {
                    return edit.range.start.saturating_add_signed(deltas[i]) + inserted[i];
                }
            }
            position.saturating_add_signed(deltas[i])
        };
        let selections = selections
            .iter()
            .map(|s| {
                if block {
                    Selection {
                        anchor: map(s.anchor),
                        head: map(s.head),
                    }
                } else {
                    let at = map(s.range().end);
                    Selection {
                        anchor: at,
                        head: at,
                    }
                }
            })
            .collect();
        Ok(Plan { edits, selections })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn apply(d: &mut Document, ranges: &[(usize, usize)], action: Action) -> Vec<Selection> {
        let s = ranges
            .iter()
            .map(|&(anchor, head)| Selection { anchor, head })
            .collect::<Vec<_>>();
        let p = d.editing_plan(&s, action).unwrap();
        d.replace_many(&p.edits).unwrap();
        p.selections
    }
    #[test]
    fn block_selection_excludes_next_line_preserves_direction_and_one_undo() {
        let mut d = Document::new("я\r\n  b\r\nlast");
        let s = apply(&mut d, &[(8, 0)], Action::Tab);
        assert_eq!(d.text(), "    я\r\n      b\r\nlast");
        assert_eq!((s[0].anchor, s[0].head), (16, 4));
        d.undo();
        assert_eq!(d.text(), "я\r\n  b\r\nlast");
        assert!(!d.is_dirty());
        d.redo();
        apply(&mut d, &[(16, 4)], Action::Outdent);
        assert_eq!(d.text(), "я\r\n  b\r\nlast");
    }
    #[test]
    fn tabs_mixed_whitespace_multicaret_and_crlf_newline() {
        let mut d = Document::new("\t  я👩‍💻\r\n  last");
        let p = apply(&mut d, &[(7, 7), (15, 15)], Action::Newline);
        assert_eq!(d.text(), "\t  я👩‍💻\r\n\t  \r\n  last\r\n  ");
        assert_eq!(p.len(), 2);
        d.undo();
        assert!(!d.is_dirty());
        apply(&mut d, &[(1, 1), (3, 3)], Action::Outdent);
        assert_eq!(d.text(), "  я👩‍💻\r\n  last"); // Same line is deduplicated.
        d.undo();
        apply(&mut d, &[(1, 1)], Action::Tab);
        assert!(d.text().starts_with("\t      я"));
    }
    #[test]
    fn noop_outdent_does_not_revoke_access_or_enter_history() {
        let mut d = Document::new("foo");
        apply(&mut d, &[(0, 0)], Action::Outdent);
        assert_eq!(d.revision(), 0);
        assert!(d.undo().is_none());
        assert!(!d.is_dirty());
        assert!(d
            .editing_plan(&[Selection { anchor: 0, head: 4 }], Action::Tab)
            .is_err());
    }
}
