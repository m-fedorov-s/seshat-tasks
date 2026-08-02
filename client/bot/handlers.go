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

// msgTaskGone is shown whenever a task turns out to be absent from the freshly
// fetched state — deleted from another client while this bot was showing (or
// about to act on) it. One wording, used at every call site, including
// DoDelete's 404 path, which used to diverge ("That task was already gone.").
const msgTaskGone = "That task no longer exists — it may have been deleted elsewhere."

// msgInternalError is shown for the bot's own bugs — an unhandled action kind,
// an unknown due keyword, or a panic recovered in main.go's dispatch — so the
// server is never blamed for a client-side defect. Used from both this file and
// main.go; both are package main.
const msgInternalError = "Something went wrong on my side — try again."

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

// validCommands is the fixed set of command tokens this bot recognises. Only an
// EXACT, whole-token match against this set may route to a command — see
// ParseCommand.
var validCommands = map[string]bool{
	"start": true,
	"help":  true,
	"list":  true,
	"find":  true,
}

// ParseCommand splits a message into a command name and its argument. It returns
// ok=false when the text is not a command, in which case the caller must treat it
// as a capture.
//
// Matching is on the WHOLE first token, never a prefix: "/listen to the podcast"
// is a task titled "/listen to the podcast", not the /list command. Telegram's
// "/list@botname" addressing form is accepted and the @suffix stripped. A token
// that is slash-shaped but not one of validCommands (a typo, or ordinary text
// that merely starts with "/") is also not a command — ok=false — so it falls
// through to capture like anything else the user typed.
func ParseCommand(text string) (cmd, arg string, ok bool) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return "", "", false
	}
	token := strings.Fields(trimmed)[0]
	if len(token) < 2 || token[0] != '/' {
		return "", "", false
	}
	name := token[1:]
	if at := strings.IndexByte(name, '@'); at >= 0 {
		name = name[:at]
	}
	name = strings.ToLower(name)
	if !validCommands[name] {
		return "", "", false
	}
	arg = strings.TrimSpace(strings.TrimPrefix(trimmed, token))
	return name, arg, true
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
			return msgTaskGone
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
	_, sendErr := b.s.Send(ctx, chatID, msgInternalError, nil)
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

// deliver sends a new message, or edits an existing one when editMsgID is
// non-zero. Navigation edits in place so the chat does not fill with dead lists.
func (b *Bot) deliver(ctx context.Context, chatID, editMsgID int64, text string, kb [][]Button) error {
	if editMsgID != 0 {
		return b.s.Edit(ctx, chatID, editMsgID, text, kb)
	}
	_, err := b.s.Send(ctx, chatID, text, kb)
	return err
}

// ShowList renders /list (query == "") or /find (query != "") at the given page.
func (b *Bot) ShowList(ctx context.Context, chatID, editMsgID int64, token, query string, page int) error {
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	now := b.now()

	var groups []Group
	overflow := 0
	if query == "" {
		groups = ListGroups(tasks, ix, now)
	} else {
		groups, overflow = FindGroups(tasks, ix, query, now)
	}
	// Paginate clamps: a recorded page can outlive the set it referred to.
	p := Paginate(groups, page)
	text, kb := RenderPage(p, query, overflow, now, b.cfg.OffsetMinutes())
	return b.deliver(ctx, chatID, editMsgID, text, kb)
}

// OpenCard renders one task's card. It re-fetches rather than trusting anything
// captured at render time.
func (b *Bot) OpenCard(ctx context.Context, chatID, editMsgID int64, token, taskID string, o Origin) error {
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	t, ok := ix.Get(taskID)
	if !ok {
		// Deleted from another client while this card was open. Say so; do not
		// pretend the button was merely stale.
		return b.deliver(ctx, chatID, editMsgID, msgTaskGone, nil)
	}
	return b.deliver(ctx, chatID, editMsgID,
		CardText(t, ix, b.now(), b.cfg.OffsetMinutes()), CardKeyboard(t, o))
}

// errTaskGone means the task was absent from the freshly fetched state — deleted
// from another client while a card was open.
var errTaskGone = errors.New("task no longer exists")

// applyEdit is the read-modify-write cycle. /api/tasks/update replaces content
// wholesale and takes an expected_version, so we must fetch, mutate a copy, and
// send the whole content block back.
//
// pinnedVersion == 0  -> picker regime: use the freshly fetched version and retry
//
//	once on 409. Safe because the change is one discrete
//	value the user picked moments ago.
//
// pinnedVersion != 0  -> free-text regime: use the pinned version and do NOT
//
//	retry. See Task 14 and spec §8.
func (b *Bot) applyEdit(ctx context.Context, token, taskID string, pinnedVersion uint64, patch func(*task.Content)) (task.Task, error) {
	attempt := func() (task.Task, error) {
		tasks, err := b.api.Get(ctx, token)
		if err != nil {
			return task.Task{}, err
		}
		ix := BuildIndex(tasks)
		t, ok := ix.Get(taskID)
		if !ok {
			return task.Task{}, errTaskGone
		}
		content := t.Content
		patch(&content)
		version := t.Meta.Version
		if pinnedVersion != 0 {
			version = pinnedVersion
		}
		updated, err := b.api.Update(ctx, token, []task.UpdateOp{{
			ID: taskID, Content: content, ExpectedVersion: version,
		}})
		if err != nil {
			return task.Task{}, err
		}
		if len(updated) == 0 {
			return task.Task{}, errTaskGone
		}
		return updated[0], nil
	}

	t, err := attempt()
	if err == nil || pinnedVersion != 0 {
		return t, err
	}
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == http.StatusConflict {
		return attempt() // one retry against fresh state
	}
	return t, err
}

func (b *Bot) originOf(a Action) Origin {
	// Read HasList off the action rather than assuming true: a card reached by
	// capture must not sprout a Back button after its first field edit.
	return Origin{HasList: a.HasList, Page: a.Page, Query: a.Query}
}

// afterMutation reports a failure or re-renders the card.
func (b *Bot) afterMutation(ctx context.Context, chatID, editMsgID int64, token string, a Action, err error) error {
	if errors.Is(err, errTaskGone) {
		return b.deliver(ctx, chatID, editMsgID, msgTaskGone, nil)
	}
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	return b.OpenCard(ctx, chatID, editMsgID, token, a.TaskID, b.originOf(a))
}

// SetField commits one picker choice.
func (b *Bot) SetField(ctx context.Context, chatID, editMsgID int64, token string, a Action) error {
	var patch func(*task.Content)
	switch a.Kind {
	case KindSetStatus:
		s := task.Status(a.Arg)
		if !s.Valid() {
			return b.fail(ctx, chatID, &APIError{Status: 400, Msg: "unknown status"})
		}
		patch = func(c *task.Content) { c.Status = s }
	case KindSetPriority:
		p := task.Priority(a.Arg)
		if !p.Valid() {
			return b.fail(ctx, chatID, &APIError{Status: 400, Msg: "unknown priority"})
		}
		patch = func(c *task.Content) { c.Priority = p }
	case KindSetDue:
		due, err := DueFromKeyword(a.Arg, b.now(), b.cfg.OffsetMinutes())
		if err != nil {
			return b.failInternal(ctx, chatID, err)
		}
		patch = func(c *task.Content) { c.DueAt = due }
	case KindClearTags:
		patch = func(c *task.Content) { c.Tags = []string{} }
	default:
		return b.failInternal(ctx, chatID, errors.New("unhandled field action"))
	}
	_, err := b.applyEdit(ctx, token, a.TaskID, 0, patch)
	return b.afterMutation(ctx, chatID, editMsgID, token, a, err)
}

// Done marks the task done and returns to the originating list rather than
// re-rendering a card for a task that has just left the open set — which would
// leave a Back button pointing into a listing the task is no longer in.
func (b *Bot) Done(ctx context.Context, chatID, editMsgID int64, token string, a Action) error {
	_, err := b.applyEdit(ctx, token, a.TaskID, 0, func(c *task.Content) {
		c.Status = task.StatusDone
	})
	if errors.Is(err, errTaskGone) {
		return b.deliver(ctx, chatID, editMsgID, msgTaskGone, nil)
	}
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	return b.ShowList(ctx, chatID, editMsgID, token, a.Query, a.Page)
}

func (b *Bot) ConfirmDelete(ctx context.Context, chatID, editMsgID int64, token string, a Action) error {
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	t, ok := ix.Get(a.TaskID)
	if !ok {
		return b.deliver(ctx, chatID, editMsgID, msgTaskGone, nil)
	}
	return b.deliver(ctx, chatID, editMsgID,
		DeleteConfirmText(t), DeleteConfirmKeyboard(a.TaskID, b.originOf(a)))
}

func (b *Bot) DoDelete(ctx context.Context, chatID, editMsgID int64, token string, a Action) error {
	if err := b.api.Delete(ctx, token, a.TaskID); err != nil {
		var ae *APIError
		if errors.As(err, &ae) && ae.Status == http.StatusNotFound {
			return b.deliver(ctx, chatID, editMsgID, msgTaskGone, nil)
		}
		return b.fail(ctx, chatID, err)
	}
	return b.ShowList(ctx, chatID, editMsgID, token, a.Query, a.Page)
}

var promptCopy = map[string]string{
	"title":       "Send me the new title.",
	"description": "Send me the new description.",
	"tags":        "Send me the tags, comma-separated.",
}

// applyTextPatch builds the content mutation for a free-text field.
func applyTextPatch(field, value string) func(*task.Content) {
	switch field {
	case "title":
		return func(c *task.Content) { c.Title = value }
	case "description":
		return func(c *task.Content) { c.Description = value }
	case "tags":
		var tags []string
		for _, part := range strings.Split(value, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				tags = append(tags, trimmed)
			}
		}
		if tags == nil {
			tags = []string{}
		}
		return func(c *task.Content) { c.Tags = tags }
	default:
		return nil
	}
}

// PromptField sends a ForceReply prompt and pins meta.version as of now.
//
// The prompt is a NEW message, not an edit: ForceReply cannot be attached through
// EditMessageText, which accepts only inline keyboards.
func (b *Bot) PromptField(ctx context.Context, chatID int64, token string, a Action) error {
	copyText, ok := promptCopy[a.Arg]
	if !ok {
		return b.failInternal(ctx, chatID, errors.New("unknown prompt field "+a.Arg))
	}
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	t, found := ix.Get(a.TaskID)
	if !found {
		_, err := b.s.Send(ctx, chatID, msgTaskGone, nil)
		return err
	}
	if a.Arg == "tags" && len(t.Content.Tags) > 0 {
		copyText += "\n\nCurrently: " + EscapeHTML(strings.Join(t.Content.Tags, ", "))
	}
	msgID, err := b.s.Prompt(ctx, chatID, copyText)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	pinned := a
	// Pin the version as of prompt time. The user is about to compose a reply
	// against text they read on a card that may be minutes old; sending a freshly
	// fetched version at write time would silently clobber a concurrent change.
	pinned.ExpectedVersion = t.Meta.Version
	return b.reg.PutPrompt(pinned, msgID)
}

// HandleReply processes a reply that targets one of the bot's own messages —
// either a live ForceReply prompt, or (after a restart wiped the in-memory
// registry, or an ordinary reply to a card) one that no longer resolves to a
// prompt record. In the latter case it captures rather than discards: losing
// typed words is worse than creating a task the user can delete from the card
// we are about to show them. See dispatch's routing in main.go, which sends any
// reply to a bot message here regardless of whether the prompt is still live.
func (b *Bot) HandleReply(ctx context.Context, chatID, promptMsgID, replyMsgID int64, token, text string) error {
	a, ok := b.reg.GetByPrompt(promptMsgID)
	if !ok {
		return b.Capture(ctx, chatID, token, text,
			"I couldn't match that to an open edit prompt, so I added it as a new task instead.")
	}
	value := strings.TrimSpace(text)
	if a.Arg == "title" && value == "" {
		_, err := b.s.Send(ctx, chatID, "A task needs a title.", nil)
		return err
	}
	patch := applyTextPatch(a.Arg, value)
	if patch == nil {
		return b.failInternal(ctx, chatID, errors.New("unknown prompt field "+a.Arg))
	}

	// Tidy up the prompt so the chat does not accumulate them. Best-effort.
	_ = b.s.DeleteMessage(ctx, chatID, promptMsgID)

	_, err := b.applyEdit(ctx, token, a.TaskID, a.ExpectedVersion, patch)
	if errors.Is(err, errTaskGone) {
		_, sErr := b.s.Send(ctx, chatID, msgTaskGone, nil)
		return sErr
	}
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == http.StatusConflict {
		return b.showConflict(ctx, chatID, token, a, value)
	}
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	return b.OpenCard(ctx, chatID, 0, token, a.TaskID, b.originOf(a))
}

// showConflict surfaces a free-text conflict as DATA, not an error: both values,
// and a choice. This mirrors the TUI's Stage 1 decision that the user's typed
// value is never lost to a conflict.
func (b *Bot) showConflict(ctx context.Context, chatID int64, token string, a Action, typed string) error {
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	t, ok := ix.Get(a.TaskID)
	if !ok {
		_, sErr := b.s.Send(ctx, chatID, msgTaskGone, nil)
		return sErr
	}
	var theirs string
	switch a.Arg {
	case "title":
		theirs = t.Content.Title
	case "description":
		theirs = t.Content.Description
	case "tags":
		theirs = strings.Join(t.Content.Tags, ", ")
	}
	text := "That task changed while you were typing.\n\n" +
		"<b>Theirs:</b>\n" + EscapeHTML(theirs) + "\n\n" +
		"<b>Yours:</b>\n" + EscapeHTML(typed)

	o := b.originOf(a)
	overwrite := o.act(KindOverwrite, a.TaskID, a.Arg)
	overwrite.Text = typed // carries the user's typed value across the button tap
	kb := [][]Button{{
		{"Overwrite", overwrite},
		{"Keep theirs", o.act(KindKeepTheirs, a.TaskID, "")},
	}}
	_, err = b.s.Send(ctx, chatID, text, kb)
	return err
}

// ResolveConflict applies the user's choice from showConflict.
func (b *Bot) ResolveConflict(ctx context.Context, chatID, editMsgID int64, token string, a Action) error {
	if a.Kind == KindKeepTheirs {
		return b.OpenCard(ctx, chatID, editMsgID, token, a.TaskID, b.originOf(a))
	}
	patch := applyTextPatch(a.Arg, a.Text)
	if patch == nil {
		return b.failInternal(ctx, chatID, errors.New("unknown field "+a.Arg))
	}
	// The user has now SEEN the other value and chosen to overwrite, so the fresh
	// version is the right guard (pinnedVersion 0).
	_, err := b.applyEdit(ctx, token, a.TaskID, 0, patch)
	return b.afterMutation(ctx, chatID, editMsgID, token, a, err)
}

// HandleCallback resolves a button token and routes it. AnswerCallbackQuery is
// called on EVERY path, including failures — otherwise Telegram leaves a spinner
// stuck on the button.
func (b *Bot) HandleCallback(ctx context.Context, chatID, msgID int64, callbackID, token, data string) error {
	a, ok := b.reg.Get(data)
	if !ok {
		// Restart, or LRU eviction. Fail closed: edit nothing, say why.
		return b.s.Answer(ctx, callbackID, "That button has expired — send /list again")
	}
	if err := b.s.Answer(ctx, callbackID, ""); err != nil {
		log.Printf("answer callback: %v", err)
	}

	o := b.originOf(a)
	switch a.Kind {
	case KindNoop:
		return nil
	case KindPage, KindBack:
		return b.ShowList(ctx, chatID, msgID, token, a.Query, a.Page)
	case KindOpenTask:
		return b.OpenCard(ctx, chatID, msgID, token, a.TaskID, o)
	case KindPickStatus:
		return b.showPicker(ctx, chatID, msgID, token, a, StatusPickerKeyboard(a.TaskID, o))
	case KindPickPriority:
		return b.showPicker(ctx, chatID, msgID, token, a, PriorityPickerKeyboard(a.TaskID, o))
	case KindPickDue:
		return b.showPicker(ctx, chatID, msgID, token, a, DuePickerKeyboard(a.TaskID, o))
	case KindSetStatus, KindSetPriority, KindSetDue, KindClearTags:
		return b.SetField(ctx, chatID, msgID, token, a)
	case KindDone:
		return b.Done(ctx, chatID, msgID, token, a)
	case KindPromptField:
		return b.PromptField(ctx, chatID, token, a)
	case KindConfirmDelete:
		return b.ConfirmDelete(ctx, chatID, msgID, token, a)
	case KindDoDelete:
		return b.DoDelete(ctx, chatID, msgID, token, a)
	case KindOverwrite, KindKeepTheirs:
		return b.ResolveConflict(ctx, chatID, msgID, token, a)
	default:
		return b.failInternal(ctx, chatID, errors.New("unhandled action kind"))
	}
}

// IsPrompt reports whether messageID is an outstanding ForceReply prompt. It is
// NOT used to gate reply-vs-capture dispatch — see shouldRouteReplyToHandler —
// because a reply to a CARD also targets a bot message and must reach
// HandleReply too, which has its own (registry-backed) live-vs-expired check.
// IsPrompt stays for callers that need to know specifically whether a live
// prompt still exists.
func (b *Bot) IsPrompt(messageID int64) bool {
	_, ok := b.reg.GetByPrompt(messageID)
	return ok
}

// shouldRouteReplyToHandler decides whether an incoming reply should be routed
// to HandleReply rather than treated as a bare Capture. replyFromID is the
// telegram user id of whoever sent the message being replied to (0 if there is
// no reply, or its sender could not be resolved); botID is this bot's own
// telegram id.
//
// The condition is "does this reply target one of the BOT's OWN messages" —
// not "is there a live prompt for it". A reply to a bot message with no live
// prompt record (registry cleared by a restart, or the message being replied to
// is a card rather than a prompt) still routes here, so HandleReply's own
// registry check can decide live-edit vs. expired-capture (see spec §6.4/§9).
// Only a reply to something the bot did NOT send falls through to Capture.
func shouldRouteReplyToHandler(replyFromID, botID int64) bool {
	return replyFromID != 0 && replyFromID == botID
}

// showPicker swaps the keyboard on the card in place, keeping the card's text.
func (b *Bot) showPicker(ctx context.Context, chatID, msgID int64, token string, a Action, kb [][]Button) error {
	tasks, err := b.api.Get(ctx, token)
	if err != nil {
		return b.fail(ctx, chatID, err)
	}
	ix := BuildIndex(tasks)
	t, ok := ix.Get(a.TaskID)
	if !ok {
		return b.deliver(ctx, chatID, msgID, msgTaskGone, nil)
	}
	return b.deliver(ctx, chatID, msgID, CardText(t, ix, b.now(), b.cfg.OffsetMinutes()), kb)
}
