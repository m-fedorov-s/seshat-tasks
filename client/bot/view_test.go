package main

import (
	"math/rand"
	"reflect"
	"testing"

	"seshat/internal/task"
)

const (
	testDay  = 86400
	testWeek = 7 * testDay
)

func mk(id string, opts ...func(*task.Task)) task.Task {
	t := task.Task{
		ID: id,
		Content: task.Content{
			Title:    id,
			Status:   task.StatusTodo,
			Priority: task.PriorityNone,
			ChildIDs: []string{},
			Tags:     []string{},
		},
		Meta: task.Meta{CreatedAt: 0, Version: 1},
	}
	for _, o := range opts {
		o(&t)
	}
	return t
}

func withPriority(p task.Priority) func(*task.Task) {
	return func(t *task.Task) { t.Content.Priority = p }
}
func withStatus(s task.Status) func(*task.Task) {
	return func(t *task.Task) { t.Content.Status = s }
}
func withDue(ts int64) func(*task.Task) {
	return func(t *task.Task) { t.Content.DueAt = &ts }
}
func withCreated(ts int64) func(*task.Task) {
	return func(t *task.Task) { t.Meta.CreatedAt = ts }
}
func withChildren(ids ...string) func(*task.Task) {
	return func(t *task.Task) { t.Content.ChildIDs = ids }
}

func TestUrgencyComponents(t *testing.T) {
	now := int64(10 * testWeek)
	cases := []struct {
		name string
		in   task.Task
		want int64
	}{
		{"bare todo, created now", mk("a", withCreated(now)), 0},
		{"high priority", mk("a", withCreated(now), withPriority(task.PriorityHigh)), 5},
		{"medium priority", mk("a", withCreated(now), withPriority(task.PriorityMedium)), 3},
		{"low priority", mk("a", withCreated(now), withPriority(task.PriorityLow)), 1},
		{"overdue", mk("a", withCreated(now), withDue(now-1)), 8},
		{"due in 12h", mk("a", withCreated(now), withDue(now+testDay/2)), 6},
		{"due in 2d", mk("a", withCreated(now), withDue(now+2*testDay)), 4},
		{"due in 5d", mk("a", withCreated(now), withDue(now+5*testDay)), 2},
		{"due in 30d", mk("a", withCreated(now), withDue(now+30*testDay)), 0},
		{"age 2 weeks", mk("a", withCreated(now-2*testWeek)), 2},
		{"age caps at 4", mk("a", withCreated(now-50*testWeek)), 4},
		{"sum", mk("a", withCreated(now-2*testWeek), withPriority(task.PriorityHigh), withDue(now-1)), 5 + 8 + 2},
		// Terminal statuses score zero regardless of everything else. Ported from
		// view.zig:310 even though selection filters these earlier.
		{"done scores zero", mk("a", withCreated(now-50*testWeek), withPriority(task.PriorityHigh), withDue(now-1), withStatus(task.StatusDone)), 0},
		{"cancelled scores zero", mk("a", withCreated(now-50*testWeek), withStatus(task.StatusCancelled)), 0},
	}
	for _, c := range cases {
		if got := Urgency(c.in, now); got != c.want {
			t.Errorf("%s: Urgency = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestSubtreeMaxUrgency(t *testing.T) {
	now := int64(0)
	tasks := []task.Task{
		mk("root", withChildren("kid")),
		mk("kid", withPriority(task.PriorityHigh)),
	}
	ix := BuildIndex(tasks)
	root, _ := ix.Get("root")
	if got := SubtreeMaxUrgency(root, ix, now); got != 5 {
		t.Errorf("SubtreeMaxUrgency = %d, want 5 (from the child)", got)
	}
}

func TestIndexParentsAndRoots(t *testing.T) {
	tasks := []task.Task{
		mk("root", withChildren("kid")),
		mk("kid"),
		mk("lonely"),
	}
	ix := BuildIndex(tasks)
	if !ix.IsRoot("root") || !ix.IsRoot("lonely") {
		t.Error("root and lonely should be roots")
	}
	if ix.IsRoot("kid") {
		t.Error("kid has a parent, not a root")
	}
	p, ok := ix.ParentOf("kid")
	if !ok || p.ID != "root" {
		t.Errorf("ParentOf(kid) = %v,%v", p.ID, ok)
	}
	if _, ok := ix.ParentOf("root"); ok {
		t.Error("root has no parent")
	}
}

// The regression test for the missing tiebreak. Rank a shuffled input repeatedly
// and assert the output is identical every time. The server returns tasks in Go
// map order, which is randomised per call, so anything less than a strict total
// order reshuffles the list between renders.
func TestRankIsATotalOrder(t *testing.T) {
	now := int64(0)
	// All five score identically: no priority, no due, created at 0.
	base := []task.Task{mk("e"), mk("d"), mk("c"), mk("b"), mk("a")}
	ix := BuildIndex(base)

	var first []string
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 20; i++ {
		shuffled := append([]task.Task(nil), base...)
		rng.Shuffle(len(shuffled), func(x, y int) {
			shuffled[x], shuffled[y] = shuffled[y], shuffled[x]
		})
		RankRoots(shuffled, ix, now)
		ids := make([]string, len(shuffled))
		for j, s := range shuffled {
			ids[j] = s.ID
		}
		if first == nil {
			first = ids
			continue
		}
		if !reflect.DeepEqual(first, ids) {
			t.Fatalf("ranking is not stable: %v then %v", first, ids)
		}
	}
	// With every key equal, the tiebreak is created_at asc then id asc.
	if !reflect.DeepEqual(first, []string{"a", "b", "c", "d", "e"}) {
		t.Errorf("tiebreak order = %v, want a..e", first)
	}
}

func TestRankOrdersByUrgencyThenCreatedThenID(t *testing.T) {
	now := int64(0)
	tasks := []task.Task{
		mk("low", withPriority(task.PriorityLow)),
		mk("high", withPriority(task.PriorityHigh)),
		mk("younger", withPriority(task.PriorityMedium), withCreated(100)),
		mk("older", withPriority(task.PriorityMedium), withCreated(50)),
	}
	ix := BuildIndex(tasks)
	RankRoots(tasks, ix, now)
	want := []string{"high", "older", "younger", "low"}
	got := make([]string, len(tasks))
	for i, s := range tasks {
		got[i] = s.ID
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("order = %v, want %v", got, want)
	}
}

func TestRankSinksClosedTasks(t *testing.T) {
	now := int64(0)
	tasks := []task.Task{
		mk("done", withPriority(task.PriorityHigh), withStatus(task.StatusDone)),
		mk("open"),
	}
	ix := BuildIndex(tasks)
	RankRoots(tasks, ix, now)
	if tasks[0].ID != "open" {
		t.Errorf("closed task should sink below open, got %v first", tasks[0].ID)
	}
}

// A malformed forest must not hang the bot. The server validates against cycles,
// but a client that trusts that absolutely is one bug away from an infinite loop.
func TestSubtreeWalkToleratesACycle(t *testing.T) {
	tasks := []task.Task{
		mk("a", withChildren("b")),
		mk("b", withChildren("a")),
	}
	ix := BuildIndex(tasks)
	a, _ := ix.Get("a")
	_ = SubtreeMaxUrgency(a, ix, 0) // must terminate
}

func groupIDs(gs []Group) [][]string {
	out := make([][]string, len(gs))
	for i, g := range gs {
		ids := make([]string, len(g))
		for j, r := range g {
			ids[j] = r.Task.ID
		}
		out[i] = ids
	}
	return out
}

func TestListGroupsKeepsAClosedParentThatHasAnOpenChild(t *testing.T) {
	tasks := []task.Task{
		mk("parent", withStatus(task.StatusDone), withChildren("kid")),
		mk("kid"), // still todo
	}
	ix := BuildIndex(tasks)
	got := groupIDs(ListGroups(tasks, ix, 0))
	want := [][]string{{"parent", "kid"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v — a done parent must be retained as context so its open child is not erased", got, want)
	}
}

func TestListGroupsDropsAFullyClosedTree(t *testing.T) {
	tasks := []task.Task{
		mk("parent", withStatus(task.StatusDone), withChildren("kid")),
		mk("kid", withStatus(task.StatusCancelled)),
		mk("live"),
	}
	ix := BuildIndex(tasks)
	got := groupIDs(ListGroups(tasks, ix, 0))
	want := [][]string{{"live"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestListGroupsSetsDepth(t *testing.T) {
	tasks := []task.Task{
		mk("root", withChildren("kid")),
		mk("kid", withChildren("grandkid")),
		mk("grandkid"),
	}
	ix := BuildIndex(tasks)
	gs := ListGroups(tasks, ix, 0)
	if len(gs) != 1 || len(gs[0]) != 3 {
		t.Fatalf("expected one group of three rows, got %v", groupIDs(gs))
	}
	for i, wantDepth := range []int{0, 1, 2} {
		if gs[0][i].Depth != wantDepth {
			t.Errorf("row %d (%s) depth = %d, want %d", i, gs[0][i].Task.ID, gs[0][i].Depth, wantDepth)
		}
	}
}

func TestListGroupsOrdersChildrenByChildIDsNotUrgency(t *testing.T) {
	tasks := []task.Task{
		mk("root", withChildren("second", "first")),
		mk("first", withPriority(task.PriorityHigh)),
		mk("second"),
	}
	ix := BuildIndex(tasks)
	got := groupIDs(ListGroups(tasks, ix, 0))
	want := [][]string{{"root", "second", "first"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v — children follow child_ids order", got, want)
	}
}

func TestListGroupsRanksRootsBySubtreeUrgency(t *testing.T) {
	tasks := []task.Task{
		mk("quiet"),
		mk("hasUrgentKid", withChildren("kid")),
		mk("kid", withPriority(task.PriorityHigh)),
	}
	ix := BuildIndex(tasks)
	got := groupIDs(ListGroups(tasks, ix, 0))
	if got[0][0] != "hasUrgentKid" {
		t.Errorf("a buried urgent subtask must lift its root; got %v", got)
	}
}

func TestListGroupsIgnoresDanglingChildIDs(t *testing.T) {
	tasks := []task.Task{mk("root", withChildren("ghost"))}
	ix := BuildIndex(tasks)
	got := groupIDs(ListGroups(tasks, ix, 0))
	want := [][]string{{"root"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestListGroupsEmptyInput(t *testing.T) {
	ix := BuildIndex(nil)
	if got := ListGroups(nil, ix, 0); len(got) != 0 {
		t.Errorf("want no groups, got %v", groupIDs(got))
	}
}

func chainOf(prefix string, n int) []task.Task {
	// one root with n-1 children
	kids := make([]string, 0, n-1)
	for i := 1; i < n; i++ {
		kids = append(kids, prefix+"-kid"+string(rune('a'+i)))
	}
	out := []task.Task{mk(prefix, withChildren(kids...))}
	for _, k := range kids {
		out = append(out, mk(k))
	}
	return out
}

func TestPaginateCapsAtFiveRoots(t *testing.T) {
	var tasks []task.Task
	for i := 0; i < 12; i++ {
		tasks = append(tasks, mk(string(rune('a'+i))))
	}
	ix := BuildIndex(tasks)
	groups := ListGroups(tasks, ix, 0)

	p := Paginate(groups, 0)
	if len(p.Rows) != 5 {
		t.Errorf("page 0 rows = %d, want 5", len(p.Rows))
	}
	if p.Count != 3 {
		t.Errorf("page count = %d, want 3 (12 roots / 5)", p.Count)
	}
	last := Paginate(groups, 2)
	if len(last.Rows) != 2 {
		t.Errorf("last page rows = %d, want 2", len(last.Rows))
	}
}

func TestPaginateNeverSplitsAGroup(t *testing.T) {
	// Four single roots then one root with four children: the fifth group would
	// take the page over 5 roots, so it starts a new page whole.
	var tasks []task.Task
	for i := 0; i < 5; i++ {
		tasks = append(tasks, mk(string(rune('a'+i)), withCreated(int64(i))))
	}
	// created_at 9 sorts this root last, so it cannot fit on page 0 alongside the
	// five singles and must move to page 1 whole, children and all.
	chain := chainOf("z", 4)
	chain[0].Meta.CreatedAt = 9
	tasks = append(tasks, chain...)
	ix := BuildIndex(tasks)
	groups := ListGroups(tasks, ix, 0)

	if got := Paginate(groups, 0).Count; got != 2 {
		t.Fatalf("page count = %d, want 2 — the sixth root must start a new page", got)
	}

	// Walk `groups` alongside the pages: each page's rows must be exactly the
	// concatenation of some run of WHOLE groups, picked up where the previous
	// page left off — never a partial group — with the single documented
	// exception of a lone oversized group, truncated and reported via Overflow.
	gi := 0
	total := 0
	for i := 0; i < Paginate(groups, 0).Count; i++ {
		p := Paginate(groups, i)
		total += len(p.Rows)

		var want Group
		consumed := 0
		for consumed < len(p.Rows) && gi < len(groups) {
			want = append(want, groups[gi]...)
			consumed += len(groups[gi])
			gi++
		}
		if p.Overflow > 0 {
			if p.Overflow >= len(want) {
				t.Fatalf("page %d: overflow %d can't exceed the %d rows it was drawn from", i, p.Overflow, len(want))
			}
			want = want[:len(want)-p.Overflow]
		}
		if !reflect.DeepEqual(Group(p.Rows), want) {
			t.Errorf("page %d rows = %v, want whole groups %v — a group must not be split across pages",
				i, groupIDs([]Group{Group(p.Rows)}), groupIDs([]Group{want}))
		}
	}
	if total != 9 {
		t.Errorf("total rows across pages = %d, want 9 (5 singles + a root with 3 children)", total)
	}
}

func TestPaginateCapsAtTwentyFiveRows(t *testing.T) {
	// Two roots of 20 rows each: 40 rows, under the 5-root cap but over the row
	// cap, so they must land on separate pages.
	tasks := append(chainOf("a", 20), chainOf("b", 20)...)
	ix := BuildIndex(tasks)
	groups := ListGroups(tasks, ix, 0)
	p := Paginate(groups, 0)
	if len(p.Rows) != 20 {
		t.Errorf("page 0 rows = %d, want 20 (the second root does not fit)", len(p.Rows))
	}
	if p.Count != 2 {
		t.Errorf("page count = %d, want 2", p.Count)
	}
}

func TestPaginateTruncatesAnOversizedSingleGroup(t *testing.T) {
	tasks := chainOf("big", 40) // one root, 39 children
	ix := BuildIndex(tasks)
	groups := ListGroups(tasks, ix, 0)
	p := Paginate(groups, 0)
	if len(p.Rows) != maxRowsPerPage {
		t.Errorf("rows = %d, want %d", len(p.Rows), maxRowsPerPage)
	}
	if p.Overflow != 40-maxRowsPerPage {
		t.Errorf("Overflow = %d, want %d — truncation must be reported, never silent", p.Overflow, 40-maxRowsPerPage)
	}
	if p.Count != 1 {
		t.Errorf("an oversized group takes exactly one page, got Count = %d", p.Count)
	}
}

func TestPaginateClampsOutOfRangePages(t *testing.T) {
	tasks := []task.Task{mk("a"), mk("b")}
	ix := BuildIndex(tasks)
	groups := ListGroups(tasks, ix, 0)
	for _, req := range []int{-5, -1, 1, 99} {
		p := Paginate(groups, req)
		if p.Index != 0 {
			t.Errorf("Paginate(page=%d).Index = %d, want 0 (clamped)", req, p.Index)
		}
	}
}

func TestPaginateEmpty(t *testing.T) {
	p := Paginate(nil, 0)
	if len(p.Rows) != 0 || p.Count != 0 || p.Index != 0 {
		t.Errorf("empty paginate = %+v", p)
	}
}

func TestFindMatchesTitleSubstringCaseInsensitively(t *testing.T) {
	tasks := []task.Task{
		mk("a"), mk("b"), mk("c"),
	}
	tasks[0].Content.Title = "Call the Dentist"
	tasks[1].Content.Title = "buy dental floss"
	tasks[2].Content.Title = "unrelated"
	ix := BuildIndex(tasks)

	groups, overflow := FindGroups(tasks, ix, "DENT", 0)
	if overflow != 0 {
		t.Errorf("overflow = %d, want 0", overflow)
	}
	got := groupIDs(groups)
	if len(got) != 2 {
		t.Fatalf("matches = %v, want two", got)
	}
	for _, g := range groups {
		if len(g) != 1 || g[0].Depth != 0 {
			t.Errorf("find rows are flat and single, got %+v", g)
		}
	}
}

func TestFindSkipsClosedTasksAndSetsParentTitle(t *testing.T) {
	tasks := []task.Task{
		mk("parent", withChildren("kid")),
		mk("kid"),
		mk("old", withStatus(task.StatusDone)),
	}
	tasks[0].Content.Title = "Japan trip"
	tasks[1].Content.Title = "book flights"
	tasks[2].Content.Title = "book hotel"
	ix := BuildIndex(tasks)

	groups, _ := FindGroups(tasks, ix, "book", 0)
	if len(groups) != 1 {
		t.Fatalf("want only the open match, got %v", groupIDs(groups))
	}
	if groups[0][0].ParentTitle != "Japan trip" {
		t.Errorf("ParentTitle = %q, want %q", groups[0][0].ParentTitle, "Japan trip")
	}
}

// With now == 0 (the old call site), dueFactor and ageFactor are always zero,
// so results order by priority alone. A none-priority task due in a few hours
// must outrank a low-priority task with no due date once the real now is
// threaded through — matching /list's full-urgency ordering.
func TestFindOrdersByFullUrgencyNotPriorityAlone(t *testing.T) {
	now := int64(10 * testWeek)
	dueSoon := now + testDay/2 // due in 12h
	tasks := []task.Task{
		mk("soon", withPriority(task.PriorityNone), withDue(dueSoon), withCreated(now)),
		mk("low", withPriority(task.PriorityLow), withCreated(now)),
	}
	tasks[0].Content.Title = "match soon"
	tasks[1].Content.Title = "match low"
	ix := BuildIndex(tasks)

	groups, _ := FindGroups(tasks, ix, "match", now)
	if len(groups) != 2 {
		t.Fatalf("want 2 matches, got %v", groupIDs(groups))
	}
	if groups[0][0].Task.ID != "soon" {
		t.Errorf("order = %v, want the soon-due task ranked first (full urgency, not priority alone)", groupIDs(groups))
	}
}

func TestFindReportsOverflowAboveCeiling(t *testing.T) {
	var tasks []task.Task
	for i := 0; i < findCeiling+7; i++ {
		tk := mk(string(rune('a'+i%26)) + string(rune('a'+i/26)))
		tk.Content.Title = "match me"
		tasks = append(tasks, tk)
	}
	ix := BuildIndex(tasks)
	groups, overflow := FindGroups(tasks, ix, "match", 0)
	if len(groups) != findCeiling {
		t.Errorf("groups = %d, want %d", len(groups), findCeiling)
	}
	if overflow != 7 {
		t.Errorf("overflow = %d, want 7", overflow)
	}
}

func TestDueFromKeywordEndOfLocalDay(t *testing.T) {
	// 2026-08-02T12:00:00Z
	const now = int64(1785672000)

	got, err := DueFromKeyword("today", now, 0)
	if err != nil {
		t.Fatal(err)
	}
	// End of 2026-08-02 UTC == 23:59:59
	if want := int64(1785715199); *got != want {
		t.Errorf("today at +00:00 = %d, want %d", *got, want)
	}

	// At +03:00 local it is 15:00 on the 2nd, so "today" is the end of the local
	// 2nd, which is 20:59:59Z.
	got, err = DueFromKeyword("today", now, 180)
	if err != nil {
		t.Fatal(err)
	}
	if want := int64(1785715199 - 180*60); *got != want {
		t.Errorf("today at +03:00 = %d, want %d", *got, want)
	}
}

func TestDueFromKeywordOffsets(t *testing.T) {
	const now = int64(1785672000) // 2026-08-02T12:00:00Z
	base, _ := DueFromKeyword("today", now, 0)
	cases := map[string]int64{
		"tomorrow": 1,
		"+3d":      3,
		"+1w":      7,
	}
	for kw, days := range cases {
		got, err := DueFromKeyword(kw, now, 0)
		if err != nil {
			t.Fatalf("%s: %v", kw, err)
		}
		if want := *base + days*86400; *got != want {
			t.Errorf("%s = %d, want %d (%d days after today)", kw, *got, want, days)
		}
	}
}

func TestDueFromKeywordClear(t *testing.T) {
	got, err := DueFromKeyword("clear", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Errorf("clear must produce nil (a cleared due_at), got %d", *got)
	}
}

func TestDueFromKeywordRejectsUnknown(t *testing.T) {
	if _, err := DueFromKeyword("next tuesday", 0, 0); err == nil {
		t.Error("free-text dates are a v1 non-goal; unknown keywords must error")
	}
}
