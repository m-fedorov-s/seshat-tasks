package main

import "seshat/internal/task"

// CurrentDataFormatVersion is the on-disk format generation this binary writes.
// It versions the CONTENTS of a data file, and is independent of the file LAYOUT
// (Stage 2's one-file-per-user change is detected from config + filesystem, not
// from this field). Distinct from State.StateVersion, which is the concurrency
// counter / ETag.
const CurrentDataFormatVersion = 1

// State is the whole server state and the on-disk JSON shape.
type State struct {
	DataFormatVersion uint64               `json:"data_format_version"`
	StateVersion      uint64               `json:"state_version"`
	Tasks             map[string]task.Task `json:"tasks"`
}
