//! Paint a `Model` onto a libvaxis window. This file MAKES NO DECISIONS: every
//! number it uses comes from `ledger.layoutFor` / `m.scroll_top` / `m.rows`, and
//! every user-visible string that the CLI also emits comes from `core/display.zig`.
//! If something here starts computing a threshold, a fold rule or a row-visibility
//! rule, it belongs in `ledger.zig` — that separation is what keeps the whole model
//! layer testable without a terminal.
//!
//! There are no tests of what this file LOOKS LIKE, by design (spec §14) — a
//! renderer's aesthetics are the screen, and that is the human checkpoint's job.
//! The `test { refAllDecls }` at the bottom exists only to force the compiler to
//! actually analyse these function bodies: a test build analyses only what a
//! `test` block reaches.
//!
//! The two real tests at the bottom test INVARIANTS the look depends on, not the
//! look. Both were written after the thing they check had already shipped broken
//! and been found by a human at a terminal, which is the bar for adding another:
//!  * a MEMORY invariant — libvaxis cells borrow the strings written into them,
//!    so `draw` has to outlive itself (see "frame scratch" below);
//!  * a LAYOUT invariant — whatever the model lets the user select, this file has
//!    to paint a selection bar for it. A pane one row shorter than its own field
//!    list is not an aesthetic problem, it is a selection you cannot see.
//! A `vaxis.Window` needs only a `Screen`, so neither costs a TTY.
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

// ─── frame scratch ───────────────────────────────────────────────────────────
//
// WHY THIS EXISTS, because getting it wrong is invisible until it is on screen:
// libvaxis's `writeCell` stores a cell's grapheme as a **slice of the text handed
// to `printSegment`**. It copies nothing. The screen is not drained until
// `vx.render` runs, which is AFTER `draw` has returned — so a string formatted
// into a local `[N]u8` inside any helper here is DANGLING by the time it reaches
// the terminal, and renders as whatever has since reused that stack. Observed
// off-screen: with per-function stack buffers, row 0 (the header) read back as
// the first ledger row's bytes, because `drawRow` was called after `drawHeader`
// returned and landed on the same stack.
//
// So every formatted string in this file comes from here instead: one bump
// buffer, reset at the top of `draw`, alive until the next `draw` — which is
// exactly the lifetime a cell's grapheme needs. Strings that already outlive the
// frame (task text in the model's live arena, editor buffers, `m.status()`,
// `@tagName`, string literals) are passed straight through and must NOT be
// copied here.
//
// Single-threaded by construction: `draw` is only ever called from the shell's
// event loop, on the same thread that then calls `vx.render`.
const frame_bytes = 64 * 1024;
var frame_buf: [frame_bytes]u8 = undefined;
var frame_used: usize = 0;

// A slice of the frame buffer, or null once a frame has used it all (a terminal
// tall enough to need more than 64 KB of formatted text in one paint). Returning
// null makes the caller drop that one string; handing back a wrapped slice would
// silently rewrite text already committed to another row's cells.
fn frameTake(n: usize) ?[]u8 {
    if (frame_bytes - frame_used < n) return null;
    defer frame_used += n;
    return frame_buf[frame_used..][0..n];
}

// ─── entry point ─────────────────────────────────────────────────────────────

pub fn draw(win: vaxis.Window, m: *const Model) void {
    // The previous frame's strings are still referenced by the cells `win.clear()`
    // is about to overwrite, and by nothing afterwards. See `frameTake`.
    frame_used = 0;
    win.clear();
    win.hideCursor(); // only an open prompt/editor turns it back on

    // The header, the rule above the footer, and the footer. `chrome_rows` is
    // shared with `model.recompute`, which subtracts the same amount before
    // handing `layoutFor`'s result to `ensureVisible` — if the two ever disagreed,
    // `scroll_top` would stop describing what is on screen.
    const layout = ledger.layoutFor(win.height -| ledger.chrome_rows, m.pane_open);
    const ledger_rows = clampU16(layout.ledger_rows);
    const pane_rows = clampU16(layout.pane_rows);

    drawHeader(win.child(.{ .height = 1 }), m, layout);
    drawLedger(win.child(.{ .y_off = 1, .height = ledger_rows }), m);
    if (pane_rows > 0)
        drawPane(win.child(.{ .y_off = 1 + @as(i17, ledger_rows), .height = pane_rows }), m);

    // The one row of `chrome_rows` that is neither the header nor the footer.
    //
    // Below `chrome_rows` there is not room for all three, and `-| 2` / `-| 1`
    // both collapse toward row 0 — so at heights 1 and 2 the rule and the footer
    // landed ON TOP of the header. Nothing writes out of bounds (vaxis clamps),
    // but three lines stacked in one row is unreadable. Degrade top-down instead,
    // dropping the rule first and then the footer: whatever fits is legible.
    if (win.height >= ledger.chrome_rows)
        drawRule(win.child(.{ .y_off = win.height -| 2, .height = 1 }));
    if (win.height >= 2)
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
    const buf = frameTake(512) orelse return; // see `frameTake` — never a stack buffer
    const first: usize = if (m.rows.len == 0) 0 else m.scroll_top + 1;
    const last: usize = @min(m.scroll_top + layout.ledger_rows, m.rows.len);
    // CAP THE SCOPE. Every other piece of this line has a small fixed maximum;
    // `m.filter_expr` is user-typed and unbounded, so a long `/` expression
    // overflowed `buf` and `catch buf[0..0]` blanked the WHOLE header — sort, row
    // range, task count and overdue count all vanishing together because one
    // filter was long. `display.truncate` counts codepoints, so this bounds the
    // scope at 4×80 bytes and leaves the fixed part ample room in `buf`.
    const scope_max_cols = 80;
    const scope = display.truncate(
        if (m.filtering and m.filter_expr.len > 0) m.filter_expr else "all",
        scope_max_cols,
    );
    const text = std.fmt.bufPrint(buf, "{s} · {s} · rows {d}–{d} of {d} · {d} overdue", .{
        scope,
        @tagName(m.strategy),
        first,
        last,
        m.tasks.len,
        overdueCount(m),
    }) catch buf[0..0];

    var col = put(win, 0, 0, text, header_style);
    // A REFRESH IS NOT A SAVE, and this marker used to claim one for every
    // in-flight request — pressing `R` said the TUI was writing to the server when
    // it was only reading. So the marker now means exactly one thing: A WRITE IS
    // OUTSTANDING. A refresh gets no header marker at all.
    //
    // ONE SURFACE, not two. The refresh signal lives on the STATUS LINE
    // (`model.refreshing_status`, written by `R` the instant it dispatches and
    // held until the reply, because `retractStatus` will not take back an
    // in-flight message). That is the surface the user is actually reading — it
    // sits beside the key bar and the prompt at the bottom of the screen — and it
    // is there precisely BECAUSE this header marker lost that argument once
    // already: for a refused connection it lives for milliseconds, "gone before
    // the eye reaches it", which is what made `R` look like a dead key. Echoing
    // the same word up here would be noise on the one line that is now scarce.
    const outstanding_write = switch (m.in_flight) {
        .commit, .create, .delete => true,
        .none, .refresh => false,
    };
    if (outstanding_write) {
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
        const fallback = "no tasks match that filter — esc to clear";
        const text = if (frameTake(256)) |buf|
            std.fmt.bufPrint(buf, "no tasks match {s} — esc to clear", .{m.filter_expr}) catch fallback
        else
            fallback;
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
            const handle = if (frameTake(40)) |buf| display.handleText(buf, row.id, m.handle_len) else "";
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

    // ── the right-hand handle column ─────────────────────────────────────────
    //
    // The `#handle` gets its own right-aligned column instead of trailing the
    // title. Down a screen whose titles are all different lengths an inline handle
    // is unfindable, and the handle is how the user names a task at the CLI.
    //
    // Its width is NOT a constant: `m.handle_len` is `view.minUniqueSuffixLen`
    // over the whole fetched set and widens whenever two id tails collide, so it
    // is read off the model — the same number the CLI uses, for the same reason.
    const handle = if (frameTake(40)) |b| display.handleText(b, t.id, m.handle_len) else "";
    const handle_cols = clampU16(m.handle_len + 1); // '#' plus the id tail
    // Decided from `win.width` ALONE, never from this row's `col`: a per-row
    // decision would make the column appear and disappear down the screen as the
    // tree indent changes, which is the one thing a column exists to prevent.
    const show_handle = handle.len > 0 and win.width >= handle_cols + 1 + min_row_cols;
    // At least one blank column between the row's text and the handle.
    const right_edge: u16 = if (show_handle) win.width -| (handle_cols + 1) else win.width;

    // Everything else on the row is measured first, so the title's truncation
    // budget is whatever is left of `right_edge`. `display.truncate` counts
    // codepoints, not columns — the same documented v1 limit the CLI has. Both
    // strings come out of the FRAME buffer, not the stack: `writeCell` keeps the
    // slice, and this function returns long before `vx.render` reads it.
    const badge = if (frameTake(48)) |b| collapsedBadge(b, row) else "";
    const due_buf = frameTake(96);
    const due: ?display.DueWording = if (t.content.due_at) |d| blk: {
        const b = due_buf orelse break :blk null;
        break :blk display.dueWording(b, d, m.now, display.isCompleted(t.content.status), m.offset_minutes);
    } else null;
    const due_text: []const u8 = if (due) |w| switch (w) {
        .due => |x| x.text,
        .overdue => |x| x.text,
    } else "";

    // THE TITLE IS THE ROW, so it is the last thing to go. As the terminal
    // narrows the optional extras are dropped in reverse order of importance —
    // the due wording, then the collapsed badge — and only what survives is
    // reserved. The arithmetic this replaces reserved all of them unconditionally
    // and then blanked the TITLE when nothing was left, so a ~30-column row showed
    // neither a name nor a handle: strictly worse than any of the things it was
    // protecting.
    const badge_cols: u16 = if (badge.len > 0) 1 + win.gwidth(badge) else 0;
    const due_cols: u16 = if (due_text.len > 0) 1 + win.gwidth(due_text) else 0;
    const room = right_edge -| col;
    var show_badge = badge.len > 0;
    var show_due = due_text.len > 0;
    var budget = room -| (badge_cols + due_cols);
    if (budget < min_title_cols and show_due) {
        show_due = false;
        budget = room -| badge_cols;
    }
    if (budget < min_title_cols and show_badge) {
        show_badge = false;
        budget = room;
    }

    // ZERO MEANS OPPOSITE THINGS ON THE TWO SIDES OF THIS CALL. `display.truncate`
    // reads `max_cols == 0` as "no budget given, don't truncate" — a sentinel the
    // CLI relies on to avoid blanking titles. Here 0 is arrived at by arithmetic
    // and means "no room left at all", which only happens now when the row has no
    // columns left for text of any kind. Do NOT "fix" this in `display.truncate`;
    // fix it here.
    const title: []const u8 = if (budget == 0) "" else display.truncate(t.content.title, budget);
    col = put(win, y, col, title, base_vx);

    if (show_badge) {
        col = put(win, y, col, " ", base_vx);
        col = put(win, y, col, badge, onCursor(badge_style, is_cursor));
    }
    if (show_due) {
        col = put(win, y, col, " ", base_vx);
        _ = put(win, y, col, due_text, onCursor(vxStyle(display.dueStyle(due.?)), is_cursor));
    }

    // RIGHT-ALIGNED from an ABSOLUTE column, not from wherever the title happened
    // to end — that is the whole point, and it is why this is the one run on the
    // row that does not chain off `col`.
    if (show_handle)
        _ = put(win, y, win.width -| win.gwidth(handle), handle, onCursor(vxStyle(.dim), is_cursor));
}

// How narrow a row may get before its handle column is worth more than the text
// it would displace, and the fewest columns worth handing a title. Judgement
// calls about legibility, so they live in the renderer: no model rule reads them.
// `min_row_cols` covers everything a depth-0 row spends before its title — the
// cursor marker (2), the fold marker (2), the status glyph (1) and its separating
// space (1) — plus `min_title_cols`. Deeper rows spend 3 more per level of tree
// rail and so get a shorter title; that is the price of deciding the column's
// existence from the WIDTH alone, which is what keeps it a column.
const min_title_cols: u16 = 8;
const min_row_cols: u16 = min_title_cols + 6;

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

fn lookup(m: *const Model, id: []const u8) ?Task {
    if (!m.idx_built) return null;
    return m.idx.by_id.get(id);
}

// ─── detail pane ─────────────────────────────────────────────────────────────

const pane_fields = [_]FieldId{ .title, .description, .status, .priority, .due, .scheduled, .tags };
const label_col: u16 = 14;

comptime {
    // These three numbers are the same number, and it is a bug when they are not.
    // `model.stepField` walks the whole `FieldId` enum, this table decides what is
    // PAINTED, and `ledger.layoutFor` decides how many rows there are to paint
    // into. If the pane is shorter than the table, the focus can sit on a field
    // that is never drawn — no visible selection at all, one row below the last
    // line of the pane. Adding a field without raising `pane_min_rows` now fails
    // to compile instead of failing on a 20-row terminal.
    std.debug.assert(pane_fields.len == @typeInfo(FieldId).@"enum".fields.len);
    std.debug.assert(pane_fields.len == ledger.pane_min_rows);
}

fn drawPane(win: vaxis.Window, m: *const Model) void {
    if (m.load_failed) return; // the ledger already says why there is nothing
    const t = paneTask(m) orelse {
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
        .due => _ = put(win, y, col, dateOrDash(t.content.due_at, m.offset_minutes), if (t.content.due_at == null) dim else plain),
        .scheduled => _ = put(win, y, col, dateOrDash(t.content.scheduled_at, m.offset_minutes), if (t.content.scheduled_at == null) dim else plain),
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
            // SATURATING. `Window.gwidth` returns a `u16` it accumulates with
            // `+=`, so a ~64 KB paste makes this sum wrap and panic in a Debug
            // build (which is what `build.zig` produces). `showCursor` no-ops out
            // of bounds, so clamping at the maximum is the correct degradation.
            win.showCursor(col_in +| win.gwidth(txt[0..cur]), y);
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

fn dateOrDash(at: ?i64, offset_minutes: i32) []const u8 {
    const unix = at orelse return "—";
    // FRAME storage, not a local: the cell keeps the slice and this function's
    // frame is gone before `vx.render` reads it. See `frameTake`.
    const buf = frameTake(64) orelse return "—";
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

// The task the PANE is about. While an editor is open that is the EDITOR's task
// (`model.Editing.id`), not the cursor's. The two diverge — the cursor is a
// viewport position and `recompute` moves it off a task that stops matching the
// filter — and the commit goes to the editor's task, so showing the cursor's
// would invite the user to press Enter believing they are editing something else.
fn paneTask(m: *const Model) ?Task {
    const id = switch (m.mode) {
        .editing => |e| e.id,
        else => m.cursor_id orelse return null,
    };
    return lookup(m, id);
}

// ─── footer ──────────────────────────────────────────────────────────────────

fn drawFooter(win: vaxis.Window, m: *const Model) void {
    // A prompt outranks the status line: the user is typing into it right now,
    // and it is the only place the typed text appears.
    switch (m.mode) {
        .filter => |le| return drawPrompt(win, "filter ", &le, m),
        .add => |le| return drawPrompt(win, "new task ", &le, m),
        else => {},
    }
    const s = m.status();
    if (s.len > 0) {
        _ = put(win, 0, 0, s, status_style);
        return;
    }
    _ = put(win, 0, 0, keyBar(m), chrome);
}

fn drawPrompt(win: vaxis.Window, label: []const u8, le: *const editors.LineEditor, m: *const Model) void {
    const txt = le.text();

    // A REJECTED PROMPT HAS TO SAY SO WHILE IT IS STILL OPEN. `applyFilter` and
    // `submitAdd` both deliberately KEEP the prompt open on a rejection so the
    // typo can be fixed in place — and both write a message saying why. The
    // prompt used to own the whole footer row, so that message was written and
    // never drawn: type a bad filter, press Enter, watch nothing happen. Exactly
    // the "indistinguishable from a dead key" failure the `R` marker fixed.
    //
    // The message shares the prompt's line, RIGHT-ALIGNED, drawn FIRST so the
    // prompt overpaints it rather than the reverse — the prompt is what the user
    // is typing into and must never be the thing that gives way.
    //
    // Why not borrow a row from the pane or the ledger instead: their heights come
    // from `ledger.layoutFor`/`chrome_rows`, numbers `render.draw` and
    // `model.recompute` have to agree on exactly (getting that wrong is what put
    // the field focus one row below the pane). Making that arithmetic conditional
    // on whether a transient message happens to be pending would put a
    // presentation state into a shared layout constant, to buy one line for a
    // string that the next keypress retracts anyway. Right-aligning also keeps the
    // message still while the user types, instead of being shoved along by it.
    const s = m.status();
    if (s.len > 0) {
        const used = win.gwidth(label) +| win.gwidth(txt);
        const room = win.width -| (used + 1); // +1: never let the two runs touch
        if (room > 0) {
            // `m.status()` is the model's own buffer and outlives the frame, and
            // `truncate` returns a slice of it — so this must NOT go through the
            // frame bump buffer. See `frameTake`.
            const msg = display.truncate(s, room);
            _ = put(win, 0, win.width -| win.gwidth(msg), msg, status_style);
        }
    }

    var col = put(win, 0, 0, label, chrome);
    const start = col;
    col = put(win, 0, col, txt, .{});
    const cur = @min(le.cursor, txt.len);
    win.showCursor(start +| win.gwidth(txt[0..cur]), 0); // saturating: see drawEditor
}

fn keyBar(m: *const Model) []const u8 {
    return switch (m.mode) {
        .list => "j/k move · h/l fold · ⏎ open · space done · a add · x delete · / filter · tab pane · R refresh · q quit",
        .field => "↑/↓ field · ⏎ edit · esc back",
        .editing => |e| switch (e.editor) {
            .line => "⏎ save · esc cancel",
            // Both pairs really work (`editors.PickEditor.handle`), and the pane
            // draws `◂ ▸`, so advertising only one pair was the confusing half.
            .pick => "←/→ or ↑/↓ choose · ⏎ save · esc cancel",
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

// ─── the one lifetime test ───────────────────────────────────────────────────
//
// Still not a test of what the screen LOOKS like (spec §14 stands — that is the
// human checkpoint's job). This pins the MEMORY invariant that the look depends
// on, and it is the same class as every other lifetime test on this branch:
// libvaxis's `writeCell` keeps a cell's grapheme as a slice of the text it was
// given, so every string `draw` commits must outlive `draw` itself. Nothing about
// that is visible in a diff, in a type, or in `zig build` — but a stack buffer
// here corrupts every date, badge, `#handle` and the entire header line, on every
// frame. It shipped that way and no review caught it; this is what catches it.
//
// A `vaxis.Window` needs no terminal — just a `Screen` — so the check costs a
// screen buffer and no TTY.

// Everything committed to one row, as bytes.
fn testRowText(win: vaxis.Window, buf: []u8, y: u16) []const u8 {
    var n: usize = 0;
    var c: u16 = 0;
    while (c < win.width) : (c += 1) {
        const cell = win.screen.readCell(c, y) orelse continue;
        const g = cell.char.grapheme;
        if (g.len == 0 or n + g.len > buf.len) continue;
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

// Reuse the stack `draw`'s helpers ran on, exactly as the caller's next call
// does. Recursive and `noinline` so the compiler cannot elide the frames.
noinline fn testDirtyStack(depth: usize) usize {
    var pad: [1024]u8 = undefined;
    @memset(&pad, 0xAA);
    if (depth == 0) return pad[0];
    return testDirtyStack(depth - 1) +% pad[3];
}

test "the strings draw() commits to cells outlive draw()" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    var m: Model = undefined;
    try m.init(a, now, 0);
    defer m.deinit();
    var tasks = [_]Task{.{
        .id = "01JQRSTUVWXYZABCDEFGHJKMNP",
        .content = .{
            .title = "write the report",
            .status = .todo,
            .priority = .high,
            .due_at = now - 5 * 86400, // overdue, so the due wording is non-empty
        },
        .meta = .{ .created_at = now },
    }};
    _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
    m.viewport = .{ .cols = 100, .rows = 24 };

    var screen: vaxis.Screen = try .init(a, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };

    draw(win, &m);
    // `run` does exactly this: `draw` returns, then `vx.render(tty)` is called and
    // reads the cells. Any string still pointing at `draw`'s stack is gone by now.
    std.mem.doNotOptimizeAway(testDirtyStack(6));

    var buf: [8192]u8 = undefined;
    const header = testRowText(win, &buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, header, "urgency") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "1 overdue") != null);

    var buf2: [8192]u8 = undefined;
    const row = testRowText(win, &buf2, 1);
    try std.testing.expect(std.mem.indexOf(u8, row, "write the report") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "OVERDUE") != null); // due wording
    try std.testing.expect(std.mem.indexOf(u8, row, "#") != null); // the handle
}

// ─── the one layout test ─────────────────────────────────────────────────────
//
// Also not a test of what the screen looks like — it asserts an INVARIANT the
// screen has to satisfy: whatever field the model lets the user focus, the pane
// has to paint a focus bar for it. The bug that earned this test (found by
// driving a real terminal, not by review) was `layoutFor` flooring the pane at 6
// rows while this file paints 7 fields: on any terminal 11–23 rows tall, ↓ onto
// `tags` moved the selection one row below the last painted line of the pane and
// the highlight simply disappeared. The comptime assert above is the real guard;
// this is what proves the assert is guarding the right thing.

// The rows of `win` whose first cell carries the cursor/focus background.
fn testHighlightedRows(win: vaxis.Window, out: []u16) []const u16 {
    var n: usize = 0;
    var y: u16 = 0;
    while (y < win.height and n < out.len) : (y += 1) {
        const cell = win.screen.readCell(0, y) orelse continue;
        if (std.meta.eql(cell.style.bg, cursor_bg)) {
            out[n] = y;
            n += 1;
        }
    }
    return out[0..n];
}

test "every field the focus can reach is painted, at every height that shows a pane" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    // The whole band from "a pane appears at all" up past the point where the
    // third-of-the-screen rule takes over from the floor. 20 was the height the
    // bug was seen at; 24 was the height every earlier eyeball happened to use.
    var rows: u16 = ledger.chrome_rows + @as(u16, ledger.pane_min_rows) + 1;
    while (rows <= 40) : (rows += 1) {
        var m: Model = undefined;
        try m.init(a, now, 0);
        defer m.deinit();

        var tasks = [_]Task{.{
            .id = "01JQRSTUVWXYZABCDEFGHJKMNP",
            .content = .{ .title = "a task", .status = .todo },
            .meta = .{ .created_at = now },
        }};
        _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
        _ = try model.update(a, &m, .{ .resize = .{ .cols = 60, .rows = rows } });

        var screen: vaxis.Screen = try .init(a, .{ .cols = 60, .rows = rows, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win: vaxis.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = screen.width,
            .height = screen.height,
            .screen = &screen,
        };

        // Enter opens the pane and descends to the fields; ↓ walks them.
        _ = try model.update(a, &m, .{ .key = .enter });
        const layout = ledger.layoutFor(rows -| ledger.chrome_rows, m.pane_open);
        try std.testing.expect(layout.pane_rows > 0); // the band was chosen for this

        for (pane_fields) |_| {
            draw(win, &m);
            var buf: [64]u16 = undefined;
            const hits = testHighlightedRows(win, &buf);
            // Two bars: the cursor's ledger row, and the focused field in the
            // pane. Exactly one of them lands inside the pane's row range.
            const pane_top: u16 = 1 + clampU16(layout.ledger_rows);
            var in_pane: usize = 0;
            for (hits) |y| {
                if (y >= pane_top and y < pane_top + clampU16(layout.pane_rows)) in_pane += 1;
            }
            std.testing.expectEqual(@as(usize, 1), in_pane) catch |err| {
                std.debug.print(
                    "rows={d} pane_rows={d} focused field={s} had {d} highlighted pane rows\n",
                    .{ rows, layout.pane_rows, @tagName(m.mode.field), in_pane },
                );
                return err;
            };
            _ = try model.update(a, &m, .{ .key = .down });
        }
    }
}

// ─── the handle-column layout test ───────────────────────────────────────────
//
// Third and last exception, and the same justification as the second: an
// INVARIANT, not an aesthetic. "The handles line up" is the entire content of the
// change that added the column — a claim about columns, which is the one thing a
// human cannot verify by reading a diff — and the arithmetic it replaced had
// already shipped a defect (a computed budget of 0 colliding with
// `display.truncate`'s "0 means unlimited" sentinel) that blanked the TITLE on any
// terminal under ~40 columns. Both halves are pinned here.

// The column the `#` of a row's handle sits in, or null if the row has none.
fn testHandleCol(win: vaxis.Window, y: u16) ?u16 {
    var c: u16 = 0;
    while (c < win.width) : (c += 1) {
        const cell = win.screen.readCell(c, y) orelse continue;
        if (std.mem.eql(u8, cell.char.grapheme, "#")) return c;
    }
    return null;
}

fn testWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

test "every #handle lands in the same right-hand column whatever the row's depth" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    var m: Model = undefined;
    try m.init(a, now, 0);
    defer m.deinit();

    // A parent, its child, and a sibling: three rows at two different depths, with
    // titles of three different lengths. Inline, the handles land in three
    // different columns; that is the thing being fixed.
    var kids = [_][]const u8{"01JQRSTUVWXYZABCDEFGHJKM02"};
    var tasks = [_]Task{
        .{
            .id = "01JQRSTUVWXYZABCDEFGHJKM01",
            .content = .{ .title = "a parent task", .status = .todo, .child_ids = &kids },
            .meta = .{ .created_at = now },
        },
        .{
            .id = "01JQRSTUVWXYZABCDEFGHJKM02",
            .content = .{ .title = "a much longer child title", .status = .todo },
            .meta = .{ .created_at = now },
        },
        .{
            .id = "01JQRSTUVWXYZABCDEFGHJKM03",
            .content = .{ .title = "x", .status = .todo },
            .meta = .{ .created_at = now },
        },
    };
    _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
    _ = try model.update(a, &m, .{ .resize = .{ .cols = 60, .rows = 24 } });
    // Nothing in this set needs attention, so the child is auto-collapsed. Unfold
    // it explicitly — a depth-1 row is half the point of the test.
    _ = try model.update(a, &m, .{ .key = .{ .char = 'l' } });
    try std.testing.expectEqual(@as(usize, 3), m.rows.len);

    var screen: vaxis.Screen = try .init(a, .{ .cols = 60, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = testWindow(&screen);
    draw(win, &m);

    // The width comes off the MODEL (`view.minUniqueSuffixLen` over the fetched
    // set), never a constant here: these ids differ only in their last character,
    // so a 4-char tail is unique and the column is 5 wide.
    try std.testing.expectEqual(@as(usize, 4), m.handle_len);
    try testHandlesAlignAt(win, &m, 60 - 5);

    // ...and it MOVES when the data makes it move. These three ids share their
    // last four characters, so `minUniqueSuffixLen` widens to five and the column
    // has to widen with it. A hardcoded 5 here would pass the case above and put
    // three identical handles on the screen in this one.
    var wide = [_]Task{
        .{ .id = "01JQRSTUVWXYZABCDEF0ABCDE", .content = .{ .title = "one", .status = .todo }, .meta = .{ .created_at = now } },
        .{ .id = "01JQRSTUVWXYZABCDEF0BBCDE", .content = .{ .title = "two", .status = .todo }, .meta = .{ .created_at = now } },
        .{ .id = "01JQRSTUVWXYZABCDEF0CBCDE", .content = .{ .title = "three", .status = .todo }, .meta = .{ .created_at = now } },
    };
    _ = try model.update(a, &m, .{ .tasks_loaded = &wide });
    try std.testing.expectEqual(@as(usize, 5), m.handle_len);
    draw(win, &m);
    try testHandlesAlignAt(win, &m, 60 - 6);
}

fn testHandlesAlignAt(win: vaxis.Window, m: *const Model, expected: u16) !void {
    for (1..1 + m.rows.len) |i| {
        const y: u16 = @intCast(i);
        const at = testHandleCol(win, y) orelse {
            std.debug.print("ledger row {d} has no handle at all\n", .{y});
            return error.TestUnexpectedResult;
        };
        std.testing.expectEqual(expected, at) catch |err| {
            std.debug.print("row {d}: handle at column {d}, expected {d}\n", .{ y, at, expected });
            return err;
        };
    }
}

// ─── the footer-reachability tests ───────────────────────────────────────────
//
// Same class as every other test in this file, and the same origin: the MODEL
// does the right thing and the SHELL swallows it, which no model test can see.
// `applyFilter` and `submitAdd` deliberately keep their prompt open on a
// rejection and write a message saying why — and the footer gave the whole row to
// the prompt, so the message was written and never drawn. Type a bad filter,
// press Enter, watch nothing happen: the same failure mode as the `R` bug.
//
// The invariant: ANYTHING THE MODEL PUTS ON THE STATUS LINE MUST BE REACHABLE ON
// SCREEN, including while a prompt owns the footer.

fn testOneRowModel(a: std.mem.Allocator, m: *Model, now: i64, tasks: []const Task, cols: u16, rows: u16) !void {
    try m.init(a, now, 0);
    _ = try model.update(a, m, .{ .tasks_loaded = tasks });
    _ = try model.update(a, m, .{ .resize = .{ .cols = cols, .rows = rows } });
}

test "a rejected prompt keeps the typed text and shows the reason on the same line" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    var tasks = [_]Task{.{
        .id = "01JQRSTUVWXYZABCDEFGHJKMNP",
        .content = .{ .title = "a task", .status = .todo },
        .meta = .{ .created_at = now },
    }};
    var m: Model = undefined;
    try testOneRowModel(a, &m, now, &tasks, 100, 24);
    defer m.deinit();

    var screen: vaxis.Screen = try .init(a, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = testWindow(&screen);
    const footer: u16 = 23;
    var buf: [8192]u8 = undefined;

    // ── `/`, with an expression `filterspec.parse` rejects ───────────────────
    _ = try model.update(a, &m, .{ .key = .{ .char = '/' } });
    for ("nonsense") |c| _ = try model.update(a, &m, .{ .key = .{ .char = c } });
    _ = try model.update(a, &m, .{ .key = .enter });
    try std.testing.expect(m.mode == .filter); // still open, by design
    try std.testing.expect(m.status().len > 0); // the model DID say why

    draw(win, &m);
    const row = testRowText(win, &buf, footer);
    // The prompt still owns the left of the line, label and all, unmoved.
    try std.testing.expect(std.mem.startsWith(u8, row, "filter nonsense"));
    // ...and the reason is on the same line, right-aligned against the edge.
    // "not a filter" cannot come from the typed text, so this cannot pass by
    // accident the way a bare search for "nonsense" would (the message echoes it).
    std.testing.expect(std.mem.indexOf(u8, row, "not a filter") != null) catch |err| {
        std.debug.print("footer: \"{s}\"\n  status was: \"{s}\"\n", .{ row, m.status() });
        return err;
    };
    try std.testing.expect(std.mem.endsWith(u8, row, "overdue)"));

    // ── `a`, whose rejection comes from the SERVER and must not cost the title ─
    _ = try model.update(a, &m, .{ .key = .escape });
    _ = try model.update(a, &m, .{ .key = .{ .char = 'a' } });
    for ("buy milk") |c| _ = try model.update(a, &m, .{ .key = .{ .char = c } });
    _ = try model.update(a, &m, .{ .key = .enter }); // -> Command.create; mode stays .add
    _ = try model.update(a, &m, .{ .request_failed = "server error (503): unavailable" });
    try std.testing.expect(m.mode == .add);

    draw(win, &m);
    var buf2: [8192]u8 = undefined;
    const row2 = testRowText(win, &buf2, footer);
    try std.testing.expect(std.mem.startsWith(u8, row2, "new task buy milk"));
    try std.testing.expect(std.mem.indexOf(u8, row2, "unavailable") != null);

    // ── narrow: the prompt wins, and the two runs never touch ────────────────
    // At 40 columns the message no longer fits beside the prompt whole, which is
    // the case where "right-aligned" could silently become "overlapping".
    var m2: Model = undefined;
    try testOneRowModel(a, &m2, now, &tasks, 40, 24);
    defer m2.deinit();
    var screen2: vaxis.Screen = try .init(a, .{ .cols = 40, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen2.deinit(a);
    const win2 = testWindow(&screen2);

    _ = try model.update(a, &m2, .{ .key = .{ .char = '/' } });
    for ("nonsense") |c| _ = try model.update(a, &m2, .{ .key = .{ .char = c } });
    _ = try model.update(a, &m2, .{ .key = .enter });
    draw(win2, &m2);
    var buf3: [8192]u8 = undefined;
    const row3 = testRowText(win2, &buf3, footer);
    const prompt_cols: u16 = @intCast("filter nonsense".len);
    try std.testing.expect(std.mem.startsWith(u8, row3, "filter nonsense"));
    try std.testing.expect(std.mem.indexOf(u8, row3, "not a filter") != null);
    // The blank column is the whole reason the prompt cannot be encroached on:
    // without it the message starts under the typed text and only survives from
    // wherever the prompt stopped overpainting it, which reads as garbage.
    std.testing.expect(testBlankAt(win2, prompt_cols, footer)) catch |err| {
        std.debug.print("40-col footer, no gap after the prompt: \"{s}\"\n", .{row3});
        return err;
    };
}

// One signal, one surface. The header marker means "a WRITE is outstanding" and
// nothing else; the refresh signal is the status line's, because that is the
// surface the user reads and because this marker already lost that argument once
// (for a refused connection it is gone before the eye reaches it, which is what
// made `R` look like a dead key). Saying it in both places is noise on the one
// line that has to give the key bar back.
test "a refresh is reported on the status line only; the header marker means a write" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    var tasks = [_]Task{.{
        .id = "01JQRSTUVWXYZABCDEFGHJKMNP",
        .content = .{ .title = "a task", .status = .todo },
        .meta = .{ .created_at = now },
    }};
    var m: Model = undefined;
    try testOneRowModel(a, &m, now, &tasks, 100, 24);
    defer m.deinit();

    var screen: vaxis.Screen = try .init(a, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win = testWindow(&screen);
    var buf: [8192]u8 = undefined;
    var buf2: [8192]u8 = undefined;

    _ = try model.update(a, &m, .{ .key = .{ .char = 'R' } });
    try std.testing.expect(m.in_flight == .refresh);
    draw(win, &m);
    const header = testRowText(win, &buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, header, "refreshing") == null);
    try std.testing.expect(std.mem.indexOf(u8, header, "saving") == null); // never a write
    try std.testing.expect(std.mem.indexOf(u8, testRowText(win, &buf2, 23), "refreshing") != null);

    // A real write still gets its marker, on the same in-flight machinery.
    _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
    _ = try model.update(a, &m, .{ .key = .{ .char = ' ' } }); // cycle the status
    try std.testing.expect(m.in_flight == .commit);
    draw(win, &m);
    try std.testing.expect(std.mem.indexOf(u8, testRowText(win, &buf, 0), "saving…") != null);
}

fn testBlankAt(win: vaxis.Window, col: u16, y: u16) bool {
    const cell = win.screen.readCell(col, y) orelse return true;
    const g = cell.char.grapheme;
    return g.len == 0 or std.mem.eql(u8, g, " ");
}

// The column is only a column if nothing else may enter it. Two mutations survived
// the two tests above until this one existed: hardcoding the column's width to 5
// (correct for the common case, one column short whenever `handle_len` widens),
// and reserving no columns at all (the title then runs under the handle and the
// handle overpaints it — which still LOOKS like a right-aligned handle from a
// distance). Both are caught here by the blank gap, not by the handle's position.
test "the handle column keeps its gap, at either handle width and every terminal width" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;
    const long = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ";

    // Distinct id tails (`handle_len` 4) and colliding ones (5) — the second is
    // exactly why the column's width is read off the model instead of written here.
    var short_ids = [_][]const u8{ "01JQRSTUVWXYZABCDEF0AAAA1", "01JQRSTUVWXYZABCDEF0AAAA2" };
    var wide_ids = [_][]const u8{ "01JQRSTUVWXYZABCDEF0ABCDE", "01JQRSTUVWXYZABCDEF0BBCDE" };
    for ([_][]const []const u8{ &short_ids, &wide_ids }, [_]usize{ 4, 5 }) |ids, want_len| {
        var width: u16 = 21;
        while (width <= 50) : (width += 1) {
            var m: Model = undefined;
            try m.init(a, now, 0);
            defer m.deinit();

            var tasks: [2]Task = undefined;
            for (ids, &tasks) |id, *dst| dst.* = .{
                .id = id,
                .content = .{ .title = long, .status = .todo },
                .meta = .{ .created_at = now },
            };
            _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
            _ = try model.update(a, &m, .{ .resize = .{ .cols = width, .rows = 24 } });
            try std.testing.expectEqual(want_len, m.handle_len);

            var screen: vaxis.Screen = try .init(a, .{ .cols = width, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
            defer screen.deinit(a);
            const win = testWindow(&screen);
            draw(win, &m);

            const handle_cols: u16 = @intCast(want_len + 1);
            const at = testHandleCol(win, 1) orelse {
                std.debug.print("handle_len={d} width={d}: no handle\n", .{ want_len, width });
                return error.TestUnexpectedResult;
            };
            std.testing.expectEqual(width - handle_cols, at) catch |err| {
                std.debug.print("handle_len={d} width={d}: handle at {d}\n", .{ want_len, width, at });
                return err;
            };
            std.testing.expect(testBlankAt(win, at - 1, 1)) catch |err| {
                var buf: [8192]u8 = undefined;
                std.debug.print("handle_len={d} width={d}: title touches the handle: \"{s}\"\n", .{ want_len, width, testRowText(win, &buf, 1) });
                return err;
            };
        }
    }
}

test "narrowing the terminal costs the due wording, then the handle, and the title last" {
    const a = std.testing.allocator;
    const now: i64 = 100 * 86400;

    var width: u16 = 8;
    while (width <= 80) : (width += 1) {
        var m: Model = undefined;
        try m.init(a, now, 0);
        defer m.deinit();

        // Overdue, so the row carries the longest optional run it ever has. This is
        // the row that used to come out completely blank below ~40 columns.
        var tasks = [_]Task{.{
            .id = "01JQRSTUVWXYZABCDEFGHJKMNP",
            .content = .{
                .title = "ZZZZZZZZZZZZZZZZZZZZ",
                .status = .todo,
                .priority = .high,
                .due_at = now - 5 * 86400,
            },
            .meta = .{ .created_at = now },
        }};
        _ = try model.update(a, &m, .{ .tasks_loaded = &tasks });
        _ = try model.update(a, &m, .{ .resize = .{ .cols = width, .rows = 24 } });

        var screen: vaxis.Screen = try .init(a, .{ .cols = width, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win = testWindow(&screen);
        draw(win, &m);

        var buf: [8192]u8 = undefined;
        const row = testRowText(win, &buf, 1);

        // THE TITLE IS THE LAST THING TO GO. Every width down to 8 shows at least
        // one character of it — the previous arithmetic showed none at all below
        // about 40, which is worse than anything it was protecting.
        std.testing.expect(std.mem.indexOf(u8, row, "Z") != null) catch |err| {
            std.debug.print("width={d}: no title on the row: \"{s}\"\n", .{ width, row });
            return err;
        };

        // The handle column exists exactly when the width rule says so, and always
        // in the same place relative to the right edge — so it cannot creep inward
        // as the extras are dropped.
        const at = testHandleCol(win, 1);
        const handle_cols: u16 = @intCast(m.handle_len + 1);
        if (width >= handle_cols + 1 + min_row_cols) {
            std.testing.expectEqual(@as(?u16, width - handle_cols), at) catch |err| {
                std.debug.print("width={d}: handle at {?d}: \"{s}\"\n", .{ width, at, row });
                return err;
            };
        } else {
            // Too narrow for both: the title wins and the handle is dropped whole,
            // rather than half a handle being printed over the title's last cells.
            std.testing.expectEqual(@as(?u16, null), at) catch |err| {
                std.debug.print("width={d}: unexpected handle at {?d}: \"{s}\"\n", .{ width, at, row });
                return err;
            };
        }
    }
}
