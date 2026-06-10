"use client";

import { useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAppStore } from "@/lib/store";
import { cn } from "@/lib/utils";

export function Chat() {
  const [draft, setDraft] = useState("");
  const messages = useAppStore((s) => s.messages);
  const isSending = useAppStore((s) => s.isSending);
  const error = useAppStore((s) => s.error);
  const sendMessage = useAppStore((s) => s.sendMessage);

  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, isSending]);

  const handleSend = async () => {
    const text = draft;
    setDraft("");
    await sendMessage(text);
  };

  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-sm font-semibold">Knowledge Graph Chat</h1>
        <p className="text-xs text-muted-foreground">
          Tell me facts; I will build your graph and answer with Graph RAG.
        </p>
      </header>

      <div className="flex-1 space-y-3 overflow-y-auto p-4">
        {messages.length === 0 && (
          <p className="text-sm text-muted-foreground">
            Try: &quot;Alice works at Acme and lives in Seoul.&quot;
          </p>
        )}
        {messages.map((m, i) => (
          <div
            key={i}
            className={cn(
              "flex",
              m.role === "user" ? "justify-end" : "justify-start"
            )}
          >
            <div
              className={cn(
                "max-w-[85%] whitespace-pre-wrap rounded-lg px-3 py-2 text-sm",
                m.role === "user"
                  ? "bg-primary text-primary-foreground"
                  : "bg-muted text-foreground"
              )}
            >
              {m.content}
            </div>
          </div>
        ))}
        {isSending && (
          <div className="flex justify-start">
            <div className="rounded-lg bg-muted px-3 py-2 text-sm text-muted-foreground">
              Thinking...
            </div>
          </div>
        )}
        {error && <p className="text-sm text-red-500">{error}</p>}
        <div ref={bottomRef} />
      </div>

      <div className="flex gap-2 border-t p-3">
        <Input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              void handleSend();
            }
          }}
          placeholder="Type a message..."
          disabled={isSending}
        />
        <Button onClick={() => void handleSend()} disabled={isSending}>
          Send
        </Button>
      </div>
    </div>
  );
}
