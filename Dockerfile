FROM golang:1.25-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY main.go web.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/clipsync .

FROM alpine:3.22

RUN addgroup -S -g 10001 clipsync \
    && adduser -S -D -H -u 10001 -G clipsync clipsync \
    && install -d -o clipsync -g clipsync -m 0700 /var/lib/clipsync
COPY --from=build --chown=clipsync:clipsync /out/clipsync /usr/local/bin/clipsync

USER clipsync
ENV CLIPSYNC_ADDR=:8787
ENV CLIPSYNC_STATE=/var/lib/clipsync
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/clipsync"]
