package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"seshat/internal/task"
)

// maxMessageRunes is Telegram's per-message cap. The page budget in view.go keeps
// us well under it; this constant exists so the test can assert that.
const maxMessageRunes = 4096

// Button is a rendered button spec. render.go deliberately does NOT produce
// Telegram types — handlers.go converts these, registering each Action as it
// goes, which keeps token allocation in one place and this file pure.
type Button struct {
	Label  string
	Action Action
}

// EscapeHTML is the SINGLE boundary at which task-derived text enters a message.
// Every title, description and tag goes through it. Ampersand must be replaced
// first, or the later replacements double-escape their own output.
func EscapeHTML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}

// FormatDate renders a UTC instant as a local YYYY-MM-DD. Local time exists at
// exactly two boundaries in this bot; this is one of them.
func FormatDate(unix int64, offsetMin int) string {
	t := time.Unix(unix+int64(offsetMin)*60, 0).UTC()
	return t.Format("2006-01-02")
}

// FormatDue renders a due date relative to now where that reads better than a
// date. Empty string means "no due date".
func FormatDue(due *int64, now int64, offsetMin int) string {
	if due == nil {
		return ""
	}
	delta := *due - now
	switch {
	case delta < 0:
		return "overdue"
	case delta <= day:
		return "today"
	case delta <= 2*day:
		return "tomorrow"
	case delta <= 7*day:
		return strconv.FormatInt(delta/day, 10) + "d"
	default:
		return FormatDate(*due, offsetMin)
	}
}

func StatusGlyph(s task.Status) string {
	switch s {
	case task.StatusInProgress:
		return "◐"
	case task.StatusDone:
		return "✓"
	case task.StatusCancelled:
		return "✗"
	default:
		return "○"
	}
}

// RenderPage renders one listing screen. query is "" for /list and the needle for
// /find; it rides along on every button so Back returns to the right listing.
// overflow is the count dropped from the whole result set (findCeiling), while
// p.Overflow is the count dropped from one oversized group. now and offsetMin are
// parameters, not reads of the clock — this file is pure.
func RenderPage(p Page, query string, overflow int, now int64, offsetMin int) (string, [][]Button) {
	if len(p.Rows) == 0 {
		if query != "" {
			return "No open task matches <b>" + EscapeHTML(query) + "</b>.", nil
		}
		return "Nothing open.", nil
	}

	var b strings.Builder
	if query != "" {
		fmt.Fprintf(&b, "Matches for <b>%s</b>\n\n", EscapeHTML(query))
	}
	for i, r := range p.Rows {
		indent := strings.Repeat("  ", r.Depth)
		fmt.Fprintf(&b, "%d. %s%s %s", i+1, indent, StatusGlyph(r.Task.Content.Status),
			EscapeHTML(r.Task.Content.Title))
		if r.ParentTitle != "" {
			fmt.Fprintf(&b, " <i>in %s</i>", EscapeHTML(r.ParentTitle))
		}
		if d := FormatDue(r.Task.Content.DueAt, now, offsetMin); d != "" {
			fmt.Fprintf(&b, "  ⏰ %s", d)
		}
		b.WriteByte('\n')
	}
	if p.Overflow > 0 {
		fmt.Fprintf(&b, "\n<i>…and %d more subtasks</i>\n", p.Overflow)
	}
	if overflow > 0 {
		fmt.Fprintf(&b, "\n<i>…and %d more — use the TUI</i>\n", overflow)
	}

	var kb [][]Button
	var row []Button
	for i, r := range p.Rows {
		row = append(row, Button{
			Label: strconv.Itoa(i + 1),
			Action: Action{
				Kind:    KindOpenTask,
				TaskID:  r.Task.ID,
				Page:    p.Index,
				Query:   query,
				HasList: true, // it came from a listing, so Back is meaningful
			},
		})
		if len(row) == 5 {
			kb = append(kb, row)
			row = nil
		}
	}
	if len(row) > 0 {
		kb = append(kb, row)
	}

	if p.Count > 1 {
		var nav []Button
		if p.Index > 0 {
			nav = append(nav, Button{"◀", Action{Kind: KindPage, Page: p.Index - 1, Query: query}})
		}
		nav = append(nav, Button{
			Label:  fmt.Sprintf(" %d/%d ", p.Index+1, p.Count),
			Action: Action{Kind: KindNoop},
		})
		if p.Index < p.Count-1 {
			nav = append(nav, Button{"▶", Action{Kind: KindPage, Page: p.Index + 1, Query: query}})
		}
		kb = append(kb, nav)
	}
	return b.String(), kb
}

// Origin names the listing a card was opened from, so Back returns there. A card
// reached by capture has HasList false and shows no Back button — a Back that
// jumped somewhere the user has never been would be worse than none.
type Origin struct {
	HasList bool
	Page    int
	Query   string
}

func (o Origin) act(kind ActionKind, taskID, arg string) Action {
	return Action{Kind: kind, TaskID: taskID, Arg: arg,
		Page: o.Page, Query: o.Query, HasList: o.HasList}
}

// CardText renders the detail view. Alignment uses newlines and <code> spans, not
// space padding — phone clients render proportional fonts, so columns built from
// spaces do not survive.
func CardText(t task.Task, ix *Index, now int64, offsetMin int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s <b>%s</b>\n", StatusGlyph(t.Content.Status), EscapeHTML(t.Content.Title))
	if p, ok := ix.ParentOf(t.ID); ok {
		fmt.Fprintf(&b, "<i>in %s</i>\n", EscapeHTML(p.Content.Title))
	}
	if t.Content.Description != "" {
		fmt.Fprintf(&b, "\n%s\n", EscapeHTML(t.Content.Description))
	}
	b.WriteString("\n")
	fmt.Fprintf(&b, "status    <code>%s</code>\n", EscapeHTML(string(t.Content.Status)))
	fmt.Fprintf(&b, "priority  <code>%s</code>\n", EscapeHTML(string(t.Content.Priority)))

	due := "—"
	if t.Content.DueAt != nil {
		due = FormatDate(*t.Content.DueAt, offsetMin)
		if rel := FormatDue(t.Content.DueAt, now, offsetMin); rel != "" {
			due += " (" + rel + ")"
		}
	}
	fmt.Fprintf(&b, "due       <code>%s</code>\n", EscapeHTML(due))

	tags := "—"
	if len(t.Content.Tags) > 0 {
		tags = strings.Join(t.Content.Tags, ", ")
	}
	fmt.Fprintf(&b, "tags      <code>%s</code>\n", EscapeHTML(tags))

	if n := len(t.Content.ChildIDs); n > 0 {
		fmt.Fprintf(&b, "subtasks  <code>%d</code>\n", n)
	}
	return b.String()
}

func CardKeyboard(t task.Task, o Origin) [][]Button {
	id := t.ID
	kb := [][]Button{
		{
			{"✓ Done", o.act(KindDone, id, "")},
			{"Status", o.act(KindPickStatus, id, "")},
			{"Priority", o.act(KindPickPriority, id, "")},
		},
		{
			{"Due", o.act(KindPickDue, id, "")},
			{"Tags", o.act(KindPromptField, id, "tags")},
			// Without this the last tag can never be removed: a ForceReply reply
			// is never empty, and Telegram allows only one reply_markup per
			// message, so the button cannot live on the prompt itself.
			{"Clear tags", o.act(KindClearTags, id, "")},
		},
		{
			{"✎ Title", o.act(KindPromptField, id, "title")},
			{"✎ Description", o.act(KindPromptField, id, "description")},
		},
	}
	last := []Button{{"🗑 Delete", o.act(KindConfirmDelete, id, "")}}
	if o.HasList {
		last = append(last, Button{"◀ Back", o.act(KindBack, id, "")})
	}
	return append(kb, last)
}

func pickerKeyboard(kind ActionKind, taskID string, o Origin, opts [][2]string) [][]Button {
	var kb [][]Button
	var row []Button
	for _, opt := range opts {
		row = append(row, Button{opt[0], o.act(kind, taskID, opt[1])})
		if len(row) == 3 {
			kb = append(kb, row)
			row = nil
		}
	}
	if len(row) > 0 {
		kb = append(kb, row)
	}
	return append(kb, []Button{{"◀", o.act(KindOpenTask, taskID, "")}})
}

func StatusPickerKeyboard(taskID string, o Origin) [][]Button {
	return pickerKeyboard(KindSetStatus, taskID, o, [][2]string{
		{"○ todo", "todo"},
		{"◐ in progress", "in_progress"},
		{"✓ done", "done"},
		{"✗ cancelled", "cancelled"},
	})
}

func PriorityPickerKeyboard(taskID string, o Origin) [][]Button {
	return pickerKeyboard(KindSetPriority, taskID, o, [][2]string{
		{"none", "none"}, {"low", "low"}, {"medium", "medium"}, {"high", "high"},
	})
}

// DuePickerKeyboard offers fixed choices only. Free-text dates are a v1 non-goal:
// they would need edit.zig's parser ported to Go. Every Arg here must be a
// keyword DueFromKeyword accepts.
func DuePickerKeyboard(taskID string, o Origin) [][]Button {
	return pickerKeyboard(KindSetDue, taskID, o, [][2]string{
		{"Today", "today"}, {"Tomorrow", "tomorrow"}, {"+3 days", "+3d"},
		{"+1 week", "+1w"}, {"Clear", "clear"},
	})
}

// DeleteConfirmText names the consequence. server/store.go:364 deletes
// non-recursively — "its former children become unreferenced roots" — and a phone
// user cannot see that from a card, so silently detaching a subtree must not be
// the outcome of a two-tap gesture.
func DeleteConfirmText(t task.Task) string {
	msg := fmt.Sprintf("Delete <b>%s</b>?", EscapeHTML(t.Content.Title))
	if n := len(t.Content.ChildIDs); n > 0 {
		msg += fmt.Sprintf("\n\nIts %d subtask(s) will become top-level tasks.", n)
	}
	return msg
}

func DeleteConfirmKeyboard(taskID string, o Origin) [][]Button {
	return [][]Button{{
		{"Yes, delete", o.act(KindDoDelete, taskID, "")},
		{"Cancel", o.act(KindOpenTask, taskID, "")},
	}}
}
