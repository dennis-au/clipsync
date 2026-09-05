# Deployment

This repository publishes source and portable examples. It deliberately does not
contain a live hostname, Cloudflare tunnel token, password, backup location, or
operator-specific `compose.yaml`.

## Run a local Docker stack

1. Build the image and create a private environment file:

   ```sh
   docker build -t clipsync:local .
   cp .env.example .env
   ```

2. Edit `.env`, replacing `CLIPSYNC_PASSWORD` with a long, unique password. Keep
   the file private. The example binds only to `127.0.0.1:8787`.

3. Start and verify the stack:

   ```sh
   docker compose -f compose.example.yaml up -d
   curl -fsS http://127.0.0.1:8787/healthz
   docker compose -f compose.example.yaml ps
   ```

To keep an operator-managed Compose file outside version control, copy the example
first:

```sh
cp compose.example.yaml compose.yaml
docker compose up -d
```

## Run a published image

After a release is published to GitHub Container Registry, set `CLIPSYNC_IMAGE` in
your private `.env` to the published tag, for example:

```dotenv
CLIPSYNC_IMAGE=ghcr.io/OWNER/clipsync:v0.1.0
```

Then pull and start it with the same Compose example:

```sh
docker compose -f compose.example.yaml pull
docker compose -f compose.example.yaml up -d
```

Use a version tag for routine deployments. `latest` is convenient for testing but
does not provide a reproducible rollback target.

## Cloudflare Tunnel

The optional Cloudflare overlay keeps the origin private and permits
`CF-Connecting-IP` only from the named connector container.

1. In your own Cloudflare Zero Trust account, create a remotely managed tunnel and
   add a public hostname whose service is `http://clipboard:8787`.
2. Put the connector token in the private `.env` file:

   ```dotenv
   CLOUDFLARE_TUNNEL_TOKEN=replace-with-your-token
   ```

3. Start the base stack with the overlay:

   ```sh
   docker compose -f compose.example.yaml -f compose.cloudflare-tunnel.example.yaml --profile tunnel up -d
   ```

The overlay uses the private Docker range `172.28.0.0/29`; change it if it overlaps
with a network already used by the host. Do not broaden
`CLIPSYNC_TRUSTED_PROXY_CIDRS`, and do not set it at all unless the listed proxy is
under your control. The application password is still required. Protect any public
hostname with Cloudflare Access or an equivalent identity-aware control before
sharing it beyond a small trusted group.

## Upgrades and operations

For source builds, rebuild then recreate the service:

```sh
docker build -t clipsync:local .
docker compose -f compose.example.yaml up -d
```

Useful checks:

```sh
docker compose -f compose.example.yaml logs -f clipboard
docker compose -f compose.example.yaml ps
curl -fsS http://127.0.0.1:8787/healthz
```

The named `clipboard-data` volume contains all room metadata and blobs. Back it up
before changing storage or restoring a prior state. The included backup scripts
expect an operator-owned `compose.yaml`; after copying the example, install `age`,
store the private identity outside this repository, and follow the backup section in
the README.

## Security notes

- Keep `.env`, `compose.yaml`, tunnel tokens, and backup archives out of Git.
- Leave the example loopback binding in place. A tunnel or reverse proxy should be
  the only public entry point.
- Use a unique shared password and high-entropy room codes. Room codes are not an
  access-control boundary by themselves.
- Arbitrary file attachments are downloadable content. Image signatures are checked,
  but uploads are not malware-scanned.
- Size and history limits should be adjusted to the available disk capacity and the
  maximum request size of any proxy in front of the service.
