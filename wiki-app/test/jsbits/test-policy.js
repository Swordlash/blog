// The page's Content Security Policy in the browser tests
// (Test.Browser.Policy): the policy the test page carries (written by
// wiki-app/test/web/policy.mjs), the violations the browser has reported
// since, and a few things to try under it.

function wiki_test_policy_text() {
  const meta = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
  return meta === null ? "" : String(meta.getAttribute("content") ?? "");
}

// Every violation reported so far, as JSON [{directive, blocked, source,
// line, sample}].
function wiki_test_policy_violations() {
  return JSON.stringify(globalThis.wikiPolicyViolations ?? []);
}

// Forget the violations a test caused on purpose: those whose blocked
// address starts with the given text.
function wiki_test_policy_forget(prefix) {
  globalThis.wikiPolicyViolations = (globalThis.wikiPolicyViolations ?? []).filter(
    (violation) => !String(violation.blocked ?? "").startsWith(prefix),
  );
}

// Whether text can be evaluated as code: never, under the policy. The
// browser reports the refusal as a violation, a moment later, which is
// then forgotten: this one is the test's own.
async function wiki_test_policy_evaluates() {
  let evaluates;
  try {
    evaluates = (0, eval)("1 + 1") === 2;
  } catch {
    evaluates = false;
  }
  await new Promise((resolve) => setTimeout(resolve, 50));
  wiki_test_policy_forget("eval");
  return evaluates;
}

// What a page's HTML may have tried to run: the value its handlers and
// scripts would have set, or "" if none ran.
function wiki_test_raw_ran() {
  return String(globalThis.wikiRawRan ?? "");
}

// Whether a fetch of an address is refused by the policy, as the browser
// reports it: the fetch fails, and a violation names the address. The
// violation is reported as a task of its own, so the answer waits a moment
// for it.
async function wiki_test_policy_refuses(address) {
  const refused = [];
  const listen = (event) => refused.push(String(event.blockedURI));
  document.addEventListener("securitypolicyviolation", listen);
  try {
    await fetch(address);
  } catch {
    // Refused, or not reachable: the violation tells which.
  }
  await new Promise((resolve) => setTimeout(resolve, 50));
  document.removeEventListener("securitypolicyviolation", listen);
  return refused.some((blocked) => blocked.startsWith(address));
}

// The providers' SDKs, as the page's island (islands/assistant.js) loads
// them, listing Anthropic's models through a fetch of the test's own that
// answers as Anthropic's API does: what the SDK does in the page, under the
// policy, without a network. JSON of the list, or {error} with what failed.
async function wiki_test_policy_sdk() {
  try {
    const island = await globalThis.wikiIslands.assistant();
    const asked = [];
    const fetch = async (url) => {
      asked.push(String(url));
      return new Response(
        JSON.stringify({
          data: [{ type: "model", id: "claude-test-1", display_name: "Claude Test", created_at: "2026-10-01T00:00:00Z" }],
          has_more: false,
          first_id: "claude-test-1",
          last_id: "claude-test-1",
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    };
    const listed = await island.listModels("anthropic", "a-test-key-not-a-real-one", { fetch });
    return JSON.stringify({ listed, asked });
  } catch (error) {
    return JSON.stringify({ error: String(error?.stack ?? error) });
  }
}
