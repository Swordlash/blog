# Scalability audit: what does not scale to many users and many pages

Read-only review of `/home/user/blog` (wiki-core, wiki-api, wiki-app, wiki-server), 2026-10-27.
Every number below is an estimate from the code, with its assumption stated; nothing was measured.
Sizes assume a "big" wiki of 20,000 pages of 20 KB in 50 spaces (one space of 2,000 pages),
1,000 users, 10,000 watches, 200,000 notifications kept, 100 tabs open on a busy page.

## Known already (listed, not re-investigated)

- `listPages` returns every page of a space with its body (`Storage.hs:951 listPagesTx` →
  `Rows.hs:405 loadPages`): a space of 2,000 × 20 KB pages is a 40 MB JSON answer. Being fixed.
  Note for that fix: the same list is also what the shell loads at every navigation into a space
  (`Shell.hs:1181 fetchHere`), what the server's page render reads through the in-process API
  (`Render.hs:89 renderPage`), and what `Preload.hs:64 preloadJSON` writes into the HTML under
  `"pages"`, so the 40 MB appears a second time inside every served page. The fix has to reach
  `fetchHere`/the preload too, or hydration keeps the whole space.
- The HTTP cache per tab (`Backend/Http/Cache.hs`) is being replaced by fetch-on-navigation.
- The storage loads `ctx.spaces` per transaction. Confirmed: `Storage.hs:438 context` calls
  `Rows.hs:292 loadSpaces` (`SELECT … FROM spaces`, the whole table) **and** `Rows.hs:296
  loadGrants` (the whole `global_grants` and `space_grants` tables), plus the user and their
  groups, on every `transact`, reads included. This is O(spaces + grants) per transaction,
  ~14 columns decoded per space. It is fine up to ~1,000 spaces (≈1–2 ms) and becomes the
  floor of every request at 10,000 spaces (≈10–30 ms each, and `listSpacesTx` at line 922
  then also computes `chainOf` for every space). Smallest fix: keep the decoded spaces + grants
  in an `IORef` in `Storage`, invalidated by the transactions that write to those tables.

## Findings, ranked by impact

### 1. One SQLite connection, held for every request, and for the backup, the import and the export

**Where.** `Storage.hs:175` `Storage { connection :: MVar Connection }`; `Storage.hs:250 openWith`
opens one connection; `Storage.hs:422 transactThenFrom` runs *every* transaction, reads and
writes alike, under `withMVar st.connection`, and also runs the `committed` callback and
`st.config.notify` under it. `Accounts.hs:648 resolveSession` (every request's cookie lookup,
static files included, `App.hs findCaller`) is `withDatabase`, so it takes the same lock.
`Storage.hs:784 copyDatabase` runs `VACUUM INTO` under `withDatabase` (called from
`Backups.hs:177 backUp`). `Import.hs:223 applyImport` runs the whole import, attachments'
`storeBlob` included, in one `BEGIN IMMEDIATE` under `withDatabase`. `Storage.hs:2211
exportArchive` reads every page under it.

**What grows with what.** Throughput is bounded by the sum of transaction times, single-threaded,
whatever the core count. A rendered page view is ~9–10 serialized holds (see finding 2), a page
save is one write transaction plus finding 3's cost, each live-channel event is one hold per
subscriber (finding 4), each image on a page is one hold (finding 8d). WAL is on
(`openWith`), so SQLite itself would let readers run beside the writer; the MVar prevents it.

**How bad.** Small wiki: ~1–3 ms per hold × ~10 holds per page view → ~30–100 page views/s,
i.e. it is fine for 100 users, tight at ~50–100 *concurrent active* readers. The real problem
is the long holders: a `VACUUM INTO` of a 1 GB database (~5–20 s) stops every request, including
the WebSocket permission checks, for its whole duration, on every scheduled backup; an import
of a large archive (minutes) does the same; a `listPages` of a 2,000-page space (~100s of ms)
or a search over 20,000 pages (finding 5, ~0.5–1 s) is a global stall each time.

**Smallest fix (keeps sqlite-simple, decision 7).** A second connection (or a small pool of
read connections) opened the same way, used for `Reads` transactions, `resolveSession`,
`mayReadPage` and the backup's `VACUUM INTO`; the one writer connection keeps `BEGIN IMMEDIATE`
and the `committed`/`notify` ordering. `busy_timeout` is already set. That alone turns the
backup and search stalls into contention only among writers. One caveat: the live channel's
subscription (`Events.hs:251` → `Storage.hs:819 threadsThen`) relies on being made in the same
hold as its read, before any write can commit (decision 23); that one read must stay on the
writer connection, or the guarantee be rebuilt. `mayReadPage`, `editorOf` and the backup have
no such constraint.

### 2. Every page view is a full server-side render that reads the whole space, ~10 transactions, and embeds it all

**Where.** `Static.hs serveStatic` → `Render.hs:89 renderPage` for every HTML address (a build
with `template.html`); `Render.hs:214 inProcess` answers the application's requests through the
API in-process. For a page route the views read: `Shell.hs:1172 fetchWorld` (`session`,
`listSpaces`, one `spaceIconUrl` per image icon), `Shell.hs:1181 fetchHere` (`getSpace`,
`listPages` with bodies), `View/Page.hs:218–221` (`listThreads`, `askPeople` →
`session` + `mentionable`, and the watch button → `watching`), `View/Bell.hs:72` (`notifications`),
`View/Directory.hs:72` (`pageCounts`, at Home). Each is a `transact` that reloads spaces +
grants. Then `Render.hs:204 withPreload` writes everything read as JSON into the page.
`Static.hs:129 readTemplate` also `BS.readFile`s `template.html` on every page request.

**What grows with what.** Per page view: O(pages in the space × body size) read from SQLite,
encoded to JSON by the in-process API, decoded by `HttpWiki`, rendered (the space's tree is
rendered into the sidebar/space view, O(pages) DOM), and encoded again into the preload. Plus
~10 serialized DB holds (finding 1), plus `Render.hs:83 renderTimeout` of 10 s after which the
build's page is served instead.

**How bad.** 2,000 × 20 KB space: ≥ 40 MB read + 40 MB JSON + 40 MB in the HTML, per page view,
per reader; at ~100–300 MB/s of encode/decode that is 0.5–1 s of CPU per view under the
global lock, and the browser receives a ~40 MB HTML page. It blocks at ~1,000 pages in one
space; it is already noticeable at 100 pages × 20 KB (2 MB per view). For a small wiki the
~10 holds alone cap it at ~50–100 views/s.

**Smallest fix.** The `listPages` summary (titles/slugs/parents, no bodies) for the tree and
`getPage` for the one page, in both `fetchHere` and the preload; count transactions per render
and merge the per-view reads the server can answer in one (session + spaces + notifications
is one "me" read). Cache `template.html` in `StaticSite` at start.

### 3. The write path: every save or comment loads every user, every watch, every grant and every group, and each notification inserted scans the whole notifications table

**Where.** `Storage.hs:2009 tellTx`, called from `createPageTx:1364`, `savePageTx:1403`,
`editCommentTx:1965`, and `tellOfComment:2045` (every comment/reply): `loadGrants`,
`Rows.hs:352 loadMembership` (whole `group_members`), `Storage/Notifications.hs:78
loadTelling` (every enabled user) + `:99 loadAllMarks` (the whole `watches` table),
`pageNodes` of the space, `:93 pageMaker` (every version row of the page). Then
`wiki-core/src/Wiki/Core/Notification.hs:305 recipients` evaluates `canView` and `pageWatch` for **every** user.
Then for each recipient `Storage/Notifications.hs:163 insertNotification` runs
`(SELECT coalesce(max(seq) + 1, 0) FROM notifications)` — there is no index on `seq`
alone (`0011-notifications.sql` has `(user_id, seq)` and the partial `mail` index), so that is
a full table scan per inserted notification. `savePageTx` also parses the body twice
(`bodyText` and `newlyMentioned` old+new), which is fine.

**What grows with what.** Per save: O(users + watches + grants + members + pages in space +
versions of page) rows loaded and O(users × space depth) rule evaluations, inside the
**write** transaction, under the global lock; plus O(recipients × all notifications) for the
`max(seq)` scans.

**How bad.** 1,000 users / 10,000 watches / 200,000 notifications, a page with 50 watchers:
~12k rows loaded + 50 × 200k-row scans ≈ 10M row visits ≈ 0.5–2 s per save with the write
lock held. Blocks at ~1,000 users with watching in use, or ~100k notifications kept
(500 per user × 200 users reaches that). Fine at 100 users.

**Smallest fix.** An index on `notifications (seq)` (or `seq INTEGER PRIMARY KEY`/rowid, which
is monotonic enough) — one migration. Load only the users who *could* be told: those with a
mark on the page or its ancestor spaces, the page's maker, the thread's commenters and the
mentioned logins (`WHERE user_id IN (...)`), instead of everyone. `pageMaker` via the first
version: `updated_at = pages.created_at` (see finding 9).

### 4. The live hub does one full permission transaction per event per subscriber, serialized through finding 1

**Where.** `Events.hs:269 sending`: for each `Tell page event` it calls `may page` (`:277`) =
`Storage.hs:789 mayReadPage` = `transact st who Reads …`, i.e. a transaction (spaces + grants +
user + groups loaded) per subscriber per event. `Events.hs:149 publish` and `:158 notify` are STM
scans over all connections (fine). `Subscribe` (`:251`) → `Storage.hs:819 threadsThen`, one
transaction per subscription, whose answer carries every thread and comment of the page with
no limit (as does `listThreadsTx:1922` → `Storage/Comments.hs:31 loadThreads`; a comment is up
to 20,000 characters, so a page with 500 comments is a ~1–10 MB answer per subscription);
`StartEditing` (`:262`) → `editorOf`, another transaction. The client (`Live.hs`) reconnects with
a 1 s → 30 s backoff with no jitter.

**What grows with what.** Per published event: O(subscribers) transactions, all through the one
connection. Per server restart: every open tab reconnects within ~1 s and re-subscribes, each a
transaction.

**How bad.** One comment on a page with 100 open tabs = 100 serialized transactions ≈ 100–300 ms
of global lock; 1,000 tabs on a hot page ≈ seconds per comment, and a save that `PageChanged`s
does the same. A restart with 2,000 tabs open is ~2,000 transactions in the first seconds.
Fine at 10 tabs per page.

**Smallest fix.** Check once per distinct `(user, page)` per publish (group the subscribers by
user before enqueueing, or memoize `mayReadPage` per `(who, page)` for the duration of one
`publish`), and run that check on the read connection of finding 1. Add jitter to the client
backoff.

### 5. Search reads and folds every page of the whole wiki per query, on every keystroke

**Where.** `Storage.hs:988 searchPagesTx` → `Rows.hs:502 loadSearchRows`
(`SELECT … search_text FROM pages`, no `WHERE`, every page in the wiki, templates and other
spaces included), then `folded r.node.title`/`folded r.text` for each row per query, then
`Wiki.Core.Search.searchPlain`, which ranks every candidate before `take limit`. The search box
fires after a 150 ms pause (`View/Search.hs:115 pause`). Decision 16 measured "a few ms over
1,000 pages" for the *demo*, where `Mem/State.hs:340 prepare` keeps the fold per version; the
server does not keep the fold.

**What grows with what.** O(total text of the wiki) read from SQLite + decoded + folded, per
query, under the global lock; independent of `space`/`limit`.

**How bad.** 20,000 pages × ~10 KB of text = 200 MB per keystroke: ~0.5–1 s per query
(SQLite read ~200 MB/s, fold ~100–500 MB/s), and every other request waits for it. Fine at
1,000 pages (~10 MB, tens of ms). Blocks at ~10,000 pages, or earlier with several people
typing at once.

**Smallest fix.** The hits need the full `Folded` (its `original`, `shifts` and `length`:
`Search.hs:346 marked` and `:358 snippetOf` slice the original), so the fold cannot simply be
stored in place of the text. Instead: keep `search_text` and add a `search_fold` column written
at save (`foldText` of title and text); match on the fold alone, in SQL (`search_fold LIKE
'%word%'` for each word, with `WHERE space_id IN (…)` from the query's space and `AND template
= 0` when templates are not asked for), and call `folded` on the original only for the hits
that are ranked into the top `limit` (≤ 200), which is what `searchPlain`'s own comment
intends. The per-query fold then costs O(hits) instead of O(wiki). FTS5 remains the answer
past tens of thousands, as decision 16 says.

### 6. The bell locates up to 500 notifications, each with a whole-space node load, on every page view of a signed-in user

**Where.** `Storage.hs:2071 notificationsTx`: `Storage/Notifications.hs:194 loadNotifications`
(every kept notification of the user, up to `keptNotifications` = 500, `Notification.hs:383`), then `locatedTx` (`:2057`) for **each**: `pageNode`
+ `pageNodes` of the page's whole space + a linear `pathOf`; `unread` is counted over all of
them and only then `take maxListed` (50, `Notification.hs:387`). Read by `View/Bell.hs:72` in the initial state, i.e.
in every server render for a signed-in user, and again on every socket reopen.

**What grows with what.** Per page view: O(notifications kept × pages in their spaces).

**How bad.** A user with 500 notifications about pages in a 2,000-page space: 500 × 2,000 =
1M node rows decoded per page view (seconds). With 100 notifications and 200-page spaces it is
20k rows (~20–40 ms) per view — already the single biggest read of a page view for that user.

**Smallest fix.** `SELECT count(*) … WHERE user_id = ? AND read_at IS NULL` for `unread`;
`ORDER BY seq DESC LIMIT 50` before locating; locate with one `pageNodes` per distinct space
(or one indexed query per path segment, finding 8c).

### 7. Sitemap and feeds read the whole public wiki with bodies, per request, uncached, for anonymous crawlers

**Where.** `Feed.hs:162 sitemap`: `listSpaces`, then `listPages s.id` (bodies and attachments)
for **every** space, per request, as `Anonymous`, `Cache-Control: no-cache`, served to anyone at
`/sitemap.xml`. `Feed.hs:119 feed`: `listPages` + `postDetails` (finding 9: every version of
every page in the space) + a Halogen render (`postHtml`, `renderToHtml`) of 20 posts per request.

**What grows with what.** Sitemap: O(all pages × body) per hit. Feed: O(pages in space +
versions in space) per hit.

**How bad.** 20,000 × 20 KB = 400 MB read and decoded per sitemap hit; search engines fetch
sitemaps repeatedly and feed readers poll every few minutes. At 1,000 pages it is 20 MB per
hit, already the most expensive request on the server, holding the global lock.

**Smallest fix.** A node-only query for the sitemap (`id, space_id, parent, slug, updated_at`;
`Rows.hs:252 allPageNodes` is nearly it) and `pageNodes` for feeds, and a per-address cache of
the rendered XML for ~60 s (an `IORef (Map key (UTCTime, Text))`).

### 8. Whole-table or whole-space reads on ordinary page views

a. **`mentionable`** — `Storage.hs:2140 mentionableTx` calls `loadTelling`, i.e. every enabled
   user plus the whole `watches` table (`loadAllMarks`), to answer which of a handful of logins
   are users; asked by `View/Page.hs:221 askPeople` (`View/Body.hs:119`, which first makes a
   `session` transaction of its own) for every page or comment that mentions someone.
   O(users + watches) plus two transactions per view. Fix: `WHERE login IN (…)` (`loadTelling`
   is not needed there at all), and the session the view already has.
b. **`watching`** — `Storage.hs:2098 watchingTx` → `Storage/Notifications.hs:107 loadMarks` →
   `:99 loadAllMarks` (whole table) per watch-button render; plus `pageMaker` (every version of the
   page). Fix: `WHERE user_id = ?` (the unique indexes already exist).
c. **Path resolution** — `Storage.hs:975 getPageTx`, `createPageTx:1343`, `movePageTx:1428/1431`,
   `deletePageTx:1466`, `locatedTx:2064` all load `pageNodes` of the whole space and resolve
   the path with `Path.hs:56 findChild`, a linear scan per segment (`subtreeOf` is
   O(pages × depth)). O(pages in space) per page read or write. 2,000 nodes ≈ 300 KB decoded
   per read (~5 ms); blocks around 20,000 pages in one space. The unique index
   `pages_sibling_slug (space_id, coalesce(parent,''), slug)` exists already, so `Path.hs:87 resolvePathM`
   with one indexed query per segment is a drop-in replacement; `subtreeOf` can be a recursive
   CTE on `pages_parent`.
d. **Attachments revalidate through a transaction each** — `Api.hs:891 attachmentContent` runs
   `Storage.hs:853 attachmentFile` (a `transact Reads`, so spaces + grants loaded) per fetch,
   and answers `Cache-Control: private, no-cache`, so every image on every page view is a DB
   hold, even for a 304. A page with 30 images = 30 serialized transactions per view. Fix:
   `private, max-age=300` (the ETag is the content hash) or a direct
   `SELECT … FROM attachments JOIN pages` + one `canView` without the full context.
e. **`pageCounts`** — `Storage.hs:931` is a `GROUP BY space_id` over every page row per Home view
   (`template = 0` forces row reads). ~20–50 ms at 100k pages. Fix: an index on
   `pages (space_id, template)` makes it a covering index scan, or cache it with finding 1's
   spaces cache.
f. **`loadGroupsOf`** — `Rows.hs:344`, by `user_id`, which is the second column of the
   `group_members` PK, so it is a scan of the table per transaction of a signed-in user. One
   index, `group_members (user_id)`.

### 9. History: every version of every page is read to find first authors; version lists are unbounded; versions only grow

**Where.** `Storage.hs:960 postDetailsTx` → `Rows.hs:463 loadSpaceVersions` (every version row
of every page in the space, without bodies) per blog listing, per feed request, per `Posts`
page view; `Storage/Notifications.hs:93 pageMaker` → `loadVersions` (all versions of the page)
per save (finding 3) and per watch query. `Storage.hs:1556 listVersionsTx` returns the whole
history with no limit. `page_versions` keeps a full body per save (`insertVersion`) and
nothing prunes it; drafts are bounded (`INSERT OR REPLACE`), versions are not.

**How bad.** 2,000 pages × 20 versions = 40k rows per blog listing (~50–100 ms). A page saved
10,000 times is a 10,000-row history answer, and 200 MB of versions on disk and in every backup.

**Smallest fix.** The first version has `updated_at = pages.created_at`, so one join
(`JOIN page_versions v ON v.page_id = p.id AND v.updated_at = p.created_at`) replaces both
`loadSpaceVersions` and `pageMaker`. `LIMIT`/`before` paging on `listVersions`.

### 10. Whole-wiki export and import live in memory, and freeze the server

**Where.** `Storage.hs:2211 exportArchive`: `loadAllPages` (every body), then `readBlob`
(`Blobs.hs:65`, `BS.readFile`) of **every** attachment into memory, then `Api.hs:486`
`zipFiles` into one strict `ByteString` served as `responseLBS`. `Api.hs:492–500`: the import
archive is a strict `ByteString` up to `maxImportSize`, `unzipFiles` in memory, then
`Import.hs:223 applyImport` in one transaction under the global lock. `Api.hs:233 uploadOptions`
uses the `Mem` multipart backend: a 50 MB attachment is 50 MB of RAM per concurrent upload
(and `storeBlob` hashes it after).

**How bad.** A wiki with 5 GB of attachments cannot be exported (the process needs > 5 GB, likely
twice that for the zip); an import of that size holds the lock for minutes. 20 concurrent
50 MB uploads = 1 GB RAM. Administrator-only for export/import, so not a user-count problem,
but a hard ceiling on wiki size.

**Smallest fix.** Stream the export: write the zip to a temporary file entry by entry (the
blobs copied from disk) and answer with `responseFile`; or leave blobs out of the archive and
let `restore`/`copyOffSite` carry `attachments/` as the backups already do. Multipart `Tmp`
backend for uploads with the hash computed while streaming.

### 11. The audit log's actor list is a full scan with a correlated subquery per row, on every Activity page; paging is by OFFSET

**Where.** `Storage/Audit.hs:121` (in `loadActivity`, `:113`): `SELECT actor_id, actor_login FROM audit_log a
WHERE at = (SELECT max(at) FROM audit_log b WHERE b.actor_id = a.actor_id) GROUP BY actor_id`
runs for every Activity page view: the outer query visits every row (the subquery is indexed by
`audit_log_actor`, so O(N log N)). `OFFSET ?` paging is O(offset) per page. The log only grows
(every grant, group, account, settings, deletion, import), with no pruning.

**How bad.** 1M entries → ~1 s per Activity view; page 100 of the log scans 5,000 rows first.
Fine at 10k entries.

**Smallest fix.** `SELECT actor_id, actor_login, max(at) FROM audit_log GROUP BY actor_id`
(SQLite's bare-column rule returns the login of the max row, and uses `audit_log_actor`);
keyset paging on `(at, id)` instead of `OFFSET`.

### 12. Metrics scrape stats every blob file

**Where.** `Health.hs:66 metricSamples`: `storedBlobs` (`Blobs.hs:71`, `listDirectory` of every
shard) and `getFileSize` of **every** blob, on every `/metrics` scrape (Prometheus scrapes every
15–60 s). O(attachments) syscalls per scrape; 100k blobs ≈ 0.3–1 s per scrape. Admin listener
only. Fix: `SELECT count(*), sum(size) FROM attachments` (the table has `size`), or cache the
directory walk for an hour.

### 13. Demo (IndexedDB) loads everything at start and re-encodes everything on every write

**Where.** `Backend/Mem.hs:377 openMemWiki` (`:380 readAll`): `IDB.getAll` on **every** store at each page load,
`attachmentsStore` (every attachment's bytes) and `versionsStore` (every version's full body)
included. `Mem/Persist.hs:156 records` re-encodes every user, group, space, page (with body),
thread and notification record to JSON on **every** write (versions are lazy, nothing else is),
and `:295 changes` diffs all of it; the editor autosaves a draft every 2–4 s while typing
(`View/Editor.hs:526 draftDelay`).

**How bad.** A demo with 500 pages × 20 KB and 50 MB of attachments reads 60 MB from IndexedDB
on every load and encodes 10 MB of JSON every 2 s while someone types. Blocks around 1,000
pages or a few hundred MB of attachments. Demo-only.

**Smallest fix.** Read `attachmentsStore` lazily (per blob when first shown; the comment at
`Persist.hs:324` already intends object URLs on demand) and `versionsStore` on first history
view; have the write path hand `changes` only the stores a write touched (the `Saved`/write
functions in `Mem/State.hs` know which), or make all of `records` lazy as versions are.

### 14. Accepted by decision 22, with numbers

`Storage.hs:1126 spaceAccessTx` and `:1599 directoryTx` return every user and group (plus
memberships, flags, identities, emails) per view. ~100 B per user: 10,000 users ≈ 1 MB per
space-permissions view and a list the browser renders whole. Fine to ~2,000 users; a search
box with `LIMIT` past that, as the decision foresees.

## Things checked that are fine

- Downloads: `app.wasm` 10.9 MB raw / ~3.6 MB gzipped (brotli smaller), `islands.js` 577 KB /
  183 KB gz, `style.css` 90 KB / 20 KB gz, served with ETags and precompressed siblings
  (`Static.hs send`); `tikzjax/` (9.4 MB) is fetched only by a page with a TikZ picture
  (`web/src/tikz.js`). The service worker precaches once and is bounded (`sw.js`: 50 pages,
  300 answers, images ≤ 1 MB). Per-user, one-time: fine. The only download that grows is the
  prerendered page itself (finding 2).
- Attachments and icons are streamed from disk with `responseFile`, ranges and ETags
  (`Api.hs:891`), never read into memory to serve (only to export, finding 10).
- Sessions: one indexed read per request (`sessions.id_hash` PK), a write at most once a minute
  per session (`Accounts.hs:576 seenEvery`), expired sessions deleted on sign-in. Fine to tens
  of thousands of sessions; the only cost is going through finding 1's lock.
- In-memory maps are bounded: `Limiter.hs maxKeys` 10,000, `Oidc.hs:598 maxFlows` 10,000,
  `SecondFactor.hs:214 maxPending` 10,000, the hub's outbox 256 per connection, the error ring in `Log.hs`,
  `Metrics` keyed by route pattern, not address.
- `threads`/`comments` `nextSeq` (`Storage/Comments.hs`) uses the `(page_id, seq)` /
  `(thread_id, seq)` indexes; `loadThreads` is two indexed queries per page. Fine.
- `audit_log` has the indexes its own paging needs; `insertAudit` is O(1).
- Notification mail: one user at a time, outside any transaction (`Notifier.hs`); a slow SMTP
  delays the next user's mail, not requests. `pruneNotifications` loads every row's id into
  Haskell once a day (`Storage/Notifications.hs:234`) — wasteful, not blocking.
- Exports of documents: one per person, 60 s timeout (`Export.hs:227 oneAtATime`); a space
  export reads the space's pages and images into pandoc's media bag in memory (`mediaOf`), which
  is bounded by the one-at-a-time rule, not by wiki size — a 2,000-page space with 1 GB of images
  would still need that much RAM, but only an administrator would ask.
- `statusOfServer`/`metrics` `count(*)` per table: SQLite walks the smallest index, ~ms at 1M rows.

## Suggested order of work

1. Finding 1 (read connections; the backup off the request path) — it multiplies every other.
2. Finding 2 together with the `listPages` fix already under way (summaries + `getPage`, and the preload).
3. Finding 3 (`notifications (seq)` index — one migration — then scoping `tellTx`'s loads) and
   finding 6 (`LIMIT 50` before locating, `count` for unread).
4. Finding 4 (one permission check per user per publish; jittered reconnect).
5. Finding 5 (store the folded text; filter by space in SQL) and finding 7 (node-only sitemap,
   cached feeds).
6. Findings 8, 9, 11: indexed path resolution, `WHERE user_id = ?`/`WHERE login IN`, the
   first-version join, the actor query, attachment `max-age`.
7. Findings 10, 12, 13 as wiki size or the demo's content demands.
