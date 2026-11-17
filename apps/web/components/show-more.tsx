'use client';
import { useState, type ReactNode } from 'react';
import { VISIBLE } from '@agentgate/controller/model-lists';

/**
 * The one "top four" control (#48): the first four items show, the rest stay in the page but
 * hidden until the button opens them. The button says how many are hidden and reports its state
 * to screen readers. Items keep their order; ordering them is the caller's job.
 *
 * Shown and hidden items each get their own container of the same kind, so list items stay
 * inside a list.
 */
export function ShowMore({
  items,
  more,
  id,
  as: Container = 'div',
  className,
  label,
}: {
  items: ReactNode[];
  /** What the hidden items are, e.g. "More providers". */
  more: string;
  /** Unique id for the hidden region. */
  id: string;
  as?: 'div' | 'ul';
  className?: string;
  /** Accessible name of the list. */
  label?: string;
}) {
  const [open, setOpen] = useState(false);
  const shown = items.slice(0, VISIBLE);
  const rest = items.slice(VISIBLE);
  return (
    <>
      <Container className={className} aria-label={label}>
        {shown}
      </Container>
      {rest.length > 0 && (
        <>
          <Container
            id={id}
            hidden={!open}
            className={
              className ? `${className} show-more-rest` : 'show-more-rest'
            }
            aria-label={label && `${label}, more`}
          >
            {rest}
          </Container>
          <button
            type="button"
            className="text-button"
            aria-expanded={open}
            aria-controls={id}
            onClick={() => setOpen((value) => !value)}
          >
            {open ? 'Show fewer' : `${more} (${rest.length})`}
          </button>
        </>
      )}
    </>
  );
}
