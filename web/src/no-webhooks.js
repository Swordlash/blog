// What web/bundle.sh gives Anthropic's SDK in the place of the
// standardwebhooks package, which its webhooks resource imports to verify
// the webhooks Anthropic sends a server. A page never receives one, so the
// assistant's island (web/src/assistant.js) never calls it; bundling the
// package would only add its code, and a package published without a
// licence file, which web/src/licenses.mjs rightly refuses to convey.
export class Webhook {
  constructor() {
    throw new Error("Webhooks are verified on a server, not in the wiki's page.");
  }
}
