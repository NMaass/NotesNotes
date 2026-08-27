'use client';
import * as DialogPrimitive from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import type { ReactNode } from 'react';
import { Button } from '@/components/ui/button';

export const Dialog = DialogPrimitive.Root;
export const DialogTrigger = DialogPrimitive.Trigger;
export const DialogClose = DialogPrimitive.Close;

export function DialogContent({ title, description, children, className = '' }: { title: string; description?: string; children: ReactNode; className?: string }) {
  return (
    <DialogPrimitive.Portal>
      <DialogPrimitive.Overlay className="dialog-overlay" />
      <DialogPrimitive.Content className={`dialog-content ${className}`}>
        <div className="dialog-heading">
          <div>
            <DialogPrimitive.Title className="dialog-title">{title}</DialogPrimitive.Title>
            {description ? <DialogPrimitive.Description className="dialog-description">{description}</DialogPrimitive.Description> : null}
          </div>
          <DialogPrimitive.Close asChild><Button variant="ghost" size="icon" aria-label="Close"><X size={20} /></Button></DialogPrimitive.Close>
        </div>
        {children}
      </DialogPrimitive.Content>
    </DialogPrimitive.Portal>
  );
}
