# Deploying the Hermes Proxy

The Hermes Pass proxy is a Cloudflare Worker located in `hermes/proxy/`.

## Deployed URL

After deployment, find the Worker in the Cloudflare dashboard under:

**Workers & Pages > hermes-proxy**

The public URL is shown there and follows the pattern:

```
https://hermes-proxy.<your-subdomain>.workers.dev
```

This URL must match the `worker_url` value configured in the Hermes macOS app (default is compiled into `internal/config/config.go`).

## How to deploy

Deployment is handled by GitHub Actions:

- `.github/workflows/deploy-proxy.yml` runs automatically when any file under `hermes/proxy/` changes on `main`.
- You can also trigger it manually from the **Actions** tab via `workflow_dispatch`.

The workflow expects these repository secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Set these in **Settings > Secrets and variables > Actions** for the repository.

## Required Worker secrets

Set the following secrets through the Cloudflare dashboard, not via local `wrangler`:

1. Go to **Workers & Pages > hermes-proxy > Settings > Variables and Secrets**.
2. Add each secret under the **Secrets** tab:
   - `ADMIN_SECRET` - Bearer token for `/admin/issue` and `/admin/revoke`.
   - `CEREBRAS_API_KEY` - Real Cerebras provider API key.
   - `GROQ_API_KEY` - Real Groq provider API key.
   - `TOKEN_SECRET` - HMAC secret used to sign short-lived Hermes tokens.

Do not commit any of these values to the repository.

## First deploy

1. Push the latest `hermes/proxy/` changes to `main` (or trigger the workflow manually).
2. Wait for the GitHub Actions run to complete.
3. Open the Cloudflare dashboard and confirm `hermes-proxy` is listed under Workers.
4. Set the four secrets above in the dashboard.
5. Copy the deployed Workers URL into the Hermes app config if it differs from the compiled-in default.
