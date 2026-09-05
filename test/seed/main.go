// Command seshat-seed loads a legacy-shaped `{"tasks": {id: Task}}` JSON file into a
// running seshat server through the same /api/tasks/add wire contract every client
// uses. It exists so integration tests (and one-off migrations, spec §8) never need
// to write the server's data file directly.
//
// Order: every task that is nobody's child is a root; each root and its subtree are
// then added depth-first in child_ids order, so sibling order is preserved by plain
// append (no explicit position). parent_id in each add request is the *new*,
// server-assigned id of the parent, not the id from the legacy file.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"time"

	"seshat/internal/task"
)

type legacy struct {
	// state_version and data_format_version are ignored: this tool re-derives both
	// by replaying adds against a live server.
	Tasks map[string]task.Task `json:"tasks"`
}

type addResponse struct {
	StateVersion uint64    `json:"state_version"`
	Task         task.Task `json:"task"`
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func main() {
	url := flag.String("url", "http://127.0.0.1:8799", "seshat server base URL")
	token := flag.String("token", "", "auth token (sent verbatim in the Authorization header)")
	flag.Parse()

	if *token == "" {
		die("-token is required")
	}
	args := flag.Args()
	if len(args) != 1 {
		die("usage: seshat-seed -url URL -token TOKEN FILE.json")
	}

	raw, err := os.ReadFile(args[0])
	if err != nil {
		die("read %s: %v", args[0], err)
	}
	var data legacy
	if err := json.Unmarshal(raw, &data); err != nil {
		die("parse %s: %v", args[0], err)
	}

	// Every id that appears in some task's child_ids is, by definition, not a root.
	isChild := make(map[string]bool, len(data.Tasks))
	for _, t := range data.Tasks {
		for _, c := range t.Content.ChildIDs {
			isChild[c] = true
		}
	}
	var roots []string
	for id := range data.Tasks {
		if !isChild[id] {
			roots = append(roots, id)
		}
	}
	sort.Strings(roots) // deterministic order, independent of Go map iteration

	if len(roots) == 0 && len(data.Tasks) > 0 {
		die("no roots: cycle in child_ids?")
	}

	client := &http.Client{Timeout: 30 * time.Second}
	newID := make(map[string]string, len(data.Tasks))

	var visit func(old string, parent *string)
	visit = func(old string, parent *string) {
		t, ok := data.Tasks[old]
		if !ok {
			die("child %s not in file", old)
		}

		content := t.Content
		content.ChildIDs = []string{} // the server rejects add with non-empty child_ids

		req := task.AddRequest{Content: content}
		if parent != nil {
			newParent := newID[*parent]
			req.ParentID = &newParent
		}
		// No Position: appending preserves the child_ids order from the legacy file.

		body, err := json.Marshal(req)
		if err != nil {
			die("marshal %s: %v", old, err)
		}

		httpReq, err := http.NewRequest(http.MethodPost, *url+"/api/tasks/add", bytes.NewReader(body))
		if err != nil {
			die("build request for %s: %v", old, err)
		}
		httpReq.Header.Set("Authorization", *token)
		httpReq.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(httpReq)
		if err != nil {
			die("add %s: %v", old, err)
		}
		respBody, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			die("add %s: %d %s", old, resp.StatusCode, string(respBody))
		}
		if readErr != nil {
			die("read response for %s: %v", old, readErr)
		}

		var decoded addResponse
		if err := json.Unmarshal(respBody, &decoded); err != nil {
			die("decode response for %s: %v", old, err)
		}
		newID[old] = decoded.Task.ID

		for _, c := range t.Content.ChildIDs {
			visit(c, &old)
		}
	}

	for _, r := range roots {
		visit(r, nil)
	}

	fmt.Fprintf(os.Stderr, "seeded %d tasks\n", len(newID))
}
