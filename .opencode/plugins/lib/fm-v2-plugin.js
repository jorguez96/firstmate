// Adapts a V1 OpenCode plugin function to the V2 default-export shape.
// V2 rejects a module that does not default-export { id, setup }.

function commandFromToolEvent(event) {
  const input = event?.input;
  if (typeof input === "string") return input;
  if (!input || typeof input !== "object") return undefined;
  if (typeof input.command === "string") return input.command;
  if (typeof input.cmd === "string") return input.cmd;
  return undefined;
}

function normalizeEvent(event) {
  if (!event || typeof event !== "object") return event;
  const properties = { ...(event.properties ?? {}) };
  const info = properties.info ?? event.info;
  const sessionID = properties.sessionID ?? event.sessionID ?? info?.id;
  if (sessionID && !properties.sessionID) properties.sessionID = sessionID;
  if (info && !properties.info) properties.info = info;
  else if (sessionID && !properties.info) properties.info = { id: sessionID };
  return { ...event, properties };
}

function v1Client(ctx) {
  return {
    session: {
      promptAsync({ path, body }) {
        const text = (body?.parts ?? [])
          .map((part) => (typeof part?.text === "string" ? part.text : ""))
          .join("");
        return ctx.session.prompt({ sessionID: path.id, text });
      },
    },
  };
}

export async function bindV1Plugin(ctx, loadHooks) {
  const hooks = await loadHooks({
    directory: ctx.location?.directory ?? "",
    worktree: ctx.location?.worktree,
    client: v1Client(ctx),
  });

  const before = hooks?.["tool.execute.before"];
  if (typeof before === "function") {
    await ctx.tool.hook("execute.before", async (event) => {
      const tool = event.tool === "shell" ? "bash" : event.tool;
      await before({ tool }, { args: { command: commandFromToolEvent(event) } });
    });
    if (typeof ctx.shell?.hook === "function") {
      await ctx.shell.hook("create.before", async (event) => {
        await before({ tool: "bash" }, { args: { command: event.command } });
      });
    }
  }

  const transform = hooks?.["experimental.chat.system.transform"];
  if (typeof transform === "function") {
    await ctx.session.hook("context", async (event) => {
      const output = { system: [] };
      await transform({ sessionID: event.sessionID }, output);
      for (const item of output.system) {
        if (typeof item === "string") event.system.push({ type: "text", text: item });
        else if (item) event.system.push(item);
      }
    });
  }

  if (typeof hooks?.event !== "function") return undefined;
  const controller = new AbortController();
  const handler = hooks.event;
  void (async () => {
    try {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        await handler({ event: normalizeEvent(event) });
      }
    } catch {
      // Subscription ends when the plugin unloads.
    }
  })();
  return () => controller.abort();
}
