# Changelog

## Unreleased

The whole HTTP API, under `/api/v1`, for the server of Phase 2 and the
application's backend over HTTP; docs/api.md lists every endpoint.

- `Wiki.Api`: the API as a servant type, a record of routes per resource
  (`SpacesApi`, `PagesApi`, `AttachmentsApi`, `ArchiveApi`) gathered in
  `WikiApi`, one endpoint per method of `MonadWiki` plus export and the
  two-step import. It builds for the browser's WebAssembly too: servant's
  core and servant-multipart's API types are pure Haskell.
- `Wiki.Api.Links`: every endpoint's address made from that type, relative
  to the application's base (`links.spaces.rename spaceId`), with
  `attachmentUrl`, `searchUrl` and `searchQueryOf`, so that client and server
  cannot disagree about a path or a parameter.
- `Wiki.Api.Types`: a small JSON record per request body, and `SessionInfo`.
- `Wiki.Api.Error`: `ApiError`, the JSON body of a refusal, one constructor
  per `WikiError` constructor, with `errorStatus` (404, 403, 409, 400) and
  `errorForStatus` for a response whose body is not one.
- `Wiki.Api.Version`: `PageVersion`, a page's `updatedAt` as its `ETag` and a
  save's `If-Match`.
- `Wiki.Api.Upload`: the multipart forms of an attachment's upload and of an
  import, read into memory.
- `Wiki.Api.Import`: the import's plan, choices and summary.
- `Wiki.Api.Zip`: `application/zip`, for the export.

Golden files (`test-server/golden/`) pin down the JSON of every body a client
depends on, and a server of the type with stub handlers is requested at the
addresses `Wiki.Api.Links` makes.

## 0.1.0 - 2026-10-22

The first type the client and the server share, `Wiki.Api.Info.ServerInfo`
(the answer to `GET /api/v1/info`), and `apiVersion`, the `v1` in the API's
paths: plain data with aeson instances derived from its `Generic`
representation, the pattern the rest of the API's types will follow when the
server arrives.
