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
  poweredByHeader: false,
};
export default config;
