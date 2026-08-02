package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// tgSender adapts *bot.Bot to the Sender interface the handlers depend on. It is
// the only place Telegram types meet this codebase's own types, and the only
// place action tokens are minted.
type tgSender struct {
	b   *bot.Bot
	reg *Registry
}

// keyboard converts render.go's button specs into Telegram markup, registering
// each Action and using its token as callback data.
func (s *tgSender) keyboard(kb [][]Button) (*models.InlineKeyboardMarkup, error) {
	if len(kb) == 0 {
		return nil, nil
	}
	out := make([][]models.InlineKeyboardButton, 0, len(kb))
	for _, row := range kb {
		cells := make([]models.InlineKeyboardButton, 0, len(row))
		for _, btn := range row {
			tok, err := s.reg.Put(btn.Action)
			if err != nil {
				return nil, err
			}
			cells = append(cells, models.InlineKeyboardButton{Text: btn.Label, CallbackData: tok})
		}
		out = append(out, cells)
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: out}, nil
}

func (s *tgSender) Send(ctx context.Context, chatID int64, text string, kb [][]Button) (int64, error) {
	markup, err := s.keyboard(kb)
	if err != nil {
		return 0, err
	}
	p := &bot.SendMessageParams{ChatID: chatID, Text: text, ParseMode: models.ParseModeHTML}
	if markup != nil {
		p.ReplyMarkup = markup
	}
	m, err := s.b.SendMessage(ctx, p)
	if err != nil {
		return 0, err
	}
	return int64(m.ID), nil
}

func (s *tgSender) Edit(ctx context.Context, chatID, messageID int64, text string, kb [][]Button) error {
	markup, err := s.keyboard(kb)
	if err != nil {
		return err
	}
	p := &bot.EditMessageTextParams{
		ChatID: chatID, MessageID: int(messageID),
		Text: text, ParseMode: models.ParseModeHTML,
	}
	if markup != nil {
		p.ReplyMarkup = markup
	}
	_, err = s.b.EditMessageText(ctx, p)
	return err
}

func (s *tgSender) Answer(ctx context.Context, callbackID, text string) error {
	_, err := s.b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{
		CallbackQueryID: callbackID, Text: text,
	})
	return err
}

// Prompt sends a ForceReply message. ForceReply cannot ride on EditMessageText,
// so this is necessarily a new message.
func (s *tgSender) Prompt(ctx context.Context, chatID int64, text string) (int64, error) {
	m, err := s.b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID: chatID, Text: text, ParseMode: models.ParseModeHTML,
		ReplyMarkup: &models.ForceReply{ForceReply: true, Selective: true},
	})
	if err != nil {
		return 0, err
	}
	return int64(m.ID), nil
}

func (s *tgSender) DeleteMessage(ctx context.Context, chatID, messageID int64) error {
	_, err := s.b.DeleteMessage(ctx, &bot.DeleteMessageParams{
		ChatID: chatID, MessageID: int(messageID),
	})
	return err
}

// senderID resolves an update's originator as a TOTAL function — no naked
// dereferences. WithAllowedUpdates should already keep exotic shapes out, but
// this must not be the thing that panics if one arrives.
//
// models.Chat.Type is models.ChatType (a defined string type, not string), so
// both returns below convert explicitly — go-telegram/bot v1.22.0 does not
// alias the two, and the compiler rejects an implicit conversion between named
// types.
func senderID(u *models.Update) (userID int64, chatID int64, chatType string, ok bool) {
	switch {
	case u == nil:
		return 0, 0, "", false
	case u.Message != nil && u.Message.From != nil:
		return u.Message.From.ID, u.Message.Chat.ID, string(u.Message.Chat.Type), true
	case u.CallbackQuery != nil:
		cq := u.CallbackQuery
		if cq.Message.Message == nil {
			return 0, 0, "", false
		}
		return cq.From.ID, cq.Message.Message.Chat.ID, string(cq.Message.Message.Chat.Type), true
	}
	return 0, 0, "", false
}

func main() {
	configPath := flag.String("config", "", "path to bot config (default $SESHAT_BOT_CONFIG or ~/.config/seshat/bot.json)")
	flag.Parse()

	path := *configPath
	if path == "" {
		path = os.Getenv("SESHAT_BOT_CONFIG")
	}
	if path == "" {
		path = DefaultConfigPath()
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		log.Fatal(err)
	}

	reg := NewRegistry(registryCapacity)
	api := NewClient(cfg.ServerURL)

	var b *Bot
	sender := &tgSender{reg: reg}

	// recoverMW is installed OUTERMOST. The allowlist below is the code most
	// exposed to update shapes we do not control, and go-telegram/bot dispatches
	// each update on its own goroutine — so an unrecovered panic there would take
	// the whole process down, not one update. This layer logs and does NOT reply,
	// because at this point it cannot know whether the sender is allowlisted.
	recoverMW := func(next bot.HandlerFunc) bot.HandlerFunc {
		return func(ctx context.Context, tb *bot.Bot, u *models.Update) {
			defer func() {
				if r := recover(); r != nil {
					log.Printf("PANIC in handler: %v", r)
				}
			}()
			next(ctx, tb, u)
		}
	}

	authMW := func(next bot.HandlerFunc) bot.HandlerFunc {
		return func(ctx context.Context, tb *bot.Bot, u *models.Update) {
			userID, _, chatType, ok := senderID(u)
			if !ok {
				return
			}
			// Checks WHO and WHERE. Without the chat-type half, the allowlisted
			// user typing /list in a group would dump their task list into it.
			if _, allowed := b.Authorize(userID, chatType); !allowed {
				return
			}
			next(ctx, tb, u)
		}
	}

	dispatch := func(ctx context.Context, tb *bot.Bot, u *models.Update) {
		userID, chatID, chatType, ok := senderID(u)
		if !ok {
			return
		}
		token, allowed := b.Authorize(userID, chatType)
		if !allowed {
			return
		}
		// The INNER recover, per spec §9. recoverMW above cannot reply because it
		// runs before identity is established; here we know the sender is
		// allowlisted, so a panic gets an apology rather than silence.
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC handling update for %d: %v", userID, r)
				_, _ = sender.Send(ctx, chatID, "Something went wrong on my side — try again.", nil)
			}
		}()
		var err error
		switch {
		case u.CallbackQuery != nil:
			msgID := int64(0)
			if u.CallbackQuery.Message.Message != nil {
				msgID = int64(u.CallbackQuery.Message.Message.ID)
			}
			err = b.HandleCallback(ctx, chatID, msgID, u.CallbackQuery.ID, token, u.CallbackQuery.Data)
		case u.Message != nil:
			text := u.Message.Text
			switch {
			case strings.HasPrefix(text, "/start"), strings.HasPrefix(text, "/help"):
				err = b.HandleStart(ctx, chatID)
			case strings.HasPrefix(text, "/list"):
				err = b.ShowList(ctx, chatID, 0, token, "", 0)
			case strings.HasPrefix(text, "/find"):
				// Fields(text)[0] is the whole command token, so this handles both
				// "/find dentist" and "/find@seshatbot dentist".
				needle := strings.TrimSpace(strings.TrimPrefix(text, strings.Fields(text)[0]))
				if needle == "" {
					_, err = sender.Send(ctx, chatID, "Usage: <code>/find some words</code>", nil)
					break
				}
				err = b.ShowList(ctx, chatID, 0, token, needle, 0)
			case u.Message.ReplyToMessage != nil && b.IsPrompt(int64(u.Message.ReplyToMessage.ID)):
				err = b.HandleReply(ctx, chatID, int64(u.Message.ReplyToMessage.ID), int64(u.Message.ID), token, text)
			default:
				// Unconditional: a bare message is ALWAYS a new task.
				err = b.Capture(ctx, chatID, token, text, "")
			}
		}
		if err != nil {
			log.Printf("handler: %v", err)
		}
	}

	tb, err := bot.New(cfg.BotToken,
		bot.WithDefaultHandler(dispatch),
		// Keep exotic update shapes out entirely rather than defending against
		// each one downstream.
		bot.WithAllowedUpdates([]string{"message", "callback_query"}),
		bot.WithMiddlewares(recoverMW, authMW),
	)
	if err != nil {
		log.Fatal(err)
	}
	sender.b = tb
	b = NewBot(cfg, api, reg, sender, func() int64 { return time.Now().Unix() })

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if _, err := tb.SetMyCommands(ctx, &bot.SetMyCommandsParams{
		Commands: []models.BotCommand{
			{Command: "list", Description: "your open tasks"},
			{Command: "find", Description: "search open task titles"},
			{Command: "help", Description: "how this bot works"},
		},
	}); err != nil {
		log.Printf("set commands: %v", err)
	}

	log.Printf("seshat bot started, server=%s, users=%d", cfg.ServerURL, len(cfg.Users))
	tb.Start(ctx)
}
