// Whether this origin has an IndexedDB database of a name, asked without
// making it (Wiki.App.Backend.Mem's memWikiFound): opening a database that
// is not there makes it, so the server's administration, which offers the
// demo's data only where the demo left some, must not open it to find out.
// indexedDB.databases() lists the origin's databases and opens none; every
// browser the wiki supports has it (Firefox since 126). Where it fails, the
// answer is that there is none.
async function wiki_database_exists(name) {
  if (typeof indexedDB === "undefined") return false;
  try {
    return (await indexedDB.databases()).some((database) => database.name === name);
  } catch {
    return false;
  }
}
