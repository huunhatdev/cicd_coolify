# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY . .

ARG ENV_FILE_HASH
RUN echo "ENV file hash: ${ENV_FILE_HASH}"

RUN --mount=type=secret,id=app_env,target=/app/.env \
    npm run build

FROM node:20-alpine AS production-dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000

RUN addgroup -S nodejs && adduser -S nestjs -G nodejs

COPY --from=production-dependencies --chown=nestjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nestjs:nodejs /app/dist ./dist
COPY --chown=nestjs:nodejs package.json ./

USER nestjs
EXPOSE 3000
CMD ["node", "dist/main.js"]
