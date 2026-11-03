import {
  Activity,
  ArrowUp,
  ArrowUpRight,
  Box,
  Check,
  ChevronRight,
  FileText,
  KeyRound,
  Layers,
  LayoutGrid,
  type LucideProps,
  Menu,
  MessageSquare,
  Plus,
  Search,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  Square,
  TriangleAlert,
  X,
} from 'lucide-react';

/** App icons come from Lucide, the open-source set shadcn/ui uses; names here describe their role. */
const icons = {
  workspace: LayoutGrid,
  shield: ShieldCheck,
  cube: Box,
  search: Search,
  plus: Plus,
  arrow: ArrowUpRight,
  close: X,
  settings: SlidersHorizontal,
  context: Layers,
  message: MessageSquare,
  chevron: ChevronRight,
  send: ArrowUp,
  stop: Square,
  check: Check,
  activity: Activity,
  warning: TriangleAlert,
  document: FileText,
  key: KeyRound,
  menu: Menu,
  spark: Sparkles,
} as const;
export type IconName = keyof typeof icons;
/** `width` sizes the icon square, as the previous hand-drawn icons did. */
export function Icon({
  name,
  width,
  ...props
}: LucideProps & { name: IconName }) {
  const Component = icons[name];
  return (
    <Component
      size={width ?? 18}
      strokeWidth={1.75}
      aria-hidden="true"
      {...props}
    />
  );
}
