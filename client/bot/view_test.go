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
		{"overdue", mk("a", withCreated(now), withDue(now - 1)), 8},
		{"due in 12h", mk("a", withCreated(now), withDue(now + testDay/2)), 6},
		{"due in 2d", mk("a", withCreated(now), withDue(now + 2*testDay)), 4},
		{"due in 5d", mk("a", withCreated(now), withDue(now + 5*testDay)), 2},
		{"due in 30d", mk("a", withCreated(now), withDue(now + 30*testDay)), 0},
		{"age 2 weeks", mk("a", withCreated(now - 2*testWeek)), 2},
		{"age caps at 4", mk("a", withCreated(now - 50*testWeek)), 4},
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
