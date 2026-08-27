import type { ButtonHTMLAttributes, ReactNode } from 'react';
import { cn } from '@/lib/utils';

export function Chip({ selected, className, children, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { selected?: boolean; children: ReactNode }) {
  return <button type="button" className={cn('chip', selected && 'chip--selected', className)} aria-pressed={selected} {...props}>{children}</button>;
}
