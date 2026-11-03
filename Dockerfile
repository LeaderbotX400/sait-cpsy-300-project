# Stage 1: install dependencies and build the standalone Next.js server.
FROM node:24-alpine AS builder
WORKDIR /app
RUN npm install -g pnpm@11.27.0
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm build

# Stage 2: only the standalone output, static assets and the data set.
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY --from=builder /app/data ./data
USER node
EXPOSE 3000
CMD ["node", "server.js"]
