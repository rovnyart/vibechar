use ratatui::{
    layout::{Constraint, Layout},
    style::{Color, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use unicode_segmentation::UnicodeSegmentation;

use crate::editor::{cell_width, Editor};

pub fn draw(frame: &mut Frame, editor: &mut Editor) {
    let [header, body, status, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());
    let line = editor.document().line_index(editor.cursor);
    let column = editor.cursor_column();
    editor.top = editor.top.min(line);
    if line >= editor.top + usize::from(body.height) {
        editor.top = line + 1 - usize::from(body.height);
    }
    editor.left = editor.left.min(column);
    if column >= editor.left + usize::from(body.width) {
        editor.left = column + 1 - usize::from(body.width);
    }

    let name = format!(
        "{}/{}  {}",
        editor.session.active_index() + 1,
        editor.session.buffers().len(),
        editor.session.active().label()
    );
    let dirty = if editor.document().is_dirty() {
        " ●"
    } else {
        ""
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                " vibechar ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Rgb(245, 158, 66)),
            ),
            Span::raw(format!("  {name}{dirty}")),
        ])),
        header,
    );

    let syntax = editor
        .syntax
        .as_ref()
        .filter(|frame| frame.document == editor.document().id());
    let lines: Vec<_> = (editor.top
        ..(editor.top + usize::from(body.height)).min(editor.document().line_count()))
        .map(|index| {
            let text = editor.document().line(index);
            let paint = syntax
                .and_then(|frame| frame.lines.get(index))
                .filter(|paint| paint.hash == vibechar_core::syntax::line_hash(&text));
            styled_line(
                &text,
                editor.left,
                usize::from(body.width),
                paint.map(|p| p.as_ref()),
                editor.light_syntax,
            )
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), body);
    let recovery = if editor.session.active().is_private() {
        if let Some(uses) = editor.document().drop_uses() {
            format!("PRIVATE · Agent access open · {uses} uses · F9 stop")
        } else {
            format!(
                "PRIVATE · not recovered · Other tabs: {}",
                editor.recovery_status
            )
        }
    } else {
        editor.recovery_status.to_owned()
    };
    let language = syntax.map_or_else(
        || {
            editor
                .session
                .language()
                .unwrap_or("Auto · Text")
                .to_owned()
        },
        |frame| {
            format!(
                "{}{}{}",
                if frame.automatic { "Auto · " } else { "" },
                frame.language,
                if frame.limited { " · preview" } else { "" }
            )
        },
    );
    frame.render_widget(
        Paragraph::new(format!(
            " {}  · {}:{}  {}",
            recovery,
            line + 1,
            column + 1,
            language,
        ))
        .style(Style::default().fg(Color::DarkGray)),
        status,
    );
    let prompt = editor.save_prompt.as_ref().map_or_else(
        || {
            if editor.message.is_empty() {
                " ^N new ^P private ^S save F2 lang F4 as F6 next ^G agent F8 paste F9 stop ^Q quit"
                    .into()
            } else {
                format!(" {}", editor.message)
            }
        },
        |value| {
            if editor.confirming_overwrite() {
                let privacy = if editor.session.active().is_private() {
                    " · ends private mode"
                } else {
                    ""
                };
                format!(" Replace file? Enter confirms{privacy} · Esc cancels: {value}")
            } else if editor.session.active().is_private() {
                format!(" Save as (ends private mode): {value}  [Enter save · Esc cancel]")
            } else {
                format!(" Save as: {value}  [Enter save · Esc cancel]")
            }
        },
    );
    let prompt = if let Some(query) = &editor.language_prompt {
        let choices = editor.language_options();
        format!(
            " Language: {}  [{}] · Enter choose · Esc cancel",
            query,
            choices
                .iter()
                .enumerate()
                .map(|(i, c)| if i == editor.selected_language() {
                    format!("›{}", c.name)
                } else {
                    c.name.clone()
                })
                .collect::<Vec<_>>()
                .join(" / ")
        )
    } else {
        prompt
    };
    frame.render_widget(
        Paragraph::new(prompt).style(Style::default().fg(Color::Rgb(245, 158, 66))),
        footer,
    );
    if editor.save_prompt.is_none() && body.width > 0 && body.height > 0 {
        frame.set_cursor_position((
            body.x + (column - editor.left) as u16,
            body.y + (line - editor.top) as u16,
        ));
    }
}

fn styled_line(
    text: &str,
    left: usize,
    width: usize,
    paint: Option<&vibechar_core::syntax::LinePaint>,
    light: bool,
) -> Line<'static> {
    let mut output: Vec<Span<'static>> = Vec::new();
    let mut run = String::new();
    let mut last_role = 0;
    let mut offset = 0;
    let mut span_index = 0;
    let spans = paint.map_or(&[][..], |p| p.spans.as_slice());
    let mut column = 0;
    for grapheme in text.graphemes(true) {
        while span_index < spans.len()
            && spans[span_index].start + spans[span_index].length <= offset
        {
            span_index += 1;
        }
        let role = spans
            .get(span_index)
            .filter(|span| span.start <= offset)
            .map_or(0, |span| span.role);
        if role != last_role && !run.is_empty() {
            output.push(Span::styled(
                std::mem::take(&mut run),
                syntax_style(last_role, light),
            ));
        }
        last_role = role;
        let size = cell_width(grapheme, column);
        let end = column + size;
        if column >= left + width {
            break;
        }
        if end > left {
            if grapheme == "\t" || column < left || end > left + width {
                let visible = end.min(left + width).saturating_sub(column.max(left));
                run.push_str(&" ".repeat(visible));
            } else if grapheme.chars().any(char::is_control) {
                run.push('�');
            } else {
                run.push_str(grapheme);
            }
        }
        column = end;
        offset += grapheme.encode_utf16().count();
    }
    if !run.is_empty() {
        output.push(Span::styled(run, syntax_style(last_role, light)));
    }
    Line::from(output)
}

fn syntax_style(role: u8, light: bool) -> Style {
    if role == 0 {
        return Style::default();
    }
    let palette = if light {
        [
            0x282B29u32,
            0x9C4263,
            0x427445,
            0x956529,
            0x81867C,
            0x7761A1,
            0x356B9A,
            0x257D82,
            0xBD4C2B,
            0x356B9A,
            0x777D73,
        ]
    } else {
        [
            0xE3E5DFu32,
            0xDDA4BB,
            0xB2CF9B,
            0xE2BA83,
            0x7F8B7B,
            0xC0B0DE,
            0x9DBFDA,
            0x8FC7C5,
            0xF49A6B,
            0x9DBFDA,
            0x969F91,
        ]
    };
    let rgb = palette[usize::from(role).min(palette.len() - 1)];
    Style::default().fg(Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8))
}
#[cfg(test)]
fn visible_line(text: &str, left: usize, width: usize) -> String {
    styled_line(text, left, width, None, false)
        .spans
        .iter()
        .map(|s| s.content.as_ref())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    #[test]
    fn renders_a_unicode_document_and_keeps_cursor_visible_after_resize() {
        let mut editor = Editor::new("я\n界界界界界界界界", None);
        editor.cursor = editor.document().len_chars();
        let mut terminal = Terminal::new(TestBackend::new(16, 5)).unwrap();
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        assert!(editor.left > 0);
        assert!(terminal
            .backend()
            .buffer()
            .content
            .iter()
            .any(|cell| cell.symbol() == "界"));
    }

    #[test]
    fn clipping_a_wide_grapheme_never_draws_half_a_character() {
        assert_eq!(visible_line("a界b", 2, 2), " b");
        assert_eq!(visible_line("\tx", 1, 4), "   x");
    }

    #[test]
    fn private_mode_is_visible_without_using_text_as_a_tab_title() {
        let mut editor = Editor::new("", None);
        editor.session.open_private();
        editor.insert("PRIVATE_VIEW_FIXTURE");
        editor.recovery_status = "Saved locally";
        let mut terminal = Terminal::new(TestBackend::new(100, 5)).unwrap();
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        let row = |y| {
            (0..100)
                .map(|x| terminal.backend().buffer()[(x, y)].symbol())
                .collect::<String>()
        };
        assert!(row(0).contains("Private"));
        assert!(!row(0).contains("PRIVATE_VIEW_FIXTURE"));
        assert!(row(3).contains("PRIVATE · not recovered · Other tabs: Saved locally"));
    }
}
