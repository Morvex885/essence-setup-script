//! Shared, TestBackend-renderable frames. Interior width is 68 terminal columns.
//! Every row is wrapped here — frame body, journal and prompt — so no text
//! depends on the terminal width or is cut at the frame edge.
use std::time::Instant;
use ratatui::{Frame, layout::Rect, style::{Color, Modifier, Style}, text::{Line, Span}, widgets::Paragraph};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
pub const CONTENT_WIDTH: usize = 68;
pub const FRAME_WIDTH: u16 = 70;
pub const CYAN: Color = Color::Cyan;
pub const GREEN: Color = Color::Green;
pub const YELLOW: Color = Color::Yellow;
pub const RED: Color = Color::Red;
pub const NC: Color = Color::Reset;
pub const DIM: Color = Color::DarkGray;
#[derive(Clone, Debug)]
pub struct Item { pub key: String, pub label: String, pub color: Color }
impl Item {
    pub fn new(key: impl ToString, label: impl Into<String>, color: Color) -> Self { Self { key: key.to_string().to_ascii_lowercase(), label: label.into(), color } }
}
/// How arrow keys act on a frame with items.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// Section menu: the highlighted item is remembered by title.
    #[default] Menu,
    /// One-off selection: keys as in `Menu`, the position is not remembered.
    Select,
    /// Multi-selection: Space toggles, Enter saves, ←/→ do nothing.
    Toggle,
    /// `0)` closes the program: keys as in `Menu`, but Esc/← do nothing.
    Root,
}
#[derive(Clone, Debug, Default)]
pub struct View {
    pub title: String,
    pub status: Vec<Line<'static>>,
    pub context: Vec<Line<'static>>,
    pub sections: Vec<Vec<Item>>,
    pub prompt: String,
    /// First visible body row; clamped to the document on every render.
    pub scroll: u16,
    pub mode: Mode,
    /// Highlighted item: index over the items of non-empty sections, in order.
    pub cursor: Option<usize>,
    /// Rows below the frame, above the journal.
    pub footer: Vec<Line<'static>>,
}
impl View {
    pub fn new(title: impl Into<String>) -> Self { Self { title: title.into(), ..Self::default() } }
    pub fn menu(title: impl Into<String>, items: Vec<Item>) -> Self { Self { title: title.into(), sections: vec![items], prompt: "Выберите действие: ".into(), ..Self::default() } }
    pub fn review(title: impl Into<String>, plan: &serde_json::Value) -> Self {
        let mut view = Self::new(title);
        view.context = plan.as_array().into_iter().flatten().filter_map(|v| v.as_str()).map(|s| Line::raw(s.to_owned())).collect();
        if view.context.is_empty() { view.context.push(warn("План не содержит описания действий.")); }
        view
    }
    /// Item keys in drawing order (empty sections skipped).
    pub fn keys(&self) -> Vec<String> { self.sections.iter().filter(|s| !s.is_empty()).flatten().map(|i| i.key.clone()).collect() }
    pub fn lines(&self) -> Vec<Line<'static>> { self.rows().0 }
    /// First and last row of the highlighted item in `lines()`.
    pub fn cursor_rows(&self) -> Option<(usize, usize)> { self.rows().1 }
    fn rows(&self) -> (Vec<Line<'static>>, Option<(usize, usize)>) {
        let mut lines = vec![Line::default(), border('┌', '┐')];
        let title = Line::raw(self.title.clone());
        for part in wrap(&title) { lines.push(framed(part, true)); }
        for status in &self.status { for part in wrap(status) { lines.push(framed(part, false)); } }
        let has_body = !self.context.is_empty() || self.sections.iter().any(|s| !s.is_empty());
        if has_body { lines.push(border('├', '┤')); }
        let has_context = !self.context.is_empty();
        for context in &self.context { for part in wrap(context) { lines.push(framed(part, false)); } }
        let mut body = has_context;
        let (mut index, mut cursor_rows) = (0, None);
        for section in self.sections.iter().filter(|s| !s.is_empty()) {
            if body { lines.push(border('├', '┤')); }
            for item in section {
                let line = Line::from(vec![Span::raw(" "), Span::styled(format!("{})", item.key), Style::default().fg(item.color)), Span::raw(format!(" {}", item.label))]);
                let selected = self.cursor == Some(index);
                let first = lines.len();
                for part in wrap(&line) {
                    let row = framed(part, false);
                    lines.push(if selected { highlighted(row) } else { row });
                }
                if selected { cursor_rows = Some((first, lines.len() - 1)); }
                index += 1;
            }
            body = true;
        }
        // A frame without context and actions (hidden entry, confirmation
        // question) has no separator: no empty section is ever drawn.
        lines.push(border('└', '┘'));
        (lines, cursor_rows)
    }
}
/// Reverse video for the interior of a framed row; the borders keep their style.
fn highlighted(mut line: Line<'static>) -> Line<'static> {
    let last = line.spans.len() - 1;
    for span in &mut line.spans[1..last] { span.style = Style::default().add_modifier(Modifier::REVERSED); }
    line
}
fn border(left: char, right: char) -> Line<'static> { Line::styled(format!("{left}{}{right}", "─".repeat(CONTENT_WIDTH)), Style::default().fg(CYAN)) }
fn wrap(line: &Line<'_>) -> Vec<Line<'static>> { wrap_to(line, CONTENT_WIDTH, 0) }
/// Word-aware wrap of one styled line into rows of at most `width` terminal
/// columns (a wide character such as `界` takes two). Continuation rows start
/// with `indent` spaces; `\n` starts a new row; control characters are
/// dropped; a word longer than a row is split. The line's own style is kept on
/// every piece.
pub fn wrap_to(line: &Line<'_>, width: usize, indent: usize) -> Vec<Line<'static>> {
    let width = width.max(indent + 1);
    let columns = |cells: &[(char, Style)]| cells.iter().map(|(c, _)| c.width().unwrap_or(0)).sum::<usize>();
    let mut rows: Vec<Vec<(char, Style)>> = vec![];
    let mut row: Vec<(char, Style)> = vec![];
    // Leading cells of `row` that are continuation indent, not text.
    let mut start = 0;
    for span in &line.spans {
        let style = line.style.patch(span.style);
        for ch in span.content.chars() {
            if ch == '\n' { rows.push(std::mem::take(&mut row)); start = 0; continue; }
            if ch.is_control() { continue; }
            let cells = ch.width().unwrap_or(0);
            if row.len() > start && columns(&row) + cells > width {
                // The unfinished word moves to the next row only when it fits
                // there; a word longer than a row is split in place.
                let carried = match row.iter().rposition(|(c, _)| *c == ' ') {
                    Some(space) if ch != ' ' && space > start && indent + columns(&row[space + 1..]) + cells <= width => row.split_off(space + 1),
                    _ => vec![],
                };
                while row.len() > start && row.last().is_some_and(|(c, _)| *c == ' ') { row.pop(); }
                rows.push(std::mem::replace(&mut row, vec![(' ', Style::default()); indent]));
                start = indent;
                row.extend(carried);
                if ch == ' ' { continue; }
            }
            if ch == ' ' && row.len() == start && start > 0 { continue; }
            row.push((ch, style));
        }
    }
    rows.push(row);
    rows.into_iter().map(|cells| {
        let mut spans: Vec<Span<'static>> = vec![];
        for (ch, style) in cells {
            match spans.last_mut() {
                Some(span) if span.style == style => span.content.to_mut().push(ch),
                _ => spans.push(Span::styled(ch.to_string(), style)),
            }
        }
        Line::from(spans)
    }).collect()
}
/// Journal lines with a status prefix (`[✗] `, `[!] `…) continue under the text.
fn journal_rows(line: &Line<'_>) -> Vec<Line<'static>> {
    let head: Vec<char> = line.spans.iter().flat_map(|s| s.content.chars()).take(4).collect();
    let indent = if head.len() == 4 && head[0] == '[' && head[2] == ']' && head[3] == ' ' { 4 } else { 0 };
    wrap_to(line, usize::from(FRAME_WIDTH), indent)
}
fn framed(line: Line<'static>, centered: bool) -> Line<'static> {
    let count: usize = line.spans.iter().map(|s| s.content.width()).sum();
    let padding = CONTENT_WIDTH.saturating_sub(count);
    let left = if centered { padding / 2 } else { 0 };
    let mut spans = vec![Span::styled("│", Style::default().fg(CYAN)), Span::raw(" ".repeat(left))];
    spans.extend(line.spans);
    spans.push(Span::raw(" ".repeat(padding-left)));
    spans.push(Span::styled("│", Style::default().fg(CYAN)));
    Line::from(spans)
}
pub fn warn(message: impl Into<String>) -> Line<'static> { Line::styled(format!("[!] {}", message.into()), Style::default().fg(YELLOW)) }
pub fn success(message: impl Into<String>) -> Line<'static> { Line::styled(format!("[✓] {}", message.into()), Style::default().fg(GREEN)) }
pub fn text(message: impl Into<String>, color: Color) -> Line<'static> { Line::styled(message.into(), Style::default().fg(color)) }
/// A request in flight: drawn instead of the prompt, with a spinner and the
/// elapsed time, from before the request is sent until its reply.
#[derive(Clone, Debug)]
pub struct Busy { pub status: String, started: Instant }
impl Busy {
    pub fn new(status: impl Into<String>) -> Self { Self { status: status.into(), started: Instant::now() } }
    pub fn line(&self) -> Line<'static> {
        const FRAMES: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
        let elapsed = self.started.elapsed();
        let frame = FRAMES[(elapsed.as_millis() / 100) as usize % FRAMES.len()];
        let text = match elapsed.as_secs() { 0 => format!("{frame} {}", self.status), seconds => format!("{frame} {} {seconds} с", self.status) };
        Line::styled(text, Style::default().fg(CYAN))
    }
}
/// Rows of one screen: the scrollable body (frame + wrapped journal) and the
/// wrapped prompt (or busy status) pinned to the bottom below a spacer row.
pub struct Layout { pub body: Vec<Line<'static>>, pub prompt: Vec<Line<'static>>, pub body_height: u16, pub max_scroll: u16 }
pub fn layout(view: &View, input: &str, hidden: bool, journal: &[Line<'static>], busy: Option<&Busy>, height: u16) -> Layout {
    let mut body = view.lines();
    for line in &view.footer { body.extend(wrap_to(line, usize::from(FRAME_WIDTH), 0)); }
    for line in journal { body.extend(journal_rows(line)); }
    let prompt = |hint: &str| match busy {
        Some(busy) => wrap_to(&busy.line(), usize::from(FRAME_WIDTH), 2),
        None => wrap_to(&Line::raw(format!("{}{}{hint}", view.prompt, if hidden { "" } else { input })), usize::from(FRAME_WIDTH), 0),
    };
    let fit = |prompt: &[Line<'static>]| {
        let rows = if height > 1 { prompt.len().min(usize::from(height) - 1) } else { 0 };
        let body_height = height.saturating_sub(rows as u16 + 1);
        (body_height, body.len().saturating_sub(usize::from(body_height)).min(usize::from(u16::MAX)) as u16)
    };
    let mut rows = prompt("");
    let (mut body_height, mut max_scroll) = fit(&rows);
    if max_scroll > 0 && busy.is_none() {
        // Keep input reachable even when the frame or its journal is long.
        rows = prompt("  [PgUp/PgDn Home/End]");
        (body_height, max_scroll) = fit(&rows);
    }
    rows.truncate(usize::from(height.saturating_sub(1)));
    Layout { body, prompt: rows, body_height, max_scroll }
}
pub fn render(frame: &mut Frame<'_>, view: &View, input: &str, hidden: bool, journal: &[Line<'static>]) {
    render_busy(frame, view, input, hidden, journal, None);
}
pub fn render_busy(frame: &mut Frame<'_>, view: &View, input: &str, hidden: bool, journal: &[Line<'static>], busy: Option<&Busy>) {
    let area = frame.area();
    if area.width < FRAME_WIDTH {
        frame.render_widget(Paragraph::new(warn("Терминал должен быть шириной не менее 70.")), area);
        return;
    }
    let layout = layout(view, input, hidden, journal, busy, area.height);
    let scroll = view.scroll.min(layout.max_scroll);
    frame.render_widget(Paragraph::new(layout.body).scroll((scroll, 0)), Rect { width: FRAME_WIDTH, height: layout.body_height, ..area });
    let rows = layout.prompt.len() as u16;
    if rows > 0 {
        frame.render_widget(Paragraph::new(layout.prompt), Rect { x: area.x, y: area.y + area.height - rows, width: FRAME_WIDTH, height: rows });
    }
}

#[cfg(test)] mod tests {
    use super::*;
    use ratatui::{Terminal, backend::TestBackend};
    fn rows(view: &View) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(80, 35)).unwrap();
        terminal.draw(|f| render(f, view, "", false, &[])).unwrap();
        terminal.backend().buffer().content.chunks(80).map(|r| r.iter().map(|c| c.symbol()).collect::<String>().trim_end().to_owned()).collect()
    }
    #[test] fn frame_structure_context_empty_sections_and_read_only() {
        let mut view = View::menu("Header", vec![Item::new(10,"Action", GREEN)]);
        view.status.push(Line::raw("version"));
        view.context.push(Line::raw("context"));
        view.sections.insert(0, vec![]);
        let rendered = rows(&view);
        let mids: Vec<_> = rendered.iter().enumerate().filter(|(_, s)| s.starts_with('├')).map(|(i,_)| i).collect();
        assert_eq!(mids.len(),2);
        assert!(mids[1] > mids[0]+1);
        assert!(rendered.iter().any(|s| s.contains("10) Action")));
        view.sections.clear();
        assert_eq!(rows(&view).iter().filter(|s| s.starts_with('├')).count(),1);
        view.context.clear();
        view.sections.push(vec![Item::new('n', "Nodes", GREEN)]);
        assert_eq!(rows(&view).iter().filter(|s| s.starts_with('├')).count(),1);
    }
    #[test] fn frame_without_body_has_no_separator_and_sections_never_touch() {
        let rendered = rows(&View::new("Question"));
        assert_eq!(rendered.iter().filter(|s| s.starts_with('├')).count(), 0);
        let mut view = View::menu("Root", vec![Item::new('n',"Nodes",GREEN)]);
        view.sections.push(vec![]);
        view.sections.push(vec![Item::new(0,"Back",NC)]);
        let rendered = rows(&view);
        assert!(rendered.windows(2).all(|pair| !(pair[0].starts_with('├') && pair[1].starts_with('├'))));
        assert!(rendered.iter().any(|s| s.starts_with('└')) && rendered.iter().all(|s| s.chars().count() <= FRAME_WIDTH as usize));
    }
    /// User rule (common.sh `menu_item`): only `key)` carries the semantic
    /// colour; the colour is reset before the label.
    #[test] fn item_colour_covers_only_the_key() {
        let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
        let view = View::menu("Root", vec![Item::new(10, "Action", GREEN)]);
        terminal.draw(|f| render(f, &view, "", false, &[])).unwrap();
        let buffer = terminal.backend().buffer();
        let row = (0..buffer.area.height).find(|y| (0..80).map(|x| buffer[(x, *y)].symbol()).collect::<String>().contains("10) Action")).unwrap();
        let line: String = (0..80).map(|x| buffer[(x, row)].symbol()).collect();
        let cell = |text: &str| line[..line.find(text).unwrap()].chars().count() as u16;
        let (key, label) = (cell("10)"), cell("Action"));
        assert!((key..key + 3).all(|x| buffer[(x, row)].fg == GREEN));
        assert!((label..label + 6).all(|x| buffer[(x, row)].fg == Color::Reset));
    }
    #[test] fn hidden_entry_never_renders_secret() {
        let mut terminal = Terminal::new(TestBackend::new(80,25)).unwrap();
        terminal.draw(|f| render(f,&View::new("Secret"),"PRIVATE",true,&[])).unwrap();
        assert!(!terminal.backend().buffer().content.iter().map(|c| c.symbol()).collect::<String>().contains("PRIVATE"));
    }
    fn screen(view: &View, journal: &[Line<'static>], height: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(80, height)).unwrap();
        terminal.draw(|f| render(f, view, "", false, journal)).unwrap();
        terminal.backend().buffer().content.chunks(80).map(|r| r.iter().map(|c| c.symbol()).collect::<String>().trim_end().to_owned()).collect()
    }
    /// The user's report: a long core error was cut at the frame edge. Every
    /// word of it is on screen, no row is wider than the frame, and the
    /// continuation rows are indented under the text after `[✗] `.
    #[test] fn long_russian_error_wraps_fully_inside_the_frame_width() {
        let message = "[✗] Не удалось подключить GitHub (этап: проверка файлов репозитория GitHub): В хранилище конфигурации GitHub обнаружен недопустимый путь: ssh/known_hosts";
        let journal = [text(message, RED), warn("Операция завершилась ошибкой. Повторите действие из меню.")];
        let rows = screen(&View::menu("Источник конфигурации", vec![Item::new('g', "Подключить GitHub", GREEN)]), &journal, 30);
        assert!(rows.iter().all(|row| row.chars().count() <= usize::from(FRAME_WIDTH)), "{rows:#?}");
        let start = rows.iter().position(|row| row.starts_with("[✗] Не удалось")).expect("error shown");
        let end = rows.iter().position(|row| row.starts_with("[!] Операция")).expect("hint shown");
        assert!(end - start >= 3, "wrapped over several rows: {rows:#?}");
        assert!(rows[start + 1..end].iter().all(|row| row.starts_with("    ") && !row.starts_with("     ")), "{rows:#?}");
        let shown = rows[start..end].iter().map(|row| row.trim()).collect::<Vec<_>>().join(" ");
        assert_eq!(shown, message, "every word is visible, none is split");
        // The frame interior wraps by words too and keeps the line's colour.
        let mut view = View::new("План");
        view.context.push(warn(message));
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();
        terminal.draw(|f| render(f, &view, "", false, &[])).unwrap();
        let buffer = terminal.backend().buffer();
        let framed: Vec<String> = buffer.content.chunks(80).map(|r| r.iter().map(|c| c.symbol()).collect::<String>().trim_end().to_owned()).collect();
        let body: Vec<&str> = framed.iter().filter(|row| row.starts_with('│')).skip(1).map(|row| row.trim_start_matches('│').trim_end_matches('│').trim()).collect();
        assert_eq!(body.join(" "), format!("[!] {message}"));
        assert!(framed.iter().all(|row| row.chars().count() <= usize::from(FRAME_WIDTH)));
        let row = framed.iter().position(|row| row.contains("[!] [✗]")).unwrap() as u16;
        assert_eq!(buffer[(2, row)].fg, YELLOW, "the line style survives wrapping");
    }
    /// A long prompt (question with a repository name) wraps above the bottom
    /// row instead of being cut; a busy status replaces the prompt.
    #[test] fn long_prompt_wraps_and_busy_status_replaces_it() {
        let mut view = View::new("Создание репозитория");
        view.prompt = "Создать приватный репозиторий Morvex885/essence-remote-control-config? (y/N): ".into();
        let rows = screen(&view, &[], 12);
        let tail = rows[rows.len() - 2..].iter().map(|row| row.trim()).collect::<Vec<_>>().join(" ");
        assert_eq!(tail, view.prompt.trim());
        let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
        terminal.draw(|f| render_busy(f, &view, "", false, &[], Some(&Busy::new("Подключение к GitHub…")))).unwrap();
        let last: String = terminal.backend().buffer().content.chunks(80).last().unwrap().iter().map(|c| c.symbol()).collect();
        assert!(last.contains("Подключение к GitHub…") && !last.contains("Создать"), "{last}");
    }
    fn reversed(buffer: &ratatui::buffer::Buffer, y: u16) -> bool { buffer[(0, y)].modifier.is_empty() && buffer[(FRAME_WIDTH - 1, y)].modifier.is_empty() && (1..FRAME_WIDTH - 1).all(|x| buffer[(x, y)].modifier.contains(Modifier::REVERSED) && buffer[(x, y)].fg == Color::Reset) }
    fn plain(buffer: &ratatui::buffer::Buffer, y: u16) -> bool { (0..FRAME_WIDTH).all(|x| !buffer[(x, y)].modifier.contains(Modifier::REVERSED)) }
    /// The highlighted item is one even reverse-video bar between the borders:
    /// its key colour is hidden, the borders and the other items are untouched.
    #[test] fn cursor_reverses_the_whole_item_row_inside_the_borders() {
        let mut view = View::menu("Root", vec![Item::new('n', "Nodes", GREEN)]);
        view.sections.push(vec![Item::new('c', "Clients", YELLOW), Item::new(0, "Exit", NC)]);
        view.cursor = Some(1);
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();
        terminal.draw(|f| render(f, &view, "", false, &[])).unwrap();
        let buffer = terminal.backend().buffer();
        let text = |y: u16| (0..80).map(|x| buffer[(x, y)].symbol()).collect::<String>();
        let row = |label: &str| (0..20).find(|y| text(*y).contains(label)).unwrap();
        assert!(reversed(buffer, row("c) Clients")));
        assert!(plain(buffer, row("n) Nodes")) && plain(buffer, row("0) Exit")));
        assert!(view.lines().iter().all(|line| line.width() <= usize::from(FRAME_WIDTH)));
        let index = view.lines().iter().position(|l| l.to_string().contains("c) Clients")).unwrap();
        assert_eq!(view.cursor_rows(), Some((index, index)));
        view.cursor = Some(3);
        assert_eq!(view.cursor_rows(), None);
    }
    #[test] fn cursor_covers_every_wrapped_row_of_a_long_item() {
        let label = "очень длинная подпись пункта ".repeat(4);
        let mut view = View::menu("Root", vec![Item::new(1, label.trim(), CYAN), Item::new(0, "Back", NC)]);
        view.cursor = Some(0);
        let (first, last) = view.cursor_rows().unwrap();
        assert_eq!(last, first + 1);
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();
        terminal.draw(|f| render(f, &view, "", false, &[])).unwrap();
        let buffer = terminal.backend().buffer();
        assert!(reversed(buffer, first as u16) && reversed(buffer, last as u16));
        assert!(plain(buffer, last as u16 + 1));
    }
    #[test] fn footer_sits_under_the_frame_above_the_journal() {
        let mut view = View::menu("Root", vec![Item::new('n', "Nodes", GREEN)]);
        view.footer.push(text("hint", DIM));
        let rows = screen(&view, &[warn("journal")], 20);
        let bottom = rows.iter().position(|row| row.starts_with('└')).unwrap();
        assert_eq!(rows[bottom + 1], "hint");
        assert_eq!(rows[bottom + 2], "[!] journal");
        assert!(view.lines().iter().all(|line| line.to_string() != "hint"));
    }
    /// Wide characters take two columns: rows wrap by columns and the right
    /// border stays in the last frame column.
    #[test] fn wide_characters_wrap_by_columns_and_keep_the_right_border() {
        let words = "界面 ".repeat(30);
        let mut view = View::new("标题 заголовок");
        view.context.push(Line::raw(words.trim().to_owned()));
        view.context.push(Line::raw("界".repeat(50)));
        let mut terminal = Terminal::new(TestBackend::new(80, 40)).unwrap();
        terminal.draw(|f| render(f, &view, "", false, &[])).unwrap();
        let buffer = terminal.backend().buffer();
        let framed: Vec<u16> = (0..40).filter(|y| buffer[(0, *y)].symbol() == "│").collect();
        assert!(framed.len() >= 6, "title and wrapped rows");
        assert!(framed.iter().all(|y| buffer[(FRAME_WIDTH - 1, *y)].symbol() == "│"), "right border in place");
        assert!(view.lines().iter().all(|line| line.width() == usize::from(FRAME_WIDTH) || line.width() == 0));
        let rows = wrap(&Line::raw(words.trim().to_owned()));
        assert!(rows.iter().all(|row| row.width() <= CONTENT_WIDTH) && rows.len() == 3);
        assert_eq!(rows.iter().map(ToString::to_string).collect::<Vec<_>>().join(" "), words.trim(), "split only between words");
        let journal = wrap_to(&Line::raw(format!("[✗] {}", "界".repeat(60))), usize::from(FRAME_WIDTH), 4);
        assert!(journal.iter().all(|row| row.width() <= usize::from(FRAME_WIDTH)));
        assert!(journal[1..].iter().all(|row| row.to_string().starts_with("    界")));
    }
}
