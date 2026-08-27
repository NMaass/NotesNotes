import type { ButtonHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export function Button({ className, variant = 'solid', size = 'md', type = 'button', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'solid' | 'outline' | 'ghost' | 'danger'; size?: 'sm' | 'md' | 'lg' | 'icon' }) {
  return <button type={type} className={cn('button', `button--${variant}`, `button--${size}`, className)} {...props} />;
}
