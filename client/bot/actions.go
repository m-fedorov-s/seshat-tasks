package main

import (
	"container/list"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"sync"
)

// registryCapacity bounds the registry. Every rendered button allocates an entry
// and nothing frees it eagerly — a card is ~10 buttons, a page ~13, and the inert
// page counter takes one on every render — so ordinary use accumulates steadily.
// 2000 is tens of interactions of history at a few hundred KB.
const registryCapacity = 2000

// actionPrefix namespaces callback data so one prefix handler catches every
// button (bot.MatchTypePrefix).
const actionPrefix = "a:"

type ActionKind uint8

const (
	KindNoop ActionKind = iota // the inert page counter
	KindPage                   // navigate to Page of Query ("" = /list)
	KindOpenTask               // render the card for TaskID
	KindBack                   // return to Page of Query
	KindPickStatus             // open the status picker
	KindPickPriority           // open the priority picker
	KindPickDue                // open the due picker
	KindSetStatus              // commit Arg as the status
	KindSetPriority            // commit Arg as the priority
	KindSetDue                 // commit Arg ("today"/"tomorrow"/"+3d"/"+1w"/"clear") as due_at
	KindDone                   // shortcut for status=done, then back to the list
	KindPromptField            // a ForceReply prompt is outstanding for Arg ("title"/"description"/"tags")
	KindClearTags              // clear every tag on TaskID
	KindConfirmDelete          // show the delete confirmation
	KindDoDelete               // actually delete TaskID
	KindOverwrite              // resolve a free-text 409 by writing Text anyway
	KindKeepTheirs             // resolve a free-text 409 by discarding Text
)

// Note: there is deliberately no KindUndo. The spec's §6.4 "[Undo]" affordance on
// an expired-prompt capture is served by the card's existing 🗑 Delete button,
// which the capture reply already renders. One kind fewer, same outcome.

// Action is a fully self-contained description of what a button does. It always
// carries the full task ULID, never a per-chat "current task" cursor — that is
// what makes a tap on a scrolled-back message act on the right task (see the TUI
// fix in 47f7249).
type Action struct {
	Kind   ActionKind
	TaskID string
	// Arg is the kind-specific payload: a status, a priority, a due keyword, or
	// a field name.
	Arg string
	// Page and Query together name the listing to return to. Query is "" for
	// /list and the needle for /find — without it, Back out of a search result
	// would silently drop the user into an unrelated list.
	Page  int
	Query string
	// HasList records whether there IS a listing to go back to. A card reached by
	// capture has none, and this flag is what keeps that true across a field edit:
	// without it, tapping Priority on a capture card re-renders the card with a
	// Back button pointing at a list the user never opened.
	HasList bool
	// ExpectedVersion is set only for KindPromptField and the 409-resolution
	// kinds: it pins meta.version as of when the prompt was sent, so a free-text
	// edit cannot silently clobber a change made elsewhere in between (§8).
	ExpectedVersion uint64
	// Text carries a typed value across a conflict prompt.
	Text string
}

type record struct {
	action          Action
	token           string
	promptMessageID int64 // 0 unless this record backs a ForceReply prompt
}

// Registry maps opaque tokens (and outstanding prompt message ids) to actions.
//
// ONE LRU-ordered record set with TWO maps into it — not two independent LRUs.
// Independent LRUs would let a record expire as a button while still resolving
// as a prompt, so the two lookups would disagree about what exists.
type Registry struct {
	mu       sync.Mutex
	capacity int
	ll       *list.List // front = most recently used; values are *record
	byToken  map[string]*list.Element
	byPrompt map[int64]*list.Element
}

func NewRegistry(capacity int) *Registry {
	return &Registry{
		capacity: capacity,
		ll:       list.New(),
		byToken:  make(map[string]*list.Element),
		byPrompt: make(map[int64]*list.Element),
	}
}

func newToken() (string, error) {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Never fall back to a weaker source: a colliding token would make one
		// button perform another button's action.
		return "", fmt.Errorf("action token: %w", err)
	}
	return actionPrefix + base64.RawURLEncoding.EncodeToString(b[:]), nil
}

// insert adds rec at the front and evicts from the back until we are at capacity.
// Caller holds the lock.
func (r *Registry) insert(rec *record) {
	el := r.ll.PushFront(rec)
	if rec.token != "" {
		r.byToken[rec.token] = el
	}
	if rec.promptMessageID != 0 {
		r.byPrompt[rec.promptMessageID] = el
	}
	for r.ll.Len() > r.capacity {
		back := r.ll.Back()
		if back == nil {
			break
		}
		old := r.ll.Remove(back).(*record)
		// Remove from BOTH maps — this is the whole point of one record set.
		if old.token != "" {
			delete(r.byToken, old.token)
		}
		if old.promptMessageID != 0 {
			delete(r.byPrompt, old.promptMessageID)
		}
	}
}

func (r *Registry) Put(a Action) (string, error) {
	tok, err := newToken()
	if err != nil {
		return "", err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.insert(&record{action: a, token: tok})
	return tok, nil
}

// PutPrompt registers an outstanding ForceReply prompt. It is called AFTER
// SendMessage returns the message id, which leaves a theoretical window in which
// a reply could arrive first; with a human typing this is not reachable and it is
// accepted rather than defended against (§7).
func (r *Registry) PutPrompt(a Action, promptMessageID int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	// Drop any existing record for this id first. Otherwise the stale element
	// stays in the LRU still carrying the id, and evicting it later would delete
	// the NEW record's index entry. Unreachable in practice — Telegram message
	// ids are unique — but the failure would be baffling.
	if el, ok := r.byPrompt[promptMessageID]; ok {
		old := r.ll.Remove(el).(*record)
		if old.token != "" {
			delete(r.byToken, old.token)
		}
		delete(r.byPrompt, promptMessageID)
	}
	r.insert(&record{action: a, promptMessageID: promptMessageID})
	return nil
}

func (r *Registry) Get(token string) (Action, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	el, ok := r.byToken[token]
	if !ok {
		return Action{}, false
	}
	r.ll.MoveToFront(el) // a hit through either map refreshes recency
	return el.Value.(*record).action, true
}

func (r *Registry) GetByPrompt(promptMessageID int64) (Action, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	el, ok := r.byPrompt[promptMessageID]
	if !ok {
		return Action{}, false
	}
	r.ll.MoveToFront(el)
	return el.Value.(*record).action, true
}
