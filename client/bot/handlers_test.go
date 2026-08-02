package main

import (
	"context"
	"strings"
	"testing"
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
