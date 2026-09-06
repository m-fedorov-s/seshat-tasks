package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"seshat/internal/task"
)

// fakeSender records calls so handler behaviour can be asserted without Telegram.
type sentMsg struct {
	ChatID int64
	Text   string
	KB     [][]Button
}

type fakeSender struct {
	sent      []sentMsg
	edited    []sentMsg
	answered  []string
	prompts   []sentMsg
	deleted   []int64
	nextMsgID int64
	failNext  error
}

func (f *fakeSender) Send(ctx context.Context, chatID int64, text string, kb [][]Button) (int64, error) {
	if f.failNext != nil {
		err := f.failNext
		f.failNext = nil
		return 0, err
	}
	f.sent = append(f.sent, sentMsg{chatID, text, kb})
	f.nextMsgID++
	return f.nextMsgID, nil
}

func (f *fakeSender) Edit(ctx context.Context, chatID int64, messageID int64, text string, kb [][]Button) error {
	f.edited = append(f.edited, sentMsg{chatID, text, kb})
	return nil
}

func (f *fakeSender) Answer(ctx context.Context, callbackID, text string) error {
	f.answered = append(f.answered, text)
	return nil
}

func (f *fakeSender) Prompt(ctx context.Context, chatID int64, text string) (int64, error) {
	f.prompts = append(f.prompts, sentMsg{chatID, text, nil})
	f.nextMsgID++
	return f.nextMsgID, nil
}

func (f *fakeSender) DeleteMessage(ctx context.Context, chatID, messageID int64) error {
	f.deleted = append(f.deleted, messageID)
	return nil
}

func testConfig() *Config {
	c := &Config{
		BotToken:  "t",
		ServerURL: "http://example.invalid",
		UTCOffset: "+00:00",
		Users:     map[string]string{"42": "sekrit"},
	}
	c.offsetMinutes = 0
	c.users = map[int64]string{42: "sekrit"}
	return c
}

func newTestBot(f *fakeSender) *Bot {
	return NewBot(testConfig(), NewClient("http://example.invalid"), NewRegistry(100), f, func() int64 { return 0 })
}

func TestAuthorizeAcceptsKnownUserInPrivateChat(t *testing.T) {
	b := newTestBot(&fakeSender{})
	tok, ok := b.Authorize(42, "private")
	if !ok || tok != "sekrit" {
		t.Errorf("Authorize(42, private) = %q,%v; want sekrit,true", tok, ok)
	}
}

func TestAuthorizeRejectsUnknownUser(t *testing.T) {
	b := newTestBot(&fakeSender{})
	if _, ok := b.Authorize(9999, "private"); ok {
		t.Error("an id absent from the users map must be rejected")
	}
}

// The allowlist checks WHO; this checks WHERE. Without it, the allowlisted user
// typing /list in a group would dump their whole task list into that group.
func TestAuthorizeRejectsNonPrivateChats(t *testing.T) {
	b := newTestBot(&fakeSender{})
	for _, chatType := range []string{"group", "supergroup", "channel", ""} {
		if _, ok := b.Authorize(42, chatType); ok {
			t.Errorf("chat type %q must be rejected even for an allowlisted user", chatType)
		}
	}
}

func TestHandleStartExplainsCaptureFirst(t *testing.T) {
	f := &fakeSender{}
	b := newTestBot(f)
	if err := b.HandleStart(context.Background(), 42); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != 1 {
		t.Fatalf("want one message, got %d", len(f.sent))
	}
	body := strings.ToLower(f.sent[0].Text)
	for _, want := range []string{"/list", "/find", "/help"} {
		if !strings.Contains(body, want) {
			t.Errorf("help text is missing %q:\n%s", want, f.sent[0].Text)
		}
	}
	// The primary affordance must be stated first.
	if !strings.Contains(body, "task") {
		t.Errorf("help should lead with 'any message becomes a task':\n%s", f.sent[0].Text)
	}
	// The privacy note must state the whole-account exposure, not a per-task one (spec §10.2).
	for _, want := range []string{"token", "every task", "telegram", "command-line"} {
		if !strings.Contains(body, want) {
			t.Errorf("help text is missing privacy-note substring %q:\n%s", want, f.sent[0].Text)
		}
	}
}

// TestParseCommand covers the finding from Task 16's review: HasPrefix matching
// let a captured task titled "/listen to the podcast" silently trigger /list.
// Matching must be on the WHOLE first token against the bot's actual command
// set, never a prefix.
func TestParseCommand(t *testing.T) {
	cases := []struct {
		in  string
		cmd string
		arg string
		ok  bool
	}{
		{"/list", "list", "", true},
		{"/list  ", "list", "", true},
		{"/find dentist", "find", "dentist", true},
		{"/find  the   dentist ", "find", "the   dentist", true},
		{"/list@seshatbot", "list", "", true},
		{"/find@seshatbot dentist", "find", "dentist", true},
		{"/listen to the podcast", "", "", false},
		{"/", "", "", false},
		{"", "", "", false},
		{"   ", "", "", false},
		{"hello", "", "", false},
		{"not /list", "", "", false},
		{"/LIST", "list", "", true},
		{"/Find@SeshatBot dentist", "find", "dentist", true},
	}
	for _, c := range cases {
		cmd, arg, ok := ParseCommand(c.in)
		if ok != c.ok {
			t.Errorf("ParseCommand(%q) ok = %v, want %v", c.in, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if cmd != c.cmd || arg != c.arg {
			t.Errorf("ParseCommand(%q) = (%q, %q), want (%q, %q)", c.in, cmd, arg, c.cmd, c.arg)
		}
	}
}

func TestParseCaptureSplitsOnFirstNewline(t *testing.T) {
	cases := []struct {
		in    string
		title string
		desc  string
		ok    bool
	}{
		{"call the dentist", "call the dentist", "", true},
		{"call the dentist\nask about the crown", "call the dentist", "ask about the crown", true},
		{"title\nline one\nline two", "title", "line one\nline two", true},
		{"  padded  \n  body  ", "padded", "body", true},
		{"", "", "", false},
		{"   ", "", "", false},
		{"\n\n", "", "", false},
		{"\nonly a body", "", "", false}, // an empty first line is not a title
	}
	for _, c := range cases {
		title, desc, ok := ParseCapture(c.in)
		if ok != c.ok {
			t.Errorf("ParseCapture(%q) ok = %v, want %v", c.in, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if title != c.title || desc != c.desc {
			t.Errorf("ParseCapture(%q) = (%q, %q), want (%q, %q)", c.in, title, desc, c.title, c.desc)
		}
	}
}

// botWithServer wires a Bot against a real httptest server so the read-modify-write
// paths are exercised end to end without Telegram.
func botWithServer(t *testing.T, h http.HandlerFunc) (*Bot, *fakeSender, func()) {
	t.Helper()
	srv := httptest.NewServer(h)
	f := &fakeSender{}
	cfg := testConfig()
	b := NewBot(cfg, NewClient(srv.URL), NewRegistry(100), f, func() int64 { return 0 })
	return b, f, srv.Close
}

func TestCaptureCreatesTodoTaskAndShowsCard(t *testing.T) {
	var got task.AddRequest
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/tasks/add":
			json.NewDecoder(r.Body).Decode(&got)
			json.NewEncoder(w).Encode(map[string]any{
				"state_version": 1,
				"task":          task.Task{ID: "NEW", Content: got.Content, Meta: task.Meta{Version: 1}},
			})
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	})
	defer done()

	if err := b.Capture(context.Background(), 42, "sekrit", "call the dentist\nask about the crown", ""); err != nil {
		t.Fatal(err)
	}
	if got.Content.Title != "call the dentist" || got.Content.Description != "ask about the crown" {
		t.Errorf("sent content = %+v", got.Content)
	}
	if got.Content.Status != task.StatusTodo || got.Content.Priority != task.PriorityNone {
		t.Errorf("capture defaults wrong: status=%q priority=%q", got.Content.Status, got.Content.Priority)
	}
	if got.ParentID != nil {
		t.Error("capture never sets a parent — hierarchy mutation is a v1 non-goal")
	}
	if len(f.sent) != 1 {
		t.Fatalf("want one reply, got %d", len(f.sent))
	}
	if !strings.Contains(f.sent[0].Text, "call the dentist") {
		t.Errorf("reply is not the task card:\n%s", f.sent[0].Text)
	}
	// The card reached by capture has no originating list, so no Back button.
	for _, row := range f.sent[0].KB {
		for _, btn := range row {
			if btn.Action.Kind == KindBack {
				t.Error("a capture card must not offer Back")
			}
		}
	}
}

func TestCaptureRejectsEmptyTitleWithoutCallingServer(t *testing.T) {
	called := false
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		called = true
	})
	defer done()

	if err := b.Capture(context.Background(), 42, "sekrit", "   \n  ", ""); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Error("an empty title must be rejected client-side, with no server round-trip")
	}
	if len(f.sent) != 1 || !strings.Contains(strings.ToLower(f.sent[0].Text), "title") {
		t.Errorf("expected a 'needs a title' reply, got %+v", f.sent)
	}
}

func TestCapturePrefixesANoteWhenGiven(t *testing.T) {
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"state_version": 1,
			"task":          task.Task{ID: "NEW", Content: task.Content{Title: "x"}, Meta: task.Meta{Version: 1}},
		})
	})
	defer done()

	note := "That edit prompt expired, so I added this as a new task instead."
	if err := b.Capture(context.Background(), 42, "sekrit", "x", note); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.sent[0].Text, "expired") {
		t.Errorf("note was not surfaced:\n%s", f.sent[0].Text)
	}
}

func TestCaptureSurfacesServerErrorText(t *testing.T) {
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"title must be non-empty"}`))
	})
	defer done()

	if err := b.Capture(context.Background(), 42, "sekrit", "x", ""); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != 1 || !strings.Contains(f.sent[0].Text, "title must be non-empty") {
		t.Errorf("server error text was not surfaced verbatim: %+v", f.sent)
	}
}

func seedServer(t *testing.T, tasks []task.Task) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/tasks/get" {
			t.Errorf("unexpected path %s", r.URL.Path)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"state_version": 1, "tasks": tasks})
	}
}

func TestShowListSendsAPageWhenNotEditing(t *testing.T) {
	tasks := []task.Task{mk("a"), mk("b")}
	b, f, done := botWithServer(t, seedServer(t, tasks))
	defer done()

	if err := b.ShowList(context.Background(), 42, 0, "sekrit", "", 0); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != 1 || len(f.edited) != 0 {
		t.Fatalf("want one Send and no Edit, got %d/%d", len(f.sent), len(f.edited))
	}
}

func TestShowListEditsInPlaceWhenGivenAMessageID(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, []task.Task{mk("a")}))
	defer done()

	if err := b.ShowList(context.Background(), 42, 77, "sekrit", "", 0); err != nil {
		t.Fatal(err)
	}
	if len(f.edited) != 1 || len(f.sent) != 0 {
		t.Fatalf("navigation must edit in place, got %d sends / %d edits", len(f.sent), len(f.edited))
	}
}

func TestShowListClampsAnOutOfRangePage(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, []task.Task{mk("a")}))
	defer done()

	// Page 9 no longer exists — clamping must not error or render an empty screen.
	if err := b.ShowList(context.Background(), 42, 0, "sekrit", "", 9); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != 1 || !strings.Contains(f.sent[0].Text, "a") {
		t.Errorf("clamped page did not render: %+v", f.sent)
	}
}

func TestShowListEmpty(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, nil))
	defer done()

	if err := b.ShowList(context.Background(), 42, 0, "sekrit", "", 0); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.ToLower(f.sent[0].Text), "nothing open") {
		t.Errorf("empty list text = %q", f.sent[0].Text)
	}
}

func TestShowListWithQueryFiltersByTitle(t *testing.T) {
	a, bb := mk("a"), mk("b")
	a.Content.Title = "call the dentist"
	bb.Content.Title = "buy milk"
	b, f, done := botWithServer(t, seedServer(t, []task.Task{a, bb}))
	defer done()

	if err := b.ShowList(context.Background(), 42, 0, "sekrit", "dent", 0); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(f.sent[0].Text, "buy milk") {
		t.Errorf("find leaked a non-match:\n%s", f.sent[0].Text)
	}
	if !strings.Contains(f.sent[0].Text, "call the dentist") {
		t.Errorf("find dropped the match:\n%s", f.sent[0].Text)
	}
}

func TestOpenCardRendersTheRightTask(t *testing.T) {
	a, bb := mk("A"), mk("B")
	a.Content.Title = "first"
	bb.Content.Title = "second"
	b, f, done := botWithServer(t, seedServer(t, []task.Task{a, bb}))
	defer done()

	o := Origin{HasList: true, Page: 0}
	if err := b.OpenCard(context.Background(), 42, 55, "sekrit", "B", o); err != nil {
		t.Fatal(err)
	}
	if len(f.edited) != 1 {
		t.Fatalf("card should edit in place, got %+v", f)
	}
	if !strings.Contains(f.edited[0].Text, "second") {
		t.Errorf("wrong task rendered:\n%s", f.edited[0].Text)
	}
}

func TestOpenCardReportsAVanishedTask(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, []task.Task{mk("A")}))
	defer done()

	err := b.OpenCard(context.Background(), 42, 55, "sekrit", "GONE", Origin{HasList: true})
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.ToLower(strings.Join([]string{textOf(f.sent), textOf(f.edited)}, " "))
	if !strings.Contains(joined, "no longer exists") {
		t.Errorf("a task deleted elsewhere must be reported plainly, got %q", joined)
	}
}

func textOf(ms []sentMsg) string {
	var out []string
	for _, m := range ms {
		out = append(out, m.Text)
	}
	return strings.Join(out, " ")
}

// updateRecorder serves a GET and an UPDATE, optionally failing the first update
// with a 409 to exercise the retry policy.
type updateRecorder struct {
	tasks       []task.Task
	updates     [][]task.UpdateOp
	conflictOn  int // 1-based update call to answer with 409; 0 = never
	updateCalls int
	deleted     string
}

func (u *updateRecorder) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/tasks/get":
			json.NewEncoder(w).Encode(map[string]any{"state_version": 1, "tasks": u.tasks})
		case "/api/tasks/update":
			var body struct {
				Updates []task.UpdateOp `json:"updates"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			u.updateCalls++
			u.updates = append(u.updates, body.Updates)
			if u.conflictOn == u.updateCalls {
				w.WriteHeader(http.StatusConflict)
				w.Write([]byte(`{"conflicts":[{"id":"T"}]}`))
				return
			}
			out := task.Task{ID: body.Updates[0].ID, Content: body.Updates[0].Content,
				Meta: task.Meta{Version: body.Updates[0].ExpectedVersion + 1}}
			// keep the fixture in step so a retry sees the new version
			for i := range u.tasks {
				if u.tasks[i].ID == out.ID {
					u.tasks[i] = out
				}
			}
			json.NewEncoder(w).Encode(map[string]any{"state_version": 2, "tasks": []task.Task{out}})
		case "/api/tasks/delete":
			var body struct {
				ID string `json:"id"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			u.deleted = body.ID
			json.NewEncoder(w).Encode(map[string]any{"state_version": 3, "deleted": body.ID})
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}
}

func targetTask() task.Task {
	t := mk("T")
	t.Content.Title = "target"
	t.Meta.Version = 4
	return t
}

func TestSetPrioritySendsFetchedVersion(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindSetPriority, TaskID: "T", Arg: "high", Page: 0}
	if err := b.SetField(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if len(u.updates) != 1 {
		t.Fatalf("update calls = %d, want 1", len(u.updates))
	}
	op := u.updates[0][0]
	if op.ExpectedVersion != 4 {
		t.Errorf("expected_version = %d, want the freshly fetched 4", op.ExpectedVersion)
	}
	if op.Content.Priority != task.PriorityHigh {
		t.Errorf("priority = %q, want high", op.Content.Priority)
	}
	if op.Content.Title != "target" {
		t.Error("update must replace content wholesale, preserving untouched fields")
	}
}

func TestSetStatusRetriesOnceOnConflict(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}, conflictOn: 1}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindSetStatus, TaskID: "T", Arg: "in_progress"}
	if err := b.SetField(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 2 {
		t.Errorf("update calls = %d, want 2 (one conflict, one retry)", u.updateCalls)
	}
	if len(f.edited) == 0 {
		t.Error("a successful retry should still render the card")
	}
}

func TestSetDueResolvesKeywordToEndOfLocalDay(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindSetDue, TaskID: "T", Arg: "today"}
	if err := b.SetField(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	got := u.updates[0][0].Content.DueAt
	want, _ := DueFromKeyword("today", 0, 0)
	if got == nil || *got != *want {
		t.Errorf("due_at = %v, want %v (23:59:59 local, per edit.zig:61-66)", got, want)
	}
}

func TestSetDueClearRemovesTheDate(t *testing.T) {
	seed := targetTask()
	due := int64(999)
	seed.Content.DueAt = &due
	u := &updateRecorder{tasks: []task.Task{seed}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindSetDue, TaskID: "T", Arg: "clear"}
	if err := b.SetField(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.updates[0][0].Content.DueAt != nil {
		t.Error("clear must null due_at")
	}
}

// Done is the most-used action; after it the task leaves the open list, so
// re-rendering its card would leave a Back pointing into a set it has left.
func TestDoneReturnsToTheList(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindDone, TaskID: "T", Page: 0}
	if err := b.Done(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.updates[0][0].Content.Status != task.StatusDone {
		t.Errorf("status = %q, want done", u.updates[0][0].Content.Status)
	}
	if len(f.edited) == 0 {
		t.Fatal("expected the list to be re-rendered in place")
	}
	last := f.edited[len(f.edited)-1].Text
	if strings.Contains(last, "priority  ") {
		t.Errorf("Done re-rendered a card instead of returning to the list:\n%s", last)
	}
}

func TestConfirmDeleteWarnsAboutOrphanedChildren(t *testing.T) {
	parent := targetTask()
	parent.Content.ChildIDs = []string{"k1", "k2"}
	u := &updateRecorder{tasks: []task.Task{parent, mk("k1"), mk("k2")}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindConfirmDelete, TaskID: "T"}
	if err := b.ConfirmDelete(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	body := strings.ToLower(f.edited[0].Text)
	if !strings.Contains(body, "2") || !strings.Contains(body, "top-level") {
		t.Errorf("delete confirm must state that children are promoted:\n%s", f.edited[0].Text)
	}
}

func TestDoDeleteRemovesAndReturnsToTheList(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindDoDelete, TaskID: "T", Page: 0}
	if err := b.DoDelete(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.deleted != "T" {
		t.Errorf("deleted = %q, want T", u.deleted)
	}
	if len(f.edited) == 0 {
		t.Error("expected the list to be re-rendered after deletion")
	}
}

func TestSetFieldReportsAVanishedTask(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{mk("OTHER")}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindSetPriority, TaskID: "GONE", Arg: "high"}
	if err := b.SetField(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 0 {
		t.Error("a task absent from the fetched set must not be POSTed")
	}
	joined := strings.ToLower(textOf(f.sent) + " " + textOf(f.edited))
	if !strings.Contains(joined, "no longer exists") {
		t.Errorf("expected a 'no longer exists' reply, got %q", joined)
	}
}

func TestPromptFieldPinsTheVersionAtPromptTime(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}} // version 4
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindPromptField, TaskID: "T", Arg: "title", Page: 1}
	if err := b.PromptField(context.Background(), 42, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if len(f.prompts) != 1 {
		t.Fatalf("want one ForceReply prompt, got %d", len(f.prompts))
	}
	got, ok := b.reg.GetByPrompt(f.nextMsgID)
	if !ok {
		t.Fatal("prompt was not registered against its message id")
	}
	if got.ExpectedVersion != 4 {
		t.Errorf("pinned version = %d, want 4 (as of prompt time)", got.ExpectedVersion)
	}
	if got.Arg != "title" || got.TaskID != "T" || got.Page != 1 {
		t.Errorf("prompt record lost context: %+v", got)
	}
}

func TestHandleReplyAppliesTheEditWithThePinnedVersion(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title", ExpectedVersion: 2}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", "a new title"); err != nil {
		t.Fatal(err)
	}
	if len(u.updates) != 1 {
		t.Fatalf("updates = %d, want 1", len(u.updates))
	}
	op := u.updates[0][0]
	if op.ExpectedVersion != 2 {
		t.Errorf("expected_version = %d, want the PINNED 2, not the fetched 4", op.ExpectedVersion)
	}
	if op.Content.Title != "a new title" {
		t.Errorf("title = %q", op.Content.Title)
	}
}

// The crux: free-text edits must NOT auto-retry, or a concurrent change is
// silently clobbered.
func TestHandleReplyDoesNotRetryOnConflict(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}, conflictOn: 1}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title", ExpectedVersion: 2}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", "mine"); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 1 {
		t.Errorf("update calls = %d, want exactly 1 — free-text edits never auto-retry", u.updateCalls)
	}
	body := textOf(f.sent) + textOf(f.edited)
	if !strings.Contains(body, "mine") {
		t.Errorf("the user's typed value must be preserved in the conflict prompt:\n%s", body)
	}
	var kinds = map[ActionKind]bool{}
	for _, m := range append(append([]sentMsg{}, f.sent...), f.edited...) {
		for _, row := range m.KB {
			for _, btn := range row {
				kinds[btn.Action.Kind] = true
			}
		}
	}
	if !kinds[KindOverwrite] || !kinds[KindKeepTheirs] {
		t.Error("a free-text conflict must offer Overwrite and Keep theirs")
	}
}

func TestHandleReplyOnExpiredPromptCapturesInstead(t *testing.T) {
	var added task.AddRequest
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/tasks/add" {
			json.NewDecoder(r.Body).Decode(&added)
			json.NewEncoder(w).Encode(map[string]any{"state_version": 1,
				"task": task.Task{ID: "NEW", Content: added.Content, Meta: task.Meta{Version: 1}}})
			return
		}
		t.Errorf("unexpected path %s", r.URL.Path)
	})
	defer done()

	// No prompt registered for 12345.
	if err := b.HandleReply(context.Background(), 42, 12345, 12346, "sekrit", "some words"); err != nil {
		t.Fatal(err)
	}
	if added.Content.Title != "some words" {
		t.Errorf("expired prompt should capture the text, got %+v", added.Content)
	}
	if !strings.Contains(strings.ToLower(textOf(f.sent)), "edit prompt") {
		t.Errorf("the user must be told why this became a task:\n%s", textOf(f.sent))
	}
}

func TestHandleReplyParsesTags(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "tags", ExpectedVersion: 4}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", " work , urgent ,, q3 "); err != nil {
		t.Fatal(err)
	}
	got := u.updates[0][0].Content.Tags
	want := []string{"work", "urgent", "q3"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("tags = %v, want %v (split, trimmed, empties dropped)", got, want)
	}
}

func TestHandleReplyRejectsAnEmptyTitleClientSide(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title", ExpectedVersion: 4}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", "    "); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 0 {
		t.Error("an empty title must not reach the server")
	}
	if !strings.Contains(strings.ToLower(textOf(f.sent)), "title") {
		t.Errorf("expected a 'needs a title' reply, got %q", textOf(f.sent))
	}
}

func TestPromptDeletesItsOwnMessageAfterHandling(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title", ExpectedVersion: 4}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", "new"); err != nil {
		t.Fatal(err)
	}
	var sawPrompt bool
	for _, id := range f.deleted {
		if id == 900 {
			sawPrompt = true
		}
	}
	if !sawPrompt {
		t.Error("the bot should delete its own ForceReply prompt after handling the reply")
	}
}

func TestResolveConflictOverwriteWritesWithTheFreshVersion(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindOverwrite, TaskID: "T", Arg: "title", Text: "mine wins"}
	if err := b.ResolveConflict(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if len(u.updates) != 1 || u.updates[0][0].Content.Title != "mine wins" {
		t.Errorf("overwrite did not apply: %+v", u.updates)
	}
	if u.updates[0][0].ExpectedVersion != 4 {
		t.Errorf("overwrite should use the fresh version, got %d", u.updates[0][0].ExpectedVersion)
	}
}

func TestResolveConflictKeepTheirsDiscardsTheEdit(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, _, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindKeepTheirs, TaskID: "T"}
	if err := b.ResolveConflict(context.Background(), 42, 55, "sekrit", a); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 0 {
		t.Error("Keep theirs must not write anything")
	}
}

// showConflict is the only place in the bot that builds an Action literal
// instead of going through Origin.act, and it used to drop HasList on both
// buttons. Overwriting a conflicted title then came back with no Back button,
// even though the edit started from a listing. This follows the conflict all
// the way from a HasList-true prompt, through the buttons showConflict
// renders, to the card ResolveConflict re-renders after Overwrite is tapped.
func TestConflictButtonsPreserveHasList(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}, conflictOn: 1}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title",
		ExpectedVersion: 2, HasList: true, Page: 2, Query: "foo"}, 900)
	if err := b.HandleReply(context.Background(), 42, 900, 901, "sekrit", "mine"); err != nil {
		t.Fatal(err)
	}

	var overwrite Action
	found := false
	for _, m := range append(append([]sentMsg{}, f.sent...), f.edited...) {
		for _, row := range m.KB {
			for _, btn := range row {
				if btn.Action.Kind == KindOverwrite {
					overwrite, found = btn.Action, true
				}
			}
		}
	}
	if !found {
		t.Fatal("no Overwrite button was rendered")
	}
	if !overwrite.HasList || overwrite.Page != 2 || overwrite.Query != "foo" {
		t.Errorf("Overwrite button lost its origin: %+v", overwrite)
	}

	if err := b.ResolveConflict(context.Background(), 42, 55, "sekrit", overwrite); err != nil {
		t.Fatal(err)
	}
	last := f.edited[len(f.edited)-1]
	if !kindsIn(last.KB)[KindBack] {
		t.Error("after Overwrite, the re-rendered card must still offer a Back button")
	}
}

func TestHandleCallbackAlwaysAnswers(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	tok, _ := b.reg.Put(Action{Kind: KindOpenTask, TaskID: "T"})
	if err := b.HandleCallback(context.Background(), 42, 55, "cb1", "sekrit", tok); err != nil {
		t.Fatal(err)
	}
	if len(f.answered) != 1 {
		t.Errorf("AnswerCallbackQuery calls = %d, want 1 — otherwise the button spins forever", len(f.answered))
	}
}

func TestHandleCallbackUnknownTokenEditsNothing(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, []task.Task{mk("a")}))
	defer done()

	if err := b.HandleCallback(context.Background(), 42, 55, "cb1", "sekrit", "a:bogus"); err != nil {
		t.Fatal(err)
	}
	if len(f.edited) != 0 || len(f.sent) != 0 {
		t.Errorf("an expired token must edit nothing, got %d edits / %d sends", len(f.edited), len(f.sent))
	}
	if len(f.answered) != 1 || !strings.Contains(strings.ToLower(f.answered[0]), "expired") {
		t.Errorf("expected an 'expired' callback answer, got %v", f.answered)
	}
}

func TestHandleCallbackNoopDoesNothingVisible(t *testing.T) {
	b, f, done := botWithServer(t, seedServer(t, []task.Task{mk("a")}))
	defer done()

	tok, _ := b.reg.Put(Action{Kind: KindNoop})
	if err := b.HandleCallback(context.Background(), 42, 55, "cb1", "sekrit", tok); err != nil {
		t.Fatal(err)
	}
	if len(f.edited) != 0 || len(f.sent) != 0 {
		t.Error("the page counter is inert")
	}
	if len(f.answered) != 1 {
		t.Error("even an inert button must be answered")
	}
}

// cardMarker appears only in CardText (see render.go's "priority  <code>" line),
// never in a list render — it is the cheapest way to tell "rendered a card" from
// "rendered a list" without duplicating render.go's layout.
const cardMarker = "priority  <code>"

// kindsIn collects every button's Action.Kind across a keyboard, so a test can
// assert WHICH picker (or confirmation) was shown rather than just that some
// keyboard was shown.
func kindsIn(kb [][]Button) map[ActionKind]bool {
	m := map[ActionKind]bool{}
	for _, row := range kb {
		for _, btn := range row {
			m[btn.Action.Kind] = true
		}
	}
	return m
}

// TestHandleCallbackRoutesEachKind checks not just whether a kind writes, but
// what it actually rendered — a card vs. a list, and (for pickers and the
// delete confirmation) which keyboard was swapped in. A write/no-write bit
// alone cannot catch e.g. KindOpenTask and KindPage being swapped, or
// KindPickStatus and KindPickPriority swapping keyboard builders: both members
// of any such pair still produce zero writes (or the same write) and exactly
// one Answer call.
func TestHandleCallbackRoutesEachKind(t *testing.T) {
	cases := []struct {
		kind      ActionKind
		arg       string
		wantWrite bool // does it POST an update or delete?
		wantCard  bool // rendered text is the task card (has cardMarker), not a list
		checkKB   bool
		wantKB    ActionKind // a button of this kind must appear in the resulting keyboard
	}{
		{kind: KindOpenTask, wantCard: true, checkKB: true, wantKB: KindDone},
		{kind: KindPage, wantCard: false},
		{kind: KindBack, wantCard: false},
		{kind: KindPickStatus, wantCard: true, checkKB: true, wantKB: KindSetStatus},
		{kind: KindPickPriority, wantCard: true, checkKB: true, wantKB: KindSetPriority},
		{kind: KindPickDue, wantCard: true, checkKB: true, wantKB: KindSetDue},
		{kind: KindSetStatus, arg: "done", wantWrite: true, wantCard: true, checkKB: true, wantKB: KindDone},
		{kind: KindSetPriority, arg: "high", wantWrite: true, wantCard: true, checkKB: true, wantKB: KindDone},
		{kind: KindSetDue, arg: "today", wantWrite: true, wantCard: true, checkKB: true, wantKB: KindDone},
		{kind: KindClearTags, wantWrite: true, wantCard: true, checkKB: true, wantKB: KindDone},
		{kind: KindConfirmDelete, wantCard: false, checkKB: true, wantKB: KindDoDelete},
		{kind: KindDoDelete, wantWrite: true, wantCard: false},
	}
	for _, c := range cases {
		u := &updateRecorder{tasks: []task.Task{targetTask()}}
		b, f, done := botWithServer(t, u.handler(t))

		tok, _ := b.reg.Put(Action{Kind: c.kind, TaskID: "T", Arg: c.arg})
		if err := b.HandleCallback(context.Background(), 42, 55, "cb", "sekrit", tok); err != nil {
			t.Errorf("kind %v: %v", c.kind, err)
		}
		wrote := u.updateCalls > 0 || u.deleted != ""
		if wrote != c.wantWrite {
			t.Errorf("kind %v: wrote=%v, want %v", c.kind, wrote, c.wantWrite)
		}
		if len(f.answered) != 1 {
			t.Errorf("kind %v: answered %d times, want 1", c.kind, len(f.answered))
		}
		// msgID (55) is always non-zero here, so every path above edits in place —
		// never sends a new message.
		if len(f.edited) == 0 {
			t.Fatalf("kind %v: expected an in-place edit, got none (sent=%d)", c.kind, len(f.sent))
		}
		last := f.edited[len(f.edited)-1]
		if gotCard := strings.Contains(last.Text, cardMarker); gotCard != c.wantCard {
			t.Errorf("kind %v: rendered a card=%v, want %v (text:\n%s)", c.kind, gotCard, c.wantCard, last.Text)
		}
		if c.checkKB && !kindsIn(last.KB)[c.wantKB] {
			t.Errorf("kind %v: keyboard is missing a %v button — wrong picker/confirmation shown", c.kind, c.wantKB)
		}
		done()
	}
}

// showPicker's vanished-task branch has no direct coverage from the table above
// (every case there targets a task that exists), so — following the convention
// of TestOpenCardReportsAVanishedTask and TestSetFieldReportsAVanishedTask —
// this exercises it on its own.
func TestShowPickerReportsAVanishedTask(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{mk("OTHER")}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	a := Action{Kind: KindPickStatus, TaskID: "GONE"}
	if err := b.showPicker(context.Background(), 42, 55, "sekrit", a, StatusPickerKeyboard("GONE", Origin{})); err != nil {
		t.Fatal(err)
	}
	if u.updateCalls != 0 {
		t.Error("a task absent from the fetched set must not be POSTed")
	}
	joined := strings.ToLower(textOf(f.sent) + " " + textOf(f.edited))
	if !strings.Contains(joined, "no longer exists") {
		t.Errorf("expected a 'no longer exists' reply, got %q", joined)
	}
}

func TestIsPromptDistinguishesPromptsFromOtherMessages(t *testing.T) {
	b, _, done := botWithServer(t, seedServer(t, []task.Task{mk("a")}))
	defer done()

	b.reg.PutPrompt(Action{Kind: KindPromptField, TaskID: "T", Arg: "title"}, 700)
	if !b.IsPrompt(700) {
		t.Error("a registered prompt must be recognised")
	}
	// IsPrompt itself still distinguishes "live prompt" from "not" — it just no
	// longer gates whether a reply reaches HandleReply (see
	// shouldRouteReplyToHandler and TestReplyToBotMessageWithNoLivePromptRoutesToCaptureWithNote).
	if b.IsPrompt(701) {
		t.Error("an unrelated message id must not look like a prompt")
	}
}

func TestShouldRouteReplyToHandler(t *testing.T) {
	cases := []struct {
		name        string
		replyFromID int64
		botID       int64
		want        bool
	}{
		{"reply to the bot's own message", 999, 999, true},
		{"reply to a different user's message", 123, 999, false},
		{"no reply, or its sender could not be resolved", 0, 999, false},
	}
	for _, c := range cases {
		if got := shouldRouteReplyToHandler(c.replyFromID, c.botID); got != c.want {
			t.Errorf("%s: shouldRouteReplyToHandler(%d, %d) = %v, want %v",
				c.name, c.replyFromID, c.botID, got, c.want)
		}
	}
}

// This is the regression FIX 1 closes: before it, main.go's dispatch gated
// HandleReply on IsPrompt — the SAME registry lookup HandleReply itself makes —
// so a restart that wiped the registry made HandleReply's expired-prompt branch
// unreachable from production code: the user got a silent duplicate task with
// no explanation. TestHandleReplyOnExpiredPromptCapturesInstead covers
// HandleReply in isolation; this proves the ROUTING decision that feeds it in
// production also says "yes, call HandleReply" for exactly this case — wiring
// the two halves of the fix together, since dispatch itself closes over
// *bot.Bot and cannot be exercised directly here.
func TestReplyToBotMessageWithNoLivePromptRoutesToCaptureWithNote(t *testing.T) {
	const botID = 12345
	replyFromID := int64(botID) // the message being replied to was sent BY the bot
	if !shouldRouteReplyToHandler(replyFromID, botID) {
		t.Fatal("a reply targeting the bot's own message must route to HandleReply")
	}

	var added task.AddRequest
	b, f, done := botWithServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/tasks/add" {
			json.NewDecoder(r.Body).Decode(&added)
			json.NewEncoder(w).Encode(map[string]any{"state_version": 1,
				"task": task.Task{ID: "NEW", Content: added.Content, Meta: task.Meta{Version: 1}}})
			return
		}
		t.Errorf("unexpected path %s", r.URL.Path)
	})
	defer done()

	// No prompt record for this message id — never one (a reply to a card) or
	// lost (a restart); HandleReply must not tell the difference, and both
	// capture with the same explanatory note.
	if err := b.HandleReply(context.Background(), 42, 777, 778, "sekrit", "buy milk"); err != nil {
		t.Fatal(err)
	}
	if added.Content.Title != "buy milk" {
		t.Errorf("expected a capture carrying the replied text, got %+v", added.Content)
	}
	if !strings.Contains(strings.ToLower(textOf(f.sent)), "couldn't match that to an open edit prompt") {
		t.Errorf("expected the softened explanatory note, got:\n%s", textOf(f.sent))
	}
}

func TestHandleCallbackPromptFieldSendsAPrompt(t *testing.T) {
	u := &updateRecorder{tasks: []task.Task{targetTask()}}
	b, f, done := botWithServer(t, u.handler(t))
	defer done()

	tok, _ := b.reg.Put(Action{Kind: KindPromptField, TaskID: "T", Arg: "title"})
	if err := b.HandleCallback(context.Background(), 42, 55, "cb", "sekrit", tok); err != nil {
		t.Fatal(err)
	}
	if len(f.prompts) != 1 {
		t.Errorf("prompts = %d, want 1", len(f.prompts))
	}
}
