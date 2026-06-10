import { Chat } from "@/components/Chat";
import { GraphView } from "@/components/GraphView";

export default function Home() {
  return (
    <main className="flex h-screen w-screen">
      <section className="w-full max-w-md border-r">
        <Chat />
      </section>
      <section className="relative flex-1 bg-muted/30">
        <GraphView />
      </section>
    </main>
  );
}
