// The writing assistant's providers (web/src/assistant.js) over the real
// SDKs, against a fetch of this script's own that answers as Anthropic's
// and OpenAI's APIs do: no key, no network. What is tested is what the
// page relies on the SDKs for: the requests they make from what the
// application assembled (the headers a browser needs, the conversation
// sent whole each turn, append-only), the stream read as it comes, the tool
// loop going on with the tools' answers, a stop, and the SDKs' typed errors
// read as the application's kinds. The browser tests use the scripted
// provider instead (wiki-app/jsbits/assistant.js); a real provider cannot
// be reached from here.
//
//   node toolchain/test-assistant.mjs
import assert from "node:assert/strict";
import { checkKey, describeError, startChat } from "../web/src/assistant.js";

let failures = 0;
const test = async (name, body) => {
  try {
    await body();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}`);
    console.log(error);
  }
};

// A fetch that answers each request with the next of `answers` (a function
// of the request, or a Response), and keeps the requests.
const fakeFetch = (answers) => {
  const requests = [];
  const fetch = async (url, init = {}) => {
    const headers = new Headers(init.headers);
    const body = init.body ? JSON.parse(init.body) : null;
    requests.push({ url: String(url), method: init.method ?? "GET", headers, body });
    if (init.signal?.aborted) throw Object.assign(new Error("aborted"), { name: "AbortError" });
    const answer = answers.shift();
    if (answer === undefined) throw new Error(`no answer left for ${url}`);
    return typeof answer === "function" ? answer(init) : answer;
  };
  return { fetch, requests };
};

const sse = (events) =>
  new Response(events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(""), {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// Anthropic's stream of one message: text, then tool calls, then why it
// stopped.
const anthropicMessage = (texts, tools, stopReason) => {
  const events = [
    ["message_start", { type: "message_start", message: { id: "msg", type: "message", role: "assistant", model: "m", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ...texts.map((text) => ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }]),
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
  ];
  tools.forEach(([id, name, input], i) => {
    events.push(
      ["content_block_start", { type: "content_block_start", index: i + 1, content_block: { type: "tool_use", id, name, input: {} } }],
      ["content_block_delta", { type: "content_block_delta", index: i + 1, delta: { type: "input_json_delta", partial_json: JSON.stringify(input) } }],
      ["content_block_stop", { type: "content_block_stop", index: i + 1 }],
    );
  });
  events.push(
    ["message_delta", { type: "message_delta", delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 2 } }],
    ["message_stop", { type: "message_stop" }],
  );
  return sse(events);
};

const anthropicRequest = {
  model: "claude-opus-5-5",
  max_tokens: 32000,
  system: [{ type: "text", text: "REFERENCE", cache_control: { type: "ephemeral" } }],
  tools: [{ name: "replace", description: "d", input_schema: { type: "object", properties: {}, required: [] } }],
};

const collect = () => {
  const texts = [];
  const calls = [];
  return {
    texts,
    calls,
    handlers: {
      text: (t) => texts.push(t),
      tool: async (name, input) => {
        calls.push([name, input]);
        return { text: "Applied.", ok: true };
      },
    },
  };
};

await test("Anthropic: streams the text, runs the tool loop, and keeps the conversation", async () => {
  const { fetch, requests } = fakeFetch([
    anthropicMessage(["I will ", "fix it."], [["tu_1", "replace", { old_text: "a", new_text: "b" }]], "tool_use"),
    anthropicMessage(["Done."], [], "end_turn"),
    anthropicMessage(["Again."], [], "end_turn"),
  ]);
  const chat = startChat("anthropic", "sk-ant-test", anthropicRequest, { fetch, maxRetries: 0 });
  const { texts, calls, handlers } = collect();
  await chat.send("Fix it.", handlers, new AbortController().signal);
  assert.equal(texts.join(""), "I will fix it.Done.");
  assert.deepEqual(calls, [["replace", { old_text: "a", new_text: "b" }]]);
  assert.equal(requests.length, 2);
  const [first, second] = requests;
  assert.match(first.url, /\/v1\/messages$/);
  // The SDK sends the key as a bearer token (its 1.x releases do).
  assert.equal(first.headers.get("authorization") ?? `Bearer ${first.headers.get("x-api-key")}`, "Bearer sk-ant-test");
  assert.equal(first.headers.get("anthropic-dangerous-direct-browser-access"), "true");
  assert.equal(first.body.stream, true);
  assert.deepEqual(first.body.system, anthropicRequest.system);
  assert.deepEqual(first.body.messages, [{ role: "user", content: "Fix it." }]);
  // The tool's result goes back after the model's call, which goes back whole.
  assert.equal(second.body.messages.length, 3);
  assert.equal(second.body.messages[1].role, "assistant");
  assert.deepEqual(second.body.messages[1].content.at(-1), { type: "tool_use", id: "tu_1", name: "replace", input: { old_text: "a", new_text: "b" } });
  assert.deepEqual(second.body.messages[2], { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_1", content: "Applied." }] });
  // The next message is sent after the whole conversation, unchanged, with
  // the request as it is now: another effort chosen since.
  await chat.send("More.", collect().handlers, new AbortController().signal, { ...anthropicRequest, output_config: { effort: "high" } });
  const third = requests[2];
  assert.deepEqual(third.body.messages.slice(0, 3), second.body.messages);
  assert.equal(third.body.messages[3].role, "assistant");
  assert.deepEqual(third.body.messages[4], { role: "user", content: "More." });
  assert.deepEqual(third.body.output_config, { effort: "high" });
  assert.deepEqual(third.body.system, anthropicRequest.system);
  assert.equal(third.body.thinking, undefined);
});

await test("Anthropic: a refused tool's answer is marked as an error", async () => {
  const { fetch, requests } = fakeFetch([
    anthropicMessage([], [["tu_1", "replace", { old_text: "x", new_text: "y" }]], "tool_use"),
    anthropicMessage(["Sorry."], [], "end_turn"),
  ]);
  const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 0 });
  await chat.send("Go.", { text: () => {}, tool: async () => ({ text: "Not applied: not found.", ok: false }) }, new AbortController().signal);
  assert.deepEqual(requests[1].body.messages[2].content[0], { type: "tool_result", tool_use_id: "tu_1", content: "Not applied: not found.", is_error: true });
});

await test("Anthropic: the SDK's typed errors are the application's kinds", async () => {
  const cases = [
    [401, { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, "authentication"],
    [403, { type: "error", error: { type: "permission_error", message: "no" } }, "permission"],
    [404, { type: "error", error: { type: "not_found_error", message: "model: claude-none" } }, "not_found"],
    [429, { type: "error", error: { type: "rate_limit_error", message: "slow down" } }, "rate_limit"],
    [400, { type: "error", error: { type: "invalid_request_error", message: "bad" } }, "bad_request"],
    [529, { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }, "overloaded"],
  ];
  for (const [status, body, kind] of cases) {
    const { fetch } = fakeFetch([json(status, body)]);
    const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 0 });
    const error = await chat.send("x", collect().handlers, new AbortController().signal).then(
      () => null,
      (e) => e,
    );
    assert.deepEqual(describeError(error), { kind, status, message: body.error.message }, `status ${status}`);
  }
});

await test("Anthropic: the SDK retries an overloaded provider", async () => {
  const { fetch, requests } = fakeFetch([json(529, { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }), anthropicMessage(["Fine."], [], "end_turn")]);
  const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 1 });
  const { texts, handlers } = collect();
  await chat.send("x", handlers, new AbortController().signal);
  assert.equal(texts.join(""), "Fine.");
  assert.equal(requests.length, 2);
});

await test("Anthropic: a refusal is an error of its own", async () => {
  const { fetch } = fakeFetch([anthropicMessage([], [], "refusal")]);
  const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 0 });
  const error = await chat.send("x", collect().handlers, new AbortController().signal).then(() => null, (e) => e);
  assert.equal(describeError(error).kind, "refusal");
});

await test("Anthropic: the network is the connection's error", async () => {
  const fetch = async () => {
    throw new TypeError("Failed to fetch");
  };
  const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 0 });
  const error = await chat.send("x", collect().handlers, new AbortController().signal).then(() => null, (e) => e);
  assert.equal(describeError(error).kind, "connection");
});

await test("Anthropic: a stop aborts the request", async () => {
  const controller = new AbortController();
  const fetch = (url, init) =>
    new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })));
      setTimeout(() => controller.abort(), 10);
    });
  const chat = startChat("anthropic", "k", anthropicRequest, { fetch, maxRetries: 0 });
  const error = await chat.send("x", collect().handlers, controller.signal).then(() => null, (e) => e);
  assert.equal(describeError(error).kind, "aborted");
});

const openAiRequest = {
  model: "gpt-6.1-sol",
  instructions: "REFERENCE\n\nINSTRUCTIONS",
  tools: [{ type: "function", name: "replace", description: "d", parameters: { type: "object", properties: {}, required: [], additionalProperties: false }, strict: true }],
  store: false,
  include: ["reasoning.encrypted_content"],
  reasoning: { effort: "low" },
};

const openAiResponse = (texts, output) =>
  sse([
    ["response.created", { type: "response.created", sequence_number: 0, response: { id: "resp", output: [] } }],
    ...texts.map((delta, i) => ["response.output_text.delta", { type: "response.output_text.delta", sequence_number: i + 1, item_id: "msg", output_index: 0, content_index: 0, delta }]),
    ["response.completed", { type: "response.completed", sequence_number: 99, response: { id: "resp", status: "completed", output } }],
  ]);

await test("OpenAI: streams the text, runs the tool loop, and sends the conversation whole", async () => {
  const reasoning = { type: "reasoning", id: "rs_1", summary: [], encrypted_content: "opaque" };
  const call = { type: "function_call", id: "fc_1", call_id: "call_1", name: "replace", arguments: '{"old_text":"a","new_text":"b"}', status: "completed" };
  const message = { type: "message", id: "msg_1", role: "assistant", status: "completed", content: [{ type: "output_text", text: "Done.", annotations: [] }] };
  const { fetch, requests } = fakeFetch([openAiResponse(["I will "], [reasoning, call]), openAiResponse(["Done."], [message])]);
  const chat = startChat("openai", "sk-open", openAiRequest, { fetch, maxRetries: 0 });
  const { texts, calls, handlers } = collect();
  await chat.send("Fix it.", handlers, new AbortController().signal);
  assert.equal(texts.join(""), "I will Done.");
  assert.deepEqual(calls, [["replace", { old_text: "a", new_text: "b" }]]);
  const [first, second] = requests;
  assert.match(first.url, /\/v1\/responses$/);
  assert.equal(first.headers.get("authorization"), "Bearer sk-open");
  assert.equal(first.body.store, false);
  assert.deepEqual(first.body.reasoning, { effort: "low" });
  assert.equal(first.body.max_output_tokens, undefined);
  assert.equal(first.body.instructions, openAiRequest.instructions);
  assert.deepEqual(first.body.input, [{ role: "user", content: "Fix it." }]);
  assert.deepEqual(second.body.input, [
    { role: "user", content: "Fix it." },
    reasoning,
    call,
    { type: "function_call_output", call_id: "call_1", output: "Applied." },
  ]);
  assert.equal(second.body.previous_response_id, undefined);
});

await test("OpenAI: an answer cut short is an error, not an empty answer", async () => {
  const { fetch } = fakeFetch([
    sse([
      ["response.created", { type: "response.created", sequence_number: 0, response: { id: "resp", output: [] } }],
      ["response.incomplete", { type: "response.incomplete", sequence_number: 1, response: { id: "resp", status: "incomplete", incomplete_details: { reason: "max_output_tokens" }, output: [] } }],
    ]),
  ]);
  const chat = startChat("openai", "k", openAiRequest, { fetch, maxRetries: 0 });
  const error = await chat.send("x", collect().handlers, new AbortController().signal).then(() => null, (e) => e);
  assert.deepEqual(describeError(error), { kind: "failed", status: null, message: "The answer was cut short (max_output_tokens)." });
});

await test("OpenAI: the SDK's typed errors are the application's kinds", async () => {
  const cases = [
    [401, { error: { message: "Incorrect API key provided: sk-proj-****abcd.", type: "invalid_request_error", code: "invalid_api_key" } }, "authentication"],
    [404, { error: { message: "The model `gpt-none` does not exist", type: "invalid_request_error", code: "model_not_found" } }, "not_found"],
    [429, { error: { message: "Rate limit reached", type: "requests", code: "rate_limit_exceeded" } }, "rate_limit"],
    [500, { error: { message: "Server error", type: "server_error" } }, "overloaded"],
  ];
  for (const [status, body, kind] of cases) {
    const { fetch } = fakeFetch([json(status, body)]);
    const chat = startChat("openai", "k", openAiRequest, { fetch, maxRetries: 0 });
    const error = await chat.send("x", collect().handlers, new AbortController().signal).then(() => null, (e) => e);
    assert.deepEqual(describeError(error), { kind, status, message: body.error.message }, `status ${status}`);
  }
});

await test("Test the key: the model looked up, which costs nothing", async () => {
  const a = fakeFetch([json(200, { type: "model", id: "claude-opus-5-5", display_name: "Claude Opus 5.5", created_at: "2026-09-01T00:00:00Z" })]);
  await checkKey("anthropic", "sk-ant", "claude-opus-5-5", { fetch: a.fetch, maxRetries: 0 });
  assert.equal(a.requests[0].method, "GET");
  assert.match(a.requests[0].url, /\/v1\/models\/claude-opus-5-5$/);
  const o = fakeFetch([json(404, { error: { message: "The model `nope` does not exist", type: "invalid_request_error" } })]);
  const error = await checkKey("openai", "sk-open", "nope", { fetch: o.fetch, maxRetries: 0 }).then(() => null, (e) => e);
  assert.equal(describeError(error).kind, "not_found");
  assert.match(o.requests[0].url, /\/v1\/models\/nope$/);
});

if (failures > 0) {
  console.error(`${failures} of the assistant's provider tests failed`);
  process.exit(1);
}
console.log("The assistant's providers: all tests passed");
