// The writing assistant's providers: Anthropic's and OpenAI's official
// JavaScript SDKs, called from the browser with the user's own key
// (decision 21 of docs/PLAN.md, WP4.19).
//
// web/bundle.sh bundles this, with the two SDKs, into islands/assistant.js,
// which islands.js imports the first time the editor's assistant asks for
// it (wikiIslands.assistant()), so that no other page fetches it. The
// application's side is wiki-app/jsbits/assistant.js, which drives a chat
// through what this exports:
//
//   startChat(provider, key, request, options): a chat, whose
//     send(user, handlers, signal, request) sends one message of the
//     user's (with the request it gives, if it gives one: a model or an
//     effort chosen since the chat began) and
//     runs the model's turn to its end: the text it writes goes to
//     handlers.text as it streams, the summary of its thinking to
//     handlers.thinking as it streams, the start of each tool call to
//     handlers.toolStart(name) as soon as the model begins writing the
//     call, and each whole tool call to handlers.tool(name, input), whose
//     promise is the tool's answer ({text, ok}); the model then goes on,
//     until it answers without a tool call. handlers.thinking and
//     handlers.toolStart may be left out. The conversation, as the
//     provider gave it (the model's
//     thinking and tool calls included, unchanged, as both providers ask),
//     is kept by the chat for the next message.
//   checkKey(provider, key, model): the smallest request there is, which
//     costs nothing: the model, looked up with the key.
//   listModels(provider, key): the provider's models (GET /v1/models, every
//     page of it), as [{id, label, created}]: the name the provider shows
//     it by, or null (OpenAI gives none), and when it was made, in seconds
//     since 1970, or null. The application groups them
//     (Wiki.Core.Assistant.groupModels).
//   describeError(error): what went wrong, by the SDK's typed errors, as
//     {kind, status, message}.
//
// `request` is the request without its conversation, as the application
// assembled it (Wiki.Core.Assistant.Prompt): the model, the system prompt
// with the wiki's Markdown reference first, the tools. The key is sent to
// its provider only, by the SDK, over HTTPS; nothing here logs (the SDKs'
// own logging is turned off) or keeps it. `options` are the SDK client's
// own: the page passes the address of another service than the provider's
// own, if it is asked at one ({baseURL}: any that speaks OpenAI's API),
// and the tests a fetch of their own.
import Anthropic from "@anthropic-ai/sdk";
import OpenAI from "openai";

// How many times a model may call its tools in one turn before the turn is
// ended: a page's worth of edits, and a guard against a model that loops.
const maxRounds = 24;

// Whether an error is the provider refusing one part of the request as
// one this model or account does not support: a 400 whose message
// matches. The part named is then left out of every later request of the
// chat (see `dropped` below).
const refusesPart = (error, pattern) =>
  (error instanceof Anthropic.BadRequestError || error instanceof OpenAI.BadRequestError) && pattern.test(messageOf(error));

// An empty key is a server's that takes none (OpenAI's API on this
// machine: Ollama, LM Studio): the SDK will not make a client without a
// key, so it gets one that is never sent, its Authorization header taken
// away, as the SDK allows.
const clientOptions = (key, options) => ({
  apiKey: key === "" ? "none" : key,
  ...(key === "" ? { defaultHeaders: { Authorization: null } } : {}),
  // The SDKs refuse to run in a browser without it, since a key in a page
  // can be read by whoever has the page: here the key is the user's own,
  // typed by them into their own browser. Anthropic's SDK sends the
  // anthropic-dangerous-direct-browser-access header its API asks for.
  dangerouslyAllowBrowser: true,
  logLevel: "off",
  ...options,
});

// Anthropic's Messages API: the conversation is its messages; a turn is
// the model's answer and, while it calls tools, the tools' results and its
// next answer. The model's content goes back whole, thinking blocks
// included, as the API requires of a conversation that goes on.
//
// The request asks for adaptive thinking with its summary shown
// (Wiki.Core.Assistant.Prompt). Older models (Claude Haiku 4.5, Opus 4.5)
// refuse adaptive thinking with a 400: the request is then sent again
// without `thinking`, and so is every later request of the chat.
const anthropicChat = (key, request, options) => {
  const client = new Anthropic(clientOptions(key, options));
  const messages = [];
  let dropped = false;
  const asked = (now) => {
    if (!dropped) return now;
    const { thinking, ...rest } = now;
    return rest;
  };
  return {
    async send(user, handlers, signal, now = request) {
      const turn = [...messages, { role: "user", content: user }];
      try {
        for (let round = 0; round < maxRounds; round++) {
          const stream = client.messages.stream({ ...asked(now), messages: turn }, { signal });
          stream.on("text", (delta) => handlers.text(delta));
          stream.on("thinking", (delta) => handlers.thinking?.(delta));
          stream.on("streamEvent", (event) => {
            if (event.type === "content_block_start" && event.content_block?.type === "tool_use") handlers.toolStart?.(String(event.content_block.name));
          });
          let message;
          try {
            message = await stream.finalMessage();
          } catch (error) {
            if (!dropped && now.thinking !== undefined && refusesPart(error, /adaptive thinking is not supported/i)) {
              dropped = true;
              round--;
              continue;
            }
            throw error;
          }
          if (message.stop_reason === "refusal") {
            throw Object.assign(new Error(message.stop_details?.explanation ?? "The model declined."), { wikiKind: "refusal" });
          }
          const uses = message.content.filter((block) => block.type === "tool_use");
          if (message.stop_reason !== "tool_use" || uses.length === 0) {
            // A tool call cut short (at max_tokens) has no result to go
            // with it, which the next request would be refused for.
            const content = uses.length === 0 ? message.content : message.content.filter((block) => block.type !== "tool_use");
            if (content.length > 0) turn.push({ role: "assistant", content });
            return;
          }
          const results = [];
          for (const use of uses) {
            const { text, ok } = await handlers.tool(use.name, use.input);
            results.push({ type: "tool_result", tool_use_id: use.id, content: text, ...(ok ? {} : { is_error: true }) });
          }
          // The call and its results together, so that the conversation
          // never holds one without the other, even when stopped.
          turn.push({ role: "assistant", content: message.content }, { role: "user", content: results });
        }
      } finally {
        messages.splice(0, messages.length, ...turn);
      }
    },
  };
};

// OpenAI's Responses API: the conversation is the input, sent whole each
// time (nothing is kept at OpenAI: the request says store: false), with the
// model's output items as it gave them, its reasoning encrypted.
//
// The request asks for a summary of the reasoning (reasoning.summary,
// Wiki.Core.Assistant.Prompt), which streams in parts before the answer;
// the parts are handed on separated by a blank line. OpenAI may refuse the
// summary to an organisation it has not verified, with a 400 that names
// it: the request is then sent again without the summary, and so is every
// later request of the chat. OpenAI may also accept the request and send
// empty summaries, as it did for gpt-6.1-sol and gpt-6-luna in October
// 2026: the panel then shows "Thinking" alone.
const openAiChat = (key, request, options) => {
  const client = new OpenAI(clientOptions(key, options));
  const input = [];
  let dropped = false;
  const asked = (now) => {
    if (!dropped || now.reasoning === undefined) return now;
    const { summary, ...reasoning } = now.reasoning;
    return { ...now, reasoning };
  };
  return {
    async send(user, handlers, signal, now = request) {
      const turn = [...input, { role: "user", content: user }];
      try {
        for (let round = 0; round < maxRounds; round++) {
          let stream;
          try {
            stream = await client.responses.create({ ...asked(now), input: turn, stream: true }, { signal });
          } catch (error) {
            if (!dropped && now.reasoning?.summary !== undefined && refusesPart(error, /summar/i)) {
              dropped = true;
              round--;
              continue;
            }
            throw error;
          }
          let response = null;
          for await (const event of stream) {
            if (event.type === "response.output_text.delta") handlers.text(event.delta);
            else if (event.type === "response.reasoning_summary_text.delta") handlers.thinking?.(event.delta);
            else if (event.type === "response.reasoning_summary_part.added" && event.summary_index > 0) handlers.thinking?.("\n\n");
            else if (event.type === "response.output_item.added" && event.item?.type === "function_call") handlers.toolStart?.(String(event.item.name));
            else if (event.type === "response.completed") response = event.response;
            else if (event.type === "response.incomplete") {
              // Cut short: a reasoning model can spend its whole budget on
              // reasoning and write nothing, which is no answer.
              const reason = event.response?.incomplete_details?.reason;
              throw Object.assign(new Error(`The answer was cut short${reason ? ` (${reason})` : ""}.`), { wikiKind: "failed" });
            }
            else if (event.type === "response.failed") {
              throw Object.assign(new Error(event.response?.error?.message ?? "The response failed."), { wikiKind: "failed" });
            } else if (event.type === "error") {
              throw Object.assign(new Error(event.message ?? "The response failed."), { wikiKind: "failed" });
            }
          }
          if (response === null) return;
          const calls = response.output.filter((item) => item.type === "function_call");
          if (calls.length === 0) {
            turn.push(...response.output);
            return;
          }
          const outputs = [];
          for (const call of calls) {
            let args = null;
            try {
              args = JSON.parse(call.arguments);
            } catch {
              args = null;
            }
            const { text } = await handlers.tool(call.name, args);
            outputs.push({ type: "function_call_output", call_id: call.call_id, output: text });
          }
          turn.push(...response.output, ...outputs);
        }
      } finally {
        input.splice(0, input.length, ...turn);
      }
    },
  };
};

export function startChat(provider, key, request, options = {}) {
  if (provider === "anthropic") return anthropicChat(key, request, options);
  if (provider === "openai") return openAiChat(key, request, options);
  throw Object.assign(new Error(`There is no provider called ${provider}.`), { wikiKind: "failed" });
}

export async function checkKey(provider, key, model, options = {}) {
  if (provider === "anthropic") await new Anthropic(clientOptions(key, options)).models.retrieve(model);
  else if (provider === "openai") await new OpenAI(clientOptions(key, options)).models.retrieve(model);
  else throw Object.assign(new Error(`There is no provider called ${provider}.`), { wikiKind: "failed" });
}

export async function listModels(provider, key, options = {}) {
  const listed = [];
  if (provider === "anthropic") {
    // Anthropic's pages are of 20 by default, of up to 1000.
    for await (const model of new Anthropic(clientOptions(key, options)).models.list({ limit: 1000 })) {
      const created = Date.parse(model.created_at);
      listed.push({
        id: String(model.id),
        label: typeof model.display_name === "string" && model.display_name !== "" ? model.display_name : null,
        created: Number.isFinite(created) ? Math.floor(created / 1000) : null,
      });
    }
  } else if (provider === "openai") {
    for await (const model of new OpenAI(clientOptions(key, options)).models.list()) {
      listed.push({ id: String(model.id), label: null, created: Number.isFinite(model.created) ? model.created : null });
    }
  } else throw Object.assign(new Error(`There is no provider called ${provider}.`), { wikiKind: "failed" });
  return listed;
}

// The provider's own message, without the status and the JSON the SDKs
// put around it.
const messageOf = (error) => {
  const body = error?.error;
  const nested = body?.error?.message ?? body?.message;
  return String(typeof nested === "string" && nested !== "" ? nested : (error?.message ?? error));
};

// The SDKs' typed errors, as the kinds the application names
// (Wiki.Core.Assistant.ErrorKind). Both SDKs have the same classes.
const kinds = [
  ["authentication", "AuthenticationError"],
  ["permission", "PermissionDeniedError"],
  ["not_found", "NotFoundError"],
  ["rate_limit", "RateLimitError"],
  ["bad_request", "BadRequestError"],
  ["bad_request", "UnprocessableEntityError"],
  ["overloaded", "InternalServerError"],
];

export function describeError(error) {
  if (error instanceof Anthropic.APIUserAbortError || error instanceof OpenAI.APIUserAbortError || error?.name === "AbortError") {
    return { kind: "aborted", status: null, message: "" };
  }
  if (typeof error?.wikiKind === "string") return { kind: error.wikiKind, status: null, message: String(error.message ?? "") };
  if (error instanceof Anthropic.APIConnectionError || error instanceof OpenAI.APIConnectionError) {
    return { kind: "connection", status: null, message: messageOf(error) };
  }
  const status = typeof error?.status === "number" ? error.status : null;
  for (const [kind, name] of kinds) {
    if (error instanceof Anthropic[name] || error instanceof OpenAI[name]) return { kind, status, message: messageOf(error) };
  }
  // Anthropic's "overloaded" is a 529 of its own.
  if (status !== null && status >= 500) return { kind: "overloaded", status, message: messageOf(error) };
  return { kind: "failed", status, message: messageOf(error) };
}
