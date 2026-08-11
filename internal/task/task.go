// Package task is the shared Task wire contract, used by the server and by every
// Go client. It is deliberately types-only: no store, no validation, no I/O.
package task

// Status is the lifecycle state of a task. Wire form: lowercase string.
type Status string

const (
	StatusTodo       Status = "todo"
	StatusInProgress Status = "in_progress"
	StatusDone       Status = "done"
	StatusCancelled  Status = "cancelled"
)

func (s Status) Valid() bool {
	switch s {
	case StatusTodo, StatusInProgress, StatusDone, StatusCancelled:
		return true
	}
	return false
}

func (s Status) Terminal() bool { return s == StatusDone || s == StatusCancelled }

// Priority is a bounded priority. Wire form: lowercase string.
type Priority string

const (
	PriorityNone   Priority = "none"
	PriorityLow    Priority = "low"
	PriorityMedium Priority = "medium"
	PriorityHigh   Priority = "high"
)

func (p Priority) Valid() bool {
	switch p {
	case PriorityNone, PriorityLow, PriorityMedium, PriorityHigh:
		return true
	}
	return false
}

// Content is the user-editable part of a task. The whole block is replaced on update.
type Content struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Status      Status   `json:"status"`
	Priority    Priority `json:"priority"`
	ChildIDs    []string `json:"child_ids"`
	Tags        []string `json:"tags"`
	DueAt       *int64   `json:"due_at"`
	ScheduledAt *int64   `json:"scheduled_at"`
}

// Meta is server-owned. Clients never write these.
type Meta struct {
	CreatedAt   int64  `json:"created_at"`
	UpdatedAt   int64  `json:"updated_at"`
	CompletedAt *int64 `json:"completed_at"`
	Version     uint64 `json:"version"`
}

type Task struct {
	ID      string  `json:"id"`
	Content Content `json:"content"`
	Meta    Meta    `json:"meta"`
}

// AddRequest is the body of POST /api/tasks/add.
type AddRequest struct {
	Content  Content `json:"content"`
	ParentID *string `json:"parent_id"`
	Position *int    `json:"position"`
}

// UpdateOp is one element of the "updates" array in POST /api/tasks/update.
// Content replaces the task's content wholesale; ExpectedVersion is the
// optimistic-concurrency guard checked against meta.version.
type UpdateOp struct {
	ID              string  `json:"id"`
	Content         Content `json:"content"`
	ExpectedVersion uint64  `json:"expected_version"`
}
