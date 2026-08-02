package main

import (
	"sort"

	"seshat/internal/task"
)

const (
	day  = int64(86400)
	week = 7 * day
)

// Index gives O(1) lookup by id and parent resolution over a flat task slice.
// The hierarchy is a forest; the server guarantees no cycles and no duplicate
// child references (validate.go), but the walks below still carry a visited set
// so a malformed response cannot hang the bot.
type Index struct {
	byID   map[string]task.Task
	parent map[string]string
}

func BuildIndex(tasks []task.Task) *Index {
	ix := &Index{
		byID:   make(map[string]task.Task, len(tasks)),
		parent: make(map[string]string, len(tasks)),
	}
	for _, t := range tasks {
		ix.byID[t.ID] = t
	}
	for _, t := range tasks {
		for _, c := range t.Content.ChildIDs {
			ix.parent[c] = t.ID
		}
	}
	return ix
}

func (ix *Index) Get(id string) (task.Task, bool) {
	t, ok := ix.byID[id]
	return t, ok
}

func (ix *Index) IsRoot(id string) bool {
	_, hasParent := ix.parent[id]
	return !hasParent
}

func (ix *Index) ParentOf(id string) (task.Task, bool) {
	pid, ok := ix.parent[id]
	if !ok {
		return task.Task{}, false
	}
	return ix.Get(pid)
}

// priorityWeight, dueFactor and ageFactor are ported verbatim from
// client/zig/src/core/view.zig:283-307. The constants are the contract; changing
// one here silently diverges the bot's ordering from the CLI's.
func priorityWeight(p task.Priority) int64 {
	switch p {
	case task.PriorityLow:
		return 1
	case task.PriorityMedium:
		return 3
	case task.PriorityHigh:
		return 5
	default:
		return 0
	}
}

func dueFactor(t task.Task, now int64) int64 {
	if t.Content.DueAt == nil {
		return 0
	}
	delta := *t.Content.DueAt - now // negative => overdue
	switch {
	case delta < 0:
		return 8
	case delta <= day:
		return 6
	case delta <= 3*day:
		return 4
	case delta <= 7*day:
		return 2
	default:
		return 0
	}
}

func ageFactor(t task.Task, now int64) int64 {
	age := now - t.Meta.CreatedAt
	if age <= 0 {
		return 0
	}
	weeks := age / week
	if weeks > 4 {
		weeks = 4
	}
	return weeks
}

// Urgency scores a single task. Terminal statuses score zero (view.zig:310).
func Urgency(t task.Task, now int64) int64 {
	if t.Content.Status.Terminal() {
		return 0
	}
	return priorityWeight(t.Content.Priority) + dueFactor(t, now) + ageFactor(t, now)
}

// SubtreeMaxUrgency is the maximum Urgency over t and everything beneath it. This
// is what roots are ranked by, so a buried urgent subtask lifts its whole tree —
// matching the TUI's ledger.
func SubtreeMaxUrgency(t task.Task, ix *Index, now int64) int64 {
	seen := make(map[string]bool)
	var walk func(task.Task) int64
	walk = func(cur task.Task) int64 {
		if seen[cur.ID] {
			return 0
		}
		seen[cur.ID] = true
		best := Urgency(cur, now)
		for _, cid := range cur.Content.ChildIDs {
			child, ok := ix.Get(cid)
			if !ok {
				continue
			}
			if u := walk(child); u > best {
				best = u
			}
		}
		return best
	}
	return walk(t)
}

// LessRoots is a STRICT TOTAL ORDER, and that is load-bearing. handlers.go:136
// serialises tasks by ranging over a Go map, whose iteration order is randomised
// per call, so the bot's input arrives shuffled differently every time. Without a
// total order, equal-scoring tasks swap places between renders and page
// boundaries move under the user. Ported from view.zig:385-397.
func LessRoots(a, b task.Task, ix *Index, now int64) bool {
	// 1. closed always sinks
	ca, cb := a.Content.Status.Terminal(), b.Content.Status.Terminal()
	if ca != cb {
		return !ca
	}
	// 2. subtree urgency, descending
	ua, ub := SubtreeMaxUrgency(a, ix, now), SubtreeMaxUrgency(b, ix, now)
	if ua != ub {
		return ua > ub
	}
	// 3. stable tiebreak: oldest first, then id ascending (ids are unique, so
	//    this resolves every remaining pair -> total order)
	if a.Meta.CreatedAt != b.Meta.CreatedAt {
		return a.Meta.CreatedAt < b.Meta.CreatedAt
	}
	return a.ID < b.ID
}

func RankRoots(roots []task.Task, ix *Index, now int64) {
	sort.SliceStable(roots, func(i, j int) bool {
		return LessRoots(roots[i], roots[j], ix, now)
	})
}

// Row is one rendered task line. Depth drives indentation. ParentTitle is set
// only for the flat rows /find produces, where the tree is not drawn but the
// parent is still needed as context.
type Row struct {
	Task        task.Task
	Depth       int
	ParentTitle string
}

// Group is a run of rows that must never be split across a page boundary. For
// /list a group is a root and its whole subtree; for /find it is a single row.
type Group []Row

func IsOpen(t task.Task) bool { return !t.Content.Status.Terminal() }

// subtreeHasOpen reports whether t or any descendant is open. This is the
// selection rule, and it is deliberately NOT "t is open": see view.zig:240-243.
// Retaining a closed parent that still has open children is what stops one tap
// on "Done" from erasing a live subtree from every future listing.
func subtreeHasOpen(t task.Task, ix *Index, seen map[string]bool) bool {
	if seen[t.ID] {
		return false
	}
	seen[t.ID] = true
	if IsOpen(t) {
		return true
	}
	for _, cid := range t.Content.ChildIDs {
		child, ok := ix.Get(cid)
		if !ok {
			continue // dangling child id: the server forbids it, but do not crash
		}
		if subtreeHasOpen(child, ix, seen) {
			return true
		}
	}
	return false
}

// expand flattens a root's subtree into indented rows, children in child_ids
// order — the user's chosen sequence, not a re-ranking of it.
func expand(t task.Task, ix *Index, depth int, seen map[string]bool, out *Group) {
	if seen[t.ID] {
		return
	}
	seen[t.ID] = true
	*out = append(*out, Row{Task: t, Depth: depth})
	for _, cid := range t.Content.ChildIDs {
		child, ok := ix.Get(cid)
		if !ok {
			continue
		}
		expand(child, ix, depth+1, seen, out)
	}
}

// ListGroups selects the roots worth showing, ranks them, and expands each into
// a group of indented rows.
func ListGroups(tasks []task.Task, ix *Index, now int64) []Group {
	var roots []task.Task
	for _, t := range tasks {
		if !ix.IsRoot(t.ID) {
			continue
		}
		if subtreeHasOpen(t, ix, make(map[string]bool)) {
			roots = append(roots, t)
		}
	}
	RankRoots(roots, ix, now)

	groups := make([]Group, 0, len(roots))
	for _, r := range roots {
		var g Group
		expand(r, ix, 0, make(map[string]bool), &g)
		groups = append(groups, g)
	}
	return groups
}
