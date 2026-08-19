# wellness-engine — production multi-stage build (STAGE 19B, PART D).
# pgx/v5 is pure Go (no CGO): static binary, distroless runtime, non-root.
# Secrets are NEVER baked; configuration is env-only.

# ---- Stage 1: build ----
FROM golang:1.25-alpine AS build
WORKDIR /src
RUN apk add --no-cache tzdata
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags "-s -w \
        -X github.com/noana-org/ritma-app/wellness-engine/internal/versioning.EngineVersion=${VERSION} \
        -X github.com/noana-org/ritma-app/wellness-engine/internal/versioning.BuildCommit=${COMMIT}" \
      -o /out/wellness-api ./cmd/wellness-api && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags "-s -w \
        -X github.com/noana-org/ritma-app/wellness-engine/internal/versioning.EngineVersion=${VERSION}" \
      -o /out/wellness-shadow ./cmd/wellness-shadow && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -o /out/wellness-engine ./cmd/wellness-engine

# ---- Stage 2: runtime ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/wellness-api /usr/local/bin/wellness-api
COPY --from=build /out/wellness-shadow /usr/local/bin/wellness-shadow
COPY --from=build /out/wellness-engine /usr/local/bin/wellness-engine
# tzdata: distroless has none; the engine's night windows use time.Local
# (TZ=America/Sao_Paulo — the HML device zone).
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
USER nonroot:nonroot
ENV TZ=America/Sao_Paulo
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/wellness-api"]
