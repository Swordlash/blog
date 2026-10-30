# Changelog

## Unreleased

- Run independent API examples in parallel.

The server's settings gain `boxes`, the kinds of box the administration
defined (WP5.29), which `SessionInfo` carries too, so that every reader
renders them. `ServerStatus` gains `guide`, whether the wiki has its guide,
and `AdminApi` gains `installGuide`, `POST api/v1/admin/guide`. Settings
and sessions without `boxes` read as having none.

`NotificationsApi` gains `searchPeople`, `GET
notifications/people/search?q=<letters>` (WP5.28): the users who may sign in
whose login or display name starts with the letters, ignoring case, at most
`maxPeopleFound` (ten), ordered by display name, as `[User]`; only users
whose login a mention can name; nobody to a visitor, or for fewer than
`minPeopleSearch` (two) letters (`searchable`). The editor completes
mentions with it.

`providerProblems`, and so `checkServerSettings`, refuse a provider of
kind Google whose client id does not end with
`.apps.googleusercontent.com`. Google takes the short form when a person
signs in, but writes the full id into the ID token, which the server then
refused only at the end of the sign-in. A wiki that already holds a short
Google id cannot save any other change to the server settings (the mail,
the public address) until the provider's id is fixed: the message names
the provider. Sign-in with it did not work before either.

The administration reads the users a page at a time (WP5.25):
`AdminApi.users` is `GET api/v1/admin/users` with the parameters `offset`,
`limit` (25 when missing, at most 100), `q` and the flags `administrators`
and `disabled`, answering a `UserPage` of `UserSummary`s with the total that
match. `Wiki.Api.Admin` gains `UserQuery` (`firstUsers`, `userQueryOf`,
`checkUserQuery`, `userPageSizes`, `maxUserPageSize`) and `pageOfDirectory`,
the meaning every backend's answer must have (`userMatches`, `userOrder`,
`summaryOf`). The directory endpoint stays.

`AdminApi.removeUser` is `DELETE api/v1/admin/users/<user>` (WP5.25): it
removes the account of a disabled login (409 for an enabled one, 400 for
one's own), keeping what the user wrote under their login.

The records of the API with an upload (`WikiApi`, `SpacesApi`, `PagesApi`,
`ArchiveApi`) take the multipart backend of their forms as their first
parameter (WP5.23): `Api` is `ApiWith Tmp`, what the server serves, and the
browser's client is derived from `ApiWith Mem`, whose uploads are bytes in
memory. A handler record is now `WikiApi Tmp AsServer`, and `links` is
`WikiApi Tmp (AsLink Text)`. Nothing on the wire changes.
`Wiki.Api.Links` gains `searchParameters`, the search endpoint's
parameters for a query (what `searchUrl` and the client's call are written
from), and `archiveExportUrl`.

`ServerInfo` gains `capabilities` (WP5.22, `Wiki.Api.Info`): `Capabilities`
`{database, search}`, the database the server keeps the wiki in and how its
search finds pages, `SearchKind` `FullText` (PostgreSQL) or `FoldedText`
(SQLite, and the demo).

`WikiApi` gains `assistant`, the `AssistantApi` of the vault and its
passkeys (WP5.21, `Wiki.Api.Vault`): `GET`, `PUT` and `DELETE
assistant/vault` (with `If-None-Match` and `If-Match` by the vault's tag),
`GET assistant/passkeys`, registration and assertion in two steps each,
and `DELETE assistant/passkeys/<id>`.

`Wiki.Api.ContentPolicy` is the application page's Content Security
Policy (WP5.21): `basePolicy`, read from `web/index.html` when the package
is compiled, `pagePolicy` and `headerPolicy` with an administrator's
assistant hosts in `connect-src`, `parseAssistantHost`, `originOf` and `allowsConnect`.
`ServerSettings` gains `assistantHosts`, the addresses the assistant may
reach besides the providers' APIs; settings without the field read as
having none.

The secrets mailed in links are three types instead of one `MailToken`
(WP5.15): `ResetToken` (a password reset), `VerificationToken` (an
address's verification) and `UnsubscribeToken` (turning notification mail
off), each with a hidden `Show`, so that one cannot be passed where another
goes. The routes that take them changed type, not address. `Invited.token`
is a `Maybe InvitationToken`, and `Invited` derives `Show`.

The file name segment of an attachment's content route is a `FileName`
(WP5.15). The address is unchanged.

The server's addresses are `Url` (WP5.15, from `Wiki.Core.Url`):
`ServerSettingsOf.publicUrl`, `ProviderSettingsOf.issuer`,
`ProviderCheck.redirectUri`, the endpoints of `Discovered`, and
`redirectUri`, which takes and gives one. `checkPublicUrl` is now
`parsePublicUrl`, with the same rule, and `secureAddress` takes a `Url`.
The JSON is unchanged.

The addresses in responses are `Email` (WP5.15): `Invitation.email`,
`InvitationInfo.email`, `AccountEmail.email`, `EmailState.email` and
`LinkedIdentity.email`. The addresses a request carries as typed
(`NewInvitation`, `NewAccount.email`, `EmailChange`, `MailTest`) stay
`Text`, checked by the backend. `checkEmail` is gone from
`Wiki.Api.Admin`: it is `Wiki.Core.User.parseEmail`. The JSON is
unchanged.

Every password in a request is a `Password` (WP5.15, from
`Wiki.Core.User`): `Credentials`, `NewAccount`, `NewPassword`,
`PasswordChange`, `CurrentPassword`, `EmailChange` and
`NewPasswordByMail`. Their `Show` instances are now derived, since
`Password`'s own never shows the password. The JSON is unchanged.

The upload forms take servant-multipart's backend as a parameter
(WP5.16c): `AttachmentUpload tag`, `ArchiveUpload tag` and `ImportApply
tag`, whose file is `MultipartResult tag` (the field `bytes` of
`AttachmentUpload` is now `payload`). The API serves `Tmp` forms, so that
the server writes an upload to disk as it arrives. `ArchiveApi.export` is
`RawM`, since the server sends the zip file from disk; `Wiki.Api.Zip` and
`Disposition` are gone with the typed response. What travels over HTTP is
unchanged.

Accounts with a password only from the console (WP5.18). `WikiSettings`
gains `adminCreatesPasswordAccounts`, true in `defaultSettings`: whether
the administration may create accounts with a password (`POST
admin/users`), which answers 403 when it is false. `Directory` gains the
same field, so that the panel learns it from the read it makes already.
The JSON of both types has the new field, and a `PUT admin/settings`
body must carry it.

The audit log's pages after an entry (WP5.16b). `ActivityQuery` gains
`before`, the id of the oldest entry of the page before, and
`AdminApi.activity` the query parameter `before`: the page is the entries
logged before that one. `offset` is still answered, but costs the server
more the further it skips.

A history a page at a time (WP5.16b). `PagesApi.versions` (`GET
pages/<id>/versions`) takes `before` (a version's time, as in its address)
and `limit` (50 if not given, 500 at most) as query parameters, and answers
the latest `limit` versions before `before`. Without them it answers the
50 latest versions, where it answered all of them. Each `VersionInfo`
carries its `number`.

Page lists without bodies (WP5.14). `SpacesApi.listPages`
(`GET spaces/<id>/pages`) answers `[PageSummary]`: each page without its
`body` and `attachments`, which `pageAt` reads. `PostDetails` gains
`excerpt`, the post's first paragraph as a blog lists it, since the list
no longer carries the body it was made from.

No password for accounts that sign in with a provider; password links
mailed by the administration (WP5.6). `Wiki.Api.Account.providerOnly` is the
rule (no password, and an account at a provider the server has);
`Directory` gains `providerOnly`, the users it holds for. `AdminApi` gains
`sendPasswordLink` (`POST admin/users/<id>/password-link`, `PostNoContent`).

Licensed under the MIT licence (WP5.1), where it was proprietary: the
package now ships `LICENSE` and says `license: MIT` in its `.cabal` file.

Tables of contents and templates (WP4.15). A page's JSON carries
`template`; `PagesApi` gains `template` (`PUT pages/<id>/template` with
`PageTemplate {"template": bool}`), and the search a `templates` flag, so
that `searchQueryOf` takes one more argument.

Observability (WP4.10). `Wiki.Api.Activity` (`Activity`, `ActivityQuery`,
`firstPage`, `activityPageSize`) and `AdminApi.activity` (`GET
admin/activity?actor=&offset=`); `ServerStatus` gains `schemaVersion`,
`lastBackup`, `connections` and `errors` (`LoggedError`); `Wiki.Api.Info.Health`
for `/healthz`.

Spaces shown as blogs (WP4.14). A space's JSON and a profile's carry
`blog`. `SpacesApi` gains `postDetails` (`GET
spaces/<id>/post-details`): what each page of a space is listed with as a
post, as an object keyed by the page's id.

Mentions, watching and notifications (WP4.13). `Wiki.Api.Notifications`:
`NotificationsApi` at `notifications` (`list`, `markRead`, `settings`,
`setSettings`, `people`, `pageWatch`, `setPageWatch`, `spaceWatch`,
`setSpaceWatch`), with `Notifications`, `ReadMark`,
`NotificationSettings`, `NotificationSettingsChange` and `Watching`;
`WikiApi` gains `notifications` and `unsubscribe` (`POST
unsubscribe/<secret>`, open in a closed wiki). `ServerMessage` gains
`Notified` (`{"notification": …}`), sent to every connection of the user
the notification is for. `PageChanged` is unchanged.

Account hygiene (WP4.11). `Wiki.Api.Security`: `SessionRef`,
`SessionSummary`, `SecondFactorState`, `TotpEnrolment`, `OneTimeCode`,
`RecoveryCodes`, `EmailState`, `EmailChange`, `AccountEmail`, `MailToken`,
`ResetRequest`, `NewPasswordByMail`, `resetLifetime`, `verificationLifetime`.
`WikiApi` gains `secondFactor` (`POST session/second-factor`),
`passwordReset` (`PasswordResetApi`: `POST password-reset`,
`POST password-reset/<secret>`) and `emailVerification`; `AccountApi` gains
`sessions`, `endSession`, `endOtherSessions`, `secondFactorState`,
`enrolTotp`, `confirmTotp`, `removeSecondFactor`, `email` and `setEmail`;
`AdminApi` gains `removeSecondFactor`. `ApiError.SecondFactorRequired` (401).
`NewAccount` gains an optional `email`; `Directory` gains `secondFactor`,
`emails` and `mailing`.

Presence and saves on the live channel (WP4.12). `ClientMessage` gains
`StartEditing` (`{"editing": page}`) and `StopEditing` (`{"stopped":
page}`); `PageEvent` gains `Editing [Author]` (`{"type": "editing",
"editors": [...]}`, who else edits the page, by id and display name, never
by login) and `PageChanged UTCTime` (`{"type": "page-changed", "updatedAt":
...}`, the page was saved). `Subscribed` carries a third field, who else
edits the page then (`"editing"`), read as empty from a server that does not
send it. `applyEvent` changes no thread for either new event. A client
message must name exactly one of its four keys.

Scheduled backups (WP4.9). `Wiki.Api.Backups`: `BackupSettingsOf s` (whether
the server backs itself up, a `Schedule` of `DailyAt` hour and minute in UTC
or `EveryHours`, a `Retention` of days and weeks, and a `DestinationOf s`, a
directory or an rclone remote with its configuration as a write-only secret),
`applyBackupChange` and `checkBackupSettings`, `Backups` (what
`GET admin/server/backups` answers: the settings, the last `BackupRecord`,
whether one is under way, when the next is due, how many are kept),
`nextBackup` and `retained`. `AdminApi` gains `backups`, `setBackups` and
`backUpNow` (`GET`/`PUT admin/server/backups`, `POST admin/server/backups/run`).

Export to documents (WP4.16). `Wiki.Api.Export`: `ExportFormat` (`Docx`,
`Html`, `Epub`, `Pdf`, `Pptx`, `BeamerTex`, `BeamerPdf`) with its name in an
address, label, extension, media type, whether it needs a TeX engine
(`needsTeX`) and whether it is a presentation (`forDecks`), `pageFormats`,
`spaceFormats` and `exportFileName`. `PagesApi` and `SpacesApi` gain `export`
(`GET pages/<page>/export/<format>`, `GET spaces/<space>/export/<format>`,
raw); `Wiki.Api.Links.pageExportUrl` and `spaceExportUrl`. `SessionInfo`
gains `exports`, the formats the server makes.

One space at a time (WP4.6). `SpacesApi` gains `pageCounts` (`GET
spaces/page-counts`, how many pages each space the asker may view has),
`setProfile` (`PUT spaces/<space>/profile`, a `SpaceProfile`), `uploadIcon`
(`POST spaces/<space>/icon`, a multipart form as an attachment's) and `icon`
(`GET spaces/<space>/icon/<blob>`, the image's bytes);
`Wiki.Api.Links.spaceIconUrl`. A `Space`'s JSON has `homePage`, `icon` and
`description`.

The server's settings (WP4.4). `Wiki.Api.ServerSettings`:
`ServerSettingsOf s {publicUrl, mail, providers}` with `MailSettingsOf s` and
`ProviderSettingsOf s`, each secret an `s`: `SecretState` (`"set"`,
`"not-set"`) as read, `Maybe Text` as written (`null` keeps, `""` clears);
`applyChange`, `checkServerSettings`, `ProviderKind` and `Security` (moved
from the server), `ProviderCheck`, `MailTest`, `MailTestResult`. `AdminApi`
gains `server`, `setServer`, `checkProvider` and `testMail`.

Comments (WP4.5). `WikiApi` gains `comments`, a page's threads at
`pages/<page>/threads` (`CommentsApi`: `list`, `open` with `NewThread
{anchor, body}`, `reply` and `edit` with `CommentText {body}`,
`deleteComment`, `delete`, `resolve` with `ThreadResolution {resolved}`),
answering `wiki-core`'s `Thread` and `Comment`. `Wiki.Api.Events` has the
live channel's messages, at `eventsPath` (`api/v1/events`, a WebSocket the
server upgrades itself): the tab's `ClientMessage` (`Subscribe`,
`Unsubscribe`), the server's `ServerMessage` (`Subscribed page threads`,
whose threads are the page's when the subscription was made, `Refused`,
`Event page PageEvent`), and `PageEvent` (`ThreadOpened`, `CommentAdded`,
`CommentEdited`, `CommentDeleted`, `ThreadResolved`, `ThreadDeleted`, and
`Unknown` for a type a newer server sends), with `applyEvent`, which folds
an event into a page's threads and counts one applied twice once.

One's own password (WP3.7). `AccountApi` gains `changePassword`, `PUT
account/password` with `PasswordChange {current, new}` (`current` null or left
out for a user without a password), answering `SignInMethods`; a wrong
`current` is 401 `Unauthenticated`, counted with failed sign-ins (429). Its
`Show` hides both passwords.

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
