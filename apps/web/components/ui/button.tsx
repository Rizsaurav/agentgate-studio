import * as React from 'react';
import { Slot } from '@radix-ui/react-slot';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '@/lib/utils';

// shadcn/ui composition pattern; adapted to the local workspace theme.
const buttonVariants = cva(
  'inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-violet-300 disabled:pointer-events-none disabled:opacity-50 h-10 px-4',
  {
    variants: {
      variant: {
        default: 'bg-[#9874d3] text-[#110b1b] hover:bg-[#b594ea]',
        outline:
          'border border-[#383340] bg-[#24212d] text-[#ddd3eb] hover:bg-[#302a3a]',
      },
    },
    defaultVariants: { variant: 'default' },
  },
);
export function Button({
  className,
  variant,
  asChild = false,
  ...props
}: React.ComponentProps<'button'> &
  VariantProps<typeof buttonVariants> & { asChild?: boolean }) {
  const Component = asChild ? Slot : 'button';
  return (
    <Component
      className={cn(buttonVariants({ variant, className }))}
      {...props}
    />
  );
}
