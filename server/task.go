package main

import "seshat/internal/task"

// CurrentDataFormatVersion is the on-disk format generation this binary writes. It lives
// once per data file, in the bbolt `meta` bucket (see tenants.go), and versions the shape
// of every user's blob. Distinct from State.StateVersion, which is the per-user
// concurrency counter / ETag.
const CurrentDataFormatVersion = 1

// State is the whole server state and the on-disk JSON shape.
type State struct {
	DataFormatVersion uint64               `json:"data_format_version"`
	StateVersion      uint64               `json:"state_version"`
	Tasks             map[string]task.Task `json:"tasks"`
}
