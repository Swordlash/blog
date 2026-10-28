// Write the script that puts the application page's Content Security
// Policy on the browser test runner's page:
//
//   node policy.mjs <web/index.html> <output.js>
//
// The runner (hspec-halogen) writes its own page, so the policy cannot be
// in it from the start, as it is in web/index.html. The script it writes
// is a classic script, which the runner's page loads in its head before
// the suite (it loads the bundle's scripts in the order of their names,
// and this one's name, 0-policy.js, comes first). The script adds the
// meta element there, before the suite's WebAssembly is compiled, so that
// the whole suite runs under the policy, as the application does. The
// policy's text is read from web/index.html, its one source
// (Wiki.Api.ContentPolicy), and Test.Browser.Policy checks that the page
// has that text.
//
// The script also keeps every violation the browser reports, in
// globalThis.wikiPolicyViolations, for the suite's last test, which fails
// on any: a directive the islands, the editor or the assistant need and
// the policy lacks.
import { readFileSync, writeFileSync } from "node:fs";

const [page, output] = process.argv.slice(2);
const found = /<meta http-equiv="Content-Security-Policy" content="([^"]*)"/.exec(readFileSync(page, "utf8"));
if (found === null) {
  process.stderr.write(`${page} has no Content Security Policy\n`);
  process.exit(1);
}
writeFileSync(
  output,
  `// Written by wiki-app/test/web/policy.mjs from web/index.html.
globalThis.wikiPolicyViolations = [];
document.addEventListener("securitypolicyviolation", (event) => {
  globalThis.wikiPolicyViolations.push({
    directive: event.effectiveDirective,
    blocked: event.blockedURI,
    source: event.sourceFile,
    line: event.lineNumber,
    sample: event.sample,
  });
});
{
  const meta = document.createElement("meta");
  meta.httpEquiv = "Content-Security-Policy";
  meta.content = ${JSON.stringify(found[1])};
  document.head.append(meta);
}
`,
);
