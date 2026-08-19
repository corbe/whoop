# wellness-engine build helpers (STAGE 19B)
VERSION ?= dev
COMMIT  ?= $(shell git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS = -s -w \
  -X github.com/noana-org/ritma-app/wellness-engine/internal/versioning.EngineVersion=$(VERSION) \
  -X github.com/noana-org/ritma-app/wellness-engine/internal/versioning.BuildCommit=$(COMMIT)

.PHONY: build test docker-build docker-smoke

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/wellness-api ./cmd/wellness-api
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/wellness-shadow ./cmd/wellness-shadow
	CGO_ENABLED=0 go build -trimpath -o bin/wellness-engine ./cmd/wellness-engine

test:
	go test ./...
	go vet ./...

docker-build:
	docker build --build-arg VERSION=$(VERSION) --build-arg COMMIT=$(COMMIT) -t wellness-engine:$(VERSION) .

docker-smoke: docker-build
	./scripts/container-smoke.sh
