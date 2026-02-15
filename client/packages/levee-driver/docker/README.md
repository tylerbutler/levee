# Levee Server Docker Setup

Docker configuration for running the Levee server locally for integration testing.

## Quick Start (Published Image)

The simplest way to run the Levee server is using the published Docker image:

```bash
# From the levee-driver package directory
cd client/packages/levee-driver

# Start the Levee server (pulls from ghcr.io/tylerbutler/levee:latest)
pnpm test:integration:up

# Run integration tests
pnpm test:integration

# View server logs
pnpm test:integration:logs

# Stop the server
pnpm test:integration:down
```

## Building from Local Source

To test against a local development version of the Levee server:

```bash
cd client/packages/levee-driver

# Start the server (builds from server/ directory)
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --wait --build

# Run tests
vitest run test/integration

# Stop
docker compose down -v
```

The `docker-compose.local.yml` file uses a relative path to `../../../server` (the `server/` directory at the repo root) as the Docker build context.

## Server Endpoints

The server will be available at:
- HTTP: http://localhost:4000
- WebSocket: ws://localhost:4000/socket

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LEVEE_HTTP_URL` | `http://localhost:4000` | HTTP API endpoint |
| `LEVEE_SOCKET_URL` | `ws://localhost:4000/socket` | WebSocket endpoint |
| `LEVEE_TENANT_KEY` | `dev-tenant-secret-key` | Tenant secret for token generation |

## Troubleshooting

### Server won't start

Check the logs:
```bash
docker compose logs levee
```

Common issues:
- Port 4000 already in use: Stop other services or change the port in `docker-compose.yml`
- Image not found: Run `docker compose pull` to fetch the latest image

### Local build fails

- Ensure you're running from the correct directory (`client/packages/levee-driver`)
- Ensure the `server/` directory contains a valid Elixir project with `Dockerfile`

### Tests fail to connect

Ensure the server is healthy:
```bash
docker compose ps
curl http://localhost:4000/health
```

### Force pull latest image

```bash
docker compose pull
docker compose up -d
```

### Rebuild local image from scratch

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml build --no-cache
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
```
