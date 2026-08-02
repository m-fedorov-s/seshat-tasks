package main

import (
	"strings"
	"sync"
	"testing"
)

func TestRegistryRoundTrip(t *testing.T) {
	r := NewRegistry(10)
	want := Action{Kind: KindOpenTask, TaskID: "01JABC", Page: 3, Query: "dentist"}
	tok, err := r.Put(want)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tok, actionPrefix) {
		t.Errorf("token %q lacks the %q prefix", tok, actionPrefix)
	}
	// Telegram caps callback_data at 64 bytes.
	if len(tok) > 64 {
		t.Errorf("token %q is %d bytes, over Telegram's 64-byte callback_data cap", tok, len(tok))
	}
	got, ok := r.Get(tok)
	if !ok {
		t.Fatal("token did not resolve")
	}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestRegistryTokensAreUnique(t *testing.T) {
	r := NewRegistry(1000)
	seen := map[string]bool{}
	for i := 0; i < 500; i++ {
		tok, err := r.Put(Action{Kind: KindPage, Page: i})
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatalf("duplicate token %q at %d", tok, i)
		}
		seen[tok] = true
	}
}

func TestRegistryUnknownToken(t *testing.T) {
	r := NewRegistry(10)
	if _, ok := r.Get("a:nope"); ok {
		t.Error("unknown token must not resolve")
	}
	if _, ok := r.GetByPrompt(999); ok {
		t.Error("unknown prompt id must not resolve")
	}
}

func TestRegistryPromptIndex(t *testing.T) {
	r := NewRegistry(10)
	want := Action{Kind: KindPromptField, TaskID: "t1", Arg: "title", ExpectedVersion: 7}
	if err := r.PutPrompt(want, 4242); err != nil {
		t.Fatal(err)
	}
	got, ok := r.GetByPrompt(4242)
	if !ok {
		t.Fatal("prompt id did not resolve")
	}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

// Eviction must drop a record from BOTH maps. Two independent LRUs would let a
// record expire as a button while still resolving as a prompt.
func TestRegistryEvictionRemovesFromBothIndexes(t *testing.T) {
	r := NewRegistry(3)
	if err := r.PutPrompt(Action{Kind: KindPromptField, TaskID: "old"}, 111); err != nil {
		t.Fatal(err)
	}
	// Push the prompt record out with three newer entries.
	for i := 0; i < 3; i++ {
		if _, err := r.Put(Action{Kind: KindPage, Page: i}); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := r.GetByPrompt(111); ok {
		t.Error("evicted record still resolves through the prompt index")
	}
}

func TestRegistryEvictsOldestFirst(t *testing.T) {
	r := NewRegistry(2)
	first, _ := r.Put(Action{Kind: KindPage, Page: 1})
	second, _ := r.Put(Action{Kind: KindPage, Page: 2})
	third, _ := r.Put(Action{Kind: KindPage, Page: 3})

	if _, ok := r.Get(first); ok {
		t.Error("oldest entry should have been evicted")
	}
	if _, ok := r.Get(second); !ok {
		t.Error("second entry should survive")
	}
	if _, ok := r.Get(third); !ok {
		t.Error("newest entry should survive")
	}
}

// A hit through either map refreshes recency, so an actively used button does
// not age out mid-flow.
func TestRegistryGetRefreshesRecency(t *testing.T) {
	r := NewRegistry(2)
	first, _ := r.Put(Action{Kind: KindPage, Page: 1})
	_, _ = r.Put(Action{Kind: KindPage, Page: 2})

	if _, ok := r.Get(first); !ok {
		t.Fatal("setup: first should still be present")
	}
	// first is now the most recent, so adding a third evicts the SECOND.
	_, _ = r.Put(Action{Kind: KindPage, Page: 3})
	if _, ok := r.Get(first); !ok {
		t.Error("recently used entry was evicted")
	}
}

func TestRegistryPromptGetRefreshesRecency(t *testing.T) {
	r := NewRegistry(2)
	if err := r.PutPrompt(Action{Kind: KindPromptField, TaskID: "p"}, 55); err != nil {
		t.Fatal(err)
	}
	_, _ = r.Put(Action{Kind: KindPage, Page: 1})
	if _, ok := r.GetByPrompt(55); !ok {
		t.Fatal("setup: prompt should still be present")
	}
	_, _ = r.Put(Action{Kind: KindPage, Page: 2})
	if _, ok := r.GetByPrompt(55); !ok {
		t.Error("recently used prompt was evicted")
	}
}

// go-telegram/bot dispatches handlers on separate goroutines. Run with -race.
func TestRegistryConcurrentAccess(t *testing.T) {
	r := NewRegistry(200)
	var wg sync.WaitGroup
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			tok, err := r.Put(Action{Kind: KindOpenTask, TaskID: "t", Page: n})
			if err != nil {
				t.Error(err)
				return
			}
			r.Get(tok)
			r.PutPrompt(Action{Kind: KindPromptField}, int64(n))
			r.GetByPrompt(int64(n))
		}(i)
	}
	wg.Wait()
}
