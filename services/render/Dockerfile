# go-fitz bundles MuPDF via cgo and links against glibc — Alpine (musl)
# crashes at runtime, so build *and* run on Debian.
FROM golang:1.25-bookworm AS builder

WORKDIR /src

ENV CGO_ENABLED=1 \
    GOFLAGS=-mod=mod

# Pre-fetch deps so the layer caches across source edits.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/render .

FROM gcr.io/distroless/base-debian12

COPY --from=builder /out/render /render

ENV RENDER_OUTPUT_DIR=/var/lib/fraktur/crops \
    CACHE_DIR=/var/lib/fraktur/render-cache

VOLUME ["/var/lib/fraktur/crops", "/var/lib/fraktur/render-cache"]

CMD ["/render"]
