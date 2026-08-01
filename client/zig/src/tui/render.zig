//! Paint a `Model` onto a libvaxis window. This file MAKES NO DECISIONS: every
//! number it uses comes from `ledger.layoutFor` / `m.scroll_top` / `m.rows`, and
//! every user-visible string that the CLI also emits comes from `core/display.zig`.
//! If something here starts computing a threshold, a fold rule or a row-visibility
//! rule, it belongs in `ledger.zig` — that separation is what keeps the whole model
//! layer testable without a terminal.
//!
//! There are no unit tests here by design (spec §14) — a renderer's output is the
//! screen. The `test { refAllDecls }` at the bottom exists only to force the
//! compiler to actually analyse these function bodies: a test build analyses only
//! what a `test` block reaches, and nothing else imports this file yet.
const std = @import("std");
const vaxis = @import("vaxis");

const display = @import("../core/display.zig");
const view = @import("../core/view.zig");
const taskmod = @import("../core/task.zig");
const Task = taskmod.Task;
const Status = taskmod.Status;
const Priority = taskmod.Priority;
const ledger = @import("ledger.zig");
const editors = @import("editors.zig");
const model = @import("model.zig");
const Model = model.Model;
const FieldId = model.FieldId;

// ─── styles ──────────────────────────────────────────────────────────────────

// The SHARED half: `display.Style` is the vocabulary the CLI and the TUI both
// speak, so this mapping is the only place the TUI decides how it looks.
fn vxStyle(s: display.Style) vaxis.Style {
    return switch (s) {
        .normal => .{},
        .dim => .{ .dim = true },
        .overdue => .{ .fg = .{ .index = 1 }, .bold = true },
        .prio_high => .{ .fg = .{ .index = 1 } },
        .prio_medium => .{ .fg = .{ .index = 3 } },
        .prio_low => .{ .fg = .{ .index = 4 } },
    };
}

// The TUI-ONLY half: nothing below has a CLI counterpart, so none of it may
// become a `display.Style` variant (that enum is what stops the two renderers
// drifting on what a *task* looks like; a cursor bar is not a property of a task).
const cursor_bg: vaxis.Color = .{ .index = 8 };
const chrome: vaxis.Style = .{ .dim = true }; // rails, connectors, labels, key bar
const header_style: vaxis.Style = .{ .bold = true };
const saving_style: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
const badge_style: vaxis.Style = .{ .fg = .{ .index = 3 } };
const warn_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
const status_style: vaxis.Style = .{ .fg = .{ .index = 6 } };
const focus_style: vaxis.Style = .{ .bg = .{ .index = 8 }, .bold = true };

fn onCursor(s: vaxis.Style, highlighted: bool) vaxis.Style {
    if (!highlighted) return s;
    var out = s;
    out.bg = cursor_bg;
    return out;
}

// ─── primitives ──────────────────────────────────────────────────────────────

// Print one styled run at (row, col) and return the column after it. `.none` wrap
// makes `PrintResult.col` exactly "where the next run starts", which is what lets
// a row be composed left-to-right out of differently-styled pieces with no
// width bookkeeping of our own.
fn put(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (row >= win.height or col >= win.width) return col;
    return win.printSegment(
        .{ .text = text, .style = style },
        .{ .row_offset = row, .col_offset = col, .wrap = .none },
    ).col;
}

fn clampU16(n: usize) u16 {
    return @intCast(@min(n, std.math.maxInt(u16)));
}

// ─── entry point ─────────────────────────────────────────────────────────────

pub fn draw(win: vaxis.Window, m: *const Model) void {
    win.clear();
    win.hideCursor(); // only an open prompt/editor turns it back on

    // 3 = header + the rule above the footer + the footer, matching the
    // `viewport.rows -| 3` that `model.recompute` fed to `ensureVisible`. If this
    // and that ever disagree, the scroll offset stops matching what is on screen.
    const layout = ledger.layoutFor(win.height -| 3, m.pane_open);
    const ledger_rows = clampU16(layout.ledger_rows);
    const pane_rows = clampU16(layout.pane_rows);

    drawHeader(win.child(.{ .height = 1 }), m, layout);
    drawLedger(win.child(.{ .y_off = 1, .height = ledger_rows }), m);
    if (pane_rows > 0)
        drawPane(win.child(.{ .y_off = 1 + @as(i17, ledger_rows), .height = pane_rows }), m);

    // The one row `layoutFor`'s `-| 3` reserves that is neither header nor footer.
    drawRule(win.child(.{ .y_off = win.height -| 2, .height = 1 }));
    drawFooter(win.child(.{ .y_off = win.height -| 1, .height = 1 }), m);
}

fn drawRule(win: vaxis.Window) void {
    var col: u16 = 0;
    while (col < win.width) : (col += 1) _ = put(win, 0, col, "─", chrome);
}

// ─── header ──────────────────────────────────────────────────────────────────

// `N` is the FETCHED task count, not the row count: when a cycle strands tasks
// under the unreachable header, or a fold hides a subtree, the discrepancy
// between "rows n–m" and "of N" is the only place it shows.
fn drawHeader(win: vaxis.Window, m: *const Model, layout: ledger.Layout) void {
    var buf: [512]u8 = undefined;
    const first: usize = if (m.rows.len == 0) 0 else m.scroll_top + 1;
    const last: usize = @min(m.scroll_top + layout.ledger_rows, m.rows.len);
    const scope: []const u8 = if (m.filtering and m.filter_expr.len > 0) m.filter_expr else "all";
    const text = std.fmt.bufPrint(&buf, "{s} · {s} · rows {d}–{d} of {d} · {d} overdue", .{
        scope,
        @tagName(m.strategy),
        first,
        last,
        m.tasks.len,
        overdueCount(m),
    }) catch buf[0..0];

    var col = put(win, 0, 0, text, header_style);
    if (m.in_flight != .none) {
        col = put(win, 0, col, " · ", chrome);
        _ = put(win, 0, col, "saving…", saving_style);
    }
}

// Reuses `view.matchesSelf` with the same `overdue` filter the CLI's
// `--filter overdue` uses, so "overdue" cannot mean two different things in the
// two front ends. Nothing about the predicate is defined here.
fn overdueCount(m: *const Model) usize {
    var n: usize = 0;
    for (m.tasks) |t| {
        if (view.matchesSelf(t, .{ .overdue = true }, m.now)) n += 1;
    }
    return n;
}

// ─── ledger ──────────────────────────────────────────────────────────────────

fn drawLedger(win: vaxis.Window, m: *const Model) void {
    // The three degenerate states, in precedence order. A failed FIRST load has
    // no data at all, so it must win over "no tasks yet"; and "no tasks yet"
    // must win over "nothing matched", because an empty server is not a failed
    // filter.
    if (m.load_failed) {
        _ = put(win, 0, 0, "could not reach the server — R to retry, q to quit", warn_style);
        if (m.status().len > 0) _ = put(win, 1, 0, m.status(), chrome);
        return;
    }
    if (m.tasks.len == 0) {
        _ = put(win, 0, 0, "no tasks yet — press a to add one", chrome);
        return;
    }
    if (m.rows.len == 0 and m.filtering) {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "no tasks match {s} — esc to clear", .{m.filter_expr}) catch
            "no tasks match that filter — esc to clear";
        _ = put(win, 0, 0, text, chrome);
        return;
    }

    const cursor = m.cursorIndex();
    var i = m.scroll_top;
    var y: u16 = 0;
    while (i < m.rows.len and y < win.height) : ({
        i += 1;
        y += 1;
    }) {
        drawRow(win, m, m.rows[i], y, cursor != null and cursor.? == i);
    }
}

fn drawRow(win: vaxis.Window, m: *const Model, row: ledger.Row, y: u16, is_cursor: bool) void {
    if (is_cursor)
        win.child(.{ .y_off = y, .height = 1 }).fill(.{ .style = .{ .bg = cursor_bg } });

    // The cursor marker gets its OWN column, to the left of the fold marker.
    // Sharing one column would make a collapsed parent (`▸`) indistinguishable
    // from the selected row (`▸`) — the single most confusing thing a ledger can
    // do, since both are extremely common.
    var col = put(win, y, 0, if (is_cursor) "▸ " else "  ", onCursor(chrome, is_cursor));

    switch (row.kind) {
        .unreachable_header => {
            _ = put(win, y, col, "⚠ unreachable", onCursor(warn_style, is_cursor));
            return;
        },
        .missing => {
            col = put(win, y, col, "  ", onCursor(chrome, is_cursor)); // no fold marker
            col = drawTreeRail(win, y, col, row, is_cursor);
            var buf: [40]u8 = undefined;
            const handle = display.handleText(&buf, row.id, handle_len);
            col = put(win, y, col, "[missing: ", onCursor(vxStyle(.dim), is_cursor));
            col = put(win, y, col, handle, onCursor(vxStyle(.dim), is_cursor));
            _ = put(win, y, col, "]", onCursor(vxStyle(.dim), is_cursor));
            return;
        },
        .task => {},
    }

    const t = lookup(m, row.id) orelse {
        // A `.task` row whose id is not in the Index cannot happen — `buildRows`
        // only emits one for a task it read out of that same Index — but a
        // renderer must never be the thing that crashes on impossible data.
        _ = put(win, y, col, row.id, onCursor(vxStyle(.dim), is_cursor));
        return;
    };

    // A fold marker only where there is something to fold. Read off the task's
    // own children rather than a rule invented here: a node whose child ids all
    // dangle still expands, into `.missing` rows.
    const fold: []const u8 = if (t.content.child_ids.len == 0)
        "  "
    else if (row.expanded)
        "▾ "
    else
        "▸ ";
    col = put(win, y, col, fold, onCursor(chrome, is_cursor));
    col = drawTreeRail(win, y, col, row, is_cursor);

    // `row.dimmed` is already computed by `buildRows` (a filter hit's ancestors
    // are context, not results). Read it; never re-derive the predicate here.
    const base: display.Style = if (row.dimmed) .dim else display.taskStyle(t.content.status, t.content.priority);
    const base_vx = onCursor(vxStyle(base), is_cursor);

    col = put(win, y, col, display.statusGlyph(t.content.status), base_vx);
    col = put(win, y, col, " ", base_vx);

    // Everything to the right of the title is measured first, so the title's
    // truncation budget is whatever is left over. `display.truncate` counts
    // codepoints, not columns — the same documented v1 limit the CLI has.
    var badge_buf: [48]u8 = undefined;
    const badge = collapsedBadge(&badge_buf, row);
    var due_buf: [96]u8 = undefined;
    const due: ?display.DueWording = if (t.content.due_at) |d|
        display.dueWording(&due_buf, d, m.now, display.isCompleted(t.content.status), m.offset_minutes)
    else
        null;
    const due_text: []const u8 = if (due) |w| switch (w) {
        .due => |x| x.text,
        .overdue => |x| x.text,
    } else "";
    var handle_buf: [40]u8 = undefined;
    const handle = display.handleText(&handle_buf, t.id, handle_len);

    const tail_cols = win.gwidth(badge) + win.gwidth(due_text) + win.gwidth(handle) + 3;
    const budget = (win.width -| col) -| tail_cols;
    col = put(win, y, col, display.truncate(t.content.title, budget), base_vx);

    if (badge.len > 0) {
        col = put(win, y, col, " ", base_vx);
        col = put(win, y, col, badge, onCursor(badge_style, is_cursor));
    }
    if (due) |w| {
        col = put(win, y, col, " ", base_vx);
        col = put(win, y, col, due_text, onCursor(vxStyle(display.dueStyle(w)), is_cursor));
    }
    col = put(win, y, col, " ", base_vx);
    _ = put(win, y, col, handle, onCursor(vxStyle(.dim), is_cursor));
}

// `├─`/`└─` from `last_sibling`, indented by `depth`. Depth 0 draws nothing;
// the unreachable section starts its tasks at depth 1, so they get a rail under
// the header for free.
fn drawTreeRail(win: vaxis.Window, y: u16, col_in: u16, row: ledger.Row, is_cursor: bool) u16 {
    var col = col_in;
    if (row.depth == 0) return col;
    var d: u16 = 1;
    while (d < row.depth) : (d += 1) col = put(win, y, col, "   ", onCursor(chrome, is_cursor));
    return put(win, y, col, if (row.last_sibling) "└─ " else "├─ ", onCursor(chrome, is_cursor));
}

fn collapsedBadge(buf: []u8, row: ledger.Row) []const u8 {
    if (row.expanded or row.descendants == 0) return "";
    if (row.attention == 0)
        return std.fmt.bufPrint(buf, "(+{d})", .{row.descendants}) catch "";
    return std.fmt.bufPrint(buf, "(+{d} · ⚠{d})", .{ row.descendants, row.attention }) catch "";
}

// The CLI derives this from `view.minUniqueSuffixLen` over the whole fetched set,
// which needs an allocator and can fail — neither of which a `draw` has. 4 is that
// function's own floor. See the task report: the per-session value belongs on the
// Model, computed once in `recompute`, not here.
const handle_len: usize = 4;

fn lookup(m: *const Model, id: []const u8) ?Task {
    if (!m.idx_built) return null;
    return m.idx.by_id.get(id);
}

// ─── detail pane ─────────────────────────────────────────────────────────────

const pane_fields = [_]FieldId{ .title, .description, .status, .priority, .due, .scheduled, .tags };
const label_col: u16 = 14;

fn drawPane(win: vaxis.Window, m: *const Model) void {
    if (m.load_failed) return; // the ledger already says why there is nothing
    const t = cursorTask(m) orelse {
        _ = put(win, 0, 0, "nothing selected", chrome);
        return;
    };
    const focused = focusedField(m);

    for (pane_fields, 0..) |f, i| {
        const y: u16 = @intCast(i);
        if (y >= win.height) return;
        const is_focus = focused != null and focused.? == f;
        if (is_focus)
            win.child(.{ .y_off = y, .height = 1 }).fill(.{ .style = .{ .bg = cursor_bg } });
        var col = put(win, y, 0, if (is_focus) "▸ " else "  ", onCursor(chrome, is_focus));
        col = put(win, y, col, @tagName(f), onCursor(chrome, is_focus));
        drawFieldValue(win, m, t, f, y, @max(col, label_col), is_focus);
    }
}

fn drawFieldValue(
    win: vaxis.Window,
    m: *const Model,
    t: Task,
    f: FieldId,
    y: u16,
    col_in: u16,
    is_focus: bool,
) void {
    // The editor OVERLAY: while `.editing` this field, what is on screen is what
    // the user is typing, not what the server last confirmed.
    switch (m.mode) {
        .editing => |e| if (e.field == f) {
            drawEditor(win, e.editor, f, y, col_in);
            return;
        },
        else => {},
    }

    const plain = onCursor(.{}, is_focus);
    const dim = onCursor(vxStyle(.dim), is_focus);
    var col = col_in;
    var buf: [64]u8 = undefined;

    switch (f) {
        .title => _ = put(win, y, col, t.content.title, onCursor(vxStyle(display.taskStyle(t.content.status, t.content.priority)), is_focus)),
        .description => {
            if (t.content.description.len == 0) {
                _ = put(win, y, col, "(no description) — ⏎ on description to add", dim);
                return;
            }
            // One line only: the pane is a summary, and the full text is what
            // $EDITOR is for.
            const line = firstLine(t.content.description);
            _ = put(win, y, col, line, plain);
        },
        .status => {
            col = put(win, y, col, display.statusGlyph(t.content.status), plain);
            col = put(win, y, col, " ", plain);
            _ = put(win, y, col, @tagName(t.content.status), plain);
        },
        .priority => _ = put(win, y, col, display.priorityLabel(t.content.priority), onCursor(vxStyle(display.priorityStyle(t.content.priority)), is_focus)),
        .due => _ = put(win, y, col, dateOrDash(&buf, t.content.due_at, m.offset_minutes), if (t.content.due_at == null) dim else plain),
        .scheduled => _ = put(win, y, col, dateOrDash(&buf, t.content.scheduled_at, m.offset_minutes), if (t.content.scheduled_at == null) dim else plain),
        .tags => {
            if (t.content.tags.len == 0) {
                _ = put(win, y, col, "—", dim);
                return;
            }
            for (t.content.tags, 0..) |tag, i| {
                if (i > 0) col = put(win, y, col, " ", plain);
                col = put(win, y, col, "#", dim);
                col = put(win, y, col, tag, plain);
            }
        },
    }
}

fn drawEditor(win: vaxis.Window, editor: model.Editor, f: FieldId, y: u16, col_in: u16) void {
    switch (editor) {
        .line => |le| {
            const txt = le.text();
            const col = put(win, y, col_in, txt, focus_style);
            _ = col;
            const cur = @min(le.cursor, txt.len);
            win.showCursor(col_in + win.gwidth(txt[0..cur]), y);
        },
        .pick => |pe| {
            var col = put(win, y, col_in, "◂ ", chrome);
            col = put(win, y, col, pickLabel(f, pe.index), focus_style);
            _ = put(win, y, col, " ▸", chrome);
        },
        // The description is edited OUT of process. `null` means $EDITOR has not
        // come back yet; a retained value means it did and the commit is either
        // in flight or was rejected — either way the text is still the user's.
        .external => |retained| {
            if (retained) |text| {
                _ = put(win, y, col_in, firstLine(text), focus_style);
            } else {
                _ = put(win, y, col_in, "editing in $EDITOR…", chrome);
            }
        },
    }
}

fn pickLabel(f: FieldId, index: usize) []const u8 {
    return switch (f) {
        .status => enumName(Status, index),
        .priority => enumName(Priority, index),
        else => "",
    };
}

fn enumName(comptime E: type, index: usize) []const u8 {
    const names = std.meta.fieldNames(E);
    if (index >= names.len) return "";
    return names[index];
}

fn dateOrDash(buf: []u8, at: ?i64, offset_minutes: i32) []const u8 {
    const unix = at orelse return "—";
    return display.formatDate(buf, unix, offset_minutes);
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn focusedField(m: *const Model) ?FieldId {
    return switch (m.mode) {
        .field => |f| f,
        .editing => |e| e.field,
        else => null,
    };
}

fn cursorTask(m: *const Model) ?Task {
    const id = m.cursor_id orelse return null;
    return lookup(m, id);
}

// ─── footer ──────────────────────────────────────────────────────────────────

fn drawFooter(win: vaxis.Window, m: *const Model) void {
    // A prompt outranks the status line: the user is typing into it right now,
    // and it is the only place the typed text appears.
    switch (m.mode) {
        .filter => |le| return drawPrompt(win, "filter ", &le),
        .add => |le| return drawPrompt(win, "new task ", &le),
        else => {},
    }
    const s = m.status();
    if (s.len > 0) {
        _ = put(win, 0, 0, s, status_style);
        return;
    }
    _ = put(win, 0, 0, keyBar(m), chrome);
}

fn drawPrompt(win: vaxis.Window, label: []const u8, le: *const editors.LineEditor) void {
    var col = put(win, 0, 0, label, chrome);
    const start = col;
    const txt = le.text();
    col = put(win, 0, col, txt, .{});
    const cur = @min(le.cursor, txt.len);
    win.showCursor(start + win.gwidth(txt[0..cur]), 0);
}

fn keyBar(m: *const Model) []const u8 {
    return switch (m.mode) {
        .list => "j/k move · h/l fold · ⏎ open · space done · a add · x delete · / filter · tab pane · R refresh · q quit",
        .field => "↑/↓ field · ⏎ edit · esc back",
        .editing => |e| switch (e.editor) {
            .line => "⏎ save · esc cancel",
            .pick => "↑/↓ choose · ⏎ save · esc cancel",
            .external => "⏎ save · esc cancel",
        },
        .filter => "tag:NAME · status:todo,done · overdue — ⏎ apply · esc cancel",
        .add => "⏎ create · esc cancel",
        .confirm_delete => "y delete · n cancel",
    };
}

test {
    // NOT a behavioural test — there are none here by design (spec §14). A bare
    // `_ = @import("tui/render.zig")` in main.zig's aggregator would link the file
    // into the test build WITHOUT analysing a single function body, so a file full
    // of type errors would still "build clean". `refAllDecls` references `draw`,
    // which forces its body and everything it calls to be analysed for real.
    std.testing.refAllDecls(@This());
}
