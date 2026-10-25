# Changelog

## Unreleased

Signing in with a provider (WP3.6). `SessionInfo` gains `providers`
(`SignInProvider {name, label}` each), `Directory` gains `identities` (the
providers each user signs in with), `WikiApi` gains `account`
(`AccountApi`: `identities`, `GET account/identities` answering
`SignInMethods {password, identities}` of `LinkedIdentity {provider, email,
name, linkedAt}`, and `unlinkIdentity`, `DELETE account/identities/<provider>`)
and `AdminApi` `unlinkIdentity` (`DELETE admin/users/<id>/identities/<provider>`).
`Wiki.Api.Auth` makes the addresses that sign in with a provider
(`startUrl`, `callbackPath`), which are the server's, not the API's.

Whom the wiki lets in (WP3.5). `WikiApi` gains `register` (`POST
accounts`, a `NewAccount`, answering the session with its cookie) and
`invitations` (`InvitationsApi`: `details`, `GET invitations/<secret>`
answering `InvitationInfo {email, expiresAt}`, and `accept`, `POST` there
with a `NewAccount`). `AdminApi` gains `settings` and `setSettings` (`GET`
and `PUT admin/settings`, `WikiSettings {access, newAccountsCreateSpaces}`),
`invitations` (`Invitations {mailing, invitations}`), `invite` (`POST
admin/invitations`, `NewInvitation {email}`, 201 `Invited {invitation, token,
mailError}`) and `revokeInvitation`. `Wiki.Api.Admin` has `defaultSettings`,
`checkEmail` and `invitationLifetime` (seven days); `Wiki.Api.Account` has
`InvitationToken`, whose `Show` hides it. A session's `grants` now carries
`access`. In a closed wiki the API answers someone not signed in 401 but for
`info`, `session`, `accounts` and `invitations`.

Permissions on a space, and who may create spaces. `SpacesApi` gains
`access` (`GET spaces/<space>/grants`, answering
`Wiki.Core.Permission.SpaceAccess`: the grants on the space and its
ancestors, and the users and groups a grant may be given to) and `setGrant`
(`PUT spaces/<space>/grants`, `SpaceGrantChange {subject, permission,
granted}`, 204). `AdminApi` gains `setCreateSpaces` (`PUT
admin/users/<user>/create-spaces`, `CreateSpacesFlag {createSpaces}`, 204).
`Directory` gains `creators`, `disabled` and `withPassword`, sets of user
ids. `ServerStatus` loses `trustNetwork`, as the server loses
`--trust-network`.

Signing in and out, and accounts. `WikiApi` gains `signIn` (`POST session`,
`Credentials`, answering the `SessionInfo` with a `Set-Cookie`) and `signOut`
(`DELETE session`), and `AdminApi` gains `createUser`
(`POST admin/users`, `NewAccount`), `setPassword` (`PUT
admin/users/<user>/password`, `NewPassword`) and `setDisabled` (`PUT
admin/users/<user>/disabled`, `AccountDisabled`), each answering an
`Account`; the types are in `Wiki.Api.Account`, whose `Show` instances never
show a password. `SessionInfo` gains `standing` (`NotSignedIn`, `SignedIn`,
`Operator`). `ApiError` gains `Unauthenticated` (401) and `TooManyRequests`
(429), signing in's alone. `requestMarker` names the header every request
that changes something must carry. Golden files for each.

The wiki's people, for the administration panel: `AdminApi` (now a record
of several routes) gains `directory` (`GET admin/directory`, a
`Wiki.Api.Admin.Directory` of the users, the ids of those granted the global
administer, the groups and each group's members), `setAdministrator`
(`PUT admin/users/<user>/administrator` with `AdministratorFlag`),
`createGroup` (`POST admin/groups` with `GroupName`, 201 and the `Group`),
`renameGroup` (`PUT admin/groups/<group>/name`), `deleteGroup`
(`DELETE admin/groups/<group>`), `addMember` and `removeMember`
(`PUT` and `DELETE admin/groups/<group>/members/<user>`). Golden files
`directory.json`, `administrator-flag.json` and `group-name.json`.

Page history: `PagesApi` gains `versions` (`GET pages/<page>/versions`),
`version` (`GET pages/<page>/versions/<time>`) and `restore`
(`POST pages/<page>/versions/<time>/restore`, with `If-Match` as a save, and
the new version as `ETag`), for `MonadWiki`'s `listVersions`, `getVersion`
and `restoreVersion`. A version is named in a path by its time,
`Wiki.Api.Version.VersionTime`, ISO 8601 with every digit of the fraction and
no quotes, read back exactly. Golden files `versions.json` and
`version.json`.

The whole HTTP API, under `/api/v1`, for the server of Phase 2 and the
application's backend over HTTP; docs/api.md lists every endpoint.

- `Wiki.Api`: the API as a servant type, a record of routes per resource
  (`SpacesApi`, `PagesApi`, `AttachmentsApi`, `ArchiveApi`, `AdminApi`) gathered in
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
- `Wiki.Api.Admin` and `AdminApi` (`api/v1/admin/…`): what only the
  administrator may ask, so far the server's status (`ServerStatus`: its
  version, data directory, and how many
  spaces, pages, attachments, users and backups it has).

Golden files (`test-server/golden/`) pin down the JSON of every body a client
depends on, and a server of the type with stub handlers is requested at the
addresses `Wiki.Api.Links` makes.

## 0.1.0 - 2026-10-22

The first type the client and the server share, `Wiki.Api.Info.ServerInfo`
(the answer to `GET /api/v1/info`), and `apiVersion`, the `v1` in the API's
paths: plain data with aeson instances derived from its `Generic`
representation, the pattern the rest of the API's types will follow when the
server arrives.
