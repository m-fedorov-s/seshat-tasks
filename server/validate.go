package main

// InvariantError reports a structural-integrity violation (HTTP 422).
type InvariantError struct {
	Invariant string
	IDs       []string
}

func (e *InvariantError) Error() string { return "invariant violation: " + e.Invariant }

// validateState checks the forest invariants over the whole state (§4.4):
//  1. each task appears in at most one child_ids list (global occurrence <= 1)
//  2. every child id references an existing task
//  3. no list has intra-list duplicates
//  4. the containment graph is a forest (no cycles; self-reference is a cycle)
func validateState(s State) error {
	seen := map[string]struct{}{}
	for _, t := range s.Tasks {
		intra := map[string]struct{}{}
		for _, c := range t.Content.ChildIDs {
			if _, dup := intra[c]; dup {
				return &InvariantError{"duplicate_in_list", []string{t.ID, c}}
			}
			intra[c] = struct{}{}
			if _, ok := s.Tasks[c]; !ok {
				return &InvariantError{"dangling_child", []string{t.ID, c}}
			}
			if _, twice := seen[c]; twice {
				return &InvariantError{"single_container", []string{c}}
			}
			seen[c] = struct{}{}
		}
	}
	// Cycle detection via DFS coloring. 0=unvisited, 1=in-stack, 2=done.
	color := map[string]int{}
	var visit func(id string) error
	visit = func(id string) error {
		color[id] = 1
		for _, c := range s.Tasks[id].Content.ChildIDs {
			switch color[c] {
			case 1:
				return &InvariantError{"cycle", []string{id, c}}
			case 0:
				if err := visit(c); err != nil {
					return err
				}
			}
		}
		color[id] = 2
		return nil
	}
	for id := range s.Tasks {
		if color[id] == 0 {
			if err := visit(id); err != nil {
				return err
			}
		}
	}
	return nil
}
