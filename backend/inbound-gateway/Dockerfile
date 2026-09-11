FROM golang:1.26.6-alpine3.23@sha256:e57c41c1d5864341031181b0db34b9a537bb5773eb6428e4e5bdaea0f9135406 AS build
WORKDIR /src
COPY go.mod main.go household_drive.go help_chat.go document_analysis.go document_analysis_jobs.go conversation_interpreter.go conversation_api.go telegram_api.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/inbound-gateway .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chown=65532:65532 /out/inbound-gateway /inbound-gateway
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/inbound-gateway"]
