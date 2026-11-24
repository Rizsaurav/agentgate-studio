import type { SVGProps } from 'react';
const paths = {
  workspace: 'M3 10 12 3l9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1Z',
  shield: 'M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6Z M8 12l3 3 5-6',
  cube: 'm12 3 9 5v9l-9 5-9-5V8Z M3 8l9 5 9-5 M12 13v9 M7.5 5.5l9 5',
  search: 'M21 21l-5-5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  plus: 'M12 5v14 M5 12h14',
  arrow: 'M7 17 17 7 M6 7h11v11',
  close: 'm6 6 12 12 M6 18 18 6',
  settings: 'M4 7h16 M4 17h16 M8 4v6 M16 14v6',
  context: 'm3 7 9-4 9 4-9 4Z M3 12l9 4 9-4 M3 17l9 4 9-4',
  message: 'M4 4h16v12H9l-5 5Z',
  chevron: 'm9 5 7 7-7 7',
  send: 'm3 3 18 9-18 9 4-9Z M7 12h14',
  stop: 'M6 6h12v12H6Z',
  check: 'm5 12 4 4L19 6',
  activity: 'M2 12h5l3-8 4 16 3-8h5',
  warning: 'm12 3 10 18H2Z M12 9v5 M12 17v.5',
  document: 'M5 3h9l5 5v13H5Z M14 3v6h5 M8 13h8 M8 17h6',
  key: 'M14 14a6 6 0 1 0-4-4l-8 8v4h4v-3h3v-3Z',
  menu: 'M4 6h16 M4 12h16 M4 18h16',
  spark: 'm12 3 2.7 6.3L21 12l-6.3 2.7L12 21l-2.7-6.3L3 12l6.3-2.7Z',
} as const;
export type IconName = keyof typeof paths;
export function Icon({
  name,
  ...props
}: SVGProps<SVGSVGElement> & { name: IconName }) {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...props}
    >
      <path d={paths[name]} />
    </svg>
  );
}
