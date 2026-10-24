// How the page's style sheet draws an element, for the editor's browser
// tests (Test.Browser.Editor): the computed colour of the first element a
// selector finds, or "" when there is none, so that a test sees that a
// colour's class has a look and not only that it is in the page.

function wiki_test_computed_colour(selector) {
  const element = document.querySelector(selector);
  return element ? getComputedStyle(element).color : "";
}

// Any computed property of the first element a selector finds, or "".
function wiki_test_computed_style(selector, property) {
  const element = document.querySelector(selector);
  return element ? getComputedStyle(element).getPropertyValue(property) : "";
}
