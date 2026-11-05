FROM node:22-alpine
WORKDIR /app
COPY server.js ./
COPY web ./web
# the list of players added in the app is kept here (mount a volume to keep it across rebuilds)
RUN mkdir -p /data && chown node:node /data
VOLUME /data
ENV PORT=8090 NODE_ENV=production DATA_DIR=/data
EXPOSE 8090
USER node
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8090/healthz || exit 1
CMD ["node", "server.js"]
