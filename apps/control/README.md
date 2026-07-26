# Ungate dashboard control service

The control service serves the Svelte dashboard on `http://127.0.0.1:47820`,
proxies the dashboard's allowlisted API calls to `ungate-api` on port `47821`,
streams NSSM logs, and controls the `ungate-api` and `frpc` services.

Build the production bundle:

```powershell
pnpm --filter @ungate/control build:bundle
```

The command builds `apps/web`, bundles the Fastify server, and copies the web
assets to `apps/control/bundle/public`.

Create the Windows service through the NSSM Service Manager panel:

1. Open **Создать службу**.
2. Paste `deploy/nssm/ungate-dashboard.service.json` into **JSON импорт**.
3. Click **Заполнить поля** and verify the paths.
4. Click **Создать**.

The JSON import only fills the form. The final **Создать** action creates and
starts the service.

The service is loopback-only. It does not expose the model proxy routes on port
`47820`; `/v1/*` remains on `ungate-api:47821`.
