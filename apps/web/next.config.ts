import type { NextConfig } from 'next';
const config: NextConfig = {
  ...(process.env.AGENTGATE_DESKTOP_BUILD === '1'
    ? { output: 'standalone' as const }
    : {}),
  transpilePackages: ['@agentgate/controller'],
  serverExternalPackages: [
    'better-sqlite3',
    '@napi-rs/keyring',
    '@earendil-works/pi-ai',
    '@earendil-works/pi-agent-core',
  ],
  // A project import can include fifty documents of up to 200 KB each.
  experimental: { serverActions: { bodySizeLimit: '12mb' } },
  poweredByHeader: false,
};
export default config;
