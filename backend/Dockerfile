FROM golang:1.22-bookworm AS build

WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/planner-sync ./cmd/planner-sync
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/import-bmstu-schedule ./cmd/import-bmstu-schedule

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/planner-sync /app/planner-sync
COPY --from=build /out/import-bmstu-schedule /app/import-bmstu-schedule
RUN mkdir -p /data /certs && useradd --system --uid 10001 planner && chown -R planner:planner /data /app
USER planner

EXPOSE 443
ENTRYPOINT ["/app/planner-sync"]
