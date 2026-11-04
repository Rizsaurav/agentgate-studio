/** Shown at once while a page does server work, so no navigation waits on a blank screen. */
export default function Loading() {
  return (
    <p role="status" className="muted">
      Loading…
    </p>
  );
}
