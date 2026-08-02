package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
