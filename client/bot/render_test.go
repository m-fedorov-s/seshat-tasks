package main

import (
	"strings"
	"testing"

	"seshat/internal/task"
)

func TestEscapeHTML(t *testing.T) {
	cases := map[string]string{
		"plain":          "plain",
		"budget < 500":   "budget &lt; 500",
		"a & b":          "a &amp; b",
		"<b>bold</b>":    "&lt;b&gt;bold&lt;/b&gt;",
		`say "hi"`:       "say &quot;hi&quot;",
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

func cardTask() task.Task {
	t := mk("01JTASK")
	t.Content.Title = "call the dentist"
	t.Content.Description = "Ask about the crown."
	t.Content.Status = task.StatusTodo
	t.Content.Priority = task.PriorityNone
	t.Content.Tags = []string{}
	return t
}

func TestCardTextShowsFields(t *testing.T) {
	tk := cardTask()
	ix := BuildIndex([]task.Task{tk})
	got := CardText(tk, ix, 0, 0)
	for _, want := range []string{"call the dentist", "Ask about the crown.", "todo", "none"} {
		if !strings.Contains(got, want) {
			t.Errorf("card is missing %q:\n%s", want, got)
		}
	}
}

func TestCardTextEscapesEverything(t *testing.T) {
	tk := cardTask()
	tk.Content.Title = "a < b"
	tk.Content.Description = "x & y"
	tk.Content.Tags = []string{"<tag>"}
	ix := BuildIndex([]task.Task{tk})
	got := CardText(tk, ix, 0, 0)
	if strings.Contains(got, "a < b") || strings.Contains(got, "x & y") || strings.Contains(got, "<tag>") {
		t.Errorf("card leaked unescaped text:\n%s", got)
	}
}

func TestCardTextOmitsEmptyDescription(t *testing.T) {
	tk := cardTask()
	tk.Content.Description = ""
	ix := BuildIndex([]task.Task{tk})
	got := CardText(tk, ix, 0, 0)
	if strings.Contains(got, "\n\n\n") {
		t.Errorf("empty description left a hole:\n%s", got)
	}
}

func TestCardTextShowsParentBreadcrumb(t *testing.T) {
	parent := mk("P")
	parent.Content.Title = "Health"
	parent.Content.ChildIDs = []string{"01JTASK"}
	tk := cardTask()
	ix := BuildIndex([]task.Task{parent, tk})
	got := CardText(tk, ix, 0, 0)
	if !strings.Contains(got, "Health") {
		t.Errorf("card lost its parent breadcrumb:\n%s", got)
	}
}

func TestCardTextShowsSubtaskCount(t *testing.T) {
	tk := cardTask()
	tk.Content.ChildIDs = []string{"a", "b"}
	ix := BuildIndex([]task.Task{tk})
	got := CardText(tk, ix, 0, 0)
	if !strings.Contains(got, "2") {
		t.Errorf("card must show the subtask count — delete is non-recursive:\n%s", got)
	}
}

func TestCardKeyboardHasBackOnlyWhenThereIsAList(t *testing.T) {
	tk := cardTask()

	_, withList := lastRowKinds(CardKeyboard(tk, Origin{HasList: true, Page: 2, Query: "x"}))
	if !withList[KindBack] {
		t.Error("a card opened from a list must offer Back")
	}
	_, fromCapture := lastRowKinds(CardKeyboard(tk, Origin{HasList: false}))
	if fromCapture[KindBack] {
		t.Error("a card reached by capture has no originating page, so no Back button")
	}
}

func lastRowKinds(kb [][]Button) ([][]Button, map[ActionKind]bool) {
	kinds := map[ActionKind]bool{}
	for _, row := range kb {
		for _, b := range row {
			kinds[b.Action.Kind] = true
		}
	}
	return kb, kinds
}

func TestCardKeyboardCarriesOriginOnEveryButton(t *testing.T) {
	tk := cardTask()
	o := Origin{HasList: true, Page: 3, Query: "dentist"}
	kb := CardKeyboard(tk, o)
	for _, row := range kb {
		for _, b := range row {
			if b.Action.Kind == KindNoop {
				continue
			}
			if b.Action.Page != 3 || b.Action.Query != "dentist" {
				t.Errorf("button %q lost its origin: page=%d query=%q", b.Label, b.Action.Page, b.Action.Query)
			}
			if b.Action.TaskID != tk.ID {
				t.Errorf("button %q lost the task id", b.Label)
			}
		}
	}
}

func TestCardKeyboardHasTheExpectedActions(t *testing.T) {
	_, kinds := lastRowKinds(CardKeyboard(cardTask(), Origin{HasList: true}))
	for _, want := range []ActionKind{KindDone, KindPickStatus, KindPickPriority, KindPickDue, KindPromptField, KindConfirmDelete} {
		if !kinds[want] {
			t.Errorf("card keyboard is missing kind %v", want)
		}
	}
	// Delete must never be a single tap.
	if kinds[KindDoDelete] {
		t.Error("the card must not expose DoDelete directly; it goes through a confirm")
	}
}

func TestPickerKeyboards(t *testing.T) {
	o := Origin{HasList: true, Page: 1}

	statuses := map[string]bool{}
	for _, row := range StatusPickerKeyboard("T", o) {
		for _, b := range row {
			if b.Action.Kind == KindSetStatus {
				statuses[b.Action.Arg] = true
			}
		}
	}
	for _, want := range []string{"todo", "in_progress", "done", "cancelled"} {
		if !statuses[want] {
			t.Errorf("status picker is missing %q", want)
		}
	}

	prios := map[string]bool{}
	for _, row := range PriorityPickerKeyboard("T", o) {
		for _, b := range row {
			if b.Action.Kind == KindSetPriority {
				prios[b.Action.Arg] = true
			}
		}
	}
	for _, want := range []string{"none", "low", "medium", "high"} {
		if !prios[want] {
			t.Errorf("priority picker is missing %q", want)
		}
	}

	dues := map[string]bool{}
	for _, row := range DuePickerKeyboard("T", o) {
		for _, b := range row {
			if b.Action.Kind == KindSetDue {
				dues[b.Action.Arg] = true
			}
		}
	}
	for _, want := range []string{"today", "tomorrow", "+3d", "+1w", "clear"} {
		if !dues[want] {
			t.Errorf("due picker is missing %q", want)
		}
	}
	// Every keyword the picker offers must resolve.
	for kw := range dues {
		if _, err := DueFromKeyword(kw, 0, 0); err != nil {
			t.Errorf("due picker offers %q which DueFromKeyword rejects", kw)
		}
	}
}

func TestDeleteConfirmNamesTheConsequence(t *testing.T) {
	tk := cardTask()
	tk.Content.ChildIDs = []string{"a", "b"}
	got := DeleteConfirmText(tk)
	if !strings.Contains(got, "2") {
		t.Errorf("confirm must state the subtask count:\n%s", got)
	}
	if !strings.Contains(strings.ToLower(got), "top-level") {
		t.Errorf("confirm must say children are promoted to top level (store.go:364 is non-recursive):\n%s", got)
	}

	// No children: no scary sentence.
	plain := DeleteConfirmText(cardTask())
	if strings.Contains(strings.ToLower(plain), "top-level") {
		t.Errorf("a childless task needs no subtask warning:\n%s", plain)
	}
}
