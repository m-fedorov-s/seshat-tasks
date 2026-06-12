package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/santhosh-tekuri/jsonschema/v5"
)

const schemaDir = "../schema"

// fixtures that are valid against the JSON Schema (excludes unknown-enum, which
// intentionally violates the enum to exercise the client fallback).
var schemaValidFixtures = []string{
	"minimal.json", "full.json", "forest.json", "optional-absent.json", "unicode.json", "unknown-fields.json",
}

func TestFixturesValidateAgainstSchema(t *testing.T) {
	compiler := jsonschema.NewCompiler()
	sch, err := compiler.Compile(filepath.Join(schemaDir, "task.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range schemaValidFixtures {
		b, err := os.ReadFile(filepath.Join(schemaDir, "fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		var v any
		json.Unmarshal(b, &v)
		if err := sch.Validate(v); err != nil {
			t.Errorf("%s failed schema validation: %v", name, err)
		}
	}
}

func TestFixtureRoundTrip(t *testing.T) {
	names := append([]string{}, schemaValidFixtures...)
	for _, name := range names {
		b, err := os.ReadFile(filepath.Join(schemaDir, "fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		var first Task
		if err := json.Unmarshal(b, &first); err != nil {
			t.Fatalf("%s decode: %v", name, err)
		}
		reB, err := json.Marshal(first)
		if err != nil {
			t.Fatalf("%s encode: %v", name, err)
		}
		var second Task
		if err := json.Unmarshal(reB, &second); err != nil {
			t.Fatalf("%s re-decode: %v", name, err)
		}
		if !reflect.DeepEqual(first, second) {
			t.Errorf("%s not semantically stable across round trip", name)
		}
	}
}

func TestUnknownFieldsTolerated(t *testing.T) {
	b, _ := os.ReadFile(filepath.Join(schemaDir, "fixtures", "unknown-fields.json"))
	var task Task
	if err := json.Unmarshal(b, &task); err != nil {
		t.Fatalf("unknown fields must be tolerated, got %v", err)
	}
	if task.Content.Title != "future" {
		t.Fatal("known fields must still decode")
	}
}

// The server tolerates an unknown enum value at the PARSE layer (it decodes
// without error) and rejects it only on WRITE via validateContent. The Zig
// client maps unknowns to a fallback; this asserts the Go no-panic half of §8.3.
func TestUnknownEnumDecodesWithoutError(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(schemaDir, "fixtures", "unknown-enum.json"))
	if err != nil {
		t.Fatal(err)
	}
	var task Task
	if err := json.Unmarshal(b, &task); err != nil {
		t.Fatalf("unknown enum must decode without error, got %v", err)
	}
	if task.Content.Status.Valid() {
		t.Fatal("expected the unknown status to be reported invalid")
	}
}
