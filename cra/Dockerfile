# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

ARG ENV_FILE_HASH
RUN echo "ENV file hash: ${ENV_FILE_HASH}"

RUN --mount=type=secret,id=app_env,target=/app/.env \
    npm run build

FROM nginx:1.27-alpine AS runner
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/build /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
