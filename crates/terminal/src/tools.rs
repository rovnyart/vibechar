use super::*;
use std::ops::Range;
use vibechar_core::tools::{choices, Command, Job};

pub struct Palette {
    pub input: find::Input,
    pub choices: Vec<Command>,
    pub selected: usize,
    pub scope: String,
    pub notice: String,
    pub job: Option<Job>,
    target: Range<usize>,
    selected_text: bool,
}
impl Editor {
    pub(super) fn tools_insert(&mut self, text: &str) -> bool {
        let Some(palette) = &mut self.tools else {
            return false;
        };
        if palette.job.is_none()
            && !text.chars().any(char::is_control)
            && palette.input.insert(text, 256)
        {
            palette.choices = choices(&palette.input.text);
            palette.selected = 0;
            palette.notice.clear();
        }
        true
    }
    pub(super) fn handle_tools_key(&mut self, key: KeyEvent) -> bool {
        if key.code == KeyCode::Char('k')
            && key.modifiers.contains(KeyModifiers::CONTROL)
            && self.save_prompt.is_none()
            && self.language_prompt.is_none()
        {
            self.find = None;
            self.pointer = selection::Pointer::default();
            let target = self.selection();
            let selected_text = !target.is_empty();
            let target = if selected_text {
                target
            } else {
                0..self.document().len_chars()
            };
            let scope = format!(
                "{} · {} characters · local",
                if selected_text {
                    "Selection"
                } else {
                    "Whole tab"
                },
                target.len()
            );
            self.tools = Some(Palette {
                input: find::Input::default(),
                choices: choices(""),
                selected: 0,
                scope,
                notice: String::new(),
                job: None,
                target,
                selected_text,
            });
            return true;
        }
        let Some(palette) = &mut self.tools else {
            return false;
        };
        if key.code == KeyCode::Esc
            || (key.code == KeyCode::Char('q') && key.modifiers.contains(KeyModifiers::CONTROL))
        {
            self.tools = None;
            return key.code == KeyCode::Esc;
        }
        if palette.job.is_some() {
            return true;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            match key.code {
                KeyCode::Char('a') => palette.input.all_selected = true,
                KeyCode::Char('v') => self.paste_clipboard(),
                _ => {}
            }
            return true;
        }
        match key.code {
            KeyCode::Up | KeyCode::Down if !palette.choices.is_empty() => {
                let count = palette.choices.len();
                palette.selected = (palette.selected
                    + if key.code == KeyCode::Down {
                        1
                    } else {
                        count - 1
                    })
                    % count;
            }
            KeyCode::Enter => {
                if let Some(command) = palette.choices.get(palette.selected) {
                    let id = command.id;
                    let target = palette.target.clone();
                    match Job::start(self.document(), target, id) {
                        Ok(job) => self.tools.as_mut().unwrap().job = Some(job),
                        Err(error) => self.tools.as_mut().unwrap().notice = error,
                    }
                }
            }
            KeyCode::Char(ch)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::ALT | KeyModifiers::SUPER) =>
            {
                self.tools_insert(&ch.to_string());
            }
            KeyCode::Insert if key.modifiers.contains(KeyModifiers::SHIFT) => {
                self.paste_clipboard()
            }
            _ => {
                palette.input.key(key.code);
                palette.choices = choices(&palette.input.text);
                palette.selected = 0;
                palette.notice.clear();
            }
        }
        true
    }
    pub fn tools_busy(&self) -> bool {
        self.tools.as_ref().is_some_and(|p| p.job.is_some())
    }
    pub fn pump_tools(&mut self) {
        let Some(mut palette) = self.tools.take() else {
            return;
        };
        if let Some(result) = palette.job.as_mut().and_then(|job| job.poll()) {
            let applied = match result {
                Ok(plan) => plan.apply(&mut self.session.active_mut().document),
                Err(error) => Err(error.clone()),
            };
            match applied {
                Ok((changed, range)) => {
                    if changed {
                        if palette.selected_text {
                            self.anchor = Some(range.start);
                            self.cursor = range.end;
                        } else {
                            self.anchor = None;
                            self.cursor = range.start;
                        }
                        self.reveal_cursor = true;
                    }
                    self.message = if changed {
                        "Text tool applied · Ctrl+Z to undo"
                    } else {
                        "Already in shape · no changes"
                    }
                    .into();
                    return;
                }
                Err(error) => {
                    palette.notice = error;
                    palette.job = None;
                }
            }
        }
        self.tools = Some(palette);
    }
}
