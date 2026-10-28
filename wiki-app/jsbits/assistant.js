// The writing assistant's side of the application's JavaScript, declared in
// Wiki.App.Assistant (WP4.19 of docs/PLAN.md). It drives a chat with a
// provider for the editor's assistant panel (Wiki.App.View.Assistant):
//
// - a chat is opened with its provider, model, key, the address of
//   another service than the provider's own if it is asked at one
//   (baseUrl: OpenAI's API elsewhere), and request (the request without
//   its conversation, as Wiki.Core.Assistant.Prompt assembles it) and one
//   Haskell callback, and is known by a number;
// - each message is sent with the request as it is now (a model or an effort
//   chosen since the chat began applies from the next message), and runs
//   one turn of the model's, whose events go to the
//   callback as JSON, in order: {type: "text", text}, as the answer
//   streams; {type: "thinking", text}, as the summary of the model's
//   thinking streams; {type: "tool-start", name}, when the model begins
//   writing a tool call; {type: "tool", call, name, input}, the whole tool
//   call, which the turn waits on until the application answers it
//   (wiki_assistant_answer); and at the end {type: "done"}, {type:
//   "stopped"} or {type: "error", kind, status, message};
// - a stop aborts the turn (the SDK's request with it) and answers any call
//   still waiting, so that nothing hangs.
//
// The providers are the island's (web/src/assistant.js, islands/assistant.js
// in the page, loaded the first time through wikiIslands.assistant()), but
// for the scripted one, which is here: a page whose tests installed a
// script as globalThis.wikiAssistantScript before the program started
// (wiki-app's browser tests, and the demo's smoke test) may choose it; no
// page served to anyone has one. On such a page the script answers for
// every provider, so that a test reaches none: what the application sends
// a provider (its model, its key, its address) is recorded, and the
// answers are the script's. Its script is {turns: [[step, ...], ...]},
// a list of steps for each message in turn: {text} streams text,
// {thinking} streams a summary of thinking, {tool, input} starts a tool
// call and, after {pause} milliseconds if given, makes it and waits for
// its answer, {error: {kind, status, message}} ends the turn with that
// error, {hold: true} waits until the turn is stopped, and {wait}
// (milliseconds, after any step) paces it; a step of {wait} alone is a
// pause, before the first text for instance. It
// keeps what it was sent in script.requests and its tools' answers in
// script.answers, for the tests to read. A provider's list of models is
// script.lists[provider], [{id, label, created}, ...], or {error: {kind,
// status, message}} to fail (kind "connection": no way to the provider);
// without one, the scripted provider has the one model "scripted" and the
// others none. script.check, an error, refuses "Test the key".
//
// The key is handed to the island, which hands it to the SDK; nothing here
// logs it or keeps it beyond the chat.

const wikiAssistantChats = new Map();
let wikiAssistantNextChat = 0;

// Text and thinking stream in many small pieces: they are handed on
// together, a few times a second, rather than one event each. The buffer
// holds pieces of one kind ("text" or "thinking"); a piece of the other
// kind, or any other event, first hands on what the buffer holds, so the
// events keep their order.
const wikiAssistantFlushAfter = 40;

function wikiAssistantFlush(chat) {
  if (chat.timer !== null) {
    clearTimeout(chat.timer);
    chat.timer = null;
  }
  if (chat.buffer !== "") {
    const text = chat.buffer;
    chat.buffer = "";
    if (wikiAssistantChats.get(chat.id) === chat) chat.callback(JSON.stringify({ type: chat.bufferKind, text }));
  }
}

function wikiAssistantEmit(chat, event) {
  wikiAssistantFlush(chat);
  if (wikiAssistantChats.get(chat.id) === chat) chat.callback(JSON.stringify(event));
}

function wikiAssistantBuffer(chat, kind, text) {
  if (chat.bufferKind !== kind) {
    wikiAssistantFlush(chat);
    chat.bufferKind = kind;
  }
  chat.buffer += String(text);
  if (chat.timer === null) chat.timer = setTimeout(() => wikiAssistantFlush(chat), wikiAssistantFlushAfter);
}

// What a chat's provider is handed to tell of its turn (web/src/assistant.js).
function wikiAssistantHandlers(chat) {
  return {
    text: (text) => wikiAssistantBuffer(chat, "text", text),
    thinking: (text) => wikiAssistantBuffer(chat, "thinking", text),
    toolStart: (name) => wikiAssistantEmit(chat, { type: "tool-start", name: String(name) }),
    tool: (name, input) => wikiAssistantAsk(chat, name, input),
  };
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

// Whether a test installed a script, which then answers for every provider.
function wikiAssistantScriptedPage() {
  return typeof globalThis.wikiAssistantScript === "object" && globalThis.wikiAssistantScript !== null;
}

// A script's error, thrown as a provider's would be described.
function wikiAssistantScriptError(error) {
  return Object.assign(new Error(String(error.message ?? "")), {
    wikiKind: String(error.kind ?? "failed"),
    wikiStatus: typeof error.status === "number" ? error.status : null,
  });
}

// The scripted provider, for the tests (see above).
function wikiAssistantScripted(config) {
  const script = globalThis.wikiAssistantScript;
  return {
    async send(user, handlers, signal, request) {
      if (!Array.isArray(script.requests)) script.requests = [];
      script.requests.push({ provider: config.provider, model: config.model, key: config.key, baseUrl: config.baseUrl ?? null, request, user });
      const steps = script.turns?.shift() ?? [{ text: "The script has nothing more to say." }];
      for (const step of steps) {
        if (signal.aborted) return;
        if (step.text !== undefined) handlers.text(step.text);
        else if (step.thinking !== undefined) handlers.thinking(step.thinking);
        else if (step.tool !== undefined) {
          handlers.toolStart(step.tool);
          if (typeof step.pause === "number") await new Promise((resolve) => setTimeout(resolve, step.pause));
          if (signal.aborted) return;
          const answer = await handlers.tool(step.tool, step.input);
          if (!Array.isArray(script.answers)) script.answers = [];
          script.answers.push({ tool: step.tool, input: step.input, text: answer.text, ok: answer.ok });
        } else if (step.error !== undefined) {
          throw wikiAssistantScriptError(step.error);
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

// What the island's SDK clients are made with besides the key: the address
// of another service, if the provider is asked at one.
function wikiAssistantOptions(baseUrl) {
  return typeof baseUrl === "string" && baseUrl !== "" ? { baseURL: baseUrl } : {};
}

// Open a chat: `config` is JSON {provider, model, key, baseUrl, request}, `callback`
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
    bufferKind: "text",
    timer: null,
  });
  return id;
}

// Send a message of the user's, with the request as it is now (JSON), and
// run the model's turn, unless one is running already. Returns at once; the
// turn tells of itself through the callback.
function wiki_assistant_send(id, user, request) {
  const chat = wikiAssistantChats.get(id);
  if (!chat || chat.controller !== null) return;
  const now = JSON.parse(request);
  const controller = new AbortController();
  chat.controller = controller;
  if (chat.made === null) {
    const { provider, model, key, baseUrl, request } = chat.config;
    chat.made =
      provider === "scripted" || wikiAssistantScriptedPage()
        ? Promise.resolve(wikiAssistantScripted({ provider, model, key, baseUrl, request }))
        : wikiAssistantIsland().then((island) => island.startChat(provider, key, request, wikiAssistantOptions(baseUrl)));
    chat.made.catch(() => {
      chat.made = null;
    });
  }
  (async () => {
    try {
      const made = await chat.made;
      await made.send(String(user), wikiAssistantHandlers(chat), controller.signal, now);
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

// "Test the key": `config` is JSON {provider, model, key, baseUrl}. The
// empty string if the provider accepts the key and has the model, or the
// error as JSON.
async function wiki_assistant_check(config) {
  const { provider, model, key, baseUrl } = JSON.parse(config);
  try {
    if (provider === "scripted" || wikiAssistantScriptedPage()) {
      const refusal = globalThis.wikiAssistantScript?.check;
      if (refusal) throw wikiAssistantScriptError(refusal);
      return "";
    }
    await (await wikiAssistantIsland()).checkKey(provider, key, model, wikiAssistantOptions(baseUrl));
    return "";
  } catch (error) {
    return JSON.stringify(await wikiAssistantDescribe(error));
  }
}

// The provider's models: `config` is JSON {provider, key, baseUrl}. JSON
// {models: [{id, label, created}, ...]}, or {error: {kind, status,
// message}}.
async function wiki_assistant_models(config) {
  const { provider, key, baseUrl } = JSON.parse(config);
  try {
    if (provider === "scripted" || wikiAssistantScriptedPage()) {
      const listed = globalThis.wikiAssistantScript?.lists?.[provider];
      if (listed !== undefined && !Array.isArray(listed)) throw wikiAssistantScriptError(listed.error ?? {});
      return JSON.stringify({ models: listed ?? (provider === "scripted" ? [{ id: "scripted", label: "Its script", created: null }] : []) });
    }
    return JSON.stringify({ models: await (await wikiAssistantIsland()).listModels(provider, key, wikiAssistantOptions(baseUrl)) });
  } catch (error) {
    return JSON.stringify({ error: await wikiAssistantDescribe(error) });
  }
}

// Whether a test installed the scripted provider.
function wiki_assistant_scripted() {
  return wikiAssistantScriptedPage();
}

// Whether the page is a secure context (HTTPS, or the machine's own
// address): a page served over plain HTTP elsewhere is not.
function wiki_assistant_secure() {
  return globalThis.isSecureContext === true;
}

// The page's Content Security Policy, as its meta element carries it (the
// server writes its header's text there too), or "" for a page without
// one; and the page's origin. The application checks another service's
// base URL against them before the browser would refuse it
// (Wiki.App.Assistant, Wiki.Api.ContentPolicy).
function wiki_assistant_page_policy() {
  const meta = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
  return meta === null ? "" : String(meta.getAttribute("content") ?? "");
}

function wiki_assistant_page_origin() {
  return String(location.origin);
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

// Whether a keydown in the message box closes the panel: Escape, outside
// a composition (where Escape cancels the composition).
function wiki_assistant_close_key(event) {
  return event.key === "Escape" && !event.isComposing;
}

// The time of day of a moment (milliseconds since 1970), as the reader's
// browser writes a short time in its language ("14:32", or "2:32 PM").
function wiki_assistant_clock(ms) {
  return new Date(ms).toLocaleTimeString(undefined, { timeStyle: "short" });
}
