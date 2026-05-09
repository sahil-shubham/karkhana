// Shadcn-style ContextMenu, built on Radix UI primitives but
// styled with our existing CSS variables (no Tailwind needed).
//
// API mirrors shadcn's:
//   <ContextMenu>
//     <ContextMenuTrigger>...</ContextMenuTrigger>
//     <ContextMenuContent>
//       <ContextMenuItem onSelect={...}>Edit</ContextMenuItem>
//       <ContextMenuSeparator />
//       <ContextMenuItem variant="danger" onSelect={...}>Delete</ContextMenuItem>
//     </ContextMenuContent>
//   </ContextMenu>

import * as RCM from "@radix-ui/react-context-menu";
import type { ComponentPropsWithoutRef, ReactNode } from "react";
import "./context-menu.css";

export const ContextMenu = RCM.Root;
export const ContextMenuTrigger = RCM.Trigger;
export const ContextMenuPortal = RCM.Portal;
export const ContextMenuSub = RCM.Sub;
export const ContextMenuSubTrigger = RCM.SubTrigger;
export const ContextMenuSubContent = RCM.SubContent;
export const ContextMenuGroup = RCM.Group;
export const ContextMenuLabel = RCM.Label;

interface ContentProps extends ComponentPropsWithoutRef<typeof RCM.Content> {
  children: ReactNode;
}

export function ContextMenuContent({ children, ...rest }: ContentProps) {
  return (
    <RCM.Portal>
      <RCM.Content
        className="kk-cm-content"
        collisionPadding={8}
        {...rest}
      >
        {children}
      </RCM.Content>
    </RCM.Portal>
  );
}

interface ItemProps extends ComponentPropsWithoutRef<typeof RCM.Item> {
  variant?: "default" | "danger";
  shortcut?: string;
}

export function ContextMenuItem({
  variant = "default",
  shortcut,
  children,
  ...rest
}: ItemProps) {
  return (
    <RCM.Item
      className={`kk-cm-item ${variant === "danger" ? "kk-cm-item-danger" : ""}`}
      {...rest}
    >
      <span style={{ flex: 1 }}>{children}</span>
      {shortcut && <span className="kk-cm-shortcut">{shortcut}</span>}
    </RCM.Item>
  );
}

export function ContextMenuSeparator() {
  return <RCM.Separator className="kk-cm-separator" />;
}
