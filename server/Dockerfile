# Build stage
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/server ./cmd/server

# Runtime stage
FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
WORKDIR /app
COPY --from=build /out/server ./server
COPY schema.sql ./schema.sql
EXPOSE 8080
ENTRYPOINT ["./server"]
