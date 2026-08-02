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
