import type { Metadata } from 'next';
import { Suspense } from 'react';
import { projects } from '@/lib/controller';
import { AppShell } from '@/components/app-shell';
import { ProvidersPanel } from '@/components/providers-panel';
import './globals.css';
export const metadata: Metadata = {
  title: 'AGENTGATE Studio',
  description:
    'A local workspace for agents, shared context, and security verification.',
};
export const dynamic = 'force-dynamic';
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <a href="#main-content" className="skip-link">
          Skip to workspace
        </a>
        <AppShell
          projects={projects().list()}
          models={
            <Suspense fallback={<p role="status">Checking providers…</p>}>
              <ProvidersPanel />
            </Suspense>
          }
        >
          {children}
        </AppShell>
      </body>
    </html>
  );
}
