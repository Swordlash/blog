// The writing assistant's side of the application's JavaScript, declared in
// Wiki.App.Assistant (WP4.19 of docs/PLAN.md). It drives a chat with a
// provider for the editor's assistant panel (Wiki.App.View.Assistant):
//
// - a chat is opened with its provider, model, key and request (the
//   request without its conversation, as Wiki.Core.Assistant.Prompt
//   assembles it) and one Haskell callback, and is known by a number;
// - each message sent runs one turn of the model's, whose events go to the
//   callback as JSON, in order: {type: "text", text}, as the answer
//   streams; {type: "tool", call, name, input}, a tool call, which the
//   turn waits on until the application answers it (wiki_assistant_answer);
//   and at the end {type: "done"}, {type: "stopped"} or {type: "error",
//   kind, status, message};
// - a stop aborts the turn (the SDK's request with it) and answers any call
//   still waiting, so that nothing hangs.
//
// The providers are the island's (web/src/assistant.js, islands/assistant.js
// in the page, loaded the first time through wikiIslands.assistant()), but
// for the scripted one, which is here: a page whose tests installed a
// script as globalThis.wikiAssistantScript before the program started
// (wiki-app's browser tests, and the demo's smoke test) may choose it; no
// page served to anyone has one. Its script is {turns: [[step, ...], ...]},
// a list of steps for each message in turn: {text} streams text, {tool,
// input} calls a tool and waits for its answer, {error: {kind, status,
// message}} ends the turn with that error, {hold: true} waits until the
// turn is stopped, and {wait} (milliseconds, after any step) paces it. It
// keeps what it was sent in script.requests and its tools' answers in
// script.answers, for the tests to read.
//
// The key is handed to the island, which hands it to the SDK; nothing here
// logs it or keeps it beyond the chat.

const wikiAssistantChats = new Map();
let wikiAssistantNextChat = 0;

// Text streams in many small pieces: they are handed on together, a few
// times a second, rather than one event each.
const wikiAssistantFlushAfter = 40;

function wikiAssistantFlush(chat) {
  if (chat.timer !== null) {
    clearTimeout(chat.timer);
    chat.timer = null;
  }
  if (chat.buffer !== "") {
    const text = chat.buffer;
    chat.buffer = "";
    if (wikiAssistantChats.get(chat.id) === chat) chat.callback(JSON.stringify({ type: "text", text }));
  }
}

function wikiAssistantEmit(chat, event) {
  wikiAssistantFlush(chat);
  if (wikiAssistantChats.get(chat.id) === chat) chat.callback(JSON.stringify(event));
}

function wikiAssistantText(chat, text) {
  chat.buffer += String(text);
  if (chat.timer === null) chat.timer = setTimeout(() => wikiAssistantFlush(chat), wikiAssistantFlushAfter);
}

// A tool call, handed to the application, whose answer the turn waits for.
function wikiAssistantAsk(chat, name, input) {
  return new Promise((resolve) => {
    const call = ++chat.nextCall;
    chat.calls.set(call, resolve);
    wikiAssistantEmit(chat, { type: "tool", call, name: String(name), input: input ?? null });
  });
}

function wikiAssistantAnswerWaiting(chat, text) {
  for (const resolve of chat.calls.values()) resolve({ text, ok: false });
  chat.calls.clear();
}

// The scripted provider, for the tests (see above).
function wikiAssistantScripted(config) {
  const script = globalThis.wikiAssistantScript;
  return {
    async send(user, handlers, signal) {
      if (!Array.isArray(script.requests)) script.requests = [];
      script.requests.push({ provider: config.provider, model: config.model, request: config.request, user });
      const steps = script.turns?.shift() ?? [{ text: "The script has nothing more to say." }];
      for (const step of steps) {
        if (signal.aborted) return;
        if (step.text !== undefined) handlers.text(step.text);
        else if (step.tool !== undefined) {
          const answer = await handlers.tool(step.tool, step.input);
          if (!Array.isArray(script.answers)) script.answers = [];
          script.answers.push({ tool: step.tool, input: step.input, text: answer.text, ok: answer.ok });
        } else if (step.error !== undefined) {
          throw Object.assign(new Error(String(step.error.message ?? "")), {
            wikiKind: String(step.error.kind ?? "failed"),
            wikiStatus: typeof step.error.status === "number" ? step.error.status : null,
          });
        } else if (step.hold) {
          await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
        }
        await new Promise((resolve) => setTimeout(resolve, typeof step.wait === "number" ? step.wait : 5));
      }
    },
  };
}

function wikiAssistantIsland() {
  const load = globalThis.wikiIslands?.assistant;
  if (typeof load !== "function") {
    return Promise.reject(Object.assign(new Error("The assistant's script is not in this page."), { wikiKind: "failed" }));
  }
  return load();
}

// What went wrong, as {kind, status, message}: by the SDK's typed errors
// (the island's describeError) for a provider's, as said for the others.
async function wikiAssistantDescribe(error) {
  if (typeof error?.wikiKind === "string") {
    return { kind: error.wikiKind, status: error.wikiStatus ?? null, message: String(error.message ?? "") };
  }
  try {
    return (await wikiAssistantIsland()).describeError(error);
  } catch {
    return { kind: "failed", status: null, message: String(error?.message ?? error) };
  }
}

// Open a chat: `config` is JSON {provider, model, key, request}, `callback`
// the Haskell function its events go to. Its number.
function wiki_assistant_open(config, callback) {
  const id = ++wikiAssistantNextChat;
  wikiAssistantChats.set(id, {
    id,
    config: JSON.parse(config),
    callback,
    made: null,
    controller: null,
    calls: new Map(),
    nextCall: 0,
    buffer: "",
    timer: null,
  });
  return id;
}

// Send a message of the user's and run the model's turn, unless one is
// running already. Returns at once; the turn tells of itself through the
// callback.
function wiki_assistant_send(id, user) {
  const chat = wikiAssistantChats.get(id);
  if (!chat || chat.controller !== null) return;
  const controller = new AbortController();
  chat.controller = controller;
  if (chat.made === null) {
    const { provider, model, key, request } = chat.config;
    chat.made =
      provider === "scripted"
        ? Promise.resolve(wikiAssistantScripted({ provider, model, request }))
        : wikiAssistantIsland().then((island) => island.startChat(provider, key, request));
    chat.made.catch(() => {
      chat.made = null;
    });
  }
  (async () => {
    try {
      const made = await chat.made;
      await made.send(
        String(user),
        { text: (text) => wikiAssistantText(chat, text), tool: (name, input) => wikiAssistantAsk(chat, name, input) },
        controller.signal,
      );
      chat.controller = null;
      wikiAssistantEmit(chat, controller.signal.aborted ? { type: "stopped" } : { type: "done" });
    } catch (error) {
      chat.controller = null;
      if (controller.signal.aborted) wikiAssistantEmit(chat, { type: "stopped" });
      else wikiAssistantEmit(chat, { type: "error", ...(await wikiAssistantDescribe(error)) });
    }
  })();
}

// The application's answer to a tool call: the text the model is given,
// and whether the edit was made.
function wiki_assistant_answer(id, call, text, ok) {
  const chat = wikiAssistantChats.get(id);
  const resolve = chat?.calls.get(call);
  if (!resolve) return;
  chat.calls.delete(call);
  resolve({ text: String(text), ok: Boolean(ok) });
}

// Stop the turn that is running, if one is.
function wiki_assistant_stop(id) {
  const chat = wikiAssistantChats.get(id);
  if (!chat || chat.controller === null) return;
  chat.controller.abort();
  wikiAssistantAnswerWaiting(chat, "Stopped by the user before this was answered.");
}

// Close a chat: its turn stopped, and nothing more told.
function wiki_assistant_close(id) {
  const chat = wikiAssistantChats.get(id);
  if (!chat) return;
  chat.controller?.abort();
  wikiAssistantAnswerWaiting(chat, "Stopped by the user before this was answered.");
  if (chat.timer !== null) clearTimeout(chat.timer);
  wikiAssistantChats.delete(id);
}

// "Test the key": `config` is JSON {provider, model, key}. The empty string
// if the provider accepts the key and has the model, or the error as JSON.
async function wiki_assistant_check(config) {
  const { provider, model, key } = JSON.parse(config);
  try {
    if (provider === "scripted") {
      const refusal = globalThis.wikiAssistantScript?.check;
      if (refusal) {
        throw Object.assign(new Error(String(refusal.message ?? "")), {
          wikiKind: String(refusal.kind ?? "failed"),
          wikiStatus: typeof refusal.status === "number" ? refusal.status : null,
        });
      }
      return "";
    }
    await (await wikiAssistantIsland()).checkKey(provider, key, model);
    return "";
  } catch (error) {
    return JSON.stringify(await wikiAssistantDescribe(error));
  }
}

// Whether a test installed the scripted provider.
function wiki_assistant_scripted() {
  return typeof globalThis.wikiAssistantScript === "object" && globalThis.wikiAssistantScript !== null;
}

// Whether the page is a secure context (HTTPS, or the machine's own
// address): a page served over plain HTTP elsewhere is not.
function wiki_assistant_secure() {
  return globalThis.isSecureContext === true;
}

// Start fetching the providers' island, so that it is there by the time a
// message is sent.
function wiki_assistant_prepare() {
  wikiAssistantIsland().catch(() => {});
}

// Whether a keydown in the message box sends it: Enter, without Shift (a
// new line) and outside a composition.
function wiki_assistant_send_key(event) {
  return event.key === "Enter" && !event.shiftKey && !event.isComposing && !event.ctrlKey && !event.metaKey && !event.altKey;
}
