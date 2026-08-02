package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"

	"seshat/internal/task"
)

// Sender is the seam between the handlers and Telegram. Handlers depend on this
// interface rather than *bot.Bot so they can be tested without a fake Telegram
// server — the places a regression here would be silent and either destructive
// or a disclosure.
type Sender interface {
	Send(ctx context.Context, chatID int64, text string, kb [][]Button) (messageID int64, err error)
	Edit(ctx context.Context, chatID int64, messageID int64, text string, kb [][]Button) error
	Answer(ctx context.Context, callbackID, text string) error
	// Prompt sends a ForceReply message and returns its id. ForceReply cannot be
	// attached through EditMessageText, so a free-text edit is necessarily a new
	// message rather than an in-place edit.
	Prompt(ctx context.Context, chatID int64, text string) (messageID int64, err error)
	DeleteMessage(ctx context.Context, chatID, messageID int64) error
}

type Bot struct {
	cfg *Config
	api *Client
	reg *Registry
	s   Sender
	now func() int64
}

func NewBot(cfg *Config, api *Client, reg *Registry, s Sender, now func() int64) *Bot {
	return &Bot{cfg: cfg, api: api, reg: reg, s: s, now: now}
}

// Authorize resolves an update's sender to a seshat token, refusing anyone not in
// the users map and any chat that is not one-to-one.
//
// The chat-type check is not redundant with the allowlist: the allowlist checks
// WHO, and without this it never checks WHERE. The allowlisted user typing
// /list@seshatbot in a group passes the identity check, and the bot would render
// their entire task list into that group. Telegram's default group privacy mode
// does not help, because commands are exactly what it still delivers.
func (b *Bot) Authorize(userID int64, chatType string) (string, bool) {
	if chatType != "private" {
		log.Printf("refused: non-private chat (type=%q, user=%d)", chatType, userID)
		return "", false
	}
	tok, ok := b.cfg.TokenFor(userID)
	if !ok {
		// No reply at all: fail closed, and do not confirm to a stranger that the
		// bot is live.
		log.Printf("refused: unknown telegram user %d", userID)
		return "", false
	}
	return tok, true
}

const helpText = `Send me any message and it becomes a task — the first line is the title, anything after it is the description.

/list — your open tasks, five at a time
/find &lt;text&gt; — search open task titles
/help — this message`

func (b *Bot) HandleStart(ctx context.Context, chatID int64) error {
	_, err := b.s.Send(ctx, chatID, helpText, nil)
	return err
}

// ParseCapture splits a captured message into a title and a description at the
// FIRST newline. No inline metadata syntax (!high, @fri): a newline is
// unambiguous in a way sigils are not, and priority and dates are one tap away in
// the card that comes back.
func ParseCapture(text string) (string, string, bool) {
	title, desc, found := strings.Cut(text, "\n")
	title = strings.TrimSpace(title)
	if title == "" {
		return "", "", false
	}
	if !found {
		return title, "", true
	}
	return title, strings.TrimSpace(desc), true
}

// userMessage turns an error into something worth showing a human. The project
// rule is that clients surface the server's own error text.
func userMessage(err error) string {
	var ae *APIError
	if errors.As(err, &ae) {
		switch ae.Status {
		case http.StatusForbidden:
			return "seshat rejected the token — check the bot's config."
		case http.StatusTooManyRequests:
			return "seshat is rate-limiting — try again in a moment."
		case http.StatusNotFound:
			return "That task no longer exists — it may have been deleted elsewhere."
		case http.StatusConflict:
			return "That task changed underneath me — reopen it."
		default:
			return EscapeHTML(ae.Msg)
		}
	}
	return "Can't reach seshat right now."
}

func (b *Bot) fail(ctx context.Context, chatID int64, err error) error {
	log.Printf("error: %v", err)
	_, sendErr := b.s.Send(ctx, chatID, userMessage(err), nil)
	return sendErr
}

// errInternal marks a client-side bug. Without it, userMessage's default arm
// reports "Can't reach seshat right now" for an unknown due keyword or an
// unhandled action kind — blaming the server for our own defect.
var errInternal = errors.New("internal bot error")

func (b *Bot) failInternal(ctx context.Context, chatID int64, err error) error {
	log.Printf("internal error: %v", err)
	_, sendErr := b.s.Send(ctx, chatID, "Something went wrong on my side — try again.", nil)
	return sendErr
}

// Capture creates a task from a bare message. note, when non-empty, is prepended
// to the reply to explain why this became a task (see the expired-prompt path).
func (b *Bot) Capture(ctx context.Context, chatID int64, token, text, note string) error {
	title, desc, ok := ParseCapture(text)
	if !ok {
		_, err := b.s.Send(ctx, chatID, "A task needs a title.", nil)
		return err
	}
	created, err := b.api.Add(ctx, token, task.AddRequest{
		Content: task.Content{
			Title:       title,
			Description: desc,
			Status:      task.StatusTodo,
			Priority:    task.PriorityNone,
			ChildIDs:    []string{},
			Tags:        []string{},
		},
	})
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	// A card reached by capture has no originating page, so Origin.HasList is
	// false and no Back button is rendered.
	ix := BuildIndex([]task.Task{created})
	body := CardText(created, ix, b.now(), b.cfg.OffsetMinutes())
	if note != "" {
		body = "<i>" + EscapeHTML(note) + "</i>\n\n" + body
	}
	_, err = b.s.Send(ctx, chatID, body, CardKeyboard(created, Origin{HasList: false}))
	return err
}
