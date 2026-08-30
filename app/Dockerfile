# One image, two binaries. The manifests choose which one a pod runs, so the
# api and the worker are provably the same build -- nothing changed between
# the broken configuration and the fixed one except the manifest.
FROM golang:1.25-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY internal ./internal
COPY cmd ./cmd

ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -o /out/api    ./cmd/api && \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -o /out/worker ./cmd/worker

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api    /api
COPY --from=build /out/worker /worker
EXPOSE 8080
ENTRYPOINT ["/api"]
