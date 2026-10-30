# Multi-stage production-ready Dockerfile for AWS Fargate
FROM node:20-alpine AS builder

WORKDIR /usr/src/app

# Install dependencies (only production deps needed)
COPY package*.json ./
RUN npm ci --only=production

# Production Image
FROM node:20-alpine

# Set NODE_ENV to production
ENV NODE_ENV=production
ENV PORT=3000

WORKDIR /usr/src/app

# Install curl for HEALTHCHECK (curl is lightweight and reliable on Alpine)
RUN apk --no-cache add curl

# Create a non-root group and user named 'nodejs'
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 -G nodejs

# Copy dependencies and application source
COPY --chown=nodejs:nodejs --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=nodejs:nodejs package*.json ./
COPY --chown=nodejs:nodejs app.js ./

# Switch to non-root user
USER nodejs

# Expose container port
EXPOSE 3000

# Docker HEALTHCHECK instruction
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

# Start application
CMD ["node", "app.js"]
