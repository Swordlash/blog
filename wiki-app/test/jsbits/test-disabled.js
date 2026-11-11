// Every change of a task box's disabled attribute from now on, for the
// tasks' browser tests (Test.Browser.Tasks), as the box's label and what
// the box became. A page adopted with its boxes as the prerender drew them
// must not change them, not even for a moment between the program's first
// render and its Initialize, which a read of the page after the adoption
// cannot see.

let wikiTestDisabledChanges = [];
let wikiTestDisabledObserver = null;

function wiki_test_watch_disabled() {
  wikiTestDisabledObserver?.disconnect();
  wikiTestDisabledChanges = [];
  wikiTestDisabledObserver = new MutationObserver((records) => {
    for (const record of records) {
      const box = record.target;
      if (!(box instanceof HTMLInputElement && box.type === "checkbox" && box.closest(".task-list-item") !== null)) continue;
      wikiTestDisabledChanges.push(`${box.getAttribute("aria-label")}: ${record.oldValue === null ? "disabled" : "enabled"}`);
    }
  });
  wikiTestDisabledObserver.observe(document.body, { subtree: true, attributes: true, attributeFilter: ["disabled"], attributeOldValue: true });
}

function wiki_test_disabled_changes() {
  return wikiTestDisabledChanges.join("\n");
}
