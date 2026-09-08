# syntax=docker/dockerfile:1.7

FROM golang:1.25.13-alpine3.23@sha256:42fc3368d1c50170a452f2bf4a1dfd292a065870c3f258d799aad4316671cb69 AS build

RUN apk add --no-cache ca-certificates git tzdata

WORKDIR /src
COPY . .
RUN go get \
      github.com/go-chi/chi/v5@v5.3.0 \
      golang.org/x/crypto@v0.53.0 \
      golang.org/x/mod@v0.40.0 \
      golang.org/x/net@v0.56.0 && \
    go mod tidy && \
    go mod download && \
    go mod verify

RUN CGO_ENABLED=0 GOOS=linux go build \
      -buildvcs=false \
      -trimpath \
      -ldflags="-s -w -X github.com/supabase/auth/internal/utilities.Version=v2.195.0-kia.3" \
      -o /out/auth .

RUN <<'EOF'
cat >/tmp/healthcheck.go <<'GO'
package main

import (
	"net/http"
	"os"
	"time"
)

func main() {
	client := http.Client{Timeout: 3 * time.Second}
	response, err := client.Get("http://127.0.0.1:9999/health")
	if err != nil || response.StatusCode != http.StatusOK {
		os.Exit(1)
	}
	response.Body.Close()
}
GO
CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/healthcheck /tmp/healthcheck.go
EOF

FROM scratch

LABEL org.opencontainers.image.title="Family Documents hardened Supabase Auth" \
      org.opencontainers.image.description="Supabase Auth v2.195.0 rebuilt with patched Go runtime and modules" \
      org.opencontainers.image.source="https://github.com/supabase/auth" \
      org.opencontainers.image.revision="0522e7bcf7135a476d258b1603134b97846179fc" \
      org.opencontainers.image.version="v2.195.0-kia.3" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /out/auth /usr/local/bin/auth
COPY --from=build /out/healthcheck /usr/local/bin/healthcheck
COPY --from=build /src/migrations /usr/local/etc/auth/migrations

ENV GOTRUE_DB_MIGRATIONS_PATH=/usr/local/etc/auth/migrations
USER 65532:65532
EXPOSE 9999
ENTRYPOINT ["/usr/local/bin/auth"]
