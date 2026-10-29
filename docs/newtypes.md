# Text fields and the newtypes that replace them

This is the inventory WP5.15 of `docs/PLAN.md` asks for: every field and
argument of type `Text` in `wiki-api` and `wiki-core`, and the `wiki-server`
and `wiki-app` boundaries that take them, grouped by what the text is. For
each group it says whether the value has rules of its own, where the rules
are applied today, and the decision: a newtype, or `Text` stays.

## How the newtypes work

Each newtype is `newtype X = X {text :: Text}`. Its JSON and URL instances
are derived from `Text` ("deriving newtype"), so the wire formats do not
change: the API's JSON, its query parameters and path segments, the export
archive, the server's database and the browser's IndexedDB records stay
byte for byte the same, and so do the golden files.

Those instances do not apply the rules. Unlike `Slug`, whose `FromJSON`
refuses a bad slug, decoding a `Login` from JSON accepts any text. The
reason is the error a client gets: today a bad login in a request is
answered with the backend's `Invalid "A login cannot be blank."`, a
`WikiError` the application shows; a refusal in `FromJSON` would be
servant's own 400 with a parser message instead. So the constructor is
exported, and is used for values from a trusted source (a database row, an
archive the backend wrote, a response of the server). The rules are in one
function per newtype (`parseLogin`, `parseEmail`, ...), called where the
rule is applied today: in the backend that receives the request, or in the
console's command.

For that reason a request type keeps `Text` for a value the receiving
backend checks (`NewAccount.login`, `NewInvitation.email`): the field holds
what someone typed, and the backend's parser turns it into the newtype. A
response type, a stored record and a domain type use the newtype. The one
exception is `Password`, which carries no rule (see its section), so every
password in a request is a `Password`.

There is no `IsString` instance: a literal `"ada"` is not a `Login`, so
production code cannot make one without the constructor or the parser.
Tests use the constructor.

## Groups

### Logins: `Login` (`Wiki.Core.User`)

Rules today: `checkLogin` in `Wiki.Core.User`. A login is trimmed of white
space, has 1 to 64 characters, no white space or control character inside,
and does not start with `~` (the server's own principals). The server
compares logins without regard to case (`COLLATE NOCASE`).

Applied today in: `Wiki.Server.Accounts.createAccount` (the console's
`users add`), `Accounts.prepared` (registration and invitations),
`Wiki.Server.Storage`'s `createUser` (the administration), the in-memory
backend's `createUser`.

| Field or argument | Decision |
| --- | --- |
| `Wiki.Core.User.User.login` | `Login` |
| `Wiki.Core.Audit.Actor.login` | `Login` (the operator's `~administrator` is built with the constructor) |
| `Wiki.Core.Export.Named.login` (a comment's author in `comments.json`) | `Maybe Login` |
| `Wiki.Api.Account.NewAccount.login` | `Text`: what was typed, parsed by the backend |
| `Wiki.Api.Account.Credentials.login` | `Text`: sign-in only looks the login up (trimmed, any case); `checkLogin` is not applied, and applying it would answer `~x` with a new refusal instead of "wrong login or password" |
| `Wiki.Api.Security.ResetRequest.login` | `Text`: a login or an e-mail address |
| the console's `LOGIN` argument of `users password`, `admin`, `disable`, `second-factor-remove`, `remove` | `Text`: a lookup, like sign-in |
| mentions (`Wiki.Core.Notification.mentionedIn`, `mentionable`) | `Text`: an `@name` in a page is a lookup of a login, not a login |

Accepted today though the rule refuses it, kept as it is:

- An archive restored into an empty server keeps its users' logins as
  `users.json` gives them, without `parseLogin` (`Wiki.Core.Export`'s
  `parseUser`, then `Wiki.Server.Storage`'s import). A hand-edited archive
  can bring a blank login or one starting with `~`.
- The login made for an account a provider creates (`loginCandidates` in
  `Wiki.Server.Accounts`) is built to follow the rule and is not parsed.

### Passwords: `Password` (`Wiki.Core.User`)

Rules today: `checkPassword` in `Wiki.Core.User`, for a new password only:
8 to 1024 characters. A password typed at sign-in has no rule; a wrong one
is refused by the hash.

Applied today in: `Accounts.createAccount`, `Accounts.prepared`,
`Accounts.setPassword`, `Accounts.changePassword`, `Reset.resetPassword`,
`Storage`'s `createUser` and `setPassword`, the in-memory backend's
`createUser` and `setPassword`.

Decision: `Password` is a newtype whose `Show` prints `Password <hidden>`,
so a password never reaches a log through `show`. It carries no promise
about the rules, because a password at sign-in is still a password; the
rule for a new one is `checkNewPassword :: Password -> Either Text Password`,
which takes a `Password` for that reason.

| Field or argument | Decision |
| --- | --- |
| `Credentials.password`, `NewAccount.password`, `NewPassword.password`, `PasswordChange.current` and `.new`, `CurrentPassword.password`, `EmailChange.password`, `NewPasswordByMail.password` | `Password`; their hand-written `Show` instances are gone, derived ones hide the password |
| `Wiki.Server.Password.hashPassword`, `hashWith`, `verifyPassword`, the server's `signIn`, `createAccount`, `setPassword`, `changePassword`, `currentPasswordIs`, `resetPassword`, the console's password reader | take or give `Password` |
| the application's `signIn`, `resetPassword`, `setPassword`, `enrolTotp`, `setOwnEmail` | take `Password`; the forms wrap what was typed when they submit |
| `MailSettingsOf.password`, `ProviderSettingsOf.secret` | stay the type parameter `s`: a stored secret is `SecretState` in a response and `Maybe Text` in a change, and the server keeps it encrypted (`Wiki.Server.Secret`) |

### E-mail addresses: `Email` (`Wiki.Core.User`)

Rules today: `checkEmail` in `Wiki.Api.Admin`: trimmed, 1 to 254
characters, no white space or control character, one `@` with text before
it and a dot inside the domain. It moves to `Wiki.Core.User` as
`parseEmail`, since the in-memory backend and the server both apply it.

Applied today in: `Storage`'s `invite`, the server's `createUser` (the
administration's optional address), `sendingTestMail`, `Reset.setEmail`,
the in-memory backend's `invite`.

| Field or argument | Decision |
| --- | --- |
| `Wiki.Api.Admin.Invitation.email`, `Wiki.Api.Account.InvitationInfo.email`, `Wiki.Api.Security.AccountEmail.email`, `EmailState.email` | `Email` |
| `NewInvitation.email`, `NewAccount.email`, `EmailChange.email` (blank removes the address), `MailTest.to` | `Text`: what was typed, parsed by the backend |
| `LinkedIdentity.email`, the server's `Claimed.email` | `Maybe Email`: what a provider said it verified, stored as given, not parsed (accepted today, kept) |
| `MailSettingsOf.from` | `Text`: a sender, `Wiki <wiki@example.org>`, not only an address |
| the server's mail functions (`Wiki.Server.Mail`, `Message.to`), `Wiki.Server.Reset`, the queued notifications | take `Email` |

### URLs: `Url` (`Wiki.Core.Url`)

Rules today, one set per field, none shared:

- the wiki's public address, `checkPublicUrl` in `Wiki.Api.ServerSettings`:
  `http://` or `https://`, a host, none of `" < > \ ? #`, no white space or
  control character; a slash is added at the end;
- a sign-in provider's issuer, `secureAddress` in the same module: `https://`,
  or `http://` to this machine;
- the assistant's base URL for OpenAI's API, `withBaseUrl` in
  `Wiki.Core.Assistant`: trimmed, slashes at the end dropped, blank means
  OpenAI's own; plain HTTP to another machine is warned about
  (`insecureUrl`), not refused.

Decision: one `Url` newtype (`Wiki.Core.Url`), for a web address the wiki
stores or uses; each field keeps its own rule where it was:
`checkPublicUrl` becomes `parsePublicUrl` and returns a `Url`,
`secureAddress` takes a `Url`, and `withBaseUrl` still takes the typed
text and makes the `Url`. `insecureUrl` stays a check of the typed text,
since the settings page warns while the user types. There is no shared
parser, since the three rules differ and this package adds none.

| Field or argument | Decision |
| --- | --- |
| `ServerSettingsOf.publicUrl` | `Maybe Url` |
| `ProviderSettingsOf.issuer` | `Maybe Url` |
| `ProviderCheck.redirectUri`, `redirectUri`, `Discovered`'s `issuer`, `authorization`, `token`, `userinfo` | `Url` |
| the server's `Mailer.publicUrl`, the mail functions, an OIDC `Provider.publicUrl`, the export's `Place.publicUrl` | `Url` |
| the server's discovery results inside `Wiki.Server.Oidc` (`Endpoints`) | `Text`: read from the provider's document and only joined to parameters; they become `Url` in the API's `Discovered` |
| `Wiki.Core.Assistant.ProviderSettings.baseUrl`, `Ready.baseUrl` | `Maybe Url` |
| `Wiki.Core.Attachment.SourceUrl` | `Url`. There is no URL check for attachments: only the demo's seed and an archive's `attachments.json` make one. An archive's URL is accepted as it is today (kept); the renderer's `safeSrc` decides whether a page shows it |
| `TotpEnrolment.uri` | `Text`: an `otpauth://` URI for a phone's camera, not a web address |
| `attachmentUrl`, `spaceIconUrl`, `exportFileName`, `startUrl` | `Text`: built for an `href` or `src` at once and never stored |

### File names: `FileName` (`Wiki.Core.Attachment`)

Rules today, written twice (in `Wiki.Server.Storage` and in the in-memory
backend): trimmed, not blank (`nonBlank "An attachment's name"`), and no
slash, backslash or control character. They become `parseFileName`, with
the same messages, which both backends call. WP5.8's escaping of a name
for a file system is applied on export, to the archive's entries, and
stays there.

| Field or argument | Decision |
| --- | --- |
| `Wiki.Core.Attachment.Attachment.name` | `FileName` |
| `findAttachment`'s name | `Text`: the name as a page's Markdown writes it |
| `Wiki.Api.Upload.AttachmentUpload.name`, `uploadAttachment`'s name | `Text`: what the browser's file gave, parsed by the backend |
| the API's `content` route's `name` segment | `FileName`: only the browser's download name |
| the Markdown renderer's `AttachmentRef.name` | `Text`: the renderer's input, made from the attachment at the last step |
| `BackupRecord.file` | `Text`: a name the server made (`wiki-<time>.db`), never typed |

### Media types: `MimeType` (`Wiki.Core.Attachment`)

Rules today: nothing is refused. Both backends store an upload's declared
type trimmed, and `application/octet-stream` when it is blank; an unknown
or malformed one makes the attachment a link (`mediaKind`). A space's icon
accepts only five image types (`checkIconUpload`), compared without
parameters and in lower case, the type's "essence".

Decision: `MimeType`, without a parser that can fail. `uploadedMimeType`
is the normalisation both backends applied, and `mimeEssence` the
comparison; `mediaKind` takes a `MimeType`, `checkIconUpload` returns one.

| Field or argument | Decision |
| --- | --- |
| `Attachment.mediaType`, `IconImage`'s type, `iconMediaTypes`, the server's `spaceIconFile` and `safeMediaType`, the demo's `blobUrl` | `MimeType` |
| `AttachmentUpload.mediaType`, `uploadAttachment`'s and `uploadSpaceIcon`'s media type | `Text`: what the browser declared, normalised by the backend |
| the Markdown renderer's `AttachmentRef.mediaType`, `attachmentReference` | `Text`: the renderer's input |

### Tokens

| Token | Today | Decision |
| --- | --- | --- |
| An invitation's secret | `InvitationToken` in `Wiki.Api.Account`; `Invited.token` is `Maybe Text` | `Invited.token` becomes `Maybe InvitationToken` |
| A reset link's secret, a verification link's secret, an unsubscribe link's secret | one `MailToken` for all three | three newtypes in `Wiki.Api.Security`, `ResetToken`, `VerificationToken`, `UnsubscribeToken`, so that one cannot be passed where another goes; `MailToken` goes away |
| A session's secret (the cookie) | `Text` throughout `Wiki.Server.Session` and `Accounts` | `SessionToken` in `Wiki.Server.Password` (beside `newToken` and `tokenHash`; `Wiki.Server.Session` imports `Accounts`, so it cannot hold it), with a hidden `Show`; the application never sees it (the cookie is `HttpOnly`) |
| A waiting sign-in's secret (the second factor's cookie) | `Text` | `PendingToken` in `Wiki.Server.SecondFactor`, with a hidden `Show` |
| A session's public id | `SessionRef` | unchanged |
| The assistant's API key | `Maybe Text` in `ProviderSettings.key`, `Text` in `Ready.key` | `ApiKey` in `Wiki.Core.Assistant`, with a hidden `Show` |
| A code from an authenticator, recovery codes, the TOTP secret | `OneTimeCode`, `RecoveryCodes`, `TotpEnrolment` (each with a hidden `Show`) | unchanged |

The newtypes that exist (`InvitationToken`, `SessionRef`, the
`OneTimeCode` family) stay in `wiki-api`, where the requests that carry
them are, and the mailed tokens join them there. `SessionToken` and
`PendingToken` are in `wiki-server`, the only package that sees them.

### Model names: `ModelName` (`Wiki.Core.Assistant`)

Rules today: `withModel`: trimmed; blank means none chosen.

| Field or argument | Decision |
| --- | --- |
| `ProviderSettings.model`, `Ready.model`, `Model.id`, `Listed.id`, `defaultModel`, `chosenModel`, `modelLabel`'s argument, `anthropicRequest` and `openAiRequest` | `ModelName` |
| the settings form's typed model | `Text`, through `withModel` |

### Text that stays `Text`

- Prose, labels and names for people: a user's display name, a group's
  name, a space's name and description, a page's title, a template's title,
  a provider's label, `ServerInfo.name`, a version's name.
- Markdown and what is derived from it: a page's body, a draft's body, a
  comment's body, a space's math macros, excerpts, search text and
  snippets, the assistant's edits and anchors.
- Messages for people: `WikiError`'s texts, `mailError`, `failure`,
  `problem`, `LoggedError.message`, the assistant's errors.
- Machine words with a fixed set of values, already read into a sum type
  where they are used: `Access`, `MailMode`, `ProviderKind`, `Security`,
  the assistant's efforts, the audit's `action` and `Subject.kind`.
- Identifiers that are not one of the wiki's own records and are only
  compared: an audit entry's id (a UUID from the archive), a provider's
  name (checked by `providerProblems`, a segment of the sign-in path), the
  activity log's cursor `before`, a provider's client id, an OIDC subject.
- Network addresses and paths of the server: `SessionSummary.address`,
  `AuditEntry.address`, `ServerStatus.dataDir`, `LoggedError.route`,
  `MailSettingsOf.host`, `MailSettingsOf.user`, `OffSite.to`.
- SQL: the server's queries are literals in `Wiki.Server.Storage`; no SQL
  fragment crosses a module's boundary as `Text`.
