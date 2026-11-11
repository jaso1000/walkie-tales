FROM node:22-alpine
# Published as ghcr.io/jaso1000/walkie-tales-remote by .github/workflows/docker-publish.yml
LABEL org.opencontainers.image.title="WalkieTales remote" \
      org.opencontainers.image.description="Web remote for WalkieTales kids' music players: several players, uploads, voice messages, settings" \
      org.opencontainers.image.source="https://github.com/jaso1000/walkie-tales"
WORKDIR /app
COPY server.js ./
COPY web ./web
# the list of players added in the app is kept here (mount a volume to keep it across rebuilds)
# ffmpeg turns Ogg audio (which iPhones can't play) into MP3 for iPhone players
# openssl makes the home-made certificate for the https address (needed for the microphone, for voice messages)
RUN apk add --no-cache ffmpeg openssl && mkdir -p /data && chown node:node /data
VOLUME /data
ENV PORT=8480 HTTPS_PORT=8490 NODE_ENV=production DATA_DIR=/data
EXPOSE 8480 8490
USER node
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8480/healthz || exit 1
CMD ["node", "server.js"]
