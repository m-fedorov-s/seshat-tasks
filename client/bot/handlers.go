package main

import (
	"context"
	"log"
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
