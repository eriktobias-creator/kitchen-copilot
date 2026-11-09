FROM node:22-slim AS build
WORKDIR /app/server
COPY server/package*.json ./
RUN npm ci
COPY server/ ./
RUN npm run build && npm prune --omit=dev

FROM node:22-slim
WORKDIR /app
COPY --from=build /app/server/node_modules server/node_modules
COPY --from=build /app/server/dist server/dist
COPY server/package.json server/
COPY prompt/ prompt/
COPY store/ store/
ENV NODE_ENV=production PORT=8787
EXPOSE 8787
USER node
CMD ["node", "server/dist/index.js"]
