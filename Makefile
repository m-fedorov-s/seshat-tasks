.PHONY: schema-test server-test dev-server dev-seed client-integration-test

server-test:
	cd server && go test ./...

# Local dev: run the server, and seed it with a realistic dataset (see dev/README.md).
dev-server:
	./dev/run-server.sh

dev-seed:
	./dev/seed.sh

# Runs the Go schema-consistency tests. The Zig half is added in the client plan.
schema-test:
	cd server && go test ./... -run 'TestFixtures|TestFixtureRoundTrip|TestUnknownFields'
	cd client/zig && zig test src/schema_test.zig

# End-to-end client tests that need a real server + real pipes.
client-integration-test:
	./test/broken-pipe.sh
