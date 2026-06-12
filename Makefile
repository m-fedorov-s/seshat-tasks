.PHONY: schema-test server-test

server-test:
	cd server && go test ./...

# Runs the Go schema-consistency tests. The Zig half is added in the client plan.
schema-test:
	cd server && go test ./... -run 'TestFixtures|TestFixtureRoundTrip|TestUnknownFields'
