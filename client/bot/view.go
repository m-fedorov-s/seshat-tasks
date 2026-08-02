package main

import (
	"sort"
	"strings"

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

const (
	// A page holds at most 5 roots AND at most 25 rendered rows, whichever limit
	// binds first. Roots alone is not enough of a bound: five roots with twenty
	// children each is 105 lines and 105 inline buttons, which exceeds Telegram's
	// 4096-unit message cap and its reply_markup limits — and would surface to
	// the user as a spurious "can't reach seshat" for a purely client-side bug.
	maxRootsPerPage = 5
	maxRowsPerPage  = 25
	// findCeiling bounds a /find result set. Truncation is always reported.
	findCeiling = 200
)

// Page is one rendered screen. Index is 0-based and always in [0, Count). Overflow
// counts rows dropped from a single oversized group, so the renderer can say so
// out loud rather than truncating silently.
type Page struct {
	Rows     []Row
	Index    int
	Count    int
	Overflow int
}

// pageBreaks computes the group index at which each page starts.
func pageBreaks(groups []Group) []int {
	if len(groups) == 0 {
		return nil
	}
	breaks := []int{0}
	roots, rows := 0, 0
	for i, g := range groups {
		// A group larger than a whole page always takes a page to itself; it is
		// truncated at render time rather than split.
		oversized := len(g) > maxRowsPerPage
		fits := roots+1 <= maxRootsPerPage && rows+len(g) <= maxRowsPerPage
		if i > 0 && (!fits || oversized) {
			breaks = append(breaks, i)
			roots, rows = 0, 0
		}
		roots++
		rows += len(g)
		if oversized {
			// force the next group onto a new page
			roots, rows = maxRootsPerPage, maxRowsPerPage
		}
	}
	return breaks
}

func Paginate(groups []Group, page int) Page {
	breaks := pageBreaks(groups)
	if len(breaks) == 0 {
		return Page{}
	}
	// Clamp: a recorded page index can outlive the set it referred to — mark the
	// only task on the last page done and that page no longer exists.
	if page < 0 {
		page = 0
	}
	if page >= len(breaks) {
		page = len(breaks) - 1
	}
	start := breaks[page]
	end := len(groups)
	if page+1 < len(breaks) {
		end = breaks[page+1]
	}

	var rows []Row
	overflow := 0
	for _, g := range groups[start:end] {
		if len(rows)+len(g) > maxRowsPerPage {
			room := maxRowsPerPage - len(rows)
			rows = append(rows, g[:room]...)
			overflow += len(g) - room
			continue
		}
		rows = append(rows, g...)
	}
	return Page{Rows: rows, Index: page, Count: len(breaks), Overflow: overflow}
}

// FindGroups matches needle case-insensitively as a substring of the TITLE of an
// open task. Results are flat — a match's parent may not itself match, so there
// is no tree to draw — but each row carries its parent's title as context.
// Returns the groups (capped at findCeiling) and the number dropped.
func FindGroups(tasks []task.Task, ix *Index, needle string) ([]Group, int) {
	n := strings.ToLower(strings.TrimSpace(needle))
	if n == "" {
		return nil, 0
	}
	var matches []task.Task
	for _, t := range tasks {
		if !IsOpen(t) {
			continue
		}
		if strings.Contains(strings.ToLower(t.Content.Title), n) {
			matches = append(matches, t)
		}
	}
	RankRoots(matches, ix, 0) // reuse the total order so results are stable

	overflow := 0
	if len(matches) > findCeiling {
		overflow = len(matches) - findCeiling
		matches = matches[:findCeiling]
	}
	groups := make([]Group, 0, len(matches))
	for _, m := range matches {
		row := Row{Task: m, Depth: 0}
		if p, ok := ix.ParentOf(m.ID); ok {
			row.ParentTitle = p.Content.Title
		}
		groups = append(groups, Group{row})
	}
	return groups, overflow
}
