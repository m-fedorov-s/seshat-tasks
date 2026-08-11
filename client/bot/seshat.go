package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"seshat/internal/task"
)

// APIError is a non-2xx response from seshat, carrying the status so callers can
// branch (409 retry policy, 404 "gone", 403 config problem) and the server's own
// message so it can be surfaced verbatim — the project rule is that clients show
// the server's error text.
type APIError struct {
	Status int
	Msg    string
}

func (e *APIError) Error() string { return fmt.Sprintf("seshat %d: %s", e.Status, e.Msg) }

type Client struct {
	base string
	hc   *http.Client
}

func NewClient(baseURL string) *Client {
	return &Client{
		base: baseURL,
		// An explicit timeout: without one a hung server holds a goroutine and the
		// user sees nothing at all.
		hc: &http.Client{Timeout: 15 * time.Second},
	}
}

// maxErrBody caps how much of an error body we read before giving up on it.
const maxErrBody = 8 << 10

// classify turns a non-2xx response into an *APIError. It must tolerate a body
// that is empty, truncated, not JSON, or JSON without an "error" key — a 409
// from this server carries {"conflicts":[...]} and nothing else.
func classify(resp *http.Response) error {
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrBody))
	var body struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(raw, &body)
	msg := body.Error
	if msg == "" {
		switch resp.StatusCode {
		case http.StatusConflict:
			msg = "version conflict"
		default:
			msg = "server error"
		}
	}
	return &APIError{Status: resp.StatusCode, Msg: msg}
}

// do issues one request with the bare Authorization header and decodes a 2xx body
// into out (which may be nil).
func (c *Client) do(ctx context.Context, path, token string, in, out any) error {
	var body io.Reader
	method := http.MethodGet
	if in != nil {
		enc, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(enc)
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, body)
	if err != nil {
		return err
	}
	// No "Bearer " prefix: seshat's contract is a bare shared secret.
	req.Header.Set("Authorization", token)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return classify(resp)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) Get(ctx context.Context, token string) ([]task.Task, error) {
	var out struct {
		StateVersion uint64      `json:"state_version"`
		Tasks        []task.Task `json:"tasks"`
	}
	if err := c.do(ctx, "/api/tasks/get", token, nil, &out); err != nil {
		return nil, err
	}
	return out.Tasks, nil
}

func (c *Client) Add(ctx context.Context, token string, req task.AddRequest) (task.Task, error) {
	var out struct {
		StateVersion uint64    `json:"state_version"`
		Task         task.Task `json:"task"`
	}
	if err := c.do(ctx, "/api/tasks/add", token, req, &out); err != nil {
		return task.Task{}, err
	}
	return out.Task, nil
}

func (c *Client) Update(ctx context.Context, token string, ops []task.UpdateOp) ([]task.Task, error) {
	in := struct {
		Updates []task.UpdateOp `json:"updates"`
	}{Updates: ops}
	var out struct {
		StateVersion uint64      `json:"state_version"`
		Tasks        []task.Task `json:"tasks"`
	}
	if err := c.do(ctx, "/api/tasks/update", token, in, &out); err != nil {
		return nil, err
	}
	return out.Tasks, nil
}

func (c *Client) Delete(ctx context.Context, token, id string) error {
	in := struct {
		ID string `json:"id"`
	}{ID: id}
	return c.do(ctx, "/api/tasks/delete", token, in, nil)
}
