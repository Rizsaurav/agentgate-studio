'use client';
import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { modelLabel } from '@/lib/model-label';
import { INSTALL_STARTED, useModelPull } from './use-model-pull';

const STEPS = [
  { id: 'runtime', label: 'Ollama' },
  { id: 'download', label: 'Download' },
  { id: 'verify', label: 'Check it runs' },
  { id: 'ready', label: 'Ready in chat' },
] as const;
/** How long a finished install stays on the strip before it slides away. */
const DONE_VISIBLE_MS = 8000;

/** A slim live strip, on every page, showing which step of a local model install is running. */
export function InstallStrip() {
  const { pull, loaded, queued, percent } = useModelPull({ watch: true });
  const [visible, setVisible] = useState(false);
  const initial = useRef<string | null>(null);
  const active = pull?.status === 'downloading';
  const key = pull ? `${pull.model}:${pull.status}:${pull.message}` : '';

  useEffect(() => {
    const show = () => setVisible(true);
    window.addEventListener(INSTALL_STARTED, show);
    return () => window.removeEventListener(INSTALL_STARTED, show);
  }, []);

  useEffect(() => {
    if (!loaded) return;
    // The first check is the baseline: an old result is not news. Any change after it means an
    // install ran while this page was open, even one that finished between two checks.
    if (initial.current === null) {
      initial.current = key;
      if (!active) return;
    }
    if (key === initial.current && !active) return;
    setVisible(true);
    if (active || pull?.status !== 'done') return;
    const timer = setTimeout(() => setVisible(false), DONE_VISIBLE_MS);
    return () => clearTimeout(timer);
  }, [loaded, key, active, pull?.status]);

  // Only installs that ran while this page was open are shown, not an old result.
  if (!pull || !visible) return null;
  const current = STEPS.findIndex((step) => step.id === pull.step);
  const failed = pull.status === 'failed' || pull.status === 'cancelled';
  return (
    <aside
      className="install-strip"
      role="status"
      aria-live="polite"
      aria-label="Local model install"
    >
      {active && pull.step === 'download' && (
        <span className="install-strip-bar" style={{ width: `${percent}%` }} />
      )}
      <span
        className={`install-strip-live ${active ? '' : failed ? 'failed' : 'done'}`}
      >
        {active ? 'Installing' : failed ? 'Stopped' : 'Installed'}
      </span>
      <strong className="install-strip-model">{modelLabel(pull.model)}</strong>
      <ol className="install-strip-steps">
        {STEPS.map((step, index) => {
          const state =
            pull.status === 'done' || index < current
              ? 'done'
              : index === current
                ? failed
                  ? 'failed'
                  : 'active'
                : 'pending';
          return (
            <li key={step.id} className={state}>
              {step.label}
              {state === 'active' && step.id === 'download' && ` ${percent}%`}
            </li>
          );
        })}
      </ol>
      <span className="install-strip-detail">{pull.message}</span>
      {queued.length > 0 && (
        <span className="install-strip-queue">+{queued.length} queued</span>
      )}
      <Link href="/models" className="install-strip-link">
        Details
      </Link>
      {!active && (
        <button
          type="button"
          className="install-strip-close"
          aria-label="Hide install status"
          onClick={() => setVisible(false)}
        >
          ×
        </button>
      )}
    </aside>
  );
}
