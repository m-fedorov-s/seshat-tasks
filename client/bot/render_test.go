package main

import (
	"strings"
	"testing"
)

// NOTE: do NOT import seshat/internal/task here yet — nothing in this file uses
// it until Task 9 adds cardTask(). An unused import is a compile error in Go.

func TestEscapeHTML(t *testing.T) {
	cases := map[string]string{
		"plain":         "plain",
		"budget < 500":  "budget &lt; 500",
		"a & b":         "a &amp; b",
		"<b>bold</b>":   "&lt;b&gt;bold&lt;/b&gt;",
		`say "hi"`:      "say &quot;hi&quot;",
		"fix auth_token": "fix auth_token", // underscores are safe in HTML mode
	}
	for in, want := range cases {
		if got := EscapeHTML(in); got != want {
			t.Errorf("EscapeHTML(%q) = %q, want %q", in, got, want)
		}
	}
	// & must be escaped first or the other replacements double-escape.
	if got := EscapeHTML("&lt;"); got != "&amp;lt;" {
		t.Errorf("EscapeHTML(%q) = %q, want %q", "&lt;", got, "&amp;lt;")
	}
}

func TestFormatDateAppliesOffset(t *testing.T) {
	// 2026-08-02T23:59:59Z
	const utc = int64(1785715199)
	if got := FormatDate(utc, 0); got != "2026-08-02" {
		t.Errorf("FormatDate(+00:00) = %q, want 2026-08-02", got)
	}
	// +03:00 pushes it into the next local day
	if got := FormatDate(utc, 180); got != "2026-08-03" {
		t.Errorf("FormatDate(+03:00) = %q, want 2026-08-03", got)
	}
	// -05:00 keeps it on the same local day
	if got := FormatDate(utc, -300); got != "2026-08-02" {
		t.Errorf("FormatDate(-05:00) = %q, want 2026-08-02", got)
	}
}

func TestFormatDue(t *testing.T) {
	now := int64(1_000_000)
	cases := []struct {
		name string
		due  *int64
		want string
	}{
		{"absent", nil, ""},
		{"overdue", ptr(now - 1), "overdue"},
		{"today", ptr(now + 3600), "today"},
		{"tomorrow", ptr(now + 26*3600), "tomorrow"},
		{"in 3 days", ptr(now + 3*86400), "3d"},
		{"far off", ptr(now + 40*86400), FormatDate(now+40*86400, 0)},
	}
	for _, c := range cases {
		if got := FormatDue(c.due, now, 0); got != c.want {
			t.Errorf("%s: FormatDue = %q, want %q", c.name, got, c.want)
		}
	}
}

func ptr(v int64) *int64 { return &v }

func renderRows(ids ...string) Page {
	rows := make([]Row, len(ids))
	for i, id := range ids {
		rows[i] = Row{Task: mk(id), Depth: 0}
	}
	return Page{Rows: rows, Index: 0, Count: 1}
}

func TestRenderPageNumbersRowsFromOne(t *testing.T) {
	text, kb := RenderPage(renderRows("a", "b", "c"), "", 0, 0, 0)
	for i, want := range []string{"1.", "2.", "3."} {
		if !strings.Contains(text, want) {
			t.Errorf("row %d: text is missing %q\n%s", i, want, text)
		}
	}
	// One button per row, plus no nav row on a single page.
	var labels []string
	for _, row := range kb {
		for _, b := range row {
			labels = append(labels, b.Label)
		}
	}
	if len(labels) != 3 {
		t.Fatalf("buttons = %v, want three numbered buttons and no nav", labels)
	}
	for i, want := range []string{"1", "2", "3"} {
		if labels[i] != want {
			t.Errorf("button %d = %q, want %q", i, labels[i], want)
		}
	}
}

func TestRenderPageButtonsCarryTaskIDsAndOpenKind(t *testing.T) {
	_, kb := RenderPage(renderRows("alpha", "beta"), "dentist", 0, 0, 0)
	seen := map[string]bool{}
	for _, row := range kb {
		for _, b := range row {
			if b.Action.Kind != KindOpenTask {
				continue
			}
			seen[b.Action.TaskID] = true
			if b.Action.Query != "dentist" {
				t.Errorf("button for %s lost the query: %q", b.Action.TaskID, b.Action.Query)
			}
		}
	}
	if !seen["alpha"] || !seen["beta"] {
		t.Errorf("buttons did not carry both task ids: %v", seen)
	}
}

func TestRenderPageNumberButtonsAreRowsOfFive(t *testing.T) {
	var ids []string
	for i := 0; i < 7; i++ {
		ids = append(ids, string(rune('a'+i)))
	}
	_, kb := RenderPage(renderRows(ids...), "", 0, 0, 0)
	if len(kb[0]) != 5 {
		t.Errorf("first button row has %d buttons, want 5", len(kb[0]))
	}
	if len(kb[1]) != 2 {
		t.Errorf("second button row has %d buttons, want 2", len(kb[1]))
	}
}

func TestRenderPageNavRow(t *testing.T) {
	p := Page{Rows: []Row{{Task: mk("a")}}, Index: 1, Count: 3}
	_, kb := RenderPage(p, "", 0, 0, 0)
	nav := kb[len(kb)-1]
	if len(nav) != 3 {
		t.Fatalf("middle page nav = %d buttons, want prev/counter/next", len(nav))
	}
	if nav[1].Action.Kind != KindNoop {
		t.Errorf("page counter must be inert, got kind %v", nav[1].Action.Kind)
	}
	if !strings.Contains(nav[1].Label, "2/3") {
		t.Errorf("counter label = %q, want it to show 2/3", nav[1].Label)
	}
	if nav[0].Action.Page != 0 || nav[2].Action.Page != 2 {
		t.Errorf("nav targets = %d and %d, want 0 and 2", nav[0].Action.Page, nav[2].Action.Page)
	}
}

func TestRenderPageOmitsPrevOnFirstAndNextOnLast(t *testing.T) {
	first := Page{Rows: []Row{{Task: mk("a")}}, Index: 0, Count: 2}
	_, kb := RenderPage(first, "", 0, 0, 0)
	nav := kb[len(kb)-1]
	if len(nav) != 2 {
		t.Errorf("first page nav = %d, want counter+next", len(nav))
	}

	last := Page{Rows: []Row{{Task: mk("a")}}, Index: 1, Count: 2}
	_, kb = RenderPage(last, "", 0, 0, 0)
	nav = kb[len(kb)-1]
	if len(nav) != 2 {
		t.Errorf("last page nav = %d, want prev+counter", len(nav))
	}
}

func TestRenderPageEscapesTitles(t *testing.T) {
	tk := mk("x")
	tk.Content.Title = "budget < 500 & rising"
	text, _ := RenderPage(Page{Rows: []Row{{Task: tk}}, Count: 1}, "", 0, 0, 0)
	if strings.Contains(text, "< 500") {
		t.Errorf("title was not escaped:\n%s", text)
	}
	if !strings.Contains(text, "&lt; 500 &amp; rising") {
		t.Errorf("expected escaped title, got:\n%s", text)
	}
}

func TestRenderPageIndentsChildren(t *testing.T) {
	p := Page{Rows: []Row{
		{Task: mk("root"), Depth: 0},
		{Task: mk("kid"), Depth: 1},
	}, Count: 1}
	text, _ := RenderPage(p, "", 0, 0, 0)
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected two lines, got:\n%s", text)
	}
	if !strings.Contains(lines[1], "  ") {
		t.Errorf("child line is not indented:\n%s", text)
	}
}

func TestRenderPageShowsParentTitleForFindRows(t *testing.T) {
	tk := mk("kid")
	tk.Content.Title = "book flights"
	p := Page{Rows: []Row{{Task: tk, Depth: 0, ParentTitle: "Japan trip"}}, Count: 1}
	text, _ := RenderPage(p, "book", 0, 0, 0)
	if !strings.Contains(text, "Japan trip") {
		t.Errorf("find row lost its parent context:\n%s", text)
	}
}

func TestRenderPageReportsTruncationLoudly(t *testing.T) {
	p := Page{Rows: []Row{{Task: mk("a")}}, Count: 1, Overflow: 12}
	text, _ := RenderPage(p, "", 5, 0, 0)
	if !strings.Contains(text, "12") {
		t.Errorf("page overflow not reported:\n%s", text)
	}
	if !strings.Contains(text, "5") {
		t.Errorf("result-set overflow not reported:\n%s", text)
	}
}

func TestRenderPageEmpty(t *testing.T) {
	text, kb := RenderPage(Page{}, "", 0, 0, 0)
	if !strings.Contains(strings.ToLower(text), "nothing open") {
		t.Errorf("empty page text = %q", text)
	}
	if len(kb) != 0 {
		t.Errorf("empty page should have no keyboard, got %v", kb)
	}
}

func TestRenderPageStaysUnderTelegramLimits(t *testing.T) {
	// A worst-case page: maxRowsPerPage rows with long titles.
	rows := make([]Row, maxRowsPerPage)
	for i := range rows {
		tk := mk(string(rune('a' + i)))
		tk.Content.Title = strings.Repeat("long title ", 12)
		rows[i] = Row{Task: tk, Depth: i % 3}
	}
	text, kb := RenderPage(Page{Rows: rows, Index: 1, Count: 4}, "", 0, 0, 0)
	if n := len([]rune(text)); n > maxMessageRunes {
		t.Errorf("rendered page is %d runes, over Telegram's %d cap", n, maxMessageRunes)
	}
	total := 0
	for _, row := range kb {
		total += len(row)
	}
	if total > maxRowsPerPage+3 {
		t.Errorf("keyboard has %d buttons, more than one per row plus nav", total)
	}
}
