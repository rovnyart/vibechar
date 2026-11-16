use ratatui::{
    layout::{Constraint, Layout},
    style::{Color, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
    Frame,
};
use unicode_segmentation::UnicodeSegmentation;

use crate::editor::{cell_width, Editor};

pub fn draw(frame: &mut Frame, editor: &mut Editor) {
    let find_height = editor.find.as_ref().map_or(0, |find| {
        1 + u16::from(find.replacing)
            + if find.preview.is_some() {
                find.frame
                    .as_ref()
                    .map_or(1, |f| f.examples.len() as u16 + 1)
            } else {
                0
            }
    });
    let [header, find_area, mut body, status, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(find_height),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());
    if let Some(find) = &mut editor.find {
        find.find_rect = ratatui::layout::Rect::new(
            find_area.x,
            find_area.y,
            find_area.width,
            u16::from(find_area.height > 0),
        );
        find.replace_rect = ratatui::layout::Rect::new(
            find_area.x,
            find_area.y + 1,
            find_area.width,
            u16::from(find.replacing && find_area.height > 1),
        );
        let render_input = |frame: &mut Frame,
                            input: &crate::editor::find::Input,
                            label: &str,
                            area: ratatui::layout::Rect,
                            focused: bool| {
            if area.is_empty() {
                return;
            }
            let prefix = format!(" {label}: ");
            let prefix_width = prefix.len();
            let width = usize::from(area.width).saturating_sub(prefix_width);
            let left = input.column().saturating_sub(width.saturating_sub(1));
            let mut line = styled_line(
                &input.display(),
                left,
                width,
                None,
                false,
                (0..0, false),
                &[],
            );
            line.spans.insert(0, Span::raw(prefix));
            frame.render_widget(
                Paragraph::new(line).style(if focused && input.all_selected {
                    selection_style(editor.light_syntax)
                } else {
                    Style::default().fg(Color::Rgb(245, 158, 66))
                }),
                area,
            );
        };
        render_input(
            frame,
            &find.needle,
            "Find",
            find.find_rect,
            find.focused && !find.replace_focus,
        );
        if find.replacing {
            render_input(
                frame,
                &find.replacement,
                "With",
                find.replace_rect,
                find.focused && find.replace_focus,
            );
        }
        if find.preview.is_some() {
            if let Some(result) = &find.frame {
                let lines = std::iter::once(Line::raw(format!(
                    " Replace {} matches? Enter applies · Esc goes back",
                    result.changed
                )))
                .chain(
                    result
                        .examples
                        .iter()
                        .map(|ex| Line::raw(format!(" {} → {}", ex.before, ex.after))),
                )
                .collect::<Vec<_>>();
                let y = find_area.y + 1 + u16::from(find.replacing);
                frame.render_widget(
                    Paragraph::new(lines).style(Style::default().fg(Color::Rgb(245, 158, 66))),
                    ratatui::layout::Rect::new(
                        find_area.x,
                        y,
                        find_area.width,
                        find_area.bottom().saturating_sub(y),
                    ),
                );
            }
        }
    }
    let digits = editor.document().line_count().to_string().len().max(2) as u16;
    let gutter_width = if editor.line_numbers {
        (digits + 2).min(body.width.saturating_sub(1))
    } else {
        0
    };
    editor.gutter = ratatui::layout::Rect::new(body.x, body.y, gutter_width, body.height);
    body.x += gutter_width;
    body.width -= gutter_width;
    editor.update_viewport(body);
    let metric_ranges = if editor.multi.active(editor.document()) {
        editor
            .multi
            .selections()
            .iter()
            .map(|s| s.range())
            .collect::<Vec<_>>()
    } else {
        vec![editor.selection()]
    };
    editor
        .metrics
        .submit(&editor.session.active().document, &metric_ranges);
    let metrics = editor.metrics.frame(editor.document());
    let line = editor.document().line_index(editor.cursor);
    let column = editor.cursor_column();

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
    let selection = editor.selection();
    let multiple = editor.multi.active(editor.document());
    let multi_ranges = if multiple {
        editor
            .multi
            .selections()
            .iter()
            .map(|s| s.range())
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let find_frame = editor
        .find
        .as_ref()
        .and_then(|f| f.frame.as_ref())
        .filter(|f| f.revision == editor.document().revision());
    let mut numbers = Vec::new();
    let mut previous = None;
    let lines: Vec<_> = editor
        .screen_rows(usize::from(body.height))
        .into_iter()
        .map(|row| {
            let index = row.line;
            let text = if previous == Some(index) {
                "·".into()
            } else {
                (index + 1).to_string()
            };
            previous = Some(index);
            let color = if index == line {
                if editor.light_syntax {
                    Color::Rgb(189, 76, 43)
                } else {
                    Color::Rgb(244, 154, 107)
                }
            } else if editor.light_syntax {
                Color::Rgb(140, 143, 135)
            } else {
                Color::Rgb(105, 110, 102)
            };
            numbers.push(Line::styled(
                format!(
                    "{text:>width$} ",
                    width = gutter_width.saturating_sub(1) as usize
                ),
                Style::default().fg(color),
            ));
            let window = row.window;
            let range = editor.document().line_range(index);
            let (start, end) = (range.start, range.end);
            let hits = if multiple {
                multi_ranges
                    .iter()
                    .filter(|range| range.end >= start && range.start <= end)
                    .map(|range| {
                        (
                            range.start.saturating_sub(start)..range.end.saturating_sub(start),
                            true,
                        )
                    })
                    .collect()
            } else {
                find_frame.map_or_else(Vec::new, |f| {
                    f.matches
                        .iter()
                        .enumerate()
                        .skip_while(|(_, h)| h.end < start)
                        .take_while(|(_, h)| h.start <= end)
                        .map(|(i, h)| {
                            (
                                h.start.saturating_sub(start)..h.end.saturating_sub(start),
                                editor.find.as_ref().and_then(|f| f.current) == Some(i),
                            )
                        })
                        .collect()
                })
            };
            let paint = syntax
                .and_then(|frame| frame.lines.get(index))
                .filter(|paint| {
                    syntax.is_some_and(|frame| frame.revision == editor.document().revision())
                        || range.len() <= 8192
                            && paint.hash
                                == vibechar_core::syntax::line_hash(&editor.document().line(index))
                });
            paint_line(
                &window.text,
                (
                    if editor.wrap {
                        window.column
                    } else {
                        editor.left
                    },
                    usize::from(body.width),
                ),
                paint.map(|p| p.as_ref()),
                editor.light_syntax,
                (
                    selection.start.saturating_sub(start)..selection.end.saturating_sub(start),
                    row.last
                        && index + 1 < editor.document().line_count()
                        && (selection.start <= end && selection.end > end
                            || multi_ranges.iter().any(|r| r.start <= end && r.end > end)),
                ),
                &hits,
                (window.character, window.utf16, window.column),
            )
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), body);
    if gutter_width > 0 {
        frame.render_widget(Paragraph::new(numbers), editor.gutter);
    }
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
    let language = format!(
        "{} · {}",
        language,
        if editor.wrap { "Wrap" } else { "No wrap" }
    );
    let summary = metrics
        .as_ref()
        .map(|m| m.summary(status.width < 70))
        .unwrap_or_default();
    let summary = if !multiple {
        summary
            .strip_prefix("1 selection · ")
            .unwrap_or(&summary)
            .to_owned()
    } else {
        summary
    };
    let statustext = if status.width < 70 {
        format!(
            " {}{}:{} · {}",
            if editor.session.active().is_private() {
                "PRIVATE · "
            } else {
                ""
            },
            line + 1,
            column + 1,
            summary
        )
    } else {
        format!(
            " {} · {}:{} · {} · {}",
            recovery,
            line + 1,
            column + 1,
            summary,
            language
        )
    };
    frame.render_widget(
        Paragraph::new(statustext).style(Style::default().fg(Color::DarkGray)),
        status,
    );
    let prompt = editor.save_prompt.as_ref().map_or_else(
        || {
            if editor.message.is_empty() {
                if multiple {" ^D next ^L all · arrows move · Shift selects · ^C/^X/^V · Esc single selection".into()}
                else {" ^S save ^F find ^K tools · F10 wrap F11 stats F12 # · ^D next · ^Q quit".into()}
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
    let prompt = if let Some(find) = editor
        .find
        .as_ref()
        .filter(|_| editor.save_prompt.is_none() && editor.language_prompt.is_none())
    {
        format!(
            " {} · {} {} · {} · F3 next · F5 all · Esc",
            find.status(),
            if find.regex { "regex" } else { "text" },
            if find.sensitive { "Aa" } else { "aa" },
            if !find.focused {
                "Ctrl+F/R fields"
            } else if find.replace_focus {
                "Enter replace · Tab fields · Alt+C/R"
            } else {
                "Enter next · Tab fields · Alt+C/R"
            }
        )
    } else if let Some(query) = &editor.language_prompt {
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
    if let Some(find) = editor
        .find
        .as_ref()
        .filter(|f| f.focused && !editor.stats_open)
    {
        let input = if find.replace_focus {
            &find.replacement
        } else {
            &find.needle
        };
        let area = if find.replace_focus {
            find.replace_rect
        } else {
            find.find_rect
        };
        if !area.is_empty() {
            frame.set_cursor_position((
                area.x + (7 + input.column()).min(usize::from(area.width).saturating_sub(1)) as u16,
                area.y,
            ));
        }
    } else if !editor.stats_open && editor.save_prompt.is_none() && !body.is_empty() {
        if let Some((x, y)) = editor.screen_cursor() {
            frame.set_cursor_position((body.x + x as u16, body.y + y as u16));
        }
    }
    if let Some(palette) = &editor.tools {
        draw_tools(frame, palette, editor.light_syntax);
    }
    if editor.stats_open {
        if let Some(stats) = metrics {
            draw_statistics(frame, &stats, editor.light_syntax);
        }
    }
}

fn draw_statistics(frame: &mut Frame, stats: &vibechar_core::metrics::Frame, light: bool) {
    let screen = frame.area();
    let width = screen.width.min(66);
    let height = screen.height.min(16);
    let area = ratatui::layout::Rect::new(
        screen.x + (screen.width - width) / 2,
        screen.bottom() - height,
        width,
        height,
    );
    let block = Block::default()
        .title(" V_ Text statistics · F11 / Esc ")
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .style(
            Style::default()
                .fg(if light {
                    Color::Rgb(40, 43, 41)
                } else {
                    Color::Rgb(227, 229, 223)
                })
                .bg(if light {
                    Color::Rgb(252, 251, 248)
                } else {
                    Color::Rgb(32, 33, 31)
                }),
        );
    let inner = block.inner(area);
    frame.render_widget(Clear, area);
    frame.render_widget(block, area);
    let n = |v: Option<usize>| {
        v.map(vibechar_core::metrics::number).unwrap_or_else(|| {
            if stats.busy {
                "…".into()
            } else {
                "—".into()
            }
        })
    };
    let col = usize::from(inner.width.saturating_sub(15) / 2).max(3);
    let row = |label: &str, total: String, selected: String| {
        Line::raw(format!(" {label:12} {total:>col$} {selected:>col$}"))
    };
    let lines = vec![
        row("", "Document".into(), "Selected".into()),
        row(
            "Characters",
            n(stats.total.characters),
            n(stats.selected.characters),
        ),
        row("Words", n(stats.total.words), n(stats.selected.words)),
        row(
            "Lines",
            stats.total.lines.to_string(),
            stats.selected.lines.to_string(),
        ),
        row(
            "UTF-8 bytes",
            vibechar_core::metrics::number(stats.total.bytes),
            vibechar_core::metrics::number(stats.selected.bytes),
        ),
        Line::raw(""),
        Line::raw(format!(
            " {} selections · {} carets",
            stats.selections, stats.carets
        )),
        Line::raw(""),
        Line::raw(" Characters = graphemes; CRLF counts once."),
        Line::raw(" Words = letters, numbers, underscores."),
        Line::raw(if stats.limited {
            " Some counts exceed the analysis budget."
        } else {
            " Local only · typing closes this panel."
        }),
    ];
    frame.render_widget(Paragraph::new(lines), inner);
}

fn draw_tools(frame: &mut Frame, palette: &crate::editor::tools::Palette, light: bool) {
    let screen = frame.area();
    let width = screen.width.min(72);
    let height = screen.height.min(19);
    let area = ratatui::layout::Rect::new(
        screen.x + (screen.width - width) / 2,
        screen.y + (screen.height - height) / 2,
        width,
        height,
    );
    let base = Style::default()
        .fg(if light {
            Color::Rgb(40, 43, 41)
        } else {
            Color::Rgb(227, 229, 223)
        })
        .bg(if light {
            Color::Rgb(249, 247, 240)
        } else {
            Color::Rgb(31, 34, 31)
        });
    let accent = Style::default().fg(Color::Rgb(235, 132, 58));
    frame.render_widget(Clear, area);
    let border = Block::default()
        .title(" V_ Text tools ")
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .style(base);
    let inner = border.inner(area);
    frame.render_widget(border, area);
    let mut lines = vec![
        Line::styled(format!(" {}", palette.scope), accent),
        Line::raw(format!(" > {}", palette.input.display())),
        Line::raw(""),
    ];
    if palette.choices.is_empty() {
        lines.push(Line::raw(" No tools found. Try json, case or url."));
    }
    let visible = usize::from(inner.height.saturating_sub(5) / 2).clamp(1, 5);
    let first = palette
        .selected
        .saturating_sub(visible / 2)
        .min(palette.choices.len().saturating_sub(visible));
    for (index, command) in palette.choices.iter().enumerate().skip(first).take(visible) {
        lines.push(Line::styled(
            format!(
                " {} {}",
                if index == palette.selected {
                    "›"
                } else {
                    " "
                },
                command.title
            ),
            if index == palette.selected {
                selection_style(light)
            } else {
                base
            },
        ));
        lines.push(Line::styled(
            format!("   {}", command.detail),
            Style::default().fg(if light { Color::DarkGray } else { Color::Gray }),
        ));
    }
    lines.push(Line::raw(if palette.choices.len() > visible {
        format!(
            " Tools {}–{} of {} · type to filter",
            first + 1,
            (first + visible).min(palette.choices.len()),
            palette.choices.len()
        )
    } else {
        String::new()
    }));
    lines.push(Line::styled(
        format!(
            " {}",
            if palette.job.is_some() {
                "Working locally…"
            } else if !palette.notice.is_empty() {
                &palette.notice
            } else {
                "↑↓ choose · Enter apply · Esc cancel · one Undo"
            }
        ),
        accent,
    ));
    frame.render_widget(Paragraph::new(lines), inner);
    if inner.width > 3 && inner.height > 1 {
        frame.set_cursor_position((
            inner.x + 3 + palette.input.column().min(usize::from(inner.width - 4)) as u16,
            inner.y + 1,
        ));
    }
}

fn styled_line(
    text: &str,
    left: usize,
    width: usize,
    paint: Option<&vibechar_core::syntax::LinePaint>,
    light: bool,
    selected: (std::ops::Range<usize>, bool),
    finds: &[(std::ops::Range<usize>, bool)],
) -> Line<'static> {
    paint_line(
        text,
        (left, width),
        paint,
        light,
        selected,
        finds,
        (0, 0, 0),
    )
}

fn paint_line(
    text: &str,
    viewport: (usize, usize),
    paint: Option<&vibechar_core::syntax::LinePaint>,
    light: bool,
    selected: (std::ops::Range<usize>, bool),
    finds: &[(std::ops::Range<usize>, bool)],
    origin: (usize, usize, usize),
) -> Line<'static> {
    let (left, width) = viewport;
    let (selection, newline) = selected;
    let mut output: Vec<Span<'static>> = Vec::new();
    let mut run = String::new();
    let mut last_style = Style::default();
    let (mut character, mut offset, mut column) = origin;
    let mut find_index = 0;
    let mut span_index = 0;
    let spans = paint.map_or(&[][..], |p| p.spans.as_slice());
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
        while find_index < finds.len()
            && finds[find_index].0.end <= character
            && !(finds[find_index].0.is_empty() && finds[find_index].0.start == character)
        {
            find_index += 1;
        }
        let found = finds.get(find_index).filter(|(r, _)| {
            r.start < character + grapheme.chars().count()
                && (r.end > character || r.is_empty() && r.start == character)
        });
        let style = if selection.contains(&character) {
            selection_style(light)
        } else if let Some((_, active)) = found {
            find_style(light, *active)
        } else {
            syntax_style(role, light)
        };
        if style != last_style && !run.is_empty() {
            output.push(Span::styled(std::mem::take(&mut run), last_style));
        }
        last_style = style;
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
        character += grapheme.chars().count();
    }
    if !run.is_empty() {
        output.push(Span::styled(run, last_style));
    }
    let found_end = finds
        .iter()
        .find(|(r, _)| r.is_empty() && r.start == character);
    if (newline || found_end.is_some()) && column >= left && column < left + width {
        output.push(Span::styled(
            " ",
            if newline {
                selection_style(light)
            } else {
                find_style(light, found_end.unwrap().1)
            },
        ));
    }
    Line::from(output)
}

fn find_style(light: bool, active: bool) -> Style {
    if active {
        selection_style(light)
    } else if light {
        Style::default()
            .fg(Color::Rgb(0x28, 0x2B, 0x29))
            .bg(Color::Rgb(0xE6, 0xE5, 0xDF))
    } else {
        Style::default()
            .fg(Color::Rgb(0xE3, 0xE5, 0xDF))
            .bg(Color::Rgb(0x35, 0x37, 0x30))
    }
}

fn selection_style(light: bool) -> Style {
    if light {
        Style::default()
            .fg(Color::Rgb(0x28, 0x2B, 0x29))
            .bg(Color::Rgb(0xF3, 0xDC, 0xCD))
    } else {
        Style::default()
            .fg(Color::Rgb(0xE3, 0xE5, 0xDF))
            .bg(Color::Rgb(0x59, 0x40, 0x2E))
    }
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
    styled_line(text, left, width, None, false, (0..0, false), &[])
        .spans
        .iter()
        .map(|s| s.content.as_ref())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{
        KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    };
    use ratatui::{backend::TestBackend, Terminal};

    fn row(terminal: &Terminal<TestBackend>, y: u16) -> String {
        let buffer = terminal.backend().buffer();
        (0..buffer.area.width)
            .map(|x| buffer[(x, y)].symbol())
            .collect()
    }
    fn click(editor: &mut Editor, column: u16, row: u16) {
        editor.mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column,
            row,
            modifiers: KeyModifiers::NONE,
        });
    }
    #[test]
    fn numbered_wrapped_rows_clicks_and_toggles_preserve_document_state() {
        let source = "abcdefghijklmnopqrstuvwx\r\nlast\r\n";
        let mut editor = Editor::new(source, None);
        editor.line_numbers = true;
        editor.recovery_status = "Saved locally";
        let mark = editor.recovery_mark();
        let mut terminal = Terminal::new(TestBackend::new(16, 10)).unwrap();
        editor.handle(KeyEvent::new(KeyCode::F(10), KeyModifiers::NONE));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(row(&terminal, 1).starts_with("  1 abcdef"));
        assert!(row(&terminal, 2).starts_with("  · mnopqr"));
        assert!(row(&terminal, 3).starts_with("  2 last"));
        assert!(row(&terminal, 4).starts_with("  3 "));
        assert_eq!(
            terminal.backend().buffer()[(2, 1)].fg,
            Color::Rgb(244, 154, 107)
        );
        click(&mut editor, 1, 2); // Continuation number selects the complete logical line.
        assert_eq!(editor.selection(), 0..26);
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        let stats = editor.metrics.frame(editor.document()).unwrap();
        assert_eq!(
            (stats.selected.characters, stats.selected.lines),
            (Some(25), 1)
        );
        click(&mut editor, 6, 3); // Gutter is excluded from text hit testing.
        assert_eq!(editor.selection(), 28..28);
        let range = editor.selection();
        editor.handle(KeyEvent::new(KeyCode::F(12), KeyModifiers::NONE));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert_eq!(editor.gutter.width, 0);
        assert_eq!(editor.selection(), range);
        editor.handle(KeyEvent::new(KeyCode::F(12), KeyModifiers::NONE));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(editor.recovery_mark() == mark);
        assert_eq!(editor.document().text(), source);
    }
    #[test]
    fn statistics_overlay_counts_graphemes_and_keeps_mouse_and_find_cursor_quiet() {
        let mut editor = Editor::new("👩‍💻e\u{301}\r\nlast", None);
        editor.line_numbers = true;
        editor.handle(KeyEvent::new(KeyCode::Right, KeyModifiers::SHIFT));
        let mut terminal = Terminal::new(TestBackend::new(100, 24)).unwrap();
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(row(&terminal, 22).contains("1 char selected · 1 line"));
        let stats = editor.metrics.frame(editor.document()).unwrap();
        assert_eq!(
            (stats.selected.characters, stats.selected.bytes),
            (Some(1), 11)
        );
        let mark = editor.recovery_mark();
        editor.handle(KeyEvent::new(KeyCode::F(11), KeyModifiers::NONE));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(row(&terminal, 8).contains("Text statistics"));
        let selected = editor.selection();
        click(&mut editor, 1, 2);
        assert_eq!(editor.selection(), selected);
        editor.handle(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        assert!(!editor.stats_open && editor.recovery_mark() == mark);
        editor.handle(KeyEvent::new(KeyCode::Char('f'), KeyModifiers::CONTROL));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        click(&mut editor, 1, 2); // Number column takes focus from Find.
        assert!(!editor.find.as_ref().unwrap().focused);
        editor.stats_open = true;
        editor.handle(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE));
        assert!(!editor.stats_open);
        assert_eq!(editor.document().text(), "xlast");
        editor.handle(KeyEvent::new(KeyCode::Char('f'), KeyModifiers::CONTROL));
        editor.handle(KeyEvent::new(KeyCode::F(11), KeyModifiers::NONE));
        assert!(editor.stats_open);
        editor.paste("query");
        assert!(!editor.stats_open);
        assert_eq!(editor.find.as_ref().unwrap().needle.text, "query");
        assert_eq!(editor.document().text(), "xlast");
    }
    #[test]
    fn narrow_private_statistics_and_scrolling_numbers_remain_view_only() {
        let source = (1..60).map(|n| format!("row {n}\n")).collect::<String>();
        let mut editor = Editor::new("", None);
        editor.session.open_private();
        editor.insert(&source);
        editor.line_numbers = true;
        editor.cursor = 0;
        let mark = editor.recovery_mark();
        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(row(&terminal, 10).contains("PRIVATE · 1:1"));
        assert!(row(&terminal, 10).contains("ch · 60 ln"));
        editor.mouse(MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: 1,
            row: 2,
            modifiers: KeyModifiers::NONE,
        });
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        assert!(row(&terminal, 1).starts_with("  4 row 4"));
        assert_eq!(editor.cursor, 0);
        editor.handle(KeyEvent::new(KeyCode::F(11), KeyModifiers::NONE));
        terminal.draw(|f| draw(f, &mut editor)).unwrap();
        let screen = (0..12)
            .map(|y| row(&terminal, y))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            screen.contains("Document")
                && screen.contains("Selected")
                && screen.contains("UTF-8 bytes")
        );
        assert!(editor.recovery_mark() == mark);
        assert_eq!(editor.document().text(), source);
    }

    #[test]
    fn windowed_render_matches_full_lines_for_unicode_selections_and_find() {
        let source = "a界\t👩‍💻e\u{301}🇦🇲 Z".repeat(600);
        let document = vibechar_core::Document::new(&source);
        let hits = [
            (20..27, false),
            (60..63, true),
            (90..90, true),
            (5000..5004, false),
        ];
        for light in [false, true] {
            for left in [0, 1, 2, 3, 4, 20, 80, 4998, 5001, 8000] {
                let window = document.line_window(0, left, 27);
                let full = styled_line(&source, left, 27, None, light, (30..65, false), &hits);
                let clipped = paint_line(
                    &window.text,
                    (left, 27),
                    None,
                    light,
                    (30..65, false),
                    &hits,
                    (window.character, window.utf16, window.column),
                );
                assert_eq!(clipped, full, "left={left}, light={light}");
            }
        }
    }

    #[test]
    fn windowed_syntax_keeps_utf16_colors_after_non_bmp_text() {
        let source = format!(
            "{{\"head\":\"{}👩‍💻e\u{301}界\",\t\"number\":42}}",
            "x".repeat(1000)
        );
        let mut editor = Editor::new(&source, Some("synthetic.json".into()));
        editor.line_numbers = false;
        editor.session.submit_syntax();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            editor.pump_syntax();
            if editor.syntax.as_ref().is_some_and(|f| f.complete) {
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let paint = editor.syntax.as_ref().unwrap().lines.first().unwrap();
        assert!(!paint.spans.is_empty());
        for left in [999, 1007, 1010, 1015, 1020] {
            let window = editor.document().line_window(0, left, 23);
            let full = styled_line(&source, left, 23, Some(paint), false, (0..0, false), &[]);
            let clipped = paint_line(
                &window.text,
                (left, 23),
                Some(paint),
                false,
                (0..0, false),
                &[],
                (window.character, window.utf16, window.column),
            );
            assert_eq!(clipped, full, "left={left}");
        }
    }

    #[test]
    fn selected_cells_cover_clipped_wide_text_tabs_and_newlines_without_bleeding() {
        for light in [true, false] {
            let line = styled_line("界\tZ", 1, 4, None, light, (0..2, false), &[]);
            assert_eq!(
                line.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>(),
                "   Z"
            );
            assert_eq!(line.spans[0].style, selection_style(light));
            assert_eq!(line.spans[0].content, "   ");
            assert_eq!(line.spans.last().unwrap().style, Style::default());
            let blank = styled_line("", 0, 4, None, light, (0..1, true), &[]);
            assert_eq!(blank.spans[0].content, " ");
            assert_eq!(blank.spans[0].style, selection_style(light));
        }
    }

    #[test]
    fn redraw_keeps_the_wheel_viewport_and_click_then_typing_edits_the_clicked_row() {
        use crossterm::event::{KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
        let source = (0..40).map(|n| format!("row {n:02}\n")).collect::<String>();
        let mut editor = Editor::new(&source, None);
        editor.line_numbers = false;
        let mut terminal = Terminal::new(TestBackend::new(20, 8)).unwrap();
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        editor.mouse(MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: 4,
            row: 2,
            modifiers: KeyModifiers::NONE,
        });
        for _ in 0..3 {
            terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        }
        assert_eq!((editor.top, editor.cursor), (3, 0));
        assert_eq!(terminal.backend().buffer()[(0, 1)].symbol(), "r");
        assert_eq!(terminal.backend().buffer()[(5, 1)].symbol(), "3");
        editor.mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 4,
            row: 2,
            modifiers: KeyModifiers::NONE,
        });
        editor.insert("!");
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        assert!(editor.document().text().contains("row !04\n"));
        editor.session.active_mut().document.undo().unwrap();
        assert_eq!(editor.document().text(), source);
    }

    #[test]
    fn renders_a_unicode_document_and_keeps_cursor_visible_after_resize() {
        let mut editor = Editor::new("я\n界界界界界界界界", None);
        editor.line_numbers = false;
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
        editor.line_numbers = false;
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
