use super::*;
use std::{ops::Range, sync::Arc};
use vibechar_core::search::{Engine, Frame, Query, MAX_QUERY, MAX_REPLACEMENT};

#[derive(Default)]
pub struct Input {
    pub text: String,
    pub cursor: usize,
    pub all_selected: bool,
}
impl Input {
    fn range(&self) -> Range<usize> {
        if self.all_selected {
            0..self.text.len()
        } else {
            self.cursor..self.cursor
        }
    }
    pub(super) fn insert(&mut self, text: &str, max: usize) -> bool {
        let range = self.range();
        if self.text.len() - range.len() + text.len() > max {
            return false;
        }
        self.text.replace_range(range.clone(), text);
        self.cursor = range.start + text.len();
        self.all_selected = false;
        true
    }
    fn previous(&self) -> usize {
        self.text[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i)
    }
    fn next(&self) -> usize {
        self.text[self.cursor..]
            .graphemes(true)
            .next()
            .map_or(self.cursor, |s| self.cursor + s.len())
    }
    pub(super) fn key(&mut self, key: KeyCode) {
        match key {
            KeyCode::Home => {
                self.cursor = 0;
                self.all_selected = false;
            }
            KeyCode::End => {
                self.cursor = self.text.len();
                self.all_selected = false;
            }
            KeyCode::Left => {
                self.cursor = if self.all_selected {
                    0
                } else {
                    self.previous()
                };
                self.all_selected = false;
            }
            KeyCode::Right => {
                self.cursor = if self.all_selected {
                    self.text.len()
                } else {
                    self.next()
                };
                self.all_selected = false;
            }
            KeyCode::Backspace | KeyCode::Delete => {
                let range = if self.all_selected {
                    0..self.text.len()
                } else if key == KeyCode::Backspace {
                    self.previous()..self.cursor
                } else {
                    self.cursor..self.next()
                };
                self.text.replace_range(range.clone(), "");
                self.cursor = range.start;
                self.all_selected = false;
            }
            _ => {}
        }
    }
    pub fn display(&self) -> String {
        visible(&self.text)
    }
    pub fn column(&self) -> usize {
        display_width(&visible(&self.text[..self.cursor]))
    }
}
fn visible(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '\n' => '↵',
            '\r' => '␍',
            '\t' => '⇥',
            c if c.is_control() => '�',
            c => c,
        })
        .collect()
}
enum Action {
    Move(isize),
    One,
    Preview,
    SelectAll,
}
pub struct Find {
    engine: Engine,
    document: u64,
    revision: u64,
    origin: usize,
    pub needle: Input,
    pub replacement: Input,
    pub replacing: bool,
    pub replace_focus: bool,
    pub focused: bool,
    pub regex: bool,
    pub sensitive: bool,
    pub frame: Option<Arc<Frame>>,
    pub current: Option<usize>,
    pub preview: Option<u64>,
    pending: Option<Action>,
    pub notice: String,
    pub find_rect: Rect,
    pub replace_rect: Rect,
}
impl Find {
    pub fn status(&self) -> String {
        if !self.notice.is_empty() {
            return self.notice.clone();
        }
        let Some(frame) = &self.frame else {
            return "Searching…".into();
        };
        if let Some(error) = &frame.error {
            return error.clone();
        }
        if frame.limited {
            return "10,000+ matches · refine before replacing".into();
        }
        if self.needle.text.is_empty() {
            return "Find in this tab".into();
        }
        if frame.matches.is_empty() {
            "No matches".into()
        } else {
            format!(
                "{} / {}",
                self.current.unwrap_or(0) + 1,
                frame.matches.len()
            )
        }
    }
    fn input(&mut self) -> &mut Input {
        if self.replace_focus {
            &mut self.replacement
        } else {
            &mut self.needle
        }
    }
}

impl Editor {
    pub fn find_busy(&self) -> bool {
        self.find
            .as_ref()
            .is_some_and(|f| f.frame.is_none() || f.engine.busy())
    }
    fn open_find(&mut self, replacing: bool) {
        self.multi.clear();
        self.pointer = selection::Pointer::default();
        self.document_mut_break();
        if self.find.is_none() {
            let Ok(engine) = Engine::new() else {
                self.message = "Could not start search".into();
                return;
            };
            let range = self.selection();
            let seed = if range.len() <= 256 {
                self.document().text_range(range).unwrap_or_default()
            } else {
                String::new()
            };
            let mut needle = Input::default();
            if seed.len() <= MAX_QUERY {
                needle.cursor = seed.len();
                needle.text = seed;
                needle.all_selected = true;
            }
            self.find = Some(Find {
                engine,
                document: self.document().id(),
                revision: self.document().revision(),
                origin: self.selection().start,
                needle,
                replacement: Input::default(),
                replacing,
                replace_focus: false,
                focused: true,
                regex: false,
                sensitive: false,
                frame: None,
                current: None,
                preview: None,
                pending: None,
                notice: String::new(),
                find_rect: Rect::default(),
                replace_rect: Rect::default(),
            });
        }
        let find = self.find.as_mut().unwrap();
        find.focused = true;
        find.replace_focus = false;
        find.replacing |= replacing;
        find.needle.all_selected = true;
        self.submit_find();
    }
    fn document_mut_break(&mut self) {
        self.session.active_mut().document.break_undo_group();
    }
    fn submit_find(&mut self) {
        let origin = self.selection().start;
        let document = &self.session.active().document;
        let Some(find) = &mut self.find else {
            return;
        };
        find.origin = origin;
        find.revision = document.revision();
        find.frame = None;
        find.current = None;
        find.preview = None;
        find.pending = None;
        find.notice.clear();
        find.engine.submit(
            document,
            Query {
                needle: find.needle.text.clone(),
                replacement: find.replacing.then(|| find.replacement.text.clone()),
                regex: find.regex,
                case_sensitive: find.sensitive,
                whole_graphemes: false,
                whole_words: false,
            },
        );
    }
    pub fn pump_find(&mut self) -> bool {
        let before = self.selection_state();
        if self
            .find
            .as_ref()
            .is_some_and(|f| f.document != self.document().id())
        {
            self.find = None;
            return false;
        }
        if self
            .find
            .as_ref()
            .is_some_and(|f| f.revision != self.document().revision())
        {
            self.submit_find();
        }
        let document = &self.session.active().document;
        let mut select = None;
        let mut action = None;
        if let Some(find) = &mut self.find {
            if let Some(frame) = find
                .engine
                .frame(document, find.frame.as_ref().map_or(0, |f| f.serial))
            {
                find.current = frame
                    .matches
                    .iter()
                    .position(|h| h.start >= find.origin)
                    .or((!frame.matches.is_empty()).then_some(0));
                select = find
                    .current
                    .map(|i| frame.matches[i].start..frame.matches[i].end);
                find.frame = Some(frame);
                action = find.pending.take();
            }
        }
        if let Some(range) = select {
            self.anchor = Some(range.start);
            self.cursor = range.end;
            self.reveal_cursor = true;
        }
        if let Some(action) = action {
            self.find_action(action);
        }
        self.selection_state() != before
    }
    pub(super) fn find_insert(&mut self, text: &str) -> bool {
        let Some(find) = &mut self.find else {
            return false;
        };
        if !find.focused {
            return false;
        }
        let max = if find.replace_focus {
            MAX_REPLACEMENT
        } else {
            MAX_QUERY
        };
        if find.input().insert(text, max) {
            self.submit_find();
        } else {
            find.notice = format!("Field limit: {} bytes · input kept", max);
        }
        true
    }
    fn find_action(&mut self, action: Action) {
        let Some(find) = &mut self.find else {
            return;
        };
        let Some(frame) = &find.frame else {
            find.pending = Some(action);
            return;
        };
        match action {
            Action::SelectAll => {
                if frame.error.is_some() || frame.limited {
                    find.notice = "Refine Find before selecting matches".into();
                    return;
                }
                let ranges = frame
                    .matches
                    .iter()
                    .map(|hit| hit.start..hit.end)
                    .collect::<Vec<_>>();
                let primary = find.current.unwrap_or(0);
                match self
                    .multi
                    .adopt(&self.session.active().document, &ranges, primary)
                {
                    Ok(()) => {
                        self.find = None;
                        self.sync_multi();
                    }
                    Err(error) => self.find.as_mut().unwrap().notice = error,
                }
            }
            Action::Move(direction) => {
                if frame.matches.is_empty() {
                    return;
                }
                let count = frame.matches.len() as isize;
                let current =
                    (find.current.unwrap_or(0) as isize + direction).rem_euclid(count) as usize;
                find.current = Some(current);
                self.anchor = Some(frame.matches[current].start);
                self.cursor = frame.matches[current].end;
                self.reveal_cursor = true;
            }
            Action::Preview => {
                if find.replacing && frame.error.is_none() && !frame.limited && frame.changed > 0 {
                    find.preview = Some(frame.serial);
                }
            }
            Action::One => {
                let index = find.current;
                let serial = frame.serial;
                if let Some(index) = index {
                    self.apply_find(serial, Some(index));
                }
            }
        }
    }
    pub(super) fn select_find_matches(&mut self) {
        self.find_action(Action::SelectAll);
    }
    fn apply_find(&mut self, serial: u64, index: Option<usize>) {
        let Some(find) = &self.find else {
            return;
        };
        let result = find
            .engine
            .apply(&mut self.session.active_mut().document, serial, index);
        match result {
            Ok((changed, range)) => {
                self.anchor = Some(range.start);
                self.cursor = range.end;
                self.reveal_cursor = true;
                self.submit_find();
                let find = self.find.as_mut().unwrap();
                find.focused = false;
                find.origin = range.end;
                self.message = if changed {
                    "Replacement applied · Ctrl+Z undoes"
                } else {
                    "No text changed"
                }
                .into();
            }
            Err(error) => {
                self.message = error.into();
                self.submit_find();
            }
        }
    }
    pub(super) fn handle_find_key(&mut self, key: KeyEvent) -> bool {
        if self.save_prompt.is_some() || self.language_prompt.is_some() {
            return false;
        }
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        if control && matches!(key.code, KeyCode::Char('f' | 'r')) {
            self.open_find(key.code == KeyCode::Char('r'));
            return true;
        }
        let Some(find) = &mut self.find else {
            return false;
        };
        if key.code == KeyCode::Esc {
            if find.preview.take().is_none() {
                self.find = None;
            }
            return true;
        }
        if key.code == KeyCode::F(3) {
            self.find_action(Action::Move(
                if key.modifiers.contains(KeyModifiers::SHIFT) {
                    -1
                } else {
                    1
                },
            ));
            return true;
        }
        if key.code == KeyCode::F(5) {
            self.find_action(Action::Preview);
            return true;
        }
        if let Some(serial) = find.preview {
            if key.code == KeyCode::Enter {
                self.apply_find(serial, None);
                return true;
            }
            find.preview = None;
        }
        if !find.focused {
            return false;
        }
        if control
            && matches!(
                key.code,
                KeyCode::Char('q' | 'n' | 'p' | 'w' | 's' | 'd' | 'l')
            )
        {
            if key.code == KeyCode::Char('s') {
                find.focused = false;
            }
            return false;
        }
        if control && key.code == KeyCode::Char('v')
            || key.code == KeyCode::Insert && key.modifiers.contains(KeyModifiers::SHIFT)
        {
            self.paste_clipboard();
            return true;
        }
        if control {
            match key.code {
                KeyCode::Char('a') => find.input().all_selected = true,
                KeyCode::Char('c' | 'x') if find.input().all_selected => {
                    if crate::clipboard::copy(&find.input().text).is_ok() {
                        if key.code == KeyCode::Char('x') {
                            find.input().insert("", MAX_REPLACEMENT);
                            self.submit_find();
                        }
                    } else {
                        find.notice = "Clipboard unavailable · field kept".into();
                    }
                }
                _ => {}
            }
            return true;
        }
        if key.modifiers.contains(KeyModifiers::ALT) {
            match key.code {
                KeyCode::Char('c') => find.sensitive = !find.sensitive,
                KeyCode::Char('r') => find.regex = !find.regex,
                _ => return true,
            }
            self.submit_find();
            return true;
        }
        match key.code {
            KeyCode::Tab | KeyCode::BackTab => {
                find.replacing = true;
                find.replace_focus = !find.replace_focus;
                find.input().all_selected = true;
                self.submit_find();
            }
            KeyCode::Enter => {
                let action = if find.replace_focus {
                    Action::One
                } else {
                    Action::Move(if key.modifiers.contains(KeyModifiers::SHIFT) {
                        -1
                    } else {
                        1
                    })
                };
                self.find_action(action);
            }
            KeyCode::Char(ch) => {
                self.find_insert(&ch.to_string());
            }
            KeyCode::Backspace | KeyCode::Delete => {
                find.input().key(key.code);
                self.submit_find();
            }
            KeyCode::Home | KeyCode::End | KeyCode::Left | KeyCode::Right => {
                find.input().key(key.code)
            }
            _ => {}
        }
        true
    }
    pub(super) fn find_mouse(&mut self, event: MouseEvent) -> bool {
        let Some(find) = &mut self.find else {
            return false;
        };
        if event.kind == MouseEventKind::Down(MouseButton::Left) {
            if find.find_rect.contains((event.column, event.row).into())
                || find.replacing && find.replace_rect.contains((event.column, event.row).into())
            {
                find.focused = true;
                find.replace_focus = find.replace_rect.contains((event.column, event.row).into());
                find.input().cursor = find.input().text.len();
                find.input().all_selected = false;
                return true;
            }
            if self.viewport.contains((event.column, event.row).into()) {
                find.focused = false;
                find.preview = None;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        thread,
        time::{Duration, Instant},
    };
    fn press(e: &mut Editor, code: KeyCode, modifiers: KeyModifiers) {
        e.handle(KeyEvent::new(code, modifiers));
    }
    fn ready(e: &mut Editor) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            e.pump_find();
            if e.find.as_ref().is_some_and(|f| f.frame.is_some()) {
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn query_input_is_unicode_safe_and_never_edits_source() {
        let mut e = Editor::new("source", None);
        let revision = e.document().revision();
        press(&mut e, KeyCode::Char('f'), KeyModifiers::CONTROL);
        e.insert("a👩‍💻e\u{301}");
        press(&mut e, KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(e.find.as_ref().unwrap().needle.text, "a👩‍💻");
        press(&mut e, KeyCode::Left, KeyModifiers::NONE);
        e.insert("!");
        assert_eq!(e.find.as_ref().unwrap().needle.text, "a!👩‍💻");
        press(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "source");
        assert_eq!(e.document().revision(), revision);
    }
    #[test]
    fn find_wraps_and_queued_preview_applies_as_one_undo() {
        let mut e = Editor::new("one One one", None);
        press(&mut e, KeyCode::Char('r'), KeyModifiers::CONTROL);
        e.insert("one");
        ready(&mut e);
        assert_eq!(
            e.find
                .as_ref()
                .unwrap()
                .frame
                .as_ref()
                .unwrap()
                .matches
                .len(),
            3
        );
        press(&mut e, KeyCode::F(3), KeyModifiers::SHIFT);
        assert_eq!(e.selection(), 8..11);
        press(&mut e, KeyCode::Tab, KeyModifiers::NONE);
        e.insert("two");
        press(&mut e, KeyCode::F(5), KeyModifiers::NONE);
        ready(&mut e);
        assert!(e.find.as_ref().unwrap().preview.is_some());
        press(&mut e, KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(e.document().text(), "two two two");
        press(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "one One one");
    }
    #[test]
    fn editing_and_switching_tabs_invalidates_search_preview() {
        let mut e = Editor::new("one one", None);
        press(&mut e, KeyCode::Char('r'), KeyModifiers::CONTROL);
        e.insert("one");
        press(&mut e, KeyCode::Tab, KeyModifiers::NONE);
        e.insert("two");
        ready(&mut e);
        press(&mut e, KeyCode::F(5), KeyModifiers::NONE);
        let serial = e.find.as_ref().unwrap().preview.unwrap();
        e.session.active_mut().document.replace(0..0, "!").unwrap();
        e.apply_find(serial, None);
        assert_eq!(e.document().text(), "!one one");
        press(&mut e, KeyCode::Char('n'), KeyModifiers::CONTROL);
        assert!(e.find.is_none());
    }
}
