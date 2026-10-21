# Build context is the repository root (see docker-compose.yml) so db/queries can be bundled.
FROM node:20-alpine AS build
WORKDIR /app
COPY api/package.json api/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY api/tsconfig.json ./
COPY api/src ./src
RUN npm run build && npm prune --omit=dev

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production QUERIES_DIR=/app/queries
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY api/package.json ./
COPY db/queries ./queries
USER node
EXPOSE 4000
CMD ["node", "dist/index.js"]
