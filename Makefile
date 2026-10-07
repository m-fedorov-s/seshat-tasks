.PHONY: schema-test server-test dev-server dev-seed client-integration-test bot-test shell-test install docker-build docker-smoke

server-test:
	go test -race ./server/... ./internal/...

# Local dev: run the server, and seed it with a realistic dataset (see dev/README.md).
dev-server:
	./dev/run-server.sh

dev-seed:
	./dev/seed.sh

# Runs the Go schema-consistency tests. The Zig half is added in the client plan.
schema-test:
	go test ./internal/task/ -run 'TestFixtures|TestFixtureRoundTrip|TestUnknownFields'
	cd client/zig && zig test src/schema_test.zig

bot-test:
	go test ./client/bot/...

# End-to-end client tests that need a real server + real pipes.
client-integration-test:
	./test/broken-pipe.sh

# Shell integration files under fish/bash/zsh, no server. Local pre-commit target only; CI does
# not run it.
shell-test:
	./test/shell/run.sh

# The client only, built from this checkout. SESHAT_INSTALL_DIR must be an absolute path: Zig
# puts a relative one under client/zig/zig-out/.
SESHAT_INSTALL_DIR ?= $(HOME)/.local/bin
install:
	cd client/zig && zig build -Doptimize=ReleaseSafe --prefix-exe-dir "$(SESHAT_INSTALL_DIR)"

# Docker images (docker/README.md): pre-release, run by hand before tagging. Not among the six
# pre-commit targets, not run by CI. Both need a Docker daemon with buildx
# (`docker buildx version`); docker-smoke also needs the compose plugin.
docker-build:
	docker build -f docker/Dockerfile.server -t seshat:dev .
	docker build -f docker/Dockerfile.bot -t seshat-bot:dev .

docker-smoke:
	./docker/smoke.sh
