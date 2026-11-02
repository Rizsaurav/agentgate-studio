'use client';
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon, type IconName } from './icon';
export function Panel({
  title,
  trigger,
  icon,
  children,
}: {
  title: string;
  trigger?: string;
  icon: IconName;
  children: ReactNode;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (open) dialog.current?.showModal();
  }, [open]);
  return (
    <>
      <button
        type="button"
        className="subtle-button"
        aria-label={title}
        onClick={() => setOpen(true)}
      >
        <Icon name={icon} />
        {trigger ?? title}
      </button>
      <dialog
        ref={dialog}
        className="sheet"
        aria-label={title}
        onClose={() => setOpen(false)}
        onClick={(event) => {
          if (event.target === event.currentTarget) dialog.current?.close();
        }}
      >
        <div className="sheet-inner">
          <header className="sheet-header">
            <div>
              <span className="eyebrow">Workspace controls</span>
              <h2>{title}</h2>
            </div>
            <button
              type="button"
              className="icon-button"
              aria-label={`Close ${title}`}
              onClick={() => dialog.current?.close()}
            >
              <Icon name="close" />
            </button>
          </header>
          <div className="sheet-content">{open && children}</div>
        </div>
      </dialog>
    </>
  );
}
