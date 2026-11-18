# syntax=docker/dockerfile:1

# muster-clankmail: the ClankMail plugin for muster, as a standalone image.
# The entrypoint is the plugin itself, so `docker run IMAGE` serves and
# `docker run IMAGE <subcommand>` runs an admin/setup subcommand.
#
# The build stage runs on the BUILD platform and cross-compiles for TARGETARCH,
# so `docker buildx build --platform linux/amd64,linux/arm64` emulates nothing.

FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -trimpath \
    -ldflags="-s -w" -o /muster-clankmail ./cmd/muster-clankmail

# distroless/static: CA certificates for the hub's HTTPS, no shell, non-root.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /muster-clankmail /muster-clankmail
# GET /health (LISTEN_ADDR's default).
EXPOSE 8080
# Exec form: the image has no shell. `show` exits 0 when the plugin's admin
# socket ($STATE_DIR/admin.sock) answers.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["/muster-clankmail", "show"]
ENTRYPOINT ["/muster-clankmail"]
