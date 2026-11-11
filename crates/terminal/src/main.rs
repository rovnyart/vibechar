mod editor;
mod files;
mod view;

use std::{
    env,
    error::Error,
    io::{self, IsTerminal, Read},
    path::PathBuf,
};

use crossterm::{
    event::{self, DisableBracketedPaste, EnableBracketedPaste, Event},
    execute,
};

use editor::Editor;

fn main() {
    if let Err(error) = run() {
        eprintln!("vibechar: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args
        .first()
        .is_some_and(|arg| arg == "--help" || arg == "-h")
    {
        println!("vibechar [FILE]\n\nA tiny text workbench. Also accepts piped UTF-8 text.\n\nCtrl+N new · F6/Shift+F6 switch · Ctrl+W close\nCtrl+S save · Ctrl+Z undo · Ctrl+Y redo · Ctrl+Q quit\n\nPrototype: no scratch recovery, highlighting, or AI yet.");
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--version") {
        println!("vibechar {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.len() > 1
        || args
            .first()
            .is_some_and(|arg| arg.to_string_lossy().starts_with('-'))
    {
        return Err("expected one filename; use --help for usage".into());
    }
    if !io::stdout().is_terminal() {
        return Err("interactive output requires a terminal".into());
    }
    let path = args.first().map(PathBuf::from);
    let text = if let Some(path) = &path {
        files::load(path)?
    } else if !io::stdin().is_terminal() {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text)?;
        text
    } else {
        String::new()
    };
    let mut editor = Editor::new(&text, path);
    let mut terminal = ratatui::init();
    let result = (|| -> io::Result<()> {
        execute!(io::stdout(), EnableBracketedPaste)?;
        loop {
            terminal.draw(|frame| view::draw(frame, &mut editor))?;
            match event::read()? {
                Event::Key(key) if editor.handle(key) => break,
                Event::Paste(text) => editor.insert(&text),
                _ => {}
            }
        }
        Ok(())
    })();
    let paste_result = execute!(io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    result?;
    paste_result?;
    Ok(())
}
