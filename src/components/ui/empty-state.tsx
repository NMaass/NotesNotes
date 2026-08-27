import type { ReactNode } from 'react';
export function EmptyState({ title, children, action }: { title: string; children: ReactNode; action?: ReactNode }) {
  return <div className="empty-state"><strong>{title}</strong><p>{children}</p>{action}</div>;
}
