# blog

A Confluence-style wiki, written in Haskell with
[haskell-halogen](https://github.com/Swordlash/haskell-halogen) and compiled to
WebAssembly for the browser.

What it is for: spaces and subspaces, each a tree of pages written in Markdown, with
Mermaid diagrams, LaTeX (inline and block), highlighted code, images, video and other
attachments, previewed live in the browser as you write. Users, groups and permissions
on spaces decide who may read, edit or administer what; a space can be public, which
makes the same application a blog.

How it is built: the browser application is Halogen components over a backend
interface, implemented once in memory (a serverless demo deployable as static files)
and once over HTTP to a Haskell server with persistence. Markdown is parsed and
rendered to Halogen HTML in the browser, so the preview never waits for a server.

Nothing is built yet. Work is planned in phases, from a serverless MVP demo through a
server with persistence to authentication and authorisation.

## Working on it

`AGENTS.md` describes how the work is organised: a planning session cuts the plan into
work packages and delegates each to an implementing agent. Toolchain and conventions
follow haskell-halogen's.

## License

Proprietary; see `LICENSE`.
